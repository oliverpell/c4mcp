-- Layer 3: Control Framework
-- Write validation, unified device control dispatch, and control tool registration

local c4_home = require("modules.c4_home")
local device_config = require("modules.device_config")
local device_types = require("modules.device_types")

local M = {}

-- Write control state
local _write_mode = "Allow All"  -- "Allow All" / "Allowlist" / "Blocklist"
local _write_devices = {}         -- {[deviceId] = true}

--- Set the write control mode
function M.set_write_control_mode(mode)
    _write_mode = mode
end

--- Set the write control device list
-- @param device_ids table Array of device IDs
function M.set_write_control_devices(device_ids)
    _write_devices = {}
    for _, id in ipairs(device_ids or {}) do
        _write_devices[tonumber(id)] = true
    end
end

--- Check if write access is allowed for a device
-- @param device_id number
-- @return boolean
function M.is_write_allowed(device_id)
    if _write_mode == "Allow All" then return true end
    if _write_mode == "Allowlist" then return _write_devices[device_id] == true end
    if _write_mode == "Blocklist" then return _write_devices[device_id] ~= true end
    return true
end

--- Validate write access for a device
-- @param device_id number|string
-- @return table {ok=true} or {ok=false, error="..."}
function M.validate_write_access(device_id)
    device_id = tonumber(device_id)
    if not device_id then
        return { ok = false, error = "Invalid device_id" }
    end
    local dev = c4_home.get_device(device_id)
    if not dev then
        return { ok = false, error = "Device " .. tostring(device_id) .. " not found" }
    end
    if not M.is_write_allowed(device_id) then
        return { ok = false, error = "Device " .. tostring(device_id) .. " (" .. dev.name .. ") is not allowed for write operations" }
    end
    return { ok = true }
end

--- Validate device type matches expected
-- @param device_id number|string
-- @param expected_type string
-- @return table {ok=true} or {ok=false, error="..."}
function M.validate_device_type(device_id, expected_type)
    device_id = tonumber(device_id)
    if not device_id then
        return { ok = false, error = "Invalid device_id" }
    end
    local dev = c4_home.get_device(device_id)
    if not dev then
        return { ok = false, error = "Device " .. tostring(device_id) .. " not found" }
    end
    if dev.type ~= expected_type then
        return { ok = false, error = "Device " .. tostring(device_id) .. " (" .. dev.name .. ") is not a " .. expected_type }
    end
    return { ok = true }
end

--- Send a command to a device
-- @param device_id number
-- @param command string C4 command name
-- @param params table Command parameters
-- @return string|nil Success message, or nil on error
-- @return string|nil Error message on failure
function M.send_device_command(device_id, command, params)
    local dev = c4_home.get_device(device_id)
    local ok, err = pcall(C4.SendToDevice, C4, device_id, command, params or {})
    if not ok then
        return nil, "Command failed: " .. tostring(err)
    end
    return "OK: " .. command .. " on " .. (dev and dev.name or tostring(device_id))
end

--- Helper: make a tool error response
local function tool_error(msg)
    return { content = {{ type = "text", text = "Error: " .. msg }}, isError = true }
end

--- Helper: make a tool success response (handles nil,err from send_device_command)
local function tool_success(msg, err)
    if not msg then return tool_error(err or "Unknown error") end
    return { content = {{ type = "text", text = msg }}, isError = false }
end

--- Register all control tools with the MCP server
-- @param mcp_server table MCP server from mcp_server.lua
function M.register_control_tools(mcp_server)

    -- Unified control_device tool
    mcp_server:register_tool("control_device", {
        description = "Control any device: light, blind, thermostat, lock, relay, security, or custom device. Call get_devices first to discover available actions and their parameter schemas in controls.actions.",
        inputSchema = {
            type = "object",
            properties = {
                device_id = { type = "number", description = "Device ID to control" },
                action = { type = "string", description = "Action name — see controls.actions from get_devices" },
                params = { type = "object", description = "Action parameters (e.g. {level: 50}, {mode: 'Heat'}, {setpoint: 22, scale: 'C'})" },
            },
            required = { "device_id", "action" },
        },
    }, function(args)
        local device_id = tonumber(args.device_id)
        if not device_id then return tool_error("Invalid device_id") end

        -- Validate write access
        local check = M.validate_write_access(device_id)
        if not check.ok then return tool_error(check.error) end

        local dev = c4_home.get_device(device_id)
        if not dev then return tool_error("Device " .. tostring(device_id) .. " not found") end

        -- Check handler exists
        local handler = device_types.get_handler(dev.type)
        if not handler then
            return tool_error("Unsupported device type: " .. tostring(dev.type))
        end

        -- Flatten params: merge top-level action-specific args into params
        -- This supports both {action: "on", params: {level: 50}} and
        -- {action: "set_level", params: {level: 50}} styles
        local params = args.params or {}

        -- Dispatch via device_types
        local msg, err = device_types.dispatch(dev.type, device_id, dev, args.action, params, M.send_device_command)
        return tool_success(msg, err)
    end)

    -- control_devices (batch)
    mcp_server:register_tool("control_devices", {
        description = "Control multiple devices in a single call. Accepts an array of operations, each with device_id, action, and optional params. Returns per-device results. Use this for bulk operations like 'turn off all lights'.",
        inputSchema = {
            type = "object",
            properties = {
                operations = {
                    type = "array",
                    description = "Array of {device_id, action, params} operations",
                    items = {
                        type = "object",
                        properties = {
                            device_id = { type = "number", description = "Device ID to control" },
                            action = { type = "string", description = "Action name" },
                            params = { type = "object", description = "Action parameters" },
                        },
                        required = { "device_id", "action" },
                    },
                },
            },
            required = { "operations" },
        },
    }, function(args)
        local ops = args.operations
        if not ops then
            return tool_error("operations is required")
        end
        if #ops == 0 then
            return tool_error("operations must not be empty")
        end
        if #ops > 20 then
            return tool_error("Maximum 20 operations per batch")
        end
        local results = {}
        for _, op in ipairs(ops) do
            local device_id = tonumber(op.device_id)
            if not device_id then
                results[#results + 1] = { device_id = tostring(op.device_id or "nil"), ok = false, error = "Invalid device_id: " .. tostring(op.device_id) }
            else
                local check = M.validate_write_access(device_id)
                if not check.ok then
                    results[#results + 1] = { device_id = device_id, ok = false, error = check.error }
                else
                    local dev = c4_home.get_device(device_id)
                    if not dev then
                        results[#results + 1] = { device_id = device_id, ok = false, error = "Device not found" }
                    else
                        local handler = device_types.get_handler(dev.type)
                        if not handler then
                            results[#results + 1] = { device_id = device_id, ok = false, error = "Unsupported device type: " .. tostring(dev.type) }
                        else
                            -- dispatch returns (success_msg, nil) or (nil, error_msg)
                            -- pcall catches Lua exceptions; it does not transform return values
                            local call_ok, success_msg, err_msg = pcall(device_types.dispatch, dev.type, device_id, dev, op.action, op.params or {}, M.send_device_command)
                            if not call_ok then
                                results[#results + 1] = { device_id = device_id, ok = false, error = "Dispatch error: " .. tostring(success_msg) }
                            elseif success_msg then
                                results[#results + 1] = { device_id = device_id, ok = true, message = success_msg }
                            else
                                results[#results + 1] = { device_id = device_id, ok = false, error = err_msg or "Unknown error" }
                            end
                        end
                    end
                end
            end
        end
        local succeeded = 0
        local failed = 0
        for _, r in ipairs(results) do
            if r.ok then succeeded = succeeded + 1 else failed = failed + 1 end
        end
        return {
            results = results,
            summary = { total = #results, succeeded = succeeded, failed = failed },
        }
    end)

    -- set_device_profiles
    mcp_server:register_tool("set_device_profiles", {
        description = "Set the Device Profiles configuration. Defines how custom devices and thermostats are exposed — mapping device IDs to categories, state labels, parameterized actions with valid values, and extra variables. Validates the JSON and persists it. Use configure_device_profiles first to get the format spec.",
        inputSchema = {
            type = "object",
            properties = {
                profiles = { type = "object", description = "Device Profiles JSON object keyed by device ID" },
            },
            required = { "profiles" },
        },
    }, function(args)
        local profiles = args.profiles
        local ok, err = device_config.validate_profiles(profiles)
        if not ok then return tool_error(err) end
        local json_str = C4:JsonEncode(profiles)
        device_config.load_config(json_str)
        C4:UpdateProperty("Device Profiles", json_str)
        local count = 0
        for _ in pairs(profiles) do count = count + 1 end
        return { content = {{ type = "text", text = "OK: Device Profiles updated (" .. count .. " device(s) configured)" }}, isError = false }
    end)
end

return M
