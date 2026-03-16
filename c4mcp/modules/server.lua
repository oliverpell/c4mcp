-- TCP/TLS → HTTP → Auth → MCP Wiring Module
-- Connects Layer 1 (HTTP), Layer 2 (MCP), and auth together via TCP or TLS server

local http_server = require("modules.http_server")

local M = {}

--- Check if a client exceeds the rate limit (sliding window)
-- @param client_state table with .request_times array
-- @param max_rps number max requests per second
-- @return boolean true if rate limited
local function is_rate_limited(client_state, max_rps)
    if not max_rps or max_rps <= 0 then return false end
    local now = os.time()
    local times = client_state.request_times
    -- Purge entries older than 1 second
    local j = 1
    for i = 1, #times do
        if times[i] >= now - 1 then
            times[j] = times[i]
            j = j + 1
        end
    end
    for i = j, #times do times[i] = nil end
    -- Check limit
    if #times >= max_rps then return true end
    times[#times + 1] = now
    return false
end

--- Process a complete HTTP request and produce a response
-- Shared by both TCP and TLS server paths
-- @param request table Parsed HTTP request {method, path, headers, body, error}
-- @param client_state table {request_times} for rate limiting
-- @param send_fn function(data) Send response data
-- @param close_fn function() Close the connection
-- @param mcp table MCP server instance
-- @param validator table|nil Auth validator
-- @param max_rps number Max requests per second
local function process_request(request, client_state, send_fn, close_fn, mcp, validator, max_rps)
    if request.error then
        send_fn(http_server.format_error_response(400, request.error))
        close_fn()
        return
    end

    if request.path ~= "/mcp" then
        send_fn(http_server.format_error_response(404, "Not Found"))
        close_fn()
        return
    end

    if request.method ~= "POST" then
        send_fn(http_server.format_error_response(405, "Method Not Allowed"))
        close_fn()
        return
    end

    if client_state and is_rate_limited(client_state, max_rps) then
        send_fn(http_server.format_error_response(429, "Too Many Requests"))
        close_fn()
        return
    end

    if validator then
        local auth_result = validator:check(request.headers)
        if not auth_result.ok then
            send_fn(http_server.format_json_response(401, auth_result.body))
            close_fn()
            return
        end
    end

    local response_json = mcp:handle_message(request.body)
    if response_json then
        send_fn(http_server.format_response(200, "OK", {
            ["Content-Type"] = "application/json",
        }, response_json))
    else
        send_fn(http_server.format_response(202, "Accepted", {
            ["Content-Type"] = "application/json",
        }, ""))
    end
    close_fn()
end

--------------------------------------------------------------------------------
-- TCP Server (HTTP, uses C4:CreateTCPServer chained API)
--------------------------------------------------------------------------------

--- Start the MCP server on a plain TCP port (HTTP)
-- @param opts table {port, mcp_server, auth_validator, max_connections, idle_timeout, max_rps}
-- @return table Server handle with :stop() method
function M.start_server(opts)
    opts = opts or {}
    local port = opts.port or 9201
    local mcp = opts.mcp_server
    local validator = opts.auth_validator
    local max_connections = opts.max_connections or 5
    local idle_timeout = opts.idle_timeout or 300  -- seconds, 0 = disabled
    local max_rps = opts.max_rps or 30

    local on_connection_change = opts.on_connection_change

    local handle = {
        _server = nil,
        _clients = {},
        _idle_timers = {},
        _retry_count = 0,
        _validator = validator,
        _transport = "HTTP",
        _listening = false,
        _stopped = false,
    }

    function handle:get_client_count()
        local count = 0
        for _ in pairs(self._clients) do count = count + 1 end
        return count
    end

    local function notify_connection_change()
        if on_connection_change then
            on_connection_change(handle:get_client_count())
        end
    end

    --- Reset or start the idle timer for a client
    local function reset_idle_timer(client)
        if idle_timeout <= 0 then return end
        local old_timer = handle._idle_timers[client]
        if old_timer then
            old_timer:Cancel()
        end
        handle._idle_timers[client] = C4:SetTimer(idle_timeout * 1000, function()
            handle._idle_timers[client] = nil
            handle._clients[client] = nil
            client:Close()
            notify_connection_change()
        end, false)
    end

    --- Create and start a TCP server instance
    local function create_and_listen()
        if handle._server then
            pcall(function() handle._server:Close() end)
        end

        local tcp_server = C4:CreateTCPServer()
        -- Store reference immediately to prevent GC
        handle._server = tcp_server
        tcp_server:OnResolve(function()
                return 1
            end)
            :OnListen(function()
                handle._listening = true
                handle._retry_count = 0
                C4:ErrorLog("[c4mcp] TCP server listening on port " .. tostring(port))
            end)
            :OnError(function(_, code, msg)
                handle._listening = false
                if handle._stopped then return end
                C4:ErrorLog("[c4mcp] Server error: " .. tostring(code) .. " - " .. tostring(msg))
                if handle._retry_count < 10 then
                    handle._retry_count = handle._retry_count + 1
                    -- Exponential backoff: 3s, 6s, 12s, 24s, ... capped at 60s
                    local delay = math.min(3000 * (2 ^ (handle._retry_count - 1)), 60000)
                    C4:ErrorLog("[c4mcp] Retrying listen in " .. tostring(delay/1000) .. "s (attempt " .. handle._retry_count .. "/10)...")
                    C4:SetTimer(delay, function()
                        if handle._stopped then return end
                        create_and_listen()
                    end, false)
                else
                    C4:ErrorLog("[c4mcp] Server failed after 10 retries — restart driver to recover")
                end
            end)
            :OnAccept(function(_, client)
                C4:ErrorLog("[c4mcp] OnAccept: new connection")
                local count = 0
                for _ in pairs(handle._clients) do count = count + 1 end
                if count >= max_connections then
                    client:Write(http_server.format_error_response(429, "Too many connections"))
                    client:Close()
                    return true
                end

                local parser = http_server.create_parser()
                handle._clients[client] = { parser = parser, request_times = {} }
                notify_connection_change()

                reset_idle_timer(client)

                local function close_client(c)
                    local timer = handle._idle_timers[c]
                    if timer then timer:Cancel() end
                    handle._idle_timers[c] = nil
                    handle._clients[c] = nil
                    c:Close()
                    notify_connection_change()
                end

                client:OnRead(function(c, data)
                    local ok, err = pcall(function()
                        reset_idle_timer(c)

                        local request = parser:feed(data)
                        if not request then
                            c:ReadUpTo(8192)
                            return
                        end

                        local client_state = handle._clients[c]
                        process_request(request, client_state,
                            function(resp) c:Write(resp) end,
                            function() close_client(c) end,
                            mcp, handle._validator, max_rps)
                    end)
                    if not ok then
                        C4:ErrorLog("[c4mcp] OnRead error: " .. tostring(err))
                        pcall(function()
                            c:Write(http_server.format_error_response(500, "Internal Server Error"))
                            close_client(c)
                        end)
                    end
                end)

                client:OnDisconnect(function(c)
                    local timer = handle._idle_timers[c]
                    if timer then timer:Cancel() end
                    handle._idle_timers[c] = nil
                    handle._clients[c] = nil
                    notify_connection_change()
                end)

                client:OnError(function(_, code, msg)
                    C4:ErrorLog("[c4mcp] Client error: " .. tostring(code) .. " - " .. tostring(msg))
                end)

                client:ReadUpTo(8192)
                return true
            end)
            :Listen("*", port)
    end

    create_and_listen()

    function handle:purge_clients()
        for client, _ in pairs(self._clients) do
            pcall(function() client:Close() end)
        end
        self._clients = {}
        for _, timer in pairs(self._idle_timers) do
            timer:Cancel()
        end
        self._idle_timers = {}
        notify_connection_change()
    end

    function handle:set_validator(new_validator)
        self._validator = new_validator
    end

    function handle:is_alive()
        return self._listening and not self._stopped
    end

    function handle:stop()
        if self._stopped then return end
        self._stopped = true
        self._listening = false
        self:purge_clients()
        if self._server then
            self._server:Close()
        end
    end

    return handle
end

--------------------------------------------------------------------------------
-- TLS Server (HTTPS, uses C4:CreateTLSServer callback API, OS 3.3.0+)
--------------------------------------------------------------------------------

local _tls_generation = 0

--- Start the MCP server with TLS (HTTPS)
-- @param opts table {port, mcp_server, auth_validator, max_connections, idle_timeout, max_rps, certificate, private_key}
-- @return table Server handle with :stop() method, or nil + error
function M.start_tls_server(opts)
    opts = opts or {}
    local port = opts.port or 9201
    local mcp = opts.mcp_server
    local validator = opts.auth_validator
    local max_connections = opts.max_connections or 5
    local idle_timeout = opts.idle_timeout or 300
    local max_rps = opts.max_rps or 30
    local cert_pem = opts.certificate
    local key_pem = opts.private_key

    if not cert_pem or cert_pem == "" then
        return nil, "TLS certificate is required"
    end
    if not key_pem or key_pem == "" then
        return nil, "TLS private key is required"
    end

    _tls_generation = _tls_generation + 1
    local tls_identifier = "c4mcp_tls_" .. _tls_generation

    local on_connection_change = opts.on_connection_change

    local handle = {
        _clients = {},       -- {[nHandle] = {parser, request_times}}
        _idle_timers = {},   -- {[nHandle] = timer}
        _stopped = false,
        _listening = false,
        _validator = validator,
        _transport = "HTTPS",
        _port = port,
        _identifier = tls_identifier,
    }

    function handle:get_client_count()
        local count = 0
        for _ in pairs(self._clients) do count = count + 1 end
        return count
    end

    local function notify_connection_change()
        if on_connection_change then
            on_connection_change(handle:get_client_count())
        end
    end

    local function reset_idle_timer(nHandle)
        if idle_timeout <= 0 then return end
        local old_timer = handle._idle_timers[nHandle]
        if old_timer then old_timer:Cancel() end
        handle._idle_timers[nHandle] = C4:SetTimer(idle_timeout * 1000, function()
            handle._idle_timers[nHandle] = nil
            handle._clients[nHandle] = nil
            pcall(C4.ServerCloseClient, C4, nHandle)
            notify_connection_change()
        end, false)
    end

    local function close_client(nHandle)
        local timer = handle._idle_timers[nHandle]
        if timer then timer:Cancel() end
        handle._idle_timers[nHandle] = nil
        handle._clients[nHandle] = nil
        pcall(C4.ServerCloseClient, C4, nHandle)
        notify_connection_change()
    end

    -- Install global callbacks for TLS server events
    -- These are called by the C4 runtime; identifier distinguishes our server
    function OnServerStatusChanged(nPort, strStatus, identifier)
        if identifier ~= tls_identifier then return end
        if strStatus == "ONLINE" then
            handle._listening = true
        elseif strStatus == "OFFLINE" then
            handle._listening = false
        end
        C4:ErrorLog("[c4mcp] TLS server " .. tostring(strStatus) .. " on port " .. tostring(nPort))
    end

    function OnServerConnectionStatusChanged(nHandle, nPort, strStatus, address, identifier)
        if identifier ~= tls_identifier then return end
        if handle._stopped then return end

        if strStatus == "ONLINE" then
            local count = 0
            for _ in pairs(handle._clients) do count = count + 1 end
            if count >= max_connections then
                C4:ServerSend(nHandle, http_server.format_error_response(429, "Too many connections"))
                pcall(C4.ServerCloseClient, C4, nHandle)
                return
            end
            handle._clients[nHandle] = { parser = http_server.create_parser(), request_times = {} }
            notify_connection_change()
            reset_idle_timer(nHandle)
        else
            -- OFFLINE
            local timer = handle._idle_timers[nHandle]
            if timer then timer:Cancel() end
            handle._idle_timers[nHandle] = nil
            handle._clients[nHandle] = nil
            notify_connection_change()
        end
    end

    function OnServerDataIn(nHandle, strData, address, nPort, identifier)
        if identifier ~= tls_identifier then return end
        if handle._stopped then return end

        local client_state = handle._clients[nHandle]
        if not client_state then return end

        local ok, err = pcall(function()
            reset_idle_timer(nHandle)

            local request = client_state.parser:feed(strData)
            if not request then return end  -- need more data

            process_request(request, client_state,
                function(resp) C4:ServerSend(nHandle, resp) end,
                function() close_client(nHandle) end,
                mcp, handle._validator, max_rps)
        end)
        if not ok then
            C4:ErrorLog("[c4mcp] TLS OnServerDataIn error: " .. tostring(err))
            pcall(function()
                C4:ServerSend(nHandle, http_server.format_error_response(500, "Internal Server Error"))
                close_client(nHandle)
            end)
        end
    end

    -- Check that CreateTLSServer API exists (requires OS 3.3.0+)
    if not C4.CreateTLSServer then
        return nil, "C4:CreateTLSServer not available (requires OS 3.3.0+)"
    end

    -- TLS options: 0x003D = DEFAULT_WORKAROUNDS | NO_SSLv2 | NO_SSLv3 | NO_TLSv1 | NO_TLSv1_1
    -- Verify mode: 0x01 = SSL_VERIFY_NONE (no client certificate required)
    local call_ok, tls_ok, tls_err = pcall(C4.CreateTLSServer, C4,
        port,
        "",              -- no delimiter (we parse HTTP ourselves)
        0x003D,          -- TLSv1.2+ only
        0x01,            -- no client cert verification
        "",              -- default cipher list
        cert_pem,
        key_pem,
        "",              -- no password
        "",              -- no chain
        tls_identifier
    )

    if not call_ok then
        C4:ErrorLog("[c4mcp] CreateTLSServer threw error: " .. tostring(tls_ok))
        pcall(C4.DestroyServer, C4, port)
        return nil, "CreateTLSServer error: " .. tostring(tls_ok)
    end

    if not tls_ok then
        C4:ErrorLog("[c4mcp] Failed to create TLS server: " .. tostring(tls_err))
        pcall(C4.DestroyServer, C4, port)
        return nil, "Failed to create TLS server: " .. tostring(tls_err)
    end

    function handle:purge_clients()
        for h, _ in pairs(self._clients) do
            pcall(C4.ServerCloseClient, C4, h)
        end
        self._clients = {}
        for _, timer in pairs(self._idle_timers) do
            timer:Cancel()
        end
        self._idle_timers = {}
        notify_connection_change()
    end

    function handle:set_validator(new_validator)
        self._validator = new_validator
    end

    function handle:is_alive()
        return self._listening and not self._stopped
    end

    function handle:stop()
        if self._stopped then return end
        self._stopped = true
        self._listening = false
        self:purge_clients()
        pcall(C4.DestroyServer, C4, self._port)
    end

    return handle
end

return M
