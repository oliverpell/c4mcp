-- C4 MCP Server Driver
-- Exposes Control4 smart home via Model Context Protocol (MCP) over HTTP


local c4_home = require("modules.c4_home")
local control_mod = require("modules.control")
local c4_media = require("modules.c4_media")
local device_config = require("modules.device_config")
require("modules.device_types")  -- load type handler registry
local mcp_server_mod = require("modules.mcp_server")
local auth_mod = require("modules.auth")
local server_mod = require("modules.server")

do -- globals
    EX_CMDS = {}
    ON_PROPERTY_CHANGED = {}
    DEBUG = false
end

local _server_handle = nil
local _mcp = nil
local _watchdog_timer = nil

local _status = {
    transport = nil,     -- "HTTP" or "HTTPS"
    error = nil,         -- TLS/server error string or nil
    clients = 0,         -- current connection count
}

local function update_status()
    local parts = {}
    if _status.error then
        parts[#parts + 1] = _status.error
    elseif _status.transport then
        parts[#parts + 1] = _status.transport .. " on port " .. tostring(tonumber(Properties["MCP Port"]) or 9201)
    end
    parts[#parts + 1] = tostring(_status.clients) .. " client" .. (_status.clients == 1 and "" or "s")
    C4:UpdateProperty("Status", table.concat(parts, " | "))
end

local function build_mcp_server()
    _mcp = mcp_server_mod.create_mcp_server({
        server_name = "c4mcp",
        server_version = C4:GetDriverConfigInfo("version") or "1.0.0",
        instructions = "Control4 smart home MCP server. Use get_home to discover rooms and devices. "
            .. "Use get_devices to read device state and available actions. Use control_device to control devices. "
            .. "Use get_media to see what's playing in each room (now-playing, volume, available sources). "
            .. "Use control_media to control media: play/pause/skip, volume, mute, select source, join another room's session, or turn off a room. "
            .. "Media is room-centric — control rooms, not individual media devices.",
    })
    c4_home.register_read_tools(_mcp)
    c4_home.register_resources(_mcp)
    control_mod.register_control_tools(_mcp)
    c4_media.register_media_tools(_mcp)
    return _mcp
end

local function load_auth_validator()
    local keys = C4:PersistGetValue("api_keys") or {}
    if #keys == 0 then
        -- No keys configured: deny all requests (secure by default)
        return auth_mod.create_auth_validator({
            validate_fn = function() return false end,
        })
    end
    return auth_mod.create_auth_validator({
        validate_fn = function(token)
            local h = auth_mod.hash_api_key(token)
            for _, entry in ipairs(keys) do
                if entry.hash == h then return true end
            end
            return false
        end,
    })
end

local function reload_auth()
    if _server_handle then
        _server_handle:set_validator(load_auth_validator())
    end
end

--- Generate a self-signed TLS certificate via lua-openssl (OS 3.4.1+)
-- @return string|nil cert_pem, string|nil key_pem, string|nil error
local function generate_tls_certificate()
    local gen_ok, cert_pem, key_pem = pcall(function()
        local openssl = require('openssl')
        local pkey_mod = openssl.pkey
        local csr_mod = openssl.x509 and openssl.x509.req
        local privkey = pkey_mod.new()
        if csr_mod then
            local name = openssl.x509.name.new({{commonName = 'c4mcp'}})
            local req = csr_mod.new(name, privkey)
            local self_signed = req:to_x509(privkey, 3650)  -- 10 years
            -- Add IP SAN so TLS clients can verify by IP address
            local ip = C4:GetControllerNetworkAddress()
            if ip and ip ~= "" and openssl.x509.extension then
                local ext_ok, ext = pcall(openssl.x509.extension.new_extension,
                    {object = "subjectAltName", value = "IP:" .. ip})
                if ext_ok and ext then
                    pcall(function() self_signed:extensions({ext}) end)
                    C4:ErrorLog("[c4mcp] TLS cert includes SAN: IP:" .. ip)
                end
            end
            return self_signed:export('pem'), privkey:export('pem')
        else
            return nil, nil
        end
    end)
    if gen_ok and cert_pem and key_pem then
        C4:PersistSetValue("tls_cert", cert_pem)
        C4:PersistSetValue("tls_key", key_pem)
        return cert_pem, key_pem
    end
    return nil, nil, "lua-openssl not available (requires OS 3.4.1+)"
end

--- Get persisted TLS certificate
-- @return string|nil cert_pem, string|nil key_pem, string|nil error
local function get_tls_certificate()
    local cert = C4:PersistGetValue("tls_cert")
    local key = C4:PersistGetValue("tls_key")
    if cert and key and cert ~= "" and key ~= "" then
        return cert, key
    end
    return nil, nil, "No TLS certificate — use 'Generate TLS Certificate' action or SetTLSCertificate() from Lua console"
end

local function start_server()
    local port = tonumber(Properties["MCP Port"]) or 9201
    if _server_handle then
        _server_handle:stop()
        _server_handle = nil
    end
    local mcp = build_mcp_server()
    local validator = load_auth_validator()
    local max_conn = tonumber(Properties["Max Connections"]) or 5
    local idle_timeout = tonumber(Properties["Idle Timeout (sec)"]) or 300
    local max_rps = tonumber(Properties["Max Requests/sec"]) or 30
    local transport = Properties["Transport"] or "HTTP"

    local function on_connection_change(client_count)
        _status.clients = client_count
        update_status()
    end

    local base_opts = {
        port = port,
        mcp_server = mcp,
        auth_validator = validator,
        max_connections = max_conn,
        idle_timeout = idle_timeout,
        max_rps = max_rps,
        on_connection_change = on_connection_change,
    }

    if transport == "HTTPS" then
        local cert_pem, key_pem, cert_err = get_tls_certificate()
        if not cert_pem then
            C4:ErrorLog("[c4mcp] HTTPS failed: " .. tostring(cert_err) .. " — falling back to HTTP")
            _status.transport = "HTTP"
            _status.error = "HTTPS failed: no cert"
            _status.clients = 0
            update_status()
            _server_handle = server_mod.start_server(base_opts)
            return
        end
        base_opts.certificate = cert_pem
        base_opts.private_key = key_pem
        local handle, tls_err = server_mod.start_tls_server(base_opts)
        if not handle then
            C4:ErrorLog("[c4mcp] TLS server failed: " .. tostring(tls_err) .. " — falling back to HTTP")
            _status.transport = "HTTP"
            _status.error = "HTTPS failed: " .. tostring(tls_err)
            _status.clients = 0
            update_status()
            _server_handle = server_mod.start_server(base_opts)
            return
        end
        _server_handle = handle
        _status.transport = "HTTPS"
        _status.error = nil
        _status.clients = 0
        update_status()
        C4:ErrorLog("[c4mcp] HTTPS server started on port " .. tostring(port))
    else
        _server_handle = server_mod.start_server(base_opts)
        _status.transport = "HTTP"
        _status.error = nil
        _status.clients = 0
        update_status()
    end
    C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version") or "1")
end

local function start_watchdog()
    if _watchdog_timer then _watchdog_timer:Cancel() end
    _watchdog_timer = C4:SetTimer(60000, function()
        if _server_handle and not _server_handle:is_alive() then
            C4:ErrorLog("[c4mcp] Watchdog: server not alive, restarting...")
            start_server()
        end
    end, true)  -- repeat = true
end

function OnDriverLateInit()
    C4:ErrorLog("[c4mcp] OnDriverLateInit starting")
    C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
    device_config.load_config(Properties["Device Profiles"] or "")
    c4_home.refresh_cache()
    control_mod.set_write_control_mode(Properties["Write Control Mode"] or "Allow All")
    start_server()
    start_watchdog()
    C4:ErrorLog("[c4mcp] OnDriverLateInit complete")
end

function OnPropertyChanged(strProperty)
    local handler = ON_PROPERTY_CHANGED[strProperty]
    if handler then handler(Properties[strProperty]) end
end

ON_PROPERTY_CHANGED["Debug Mode"] = function(value)
    DEBUG = (value == "On")
end

ON_PROPERTY_CHANGED["Last Generated Key"] = function(value)
    if value ~= "" then
        C4:UpdateProperty("Last Generated Key", "")
    end
end

ON_PROPERTY_CHANGED["Transport"] = function()
    start_server()
end

ON_PROPERTY_CHANGED["MCP Port"] = function()
    start_server()
end

ON_PROPERTY_CHANGED["API Keys"] = function()
    reload_auth()
end

ON_PROPERTY_CHANGED["Max Connections"] = function()
    start_server()
end

ON_PROPERTY_CHANGED["Idle Timeout (sec)"] = function()
    start_server()
end

ON_PROPERTY_CHANGED["Max Requests/sec"] = function()
    start_server()
end

ON_PROPERTY_CHANGED["Device Profiles"] = function(value)
    device_config.load_config(value)
end

ON_PROPERTY_CHANGED["Write Control Mode"] = function(value)
    control_mod.set_write_control_mode(value)
end

ON_PROPERTY_CHANGED["Write Control Devices"] = function(value)
    local ids = {}
    for id in (value or ""):gmatch("%d+") do
        ids[#ids + 1] = tonumber(id)
    end
    control_mod.set_write_control_devices(ids)
end

function ExecuteCommand(strCommand, tParams)
    if strCommand == "LUA_ACTION" then
        local handler = EX_CMDS[tParams.ACTION]
        if handler then handler(tParams) end
        return
    end
    local handler = EX_CMDS[strCommand]
    if handler then handler(tParams) end
end

EX_CMDS["REFRESH_DEVICES"] = function()
    c4_home.refresh_cache()
end

EX_CMDS["RefreshDeviceCache"] = function()
    c4_home.refresh_cache()
end

EX_CMDS["PurgeConnections"] = function()
    if _server_handle then
        _server_handle:purge_clients()
    end
end


local function format_api_keys_display(keys)
    if #keys == 0 then return "No keys" end
    local parts = {}
    for _, entry in ipairs(keys) do
        local suffix = entry.last4 and (" ..." .. entry.last4) or ""
        parts[#parts + 1] = entry.name .. suffix
    end
    return table.concat(parts, ", ")
end

EX_CMDS["GenerateAPIKey"] = function(tParams)
    local key_name = (tParams and tParams.Name and tParams.Name ~= "") and tParams.Name or ("key_" .. os.time())
    -- Generate a random API key with mixed entropy sources, full SHA-256 output
    local entropy = tostring(os.time())
        .. tostring(math.random()) .. tostring(math.random()) .. tostring(math.random())
        .. tostring(os.clock())
    local key = C4:Hash("SHA256", entropy, { encoding = "HEX" })
    local keys = C4:PersistGetValue("api_keys") or {}
    keys[#keys + 1] = {
        name = key_name,
        hash = auth_mod.hash_api_key(key),
        last4 = key:sub(-4),
    }
    C4:PersistSetValue("api_keys", keys)
    C4:UpdateProperty("API Keys", format_api_keys_display(keys))
    C4:UpdateProperty("Last Generated Key", key)
    if Properties then Properties["Last Generated Key"] = key end
    print("[c4mcp] Generated API key '" .. key_name .. "': " .. key)
    -- Auto-clear displayed key after 30 seconds
    C4:SetTimer(30000, function()
        C4:UpdateProperty("Last Generated Key", "")
    end, false)
    reload_auth()
end

EX_CMDS["RevokeAPIKey"] = function(tParams)
    local key_name = tParams and tParams.Name
    if not key_name or key_name == "" then return end
    local keys = C4:PersistGetValue("api_keys") or {}
    for i = #keys, 1, -1 do
        if keys[i].name == key_name then
            table.remove(keys, i)
            break
        end
    end
    C4:PersistSetValue("api_keys", keys)
    C4:UpdateProperty("API Keys", format_api_keys_display(keys))
    C4:UpdateProperty("Last Generated Key", "")
    reload_auth()
end

EX_CMDS["RevokeAllAPIKeys"] = function()
    -- Preserve TLS credentials across key revocation
    local cert = C4:PersistGetValue("tls_cert")
    local key = C4:PersistGetValue("tls_key")
    C4:PersistDeleteAll()
    if cert and cert ~= "" then C4:PersistSetValue("tls_cert", cert) end
    if key and key ~= "" then C4:PersistSetValue("tls_key", key) end
    C4:UpdateProperty("API Keys", "No keys")
    C4:UpdateProperty("Last Generated Key", "")
    reload_auth()
end

--- Convert raw base64 (no headers/newlines) to PEM format
-- If input already has PEM headers, return as-is.
-- @param b64 string Raw base64 or PEM
-- @param pem_type string "CERTIFICATE" or "PRIVATE KEY"
-- @return string PEM-formatted string
local function to_pem(b64, pem_type)
    if b64:find("^%-%-%-%-%-BEGIN") then return b64 end
    local lines = { "-----BEGIN " .. pem_type .. "-----" }
    for i = 1, #b64, 64 do
        lines[#lines + 1] = b64:sub(i, i + 63)
    end
    lines[#lines + 1] = "-----END " .. pem_type .. "-----"
    return table.concat(lines, "\n")
end

EX_CMDS["GenerateTLSCertificate"] = function()
    local cert_pem, key_pem, err = generate_tls_certificate()
    if cert_pem then
        C4:ErrorLog("[c4mcp] Generated self-signed TLS certificate (" .. tostring(#cert_pem) .. " bytes)")
        print("[c4mcp] Generated TLS certificate (" .. tostring(#cert_pem) .. " bytes cert, " .. tostring(#key_pem) .. " bytes key)")
        if Properties["Transport"] == "HTTPS" then
            start_server()
        end
    else
        C4:ErrorLog("[c4mcp] Failed to generate TLS certificate: " .. tostring(err))
        print("[c4mcp] ERROR: " .. tostring(err))
    end
end

EX_CMDS["ClearTLSCertificate"] = function()
    C4:PersistSetValue("tls_cert", "")
    C4:PersistSetValue("tls_key", "")
    C4:ErrorLog("[c4mcp] TLS certificate cleared")
    print("[c4mcp] TLS certificate cleared")
end

EX_CMDS["PrintTLSCertificate"] = function()
    local cert = C4:PersistGetValue("tls_cert")
    if cert and cert ~= "" then
        print("[c4mcp] TLS Certificate:\n" .. cert)
    else
        print("[c4mcp] No TLS certificate stored. Use 'Generate TLS Certificate' action or SetTLSCertificate() from Lua console.")
    end
end

--- Global function for manual cert upload from Lua console
-- @param cert_pem string Certificate PEM or raw base64
-- @param key_pem string Private key PEM or raw base64
function SetTLSCertificate(cert_pem, key_pem)
    if not cert_pem or cert_pem == "" or not key_pem or key_pem == "" then
        print("Usage: SetTLSCertificate(cert_pem, key_pem)")
        print("  cert_pem: PEM certificate or raw base64")
        print("  key_pem:  PEM private key or raw base64")
        return
    end
    cert_pem = to_pem(cert_pem, "CERTIFICATE")
    key_pem = to_pem(key_pem, "PRIVATE KEY")
    C4:PersistSetValue("tls_cert", cert_pem)
    C4:PersistSetValue("tls_key", key_pem)
    print("[c4mcp] Stored TLS certificate (" .. tostring(#cert_pem) .. " bytes cert, " .. tostring(#key_pem) .. " bytes key)")
    C4:ErrorLog("[c4mcp] TLS certificate set via Lua console (" .. tostring(#cert_pem) .. " bytes)")
    if Properties["Transport"] == "HTTPS" then
        start_server()
        print("[c4mcp] HTTPS server restarted with new certificate")
    end
end

EX_CMDS["TestMCPResponse"] = function()
    if _mcp then
        local response = _mcp:handle_message(C4:JsonEncode({
            jsonrpc = "2.0", id = 0, method = "ping",
        }))
        if response then
            -- Temporarily show MCP OK in status, then restore normal status
            local parts = { "MCP OK" }
            if _status.transport then
                parts[#parts + 1] = _status.transport .. " on port " .. tostring(tonumber(Properties["MCP Port"]) or 9201)
            end
            parts[#parts + 1] = tostring(_status.clients) .. " client" .. (_status.clients == 1 and "" or "s")
            C4:UpdateProperty("Status", table.concat(parts, " | "))
        end
    end
end
