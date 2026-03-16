-- Device Configuration (replaces experience_profiles.lua)
-- Supports user-editable JSON config via "Device Profiles" property,
-- with built-in profiles as defaults and compact action string syntax.

local M = {}

-- Built-in profiles by driver filename
-- Actions use actual driver EX_CMDs. @parent = send to parent device (type 6).
M.BUILTIN_PROFILES = {
    -- Relay Controllers (all use OPEN/CLOSE/STOP EX_CMDs on parent)
    -- STATE is a string variable: "Opened", "Closed", "Partial", "Unknown"
    -- Lift/screen override state labels (up/down instead of open/closed)
    ["lift_relay_control.c4z"] = {
        category = "lift",
        states = { Opened = "up", Closed = "down", Partial = "partial", Unknown = "unknown" },
        actions = { open = "OPEN @parent", close = "CLOSE @parent", stop = "STOP @parent" },
        extra_vars = {},
    },
    ["screen_relay_control.c4z"] = {
        category = "screen",
        states = { Opened = "up", Closed = "down", Partial = "partial", Unknown = "unknown" },
        actions = { open = "OPEN @parent", close = "CLOSE @parent", stop = "STOP @parent" },
        extra_vars = {},
    },
    -- Wildcard catches garage, gate, door, window, and any future relay controllers
    ["*_relay_control.c4z"] = {
        category = "relay_control",
        states = { Opened = "open", Closed = "closed", Partial = "partial", Unknown = "unknown" },
        actions = { open = "OPEN @parent", close = "CLOSE @parent", stop = "STOP @parent" },
        extra_vars = {},
    },

    -- Timer Drivers (wildcard: all timer_*.c4z share the same SetCountdown interface)
    ["timer_*.c4z"] = { category = "timer", states = { [0] = "off", [1] = "on" }, actions = { on = "SetCountdown(Time[On]) @parent", off = "SetCountdown(Time[Off]) @parent", set_countdown_mins = "SetCountdown(Time) @parent" }, extra_vars = { "COUNTDOWN", "RUNTIME" } },

    -- Scenario / AV Source Buttons (SELECT is a proxy command, no @parent)
    ["experience-button-scenario.c4z"] = { category = "scenario",  states = { [0] = "idle", [1] = "selected" }, actions = { select = "SELECT", set_state = "SetState(State[Off,On]) @parent" }, extra_vars = {} },
    ["uibutton_*.c4z"]                = { category = "av_source", states = { [0] = "idle", [1] = "selected" }, actions = { select = "SELECT" }, extra_vars = {} },
}

-- Wildcard pattern keys cached as Lua patterns for matching
local _wildcard_patterns = {}  -- {lua_pattern, profile}

--- Match a driver name against builtin profiles (exact first, then wildcard)
-- @param driver_name string
-- @return table|nil
function M.match_builtin(driver_name)
    if not driver_name then return nil end
    -- 1. Exact match
    if M.BUILTIN_PROFILES[driver_name] then
        return M.BUILTIN_PROFILES[driver_name]
    end
    -- 2. Wildcard match
    for _, wp in ipairs(_wildcard_patterns) do
        if driver_name:match(wp.pattern) then
            return wp.profile
        end
    end
    return nil
end

-- Parse all builtin profile action strings into structured defs at load time.
-- Also builds wildcard pattern cache.
local function init_builtin_profiles()
    -- Parse all action strings and build wildcard cache
    _wildcard_patterns = {}
    for key, profile in pairs(M.BUILTIN_PROFILES) do
        if profile.actions then
            for action_name, action_val in pairs(profile.actions) do
                if type(action_val) == "string" then
                    profile.actions[action_name] = M.parse_action_string(action_val)
                end
            end
        end
        -- If key contains *, convert to Lua pattern and cache
        if key:find("%*") then
            local lua_pattern = "^" .. key:gsub("%.", "%%."):gsub("%*", ".*") .. "$"
            _wildcard_patterns[#_wildcard_patterns + 1] = { pattern = lua_pattern, profile = profile }
        end
    end
end

-- User config from JSON property, keyed by device ID string
local _user_config = {}

--- Parse compact action string into structured definition
-- Syntax: "COMMAND" | "COMMAND(Param[A,B,C])" | "COMMAND(Param[0-100])" | "COMMAND(Param)" | "... @parent"
-- @param str string Compact action string
-- @return table {command, target, params} where params is {[name]={type,values/min/max}}
function M.parse_action_string(str)
    if not str or str == "" then return nil end

    local target = "device"
    -- Check for @parent suffix
    local base = str:match("^(.-)%s*@parent%s*$")
    if base then
        target = "parent"
        str = base
    end

    -- Check for params in parens: COMMAND(...)
    local command, params_str = str:match("^(%S+)%((.+)%)$")
    if not command then
        -- No params - plain command (alphanumeric/underscore only)
        command = str:match("^([%w_]+)$")
        if not command then return nil end
        return { command = command, target = target, params = {} }
    end

    -- Split parameter list on commas that are NOT inside brackets
    -- "P1[a,b,c], P2[0-100], P3" → {"P1[a,b,c]", "P2[0-100]", "P3"}
    local param_parts = {}
    local depth = 0
    local start = 1
    for i = 1, #params_str do
        local ch = params_str:sub(i, i)
        if ch == "[" then depth = depth + 1
        elseif ch == "]" then depth = depth - 1
        elseif ch == "," and depth == 0 then
            param_parts[#param_parts + 1] = params_str:sub(start, i - 1)
            start = i + 1
        end
    end
    param_parts[#param_parts + 1] = params_str:sub(start)

    local params = {}
    for _, param_part in ipairs(param_parts) do
        param_part = param_part:match("^%s*(.-)%s*$") -- trim

        -- Param with bracket constraint: Name[...]
        local name, constraint = param_part:match("^(%w+)%[(.+)%]$")
        if name and constraint then
            -- Range: 0-100
            local range_min, range_max = constraint:match("^(%d+)%-(%d+)$")
            if range_min then
                params[name] = { type = "range", min = tonumber(range_min), max = tonumber(range_max) }
            else
                -- Enum values: a,b,c (split on comma within brackets)
                local values = {}
                for v in constraint:gmatch("[^,]+") do
                    v = v:match("^%s*(.-)%s*$")
                    local num = tonumber(v)
                    values[#values + 1] = num or v
                end
                params[name] = { type = "enum", values = values }
            end
        else
            -- Bare param name (no constraint)
            name = param_part:match("^(%w+)$")
            if name then
                params[name] = { type = "any" }
            end
        end
    end

    return { command = command, target = target, params = params }
end

--- Validate params against an action definition
-- @param action_def table Parsed action from parse_action_string or from config
-- @param params table User-provided {name=value} params
-- @return boolean, string ok or false + error message
function M.validate_params(action_def, params)
    if not action_def or not action_def.params then return true end
    params = params or {}

    for name, spec in pairs(action_def.params) do
        local val = params[name]
        if val == nil then
            return false, "Missing required parameter: " .. name
        end
        if spec.type == "enum" then
            local found = false
            for _, allowed in ipairs(spec.values) do
                if tostring(val) == tostring(allowed) then found = true; break end
            end
            if not found then
                local vals = {}
                for _, v in ipairs(spec.values) do vals[#vals + 1] = tostring(v) end
                return false, "Invalid value '" .. tostring(val) .. "' for " .. name .. ". Allowed: " .. table.concat(vals, ", ")
            end
        elseif spec.type == "range" then
            local num = tonumber(val)
            if not num then
                return false, name .. " must be a number"
            end
            if num < spec.min or num > spec.max then
                return false, name .. " must be between " .. spec.min .. " and " .. spec.max
            end
        end
        -- type == "any" always passes
    end
    return true
end

--- Build C4 command params from user params (convert to string values for C4)
-- @param action_def table Parsed action definition
-- @param params table User-provided params
-- @return table C4 command params
function M.build_c4_params(action_def, params)
    if not params then return {} end
    local c4_params = {}
    for name, val in pairs(params) do
        c4_params[name] = tostring(val)
    end
    return c4_params
end

--- Parse a JSON config entry's actions into internal format
-- @param json_actions table {action_name = "compact string", ...}
-- @return table {action_name = parsed_action_def, ...}
local function parse_config_actions(json_actions)
    if not json_actions then return nil end
    local parsed = {}
    for name, action_str in pairs(json_actions) do
        parsed[name] = M.parse_action_string(action_str)
    end
    return parsed
end

--- Parse states from JSON (keys may be numeric strings "0","1" or string values "Opened","Closed")
local function parse_config_states(json_states)
    if not json_states then return nil end
    local states = {}
    for k, v in pairs(json_states) do
        local num = tonumber(k)
        if num then
            states[num] = v
        else
            states[k] = v
        end
    end
    return states
end

--- Load JSON config from property value
-- @param json_string string JSON from "Device Profiles" property
function M.load_config(json_string)
    if not json_string or json_string == "" then
        _user_config = {}
        return
    end
    local ok, decoded = pcall(C4.JsonDecode, C4, json_string)
    if not ok or type(decoded) ~= "table" then
        C4:ErrorLog("device_config: invalid JSON in Device Profiles, keeping previous config")
        return
    end
    -- Parse each entry
    local config = {}
    for device_id_str, entry in pairs(decoded) do
        local parsed = {}
        if entry.category then parsed.category = entry.category end
        if entry.states then parsed.states = parse_config_states(entry.states) end
        if entry.actions then parsed.actions = parse_config_actions(entry.actions) end
        if entry.extra_vars then
            local normalized = {}
            for _, v in pairs(entry.extra_vars) do
                normalized[#normalized + 1] = v
            end
            parsed.extra_vars = normalized
        end
        if entry.setpoint_type then parsed.setpoint_type = entry.setpoint_type end
        if entry.state_var then parsed.state_var = entry.state_var end
        config[device_id_str] = parsed
    end
    _user_config = config
end

--- Get effective config for a device
-- Lookup order: device ID in user config → driver filename in builtins → nil
-- @param device_id number
-- @param driver_name string
-- @return table|nil Profile/config table
function M.get_config(device_id, driver_name)
    -- 1. Device ID in user JSON config (highest priority)
    local id_str = tostring(device_id)
    if _user_config[id_str] then
        return _user_config[id_str]
    end
    -- 2. Built-in profile by driver filename (exact, then wildcard)
    return M.match_builtin(driver_name)
end

--- Get thermostat config for a device
-- @param device_id number
-- @return table {setpoint_type="single"|"heat"|"cool"|"heat_cool", user_configured=boolean}
function M.get_thermostat_config(device_id)
    local id_str = tostring(device_id)
    local cfg = _user_config[id_str]
    if cfg and cfg.setpoint_type then
        return { setpoint_type = cfg.setpoint_type, user_configured = true }
    end
    return { setpoint_type = "single" }
end

--- Get the raw user config table (for get_device_profiles tool)
function M.get_user_config()
    return _user_config
end

--- Get profile for a driver file name (exact or wildcard match)
function M.get_profile(driver_name)
    return M.match_builtin(driver_name)
end

--- Get the state label for a given config/profile and state value
-- Supports both string keys ("Opened") and numeric keys (0, 1)
function M.get_state_label(config, state_value)
    if not config or not config.states then return "unknown" end
    -- Try direct lookup (string key like "Opened" or numeric key)
    if state_value ~= nil and config.states[state_value] then
        return config.states[state_value]
    end
    -- Try numeric lookup for backward compat with numeric string values
    local num = tonumber(state_value)
    if num ~= nil and config.states[num] then
        return config.states[num]
    end
    return "unknown"
end

--- Resolve action definition (full, with params/target info)
-- @param config table Config from get_config()
-- @param action_name string
-- @return table|nil {command, target, params} or nil
function M.resolve_action_def(config, action_name)
    if config and config.actions and config.actions[action_name] then
        local action_def = config.actions[action_name]
        if type(action_def) == "table" and action_def.command then
            return action_def
        end
        -- Simple string command → wrap in standard format
        return { command = action_def, target = "device", params = {} }
    end
    -- Generic fallback: unconfigured uibutton proxies support SELECT
    local generic = { select = "SELECT" }
    if generic[action_name] then
        return { command = generic[action_name], target = "device", params = {} }
    end
    return nil
end

--- Resolve action definition from config only (no generic fallback)
-- Used for thermostats and other typed devices that shouldn't inherit toggle/on/off.
-- @param config table Config from get_config()
-- @param action_name string
-- @return table|nil {command, target, params} or nil
function M.resolve_config_action(config, action_name)
    if not config or not config.actions or not config.actions[action_name] then
        return nil
    end
    local action_def = config.actions[action_name]
    if type(action_def) == "table" and action_def.command then
        return action_def
    end
    -- Simple string command → wrap in standard format
    return { command = action_def, target = "device", params = {} }
end

--- Validate a JSON profiles object (for set_device_profiles tool)
-- @param profiles table Decoded JSON
-- @return boolean, string ok or false + error message
function M.validate_profiles(profiles)
    if type(profiles) ~= "table" then
        return false, "profiles must be a JSON object"
    end
    for device_id_str, entry in pairs(profiles) do
        if type(entry) ~= "table" then
            return false, "Profile for device " .. tostring(device_id_str) .. " must be an object"
        end
        -- Validate actions if present
        if entry.actions then
            if type(entry.actions) ~= "table" then
                return false, "actions for device " .. device_id_str .. " must be an object"
            end
            for action_name, action_str in pairs(entry.actions) do
                if type(action_str) ~= "string" then
                    return false, "Action '" .. action_name .. "' for device " .. device_id_str .. " must be a string"
                end
                local parsed = M.parse_action_string(action_str)
                if not parsed then
                    return false, "Invalid action syntax '" .. action_str .. "' for action '" .. action_name .. "' on device " .. device_id_str
                end
            end
        end
        -- Validate state_var if present
        if entry.state_var ~= nil then
            if type(entry.state_var) ~= "string" then
                return false, "state_var for device " .. device_id_str .. " must be a string"
            end
        end
        -- Validate setpoint_type if present
        if entry.setpoint_type then
            local valid_types = { single = true, heat = true, cool = true, heat_cool = true }
            if not valid_types[entry.setpoint_type] then
                return false, "setpoint_type for device " .. device_id_str .. " must be 'single', 'heat', 'cool', or 'heat_cool'"
            end
        end
    end
    return true
end

-- Initialize builtin profiles (parse action strings, add set_countdown to timers)
init_builtin_profiles()

return M
