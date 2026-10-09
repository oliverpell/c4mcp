-- TCP/TLS → HTTP → Auth → MCP Wiring Module
-- Connects Layer 1 (HTTP), Layer 2 (MCP), and auth together via TCP or TLS server

local http_server = require("modules.http_server")

local M = {}

-- Hard cap on how long any socket may stay open before completing a request.
-- Independent of the Idle Timeout property so the default install is protected:
-- an unauthenticated socket (idle-hold or slow-loris) is closed within this
-- window and cannot hold a connection slot. MCP payloads are small, so this is
-- generous for legitimate clients.
local UNAUTH_TIMEOUT = 5           -- seconds

-- Listen retry after a bind error: every second, then give up and leave it to
-- the driver's watchdog (which restarts a server that is no longer retrying).
M.LISTEN_RETRY_MS = 1000
local MAX_RETRIES = 60

--- Pick the socket to close when the server is full: the oldest socket of the
--- IP holding the most open sockets, so a flood mostly evicts its own sockets
--- rather than a real client's.
-- @param clients table {[key] = {seq=n, ip=string, ...}}
-- @return any key of the socket to close, or nil if none
local function choose_eviction(clients)
    local per_ip = {}
    for _, state in pairs(clients) do
        per_ip[state.ip] = (per_ip[state.ip] or 0) + 1
    end
    local pick_key, pick_count, pick_seq = nil, -1, nil
    for key, state in pairs(clients) do
        local count = per_ip[state.ip]
        if count > pick_count or (count == pick_count and state.seq < pick_seq) then
            pick_key, pick_count, pick_seq = key, count, state.seq
        end
    end
    return pick_key
end


--- Drop entries older than `window` seconds from a timestamp array (in place).
-- @return number remaining count
local function prune_window(times, now, window)
    local j = 1
    for i = 1, #times do
        if times[i] >= now - window then
            times[j] = times[i]
            j = j + 1
        end
    end
    for i = j, #times do times[i] = nil end
    return j - 1
end

--- Record "now" against a keyed sliding window; return true if it would exceed max.
-- The window lives in `bucket[key]`, so it is shared across connections from the
-- same key (source IP) — unlike the old per-connection counter, which a client
-- bypassed by opening a fresh connection per request.
local function exceeds(bucket, key, max, window)
    if not max or max <= 0 then return false end
    bucket[key] = bucket[key] or {}
    local times = bucket[key]
    local now = os.time()
    if prune_window(times, now, window) >= max then
        return true
    end
    times[#times + 1] = now
    return false
end

--- Process a complete HTTP request and produce a response.
-- Shared by both TCP and TLS server paths.
-- @param request table Parsed HTTP request {method, path, headers, body, error}
-- @param ctx table {
--   ip            source IP string (for per-IP limits),
--   shared        handle-level {unauth={}} per-IP window table,
--   send_fn       function(data),
--   close_fn      function(),
--   mcp           MCP server instance,
--   validator     auth validator or nil,
--   max_rps       max unauthenticated requests/sec per IP,
-- }
--
-- Only UNauthenticated / bad-auth requests are rate limited, per source IP and
-- shared across that IP's connections (so opening a fresh connection per request
-- no longer bypasses the limit). Authenticated requests are not throttled: the
-- key holder is trusted, and the MCP client legitimately bursts several requests
-- per call (initialize + notify + call), which a hard cap would break.
local function process_request(request, ctx)
    if request.error then
        ctx.send_fn(http_server.format_error_response(400, request.error))
        ctx.close_fn()
        return
    end

    if request.path ~= "/mcp" then
        ctx.send_fn(http_server.format_error_response(404, "Not Found"))
        ctx.close_fn()
        return
    end

    if request.method ~= "POST" then
        ctx.send_fn(http_server.format_error_response(405, "Method Not Allowed"))
        ctx.close_fn()
        return
    end

    local caller = nil
    if ctx.validator then
        local auth_result = ctx.validator:check(request.headers)
        if not auth_result.ok then
            -- Per-IP throttle of failed/unauthenticated attempts: bounds online
            -- key-guessing and unauthenticated request floods across connections.
            if exceeds(ctx.shared.unauth, ctx.ip, ctx.max_rps, 1) then
                ctx.send_fn(http_server.format_error_response(429, "Too Many Requests"))
            else
                ctx.send_fn(http_server.format_json_response(401, auth_result.body))
            end
            ctx.close_fn()
            return
        end
        caller = auth_result.caller
    end

    local response_json = ctx.mcp:handle_message(request.body, caller)
    if response_json then
        ctx.send_fn(http_server.format_response(200, "OK", {
            ["Content-Type"] = "application/json",
        }, response_json))
    else
        ctx.send_fn(http_server.format_response(202, "Accepted", {
            ["Content-Type"] = "application/json",
        }, ""))
    end
    ctx.close_fn()
end

--- Effective per-socket deadline: never longer than UNAUTH_TIMEOUT, but a
--- smaller Idle Timeout still shortens it. 0 ("disabled") falls back to the cap.
local function socket_deadline(idle_timeout)
    local base = (idle_timeout and idle_timeout > 0) and idle_timeout or UNAUTH_TIMEOUT
    return math.min(base, UNAUTH_TIMEOUT)
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
    local idle_timeout = opts.idle_timeout or 300  -- seconds
    local max_rps = opts.max_rps or 30
    local deadline = socket_deadline(idle_timeout)

    local on_connection_change = opts.on_connection_change

    local handle = {
        _server = nil,
        _clients = {},
        _deadline_timers = {},
        _retry_count = 0,
        _validator = validator,
        _transport = "HTTP",
        _listening = false,
        _stopped = false,
        _shared = { unauth = {} },
        _seq = 0,               -- accept counter, to find the oldest socket
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

    local function remote_ip(client)
        local ok, addr = pcall(function() return client:GetRemoteAddress() end)
        if ok and type(addr) == "table" and addr.ip then return addr.ip end
        return "unknown"
    end

    local function close_client(c)
        local timer = handle._deadline_timers[c]
        if timer then timer:Cancel() end
        handle._deadline_timers[c] = nil
        handle._clients[c] = nil
        c:Close()
        notify_connection_change()
    end

    --- Start the (non-resettable) deadline timer that closes a socket if it has
    --- not completed a request in time. Not reset on read, so a slow-loris
    --- client cannot extend it by trickling bytes.
    local function start_deadline(client)
        if deadline <= 0 then return end
        handle._deadline_timers[client] = C4:SetTimer(deadline * 1000, function()
            close_client(client)
        end, false)
    end

    --- Create and start a TCP server instance
    local function create_and_listen()
        if handle._server then
            pcall(function() handle._server:Close() end)
        end

        local tcp_server = C4:CreateTCPServer()
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
                if handle._retry_count < MAX_RETRIES then
                    handle._retry_count = handle._retry_count + 1
                    local delay = M.LISTEN_RETRY_MS
                    C4:ErrorLog("[c4mcp] Retrying listen in " .. tostring(delay/1000) .. "s (attempt " .. handle._retry_count .. "/" .. MAX_RETRIES .. ")...")
                    C4:SetTimer(delay, function()
                        if handle._stopped then return end
                        create_and_listen()
                    end, false)
                else
                    C4:ErrorLog("[c4mcp] Server failed after " .. MAX_RETRIES .. " retries — restart driver to recover")
                end
            end)
            :OnAccept(function(_, client)
                -- Full: make room by closing the oldest socket of the IP holding the
                -- most sockets. Every open socket is still waiting for its one request
                -- (a socket closes as soon as it is answered) and a real client sends
                -- within milliseconds, so sockets held to exhaust the limit go first.
                if handle:get_client_count() >= max_connections then
                    local victim = choose_eviction(handle._clients)
                    if victim then close_client(victim) end
                end

                local parser = http_server.create_parser()
                handle._seq = handle._seq + 1
                handle._clients[client] = { parser = parser, ip = remote_ip(client), seq = handle._seq }
                notify_connection_change()
                start_deadline(client)

                client:OnRead(function(c, data)
                    local ok, err = pcall(function()
                        local request = parser:feed(data)
                        if not request then
                            c:ReadUpTo(8192)
                            return
                        end

                        local client_state = handle._clients[c]
                        process_request(request, {
                            ip = client_state and client_state.ip or "unknown",
                            shared = handle._shared,
                            send_fn = function(resp) c:Write(resp) end,
                            close_fn = function() close_client(c) end,
                            mcp = mcp,
                            validator = handle._validator,
                            max_rps = max_rps,
                        })
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
                    local timer = handle._deadline_timers[c]
                    if timer then timer:Cancel() end
                    handle._deadline_timers[c] = nil
                    handle._clients[c] = nil
                    notify_connection_change()
                end)

                client:OnError(function(_, code, msg)
                    C4:ErrorLog("[c4mcp] Client error: " .. tostring(code) .. " - " .. tostring(msg))
                end)

                client:ReadUpTo(8192)
                return true
            end)
            -- The server closes each connection after answering, leaving the
            -- controller's side in TIME_WAIT for ~60 s; without reuseaddr a restart
            -- cannot bind the port again until those expire ("Address already in use").
            :Option("reuseaddr", true)
            :Listen("*", port)
    end

    create_and_listen()

    function handle:purge_clients()
        for client, _ in pairs(self._clients) do
            pcall(function() client:Close() end)
        end
        self._clients = {}
        for _, timer in pairs(self._deadline_timers) do
            timer:Cancel()
        end
        self._deadline_timers = {}
        notify_connection_change()
    end

    function handle:set_validator(new_validator)
        self._validator = new_validator
    end

    function handle:is_alive()
        return self._listening and not self._stopped
    end

    --- Still retrying a failed listen? The watchdog leaves such a server alone.
    function handle:is_retrying()
        return not self._listening and not self._stopped and (self._retry_count or 0) > 0
            and self._retry_count < MAX_RETRIES
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
    local deadline = socket_deadline(idle_timeout)
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
        _clients = {},         -- {[nHandle] = {parser, ip}}
        _deadline_timers = {}, -- {[nHandle] = timer}
        _stopped = false,
        _listening = false,
        _validator = validator,
        _transport = "HTTPS",
        _port = port,
        _identifier = tls_identifier,
        _shared = { unauth = {} },
        _seq = 0,              -- accept counter, to find the oldest socket
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

    local function close_client(nHandle)
        local timer = handle._deadline_timers[nHandle]
        if timer then timer:Cancel() end
        handle._deadline_timers[nHandle] = nil
        handle._clients[nHandle] = nil
        pcall(C4.ServerCloseClient, C4, nHandle)
        notify_connection_change()
    end

    local function start_deadline(nHandle)
        if deadline <= 0 then return end
        handle._deadline_timers[nHandle] = C4:SetTimer(deadline * 1000, function()
            close_client(nHandle)
        end, false)
    end

    -- Install global callbacks for TLS server events.
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
            -- Full: close the oldest socket of the busiest IP (see the TCP server)
            if handle:get_client_count() >= max_connections then
                local victim = choose_eviction(handle._clients)
                if victim then close_client(victim) end
            end
            handle._seq = handle._seq + 1
            handle._clients[nHandle] = {
                parser = http_server.create_parser(),
                ip = (address and address ~= "") and address or "unknown",
                seq = handle._seq,
            }
            notify_connection_change()
            start_deadline(nHandle)
        else
            close_client(nHandle)
        end
    end

    function OnServerDataIn(nHandle, strData, address, nPort, identifier)
        if identifier ~= tls_identifier then return end
        if handle._stopped then return end

        local client_state = handle._clients[nHandle]
        if not client_state then return end

        local ok, err = pcall(function()
            local request = client_state.parser:feed(strData)
            if not request then return end  -- need more data

            process_request(request, {
                ip = client_state.ip or "unknown",
                shared = handle._shared,
                send_fn = function(resp) C4:ServerSend(nHandle, resp) end,
                close_fn = function() close_client(nHandle) end,
                mcp = mcp,
                validator = handle._validator,
                max_rps = max_rps,
            })
        end)
        if not ok then
            C4:ErrorLog("[c4mcp] TLS OnServerDataIn error: " .. tostring(err))
            pcall(function()
                C4:ServerSend(nHandle, http_server.format_error_response(500, "Internal Server Error"))
                close_client(nHandle)
            end)
        end
    end

    if not C4.CreateTLSServer then
        return nil, "C4:CreateTLSServer not available (requires OS 3.3.0+)"
    end

    -- TLS options: 0x003D = DEFAULT_WORKAROUNDS | NO_SSLv2 | NO_SSLv3 | NO_TLSv1 | NO_TLSv1_1
    -- Verify mode: 0x01 = SSL_VERIFY_NONE (clients authenticate via bearer token, not cert)
    local call_ok, tls_ok, tls_err = pcall(C4.CreateTLSServer, C4,
        port,
        "",
        0x003D,
        0x01,
        "",
        cert_pem,
        key_pem,
        "",
        "",
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
        for _, timer in pairs(self._deadline_timers) do
            timer:Cancel()
        end
        self._deadline_timers = {}
        notify_connection_change()
    end

    function handle:set_validator(new_validator)
        self._validator = new_validator
    end

    function handle:is_alive()
        return self._listening and not self._stopped
    end

    --- Still retrying a failed listen? The watchdog leaves such a server alone.
    function handle:is_retrying()
        return not self._listening and not self._stopped and (self._retry_count or 0) > 0
            and self._retry_count < MAX_RETRIES
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
