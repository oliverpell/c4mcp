-- Device Type Handler Registry
-- Unified dispatch for get_state and control actions across all device types.
-- Dependency chain: c4_home → device_types → device_config

local device_config = require("modules.device_config")

local M = {}

-- No-params marker: forces JSON object encoding
local NO_PARAMS = { params = "none" }

--------------------------------------------------------------------------------
-- Shared helpers (moved from c4_home to avoid circular deps)
--------------------------------------------------------------------------------

--- Split a comma-separated string into a table
function M.split_csv(str)
    if not str or str == "" then return {} end
    local result = {}
    for item in str:gmatch("([^,]+)") do
        result[#result + 1] = item
    end
    return result
end

--- Scan GetDeviceVariables result for a variable by name (logs on missing)
function M.get_var_by_name(vars, name, deviceId)
    if not vars then
        C4:ErrorLog("c4_home: GetDeviceVariables returned nil for device " .. tostring(deviceId))
        return nil
    end
    for _, v in pairs(vars) do
        if v.name == name then return v.value end
    end
    C4:ErrorLog("c4_home: variable '" .. name .. "' not found on device " .. tostring(deviceId))
    return nil
end

--- Silent variable lookup for optional/capability-gated variables
function M.try_get_var(vars, name)
    if not vars then return nil end
    for _, v in pairs(vars) do
        if v.name == name then return v.value end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Action schema builder: converts parsed action defs to controls.actions format
--------------------------------------------------------------------------------

local function build_action_schema(action_def)
    if type(action_def) ~= "table" or not action_def.command then
        return NO_PARAMS
    end
    if not action_def.params or not next(action_def.params) then
        return NO_PARAMS
    end
    local params_meta = {}
    for pname, pspec in pairs(action_def.params) do
        params_meta[pname] = {}
        if pspec.type == "enum" then
            params_meta[pname].type = "enum"
            params_meta[pname].values = pspec.values
        elseif pspec.type == "range" then
            params_meta[pname].type = "range"
            params_meta[pname].min = pspec.min
            params_meta[pname].max = pspec.max
        else
            params_meta[pname].type = "any"
        end
    end
    return { params = params_meta }
end

--------------------------------------------------------------------------------
-- Type handler registry
--------------------------------------------------------------------------------

local _handlers = {}

--- Register a device type handler
function M.register(type_name, handler)
    _handlers[type_name] = handler
end

--- Get handler for a device type
function M.get_handler(type_name)
    return _handlers[type_name]
end

--- Dispatch an action for a device
-- @param type_name string Device type
-- @param device_id number
-- @param dev table Device info from cache
-- @param action string Action name
-- @param params table Action parameters
-- @param send_cmd function(device_id, command, params) → msg, err
-- @return string|nil Success message
-- @return string|nil Error message
function M.dispatch(type_name, device_id, dev, action, params, send_cmd)
    local handler = _handlers[type_name]
    if not handler then
        return nil, "No handler for device type: " .. tostring(type_name)
    end

    -- 1. Try built-in action
    if handler.actions and handler.actions[action] then
        local action_def = handler.actions[action]
        if action_def.handler then
            return action_def.handler(device_id, dev, params or {}, send_cmd)
        end
        -- Declarative: merge fixed_params
        local c4_params = {}
        if action_def.fixed_params then
            for k, v in pairs(action_def.fixed_params) do
                c4_params[k] = v
            end
        end
        return send_cmd(device_id, action_def.command, c4_params)
    end

    -- 2. Try profile action
    local config = device_config.get_config(device_id, dev.driver_name)
    local action_def = device_config.resolve_config_action(config, action)
    if not action_def then
        -- For custom_device, also try resolve_action_def (includes generic fallback)
        if type_name == "custom_device" then
            action_def = device_config.resolve_action_def(config, action)
        end
    end

    if action_def then
        local user_params = params or {}
        -- Validate params
        if action_def.params and next(action_def.params) then
            local ok, err = device_config.validate_params(action_def, user_params)
            if not ok then return nil, err end
        end
        -- Determine target
        local target_id = device_id
        if action_def.target == "parent" then
            target_id = dev.parent_id or device_id
        end
        -- Build C4 params
        local c4_params = device_config.build_c4_params(action_def, user_params)
        return send_cmd(target_id, action_def.command, c4_params)
    end

    -- 3. Not found — build error with available actions
    local available = {}
    if handler.actions then
        for name, _ in pairs(handler.actions) do
            available[#available + 1] = name
        end
    end
    if config and config.actions then
        for name, _ in pairs(config.actions) do
            available[#available + 1] = name
        end
    end
    table.sort(available)
    return nil, "Unknown action '" .. tostring(action) .. "'. Available: " .. table.concat(available, ", ")
end

--------------------------------------------------------------------------------
-- Type handlers
--------------------------------------------------------------------------------

-- Light
M.register("light", {
    actions = {
        on = { command = "SET_LEVEL", fixed_params = { LEVEL = 100 }, schema = {} },
        off = { command = "SET_LEVEL", fixed_params = { LEVEL = 0 }, schema = {} },
        toggle = { command = "TOGGLE", schema = {} },
        set_level = {
            handler = function(device_id, dev, args, send_cmd)
                local level = tonumber(args.level)
                if not level or level < 0 or level > 100 then
                    return nil, "level must be 0-100"
                end
                return send_cmd(device_id, "SET_LEVEL", { LEVEL = level })
            end,
            schema = { level = { type = "range", min = 0, max = 100 } },
        },
        set_color = {
            handler = function(device_id, dev, args, send_cmd)
                if not args.color then return nil, "color is required for set_color" end
                return send_cmd(device_id, "SET_COLOR", { COLOR = args.color })
            end,
            schema = { color = { type = "any" } },
        },
    },
    get_state = function(device_id, dev, vars)
        local try_var = M.try_get_var
        local level = tonumber(try_var(vars, "Brightness Percent"))
        local light_state = try_var(vars, "LIGHT_STATE")
        -- supports_color from Navigator Dynamic Capabilities variable (not in project XML caps)
        local nav_caps = try_var(vars, "Navigator Dynamic Capabilities")
        local supports_color = nav_caps and nav_caps:find("<supports_color>True</supports_color>") ~= nil

        -- Use project capabilities to determine dimmer support
        local caps = dev.capabilities or {}
        local is_dimmable = caps.dimmer ~= "False"
        -- Fall back to Navigator Dynamic Capabilities if no project caps
        if not caps.dimmer then
            is_dimmable = nav_caps and nav_caps:find("<dimmer>True</dimmer>") ~= nil
        end

        local state = {
            power = light_state == "1" or (light_state == nil and level ~= nil and level > 0),
            controls = {},
        }

        -- Build controls.actions based on capabilities
        local actions = {
            on = NO_PARAMS,
            off = NO_PARAMS,
            toggle = NO_PARAMS,
        }
        if is_dimmable then
            state.level = level
            actions.set_level = { params = { level = { type = "range", min = 0, max = 100 } } }
        end
        if supports_color then
            state.supports_color = true
            actions.set_color = { params = { color = { type = "any" } } }
        end
        state.controls.actions = actions

        return state
    end,
})

-- Blind
M.register("blind", {
    actions = {
        open = { command = "SET_LEVEL_TARGET", fixed_params = { LEVEL_TARGET_NAME = "Open" }, schema = {} },
        close = { command = "SET_LEVEL_TARGET", fixed_params = { LEVEL_TARGET_NAME = "Closed" }, schema = {} },
        stop = { command = "STOP", schema = {} },
        set_level = {
            handler = function(device_id, dev, args, send_cmd)
                if args.level == nil then
                    return nil, "level is required for set_level action"
                end
                return send_cmd(device_id, "SET_LEVEL_TARGET", { LEVEL_TARGET = tonumber(args.level) })
            end,
            schema = { level = { type = "range", min = 0, max = 100 } },
        },
    },
    get_state = function(device_id, dev, vars)
        local get_var = M.get_var_by_name
        local opening = get_var(vars, "Opening", device_id)
        local closing = get_var(vars, "Closing", device_id)

        local actions = {
            open = NO_PARAMS,
            close = NO_PARAMS,
            set_level = { params = { level = { type = "range", min = 0, max = 100 } } },
        }
        -- Only include stop if can_stop capability is not False
        local caps = dev.capabilities or {}
        if caps.can_stop ~= "False" then
            actions.stop = NO_PARAMS
        end

        return {
            level = tonumber(get_var(vars, "Level", device_id)),
            moving = (opening == "1") or (closing == "1"),
            controls = { actions = actions },
        }
    end,
})

-- Lock
M.register("lock", {
    actions = {
        lock = { command = "LOCK", schema = {} },
        unlock = {
            handler = function(device_id, dev, args, send_cmd)
                return send_cmd(device_id, "UNLOCK", {})
            end,
            schema = {},
        },
    },
    get_state = function(device_id, dev, vars)
        local status = M.get_var_by_name(vars, "LOCK_STATUS", device_id)
        return {
            locked = (status == "Locked"),
            battery = tonumber(M.try_get_var(vars, "BATTERY_LEVEL")),
            controls = {
                actions = {
                    lock = NO_PARAMS,
                    unlock = NO_PARAMS,
                },
            },
        }
    end,
})

-- Relay
M.register("relay", {
    actions = {
        open = { command = "OPEN", schema = {} },
        close = { command = "CLOSE", schema = {} },
        toggle = { command = "TOGGLE", schema = {} },
        trigger = {
            handler = function(device_id, dev, args, send_cmd)
                local duration = tonumber(args.duration_ms) or 500
                return send_cmd(device_id, "TRIGGER", { TIME = duration })
            end,
            schema = { duration_ms = { type = "range", min = 0, max = 60000 } },
        },
    },
    get_state = function(device_id, dev, vars)
        return {
            state = M.get_var_by_name(vars, "RelayState", device_id),
            controls = {
                actions = {
                    open = NO_PARAMS,
                    close = NO_PARAMS,
                    toggle = NO_PARAMS,
                    trigger = { params = { duration_ms = { type = "range", min = 0, max = 60000 } } },
                },
            },
        }
    end,
})

-- Security
M.register("security", {
    actions = {
        arm_stay = {
            handler = function(device_id, dev, args, send_cmd)
                local code_params = args.code and { CODE = args.code } or {}
                return send_cmd(device_id, "ARM_STAY", code_params)
            end,
            schema = {},
        },
        arm_away = {
            handler = function(device_id, dev, args, send_cmd)
                local code_params = args.code and { CODE = args.code } or {}
                return send_cmd(device_id, "ARM_AWAY", code_params)
            end,
            schema = {},
        },
        arm_night = {
            handler = function(device_id, dev, args, send_cmd)
                local code_params = args.code and { CODE = args.code } or {}
                return send_cmd(device_id, "ARM_NIGHT", code_params)
            end,
            schema = {},
        },
        disarm = {
            handler = function(device_id, dev, args, send_cmd)
                local code_params = args.code and { CODE = args.code } or {}
                return send_cmd(device_id, "DISARM", code_params)
            end,
            schema = {},
        },
    },
    get_state = function(device_id, dev, vars)
        return {
            armed_mode = M.get_var_by_name(vars, "ARMED_STATE", device_id),
            alarm_state = M.get_var_by_name(vars, "ALARM_STATE", device_id),
            controls = {
                actions = {
                    arm_stay = { params = { code = { type = "any" } } },
                    arm_away = { params = { code = { type = "any" } } },
                    arm_night = { params = { code = { type = "any" } } },
                    disarm = { params = { code = { type = "any" } } },
                },
            },
        }
    end,
})

-- Thermostat (dynamic action schemas from variables)
M.register("thermostat", {
    actions = {
        set_mode = {
            handler = function(device_id, dev, args, send_cmd)
                if not args.mode then return nil, "mode is required for set_mode" end
                return send_cmd(device_id, "SET_MODE_HVAC", { MODE = args.mode })
            end,
            -- schema is dynamic, built in get_state
        },
        set_setpoint = {
            handler = function(device_id, dev, args, send_cmd)
                if not args.setpoint then return nil, "setpoint is required for set_setpoint" end
                local setpoint = tonumber(args.setpoint)
                if not setpoint then return nil, "setpoint must be a number" end
                -- Lazy-require c4_home for scale (breaks circular dep at call time, not load time)
                local c4_home = require("modules.c4_home")
                local scale = args.scale or c4_home.get_scale()
                if scale ~= "C" and scale ~= "F" then
                    return nil, "scale must be 'C' or 'F'"
                end
                local celsius, fahrenheit
                if scale == "F" then
                    fahrenheit = setpoint
                    celsius = (setpoint - 32) * 5 / 9
                else
                    celsius = setpoint
                    fahrenheit = setpoint * 9 / 5 + 32
                end
                local kelvin = celsius + 273.15
                local tstat_cfg = device_config.get_thermostat_config(device_id)
                local sp_command
                if tstat_cfg.setpoint_type == "heat_cool" then
                    local target = args.setpoint_target or "heat"
                    if target == "cool" then
                        sp_command = "SET_SETPOINT_COOL"
                    else
                        sp_command = "SET_SETPOINT_HEAT"
                    end
                elseif tstat_cfg.setpoint_type == "heat" then
                    sp_command = "SET_SETPOINT_HEAT"
                elseif tstat_cfg.setpoint_type == "cool" then
                    sp_command = "SET_SETPOINT_COOL"
                else
                    sp_command = "SET_SETPOINT_SINGLE"
                end
                return send_cmd(device_id, sp_command, {
                    CELSIUS = celsius,
                    FAHRENHEIT = fahrenheit,
                    KELVIN = kelvin,
                })
            end,
            -- schema is dynamic
        },
        set_fan = {
            handler = function(device_id, dev, args, send_cmd)
                if not args.fan_mode then return nil, "fan_mode is required for set_fan" end
                return send_cmd(device_id, "SET_FAN_MODE", { MODE = args.fan_mode })
            end,
        },
        set_hold = {
            handler = function(device_id, dev, args, send_cmd)
                if not args.hold_mode then return nil, "hold_mode is required for set_hold" end
                return send_cmd(device_id, "SET_MODE_HOLD", { MODE = args.hold_mode })
            end,
        },
    },
    get_state = function(device_id, dev, vars)
        local get_var = M.get_var_by_name
        local split_csv = M.split_csv
        local c4_home = require("modules.c4_home")

        local hvac_modes = split_csv(get_var(vars, "HVAC_MODES_LIST", device_id) or "")
        local hold_modes = split_csv(get_var(vars, "HOLD_MODES_LIST", device_id) or "")
        local fan_modes = split_csv(get_var(vars, "FAN_MODES_LIST", device_id) or "")
        local hvac_mode = get_var(vars, "HVAC_MODE", device_id)
        local is_off = (hvac_mode == "Off")
        local caps = dev.capabilities or {}

        local state = {
            temperature_c = tonumber(get_var(vars, "TEMPERATURE_C", device_id)),
            temperature_f = tonumber(get_var(vars, "TEMPERATURE_F", device_id)),
            hvac_state = get_var(vars, "HVAC_STATE", device_id),
            hold_mode = get_var(vars, "HOLD_MODE", device_id),
            scale = c4_home.get_scale(),
            controls = {},
        }

        -- Conditionally include humidity based on capabilities
        if caps.has_humidity == "true" then
            state.humidity = tonumber(get_var(vars, "HUMIDITY", device_id))
        end

        -- Conditionally include outdoor temperature based on capabilities
        if caps.has_outdoor_temperature == "true" then
            state.outdoor_temperature_c = tonumber(get_var(vars, "OUTDOOR_TEMPERATURE_C", device_id))
            state.outdoor_temperature_f = tonumber(get_var(vars, "OUTDOOR_TEMPERATURE_F", device_id))
        end

        -- Build controls.actions dynamically
        local actions = {}

        -- hvac_mode and modes
        if #hvac_modes > 0 then
            state.hvac_mode = hvac_mode
            actions.set_mode = { params = { mode = { type = "enum", values = hvac_modes } } }
        end

        -- Determine setpoint type from Device Profile config (defaults to "single")
        local tstat_cfg = device_config.get_thermostat_config(device_id)
        local setpoint_type = tstat_cfg.setpoint_type

        -- Setpoint range from capabilities, with fallbacks
        local sp_min = 5
        local sp_max = 35
        if setpoint_type == "heat_cool" then
            sp_min = tonumber(caps.setpoint_heat_min_c) or sp_min
            sp_max = tonumber(caps.setpoint_cool_max_c) or sp_max
        elseif setpoint_type == "heat" then
            sp_min = tonumber(caps.setpoint_heat_min_c) or sp_min
            sp_max = tonumber(caps.setpoint_heat_max_c) or sp_max
        elseif setpoint_type == "cool" then
            sp_min = tonumber(caps.setpoint_cool_min_c) or sp_min
            sp_max = tonumber(caps.setpoint_cool_max_c) or sp_max
        else -- "single"
            sp_min = tonumber(caps.setpoint_single_min_c) or sp_min
            sp_max = tonumber(caps.setpoint_single_max_c) or sp_max
        end

        -- Setpoint action (always available)
        local setpoint_params = {
            setpoint = { type = "range", min = sp_min, max = sp_max },
            scale = { type = "enum", values = {"C", "F"} },
        }
        if setpoint_type == "heat_cool" then
            setpoint_params.setpoint_target = { type = "enum", values = {"heat", "cool"} }
        end
        actions.set_setpoint = { params = setpoint_params }

        -- Fan modes
        if #fan_modes > 0 then
            state.fan_mode = get_var(vars, "FAN_MODE", device_id)
            actions.set_fan = { params = { fan_mode = { type = "enum", values = fan_modes } } }
        end

        -- Hold modes
        if #hold_modes > 0 then
            actions.set_hold = { params = { hold_mode = { type = "enum", values = hold_modes } } }
        end

        -- Merge profile-defined actions
        local config = device_config.get_config(device_id, dev.driver_name)
        if config and config.actions then
            for name, action_def in pairs(config.actions) do
                actions[name] = build_action_schema(action_def)
            end
        end

        state.controls.actions = actions

        -- Setpoints (only when not off)
        if not is_off then
            state.setpoint_type = setpoint_type
            if setpoint_type == "heat_cool" then
                state.heat_setpoint_c = tonumber(get_var(vars, "HEAT_SETPOINT_C", device_id))
                state.cool_setpoint_c = tonumber(get_var(vars, "COOL_SETPOINT_C", device_id))
            elseif setpoint_type == "heat" then
                state.heat_setpoint_c = tonumber(get_var(vars, "HEAT_SETPOINT_C", device_id))
            elseif setpoint_type == "cool" then
                state.cool_setpoint_c = tonumber(get_var(vars, "COOL_SETPOINT_C", device_id))
            else -- "single"
                state.single_setpoint_c = tonumber(get_var(vars, "SINGLE_SETPOINT_C", device_id))
            end
        end

        return state
    end,
})

-- Sensor (read-only)
M.register("sensor", {
    actions = {},
    get_state = function(device_id, dev, vars)
        local try_var = M.try_get_var
        local state = {
            battery = tonumber(try_var(vars, "BATTERY_LEVEL")),
            controls = { actions = {} },
        }
        if dev.c4i == "contactsingle.c4i" then
            state.sensor_type = "contact"
            local contact = M.get_var_by_name(vars, "CONTACT_STATE", device_id)
            state.triggered = (contact == "Open")
        elseif dev.c4i == "motionsensor.c4i" then
            state.sensor_type = "motion"
            local motion_state = M.get_var_by_name(vars, "MOTION_SENSOR_STATE", device_id)
            state.triggered = (motion_state == "Active")
            state.last_triggered = try_var(vars, "LAST_TRIGGERED")
        else
            state.sensor_type = "unknown"
        end
        return state
    end,
})

-- Custom device (experience buttons) — 3-layer: base → builtin profile → user profile
M.register("custom_device", {
    actions = {
        select = { command = "SELECT", schema = {} },
    },
    get_state = function(device_id, dev, vars, vars_cache)
        local get_var = M.get_var_by_name
        -- STATE lives on the parent device
        local var_device_id = dev.parent_id or device_id
        local eb_vars
        if var_device_id ~= device_id then
            if vars_cache and vars_cache[var_device_id] then
                eb_vars = vars_cache[var_device_id]
            else
                eb_vars = C4:GetDeviceVariables(var_device_id)
                if vars_cache then vars_cache[var_device_id] = eb_vars end
            end
        else
            eb_vars = vars
        end
        local config = device_config.get_config(device_id, dev.driver_name)
        local state_var_name = (config and config.state_var) or "STATE"
        local raw_state = get_var(eb_vars, state_var_name, var_device_id)
        local state_val = tonumber(raw_state) or raw_state
        local label = device_config.get_state_label(config, state_val)

        -- Build actions: base "select" + profile actions
        local actions_schema = { select = NO_PARAMS }
        if config and config.actions then
            for name, action_def in pairs(config.actions) do
                actions_schema[name] = build_action_schema(action_def)
            end
        end

        local result = {
            value = state_val,
            label = label,
            controls = { actions = actions_schema },
        }

        if config then
            result.category = config.category
            if config.states then
                local available_states = {}
                for k, v in pairs(config.states) do
                    available_states[tostring(k)] = v
                end
                result.available_states = available_states
            end
            -- Extra variables (silent lookup — absence is expected)
            if config.extra_vars and #config.extra_vars > 0 then
                local extra = {}
                for _, var_name in ipairs(config.extra_vars) do
                    local val = M.try_get_var(eb_vars, var_name)
                    if val ~= nil then
                        extra[var_name] = val
                    end
                end
                if next(extra) then result.extra = extra end
            end
        end

        return result
    end,
})

-- Camera (minimal)
M.register("camera", {
    actions = {},
    get_state = function(device_id, dev, vars)
        return { streaming_url = "" }
    end,
})

-- Door station (minimal)
M.register("door_station", {
    actions = {},
    get_state = function(device_id, dev, vars)
        return { state = "idle" }
    end,
})

return M
