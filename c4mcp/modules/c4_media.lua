-- Layer 3: Media Control
-- Room-centric media status reading and control via get_media and control_media tools.

local c4_home = require("modules.c4_home")
local control_mod = require("modules.control")

local M = {}

-- No-params marker: forces JSON object encoding (same pattern as device_types.lua)
local NO_PARAMS = { params = "none" }

--------------------------------------------------------------------------------
-- Room Variable Constants (verified on real controller)
--------------------------------------------------------------------------------

local ROOM_VAR = {
    CURRENT_SELECTED_DEVICE = 1000,
    CURRENT_AUDIO_DEVICE    = 1001,
    CURRENT_VIDEO_DEVICE    = 1002,
    POWER_STATE             = 1010,
    CURRENT_VOLUME          = 1011,
    HAS_DISCRETE_VOLUME     = 1016,
    HAS_DISCRETE_MUTE       = 1017,
    IS_MUTED                = 1018,
    CURRENT_MEDIA_INFO      = 1031,
    LAST_DEVICE_GROUP       = 1032,
    PLAYING_AUDIO_DEVICE    = 1036,
}

--------------------------------------------------------------------------------
-- Session Info (Phase 2)
--------------------------------------------------------------------------------

--- Parse DA device QUEUE_STATUS (var 1004) into a room→session map
-- @param queue_xml string XML from DA device var 1004
-- @return table {[room_id] = {id=queue_id, state="Play"/"Pause", item="song", rooms={id1,id2,...}}}
local function parse_queue_status(queue_xml)
    if not queue_xml or queue_xml == "" then return {} end

    -- Parse each <queue> block
    local sessions = {}  -- {[queue_id] = {id, state, item, rooms}}
    for queue_block in queue_xml:gmatch("<queue>(.-)</queue>") do
        local queue_id = tonumber(queue_block:match("<id>(%d+)</id>"))
        local state = queue_block:match("<state>(.-)</state>")
        local item = queue_block:match("<item>(.-)</item>")
        local room_ids = {}
        -- Rooms can be: <rooms><id>45</id><id>55</id></rooms>
        local rooms_block = queue_block:match("<rooms>(.-)</rooms>")
        if rooms_block then
            for rid in rooms_block:gmatch("<id>(%d+)</id>") do
                room_ids[#room_ids + 1] = tonumber(rid)
            end
        end
        if queue_id and #room_ids > 0 then
            sessions[queue_id] = {
                id = queue_id,
                state = state,
                item = item,
                rooms = room_ids,
            }
        end
    end

    -- Build room→session lookup
    local room_sessions = {}
    for _, session in pairs(sessions) do
        for _, rid in ipairs(session.rooms) do
            room_sessions[rid] = session
        end
    end
    return room_sessions
end

--- Fetch current session info for all rooms
-- Reads DA device var 1004 (QUEUE_STATUS) once and returns room→session map
local function fetch_session_map()
    local da_id = c4_home.get_da_device_id()
    local queue_xml = C4:GetDeviceVariable(da_id, 1004)
    return parse_queue_status(queue_xml)
end

-- Exported for unit testing
M.parse_queue_status = parse_queue_status

--------------------------------------------------------------------------------
-- Station Discovery (Phase 3) — Lazy TTL Cache
--------------------------------------------------------------------------------

local STATION_TTL = 3600  -- 1 hour in seconds
-- {[device_id] = {stations = [...], timestamp = os.time()}}
local _station_cache = {}

--- Discover broadcast audio stations for an MSP source device (uncached)
-- @param device_id number MSP device proxy ID (e.g., TuneIn=20, Spotify=494)
-- @return table Array of {mediaid, name, station_id} or empty table
local function discover_stations_uncached(device_id)
    local stations = {}
    local ok = pcall(function()
        C4:MediaSetDeviceContext(device_id)
    end)
    if not ok then return stations end

    local ok2, result = pcall(function()
        return C4:MediaGetAllBroadcastAudio()
    end)
    if not ok2 or not result or type(result) ~= "table" then
        pcall(function() C4:MediaSetDeviceContext(0) end)
        return stations
    end

    for mediaId, stationId in pairs(result) do
        local nid = tonumber(mediaId)
        if nid then
            local name = nil
            local ok3, info = pcall(function()
                return C4:MediaGetBroadcastAudioInfo(nid)
            end)
            if ok3 and info and type(info) == "table" then
                name = info.name
            end
            stations[#stations + 1] = {
                mediaid = nid,
                name = name or ("Station " .. nid),
                station_id = stationId,
            }
        end
    end

    -- Reset context to avoid interference with other calls
    pcall(function() C4:MediaSetDeviceContext(0) end)

    table.sort(stations, function(a, b) return a.name < b.name end)
    return stations
end

--- Get stations for a device, using lazy TTL cache (1 hour)
-- First call or stale cache triggers a fresh query; subsequent calls within
-- the TTL window return cached results instantly.
local function get_device_stations(device_id)
    local cached = _station_cache[device_id]
    local now = os.time()
    if cached and (now - cached.timestamp) < STATION_TTL then
        return cached.stations
    end
    local stations = discover_stations_uncached(device_id)
    _station_cache[device_id] = { stations = stations, timestamp = now }
    return stations
end

--------------------------------------------------------------------------------
-- Room Media Status Builder
--------------------------------------------------------------------------------

--- Build media status for a single room
-- @param room_id number
-- @param session_map table|nil Optional room→session map from fetch_session_map()
-- @return table Media status object
local function build_room_media_status(room_id, session_map)
    local room = c4_home.get_room(room_id)
    if not room then return nil, "Room " .. tostring(room_id) .. " not found" end

    -- Single call to get all room variables
    -- On real controllers, keys may be numbers or strings — use tonumber to normalize
    local room_vars = C4:GetDeviceVariables(room_id)
    local rv = {}
    if room_vars then
        for varId, v in pairs(room_vars) do
            local nid = tonumber(varId)
            if nid then rv[nid] = v.value end
        end
    end

    local power = rv[ROOM_VAR.POWER_STATE] == "1"
    local selected = tonumber(rv[ROOM_VAR.CURRENT_SELECTED_DEVICE]) or 0
    local playing_audio = tonumber(rv[ROOM_VAR.PLAYING_AUDIO_DEVICE]) or 0
    local device_group = rv[ROOM_VAR.LAST_DEVICE_GROUP] or ""
    local has_volume = rv[ROOM_VAR.HAS_DISCRETE_VOLUME] == "1"
    local has_mute = rv[ROOM_VAR.HAS_DISCRETE_MUTE] == "1"

    -- Resolve selected device name
    local dev_id, dev_name = c4_home.resolve_selected_device(selected, playing_audio)

    -- Media type
    local media_type = nil
    if device_group == "watch" or device_group == "video" then media_type = "video"
    elseif device_group == "listen" or device_group == "audio" then media_type = "audio"
    end

    -- Now playing (only when power is on to avoid stale data)
    local now_playing = nil
    if power then
        now_playing = c4_home.parse_now_playing(rv[ROOM_VAR.CURRENT_MEDIA_INFO])
    end

    -- Volume
    local volume = nil
    if has_volume then
        volume = {
            level = tonumber(rv[ROOM_VAR.CURRENT_VOLUME]),
            muted = rv[ROOM_VAR.IS_MUTED] == "1",
        }
    end

    -- Build controls.actions
    local actions = {
        play = NO_PARAMS,
        pause = NO_PARAMS,
        play_pause = NO_PARAMS,
        stop = NO_PARAMS,
        skip_fwd = NO_PARAMS,
        skip_rev = NO_PARAMS,
        room_off = NO_PARAMS,
        select_source = { params = { device_id = { type = "number" } } },
        join_session = { params = { source_room_id = { type = "number" } } },
        set_channel = { params = { channel = { type = "any" } } },
        channel_up = NO_PARAMS,
        channel_down = NO_PARAMS,
        select_station = { params = { mediaid = { type = "number" } } },
    }
    if has_volume then
        actions.set_volume = { params = { level = { type = "range", min = 0, max = 100 } } }
        actions.volume_up = { params = { step = { type = "range", min = 1, max = 20 } } }
        actions.volume_down = { params = { step = { type = "range", min = 1, max = 20 } } }
    end
    if has_mute then
        actions.mute = NO_PARAMS
        actions.unmute = NO_PARAMS
        actions.mute_toggle = NO_PARAMS
    end

    local selected_device = nil
    if dev_id then
        selected_device = { id = dev_id, name = dev_name }
    end

    -- Session info (from pre-fetched session map)
    local session = nil
    if session_map and session_map[room_id] then
        local s = session_map[room_id]
        -- Resolve room IDs to names for readability
        local room_names = {}
        for _, rid in ipairs(s.rooms) do
            local r = c4_home.get_room(rid)
            room_names[#room_names + 1] = r and r.name or tostring(rid)
        end
        session = {
            id = s.id,
            state = s.state,
            item = s.item,
            rooms = s.rooms,
            room_names = room_names,
        }
    end

    -- Build sources with station enrichment for MSP devices
    local raw_sources = c4_home.get_room_sources(room_id)
    local sources = {}
    for _, src in ipairs(raw_sources) do
        local enriched = { id = src.id, name = src.name, category = src.category }
        local dev = c4_home.get_device(src.id)
        if dev and dev.c4i == "media_service.c4i" then
            local stations = get_device_stations(src.id)
            if #stations > 0 then
                enriched.stations = stations
            end
        end
        sources[#sources + 1] = enriched
    end

    return {
        room_id = room_id,
        room_name = room.name,
        power = power,
        selected_device = selected_device,
        media_type = media_type,
        volume = volume,
        now_playing = now_playing,
        session = session,
        available_sources = sources,
        controls = { actions = actions },
    }
end

--------------------------------------------------------------------------------
-- control_media Action Dispatch
--------------------------------------------------------------------------------

-- Simple transport actions: action_name → C4 command
local SIMPLE_ACTIONS = {
    play = "PLAY",
    pause = "PAUSE",
    play_pause = "PLAYPAUSE",
    stop = "STOP",
    skip_fwd = "SKIP_FWD",
    skip_rev = "SKIP_REV",
    mute = "MUTE_ON",
    unmute = "MUTE_OFF",
    mute_toggle = "MUTE_TOGGLE",
    room_off = "ROOM_OFF",
    channel_up = "PULSE_CH_UP",
    channel_down = "PULSE_CH_DOWN",
}

--- Dispatch a control_media action
-- @param room_id number Target room
-- @param action string Action name
-- @param params table Action parameters
-- @param send_fn function(device_id, command, params) Send command function
-- @return string|nil Success message
-- @return string|nil Error message
local function dispatch_action(room_id, action, params, send_fn)
    params = params or {}

    -- Simple transport/mute/room_off actions
    if SIMPLE_ACTIONS[action] then
        send_fn(room_id, SIMPLE_ACTIONS[action], {})
        return action .. " sent"
    end

    -- set_volume
    if action == "set_volume" then
        local level = tonumber(params.level)
        if level == nil or level < 0 or level > 100 then
            return nil, "level must be 0-100"
        end
        send_fn(room_id, "SET_VOLUME_LEVEL", { LEVEL = level })
        return "volume set to " .. level
    end

    -- set_channel
    if action == "set_channel" then
        local channel = params.channel
        if not channel or tostring(channel) == "" then
            return nil, "channel is required for set_channel"
        end
        send_fn(room_id, "SET_CHANNEL", { CHANNEL = tostring(channel) })
        return "channel set to " .. tostring(channel)
    end

    -- select_station (broadcast audio like TuneIn — requires mediaid from station discovery)
    if action == "select_station" then
        local mediaid = tonumber(params.mediaid)
        if not mediaid then
            return nil, "mediaid is required for select_station (numeric station ID)"
        end
        send_fn(room_id, "SELECT_AUDIO_MEDIA", {
            deselect = "0",
            type = "BROADCAST_AUDIO",
            mediaid = mediaid,
        })
        return "station selected (mediaid " .. mediaid .. ")"
    end

    -- volume_up / volume_down
    if action == "volume_up" or action == "volume_down" then
        local step = tonumber(params.step) or 5
        if step < 1 or step > 20 then
            return nil, "step must be 1-20"
        end
        local current = tonumber(C4:GetDeviceVariable(room_id, ROOM_VAR.CURRENT_VOLUME)) or 0
        local new_level
        if action == "volume_up" then
            new_level = math.min(100, current + step)
        else
            new_level = math.max(0, current - step)
        end
        send_fn(room_id, "SET_VOLUME_LEVEL", { LEVEL = new_level })
        return "volume " .. (action == "volume_up" and "up" or "down") .. " to " .. new_level
    end

    -- select_source
    if action == "select_source" then
        local device_id = tonumber(params.device_id)
        if not device_id then
            return nil, "device_id is required for select_source"
        end
        if not c4_home.is_room_source(room_id, device_id) then
            local sources = c4_home.get_room_sources(room_id)
            local names = {}
            for _, s in ipairs(sources) do
                names[#names + 1] = s.name .. " (" .. s.id .. ")"
            end
            return nil, "Device " .. device_id .. " is not available in this room. Available: " .. table.concat(names, ", ")
        end
        if c4_home.is_watch_source(room_id, device_id) then
            send_fn(room_id, "SELECT_VIDEO_DEVICE", { deviceid = device_id })
        else
            send_fn(room_id, "SELECT_AUDIO_DEVICE", { deviceid = device_id })
        end
        return "source selected"
    end

    -- join_session
    if action == "join_session" then
        local source_room_id = tonumber(params.source_room_id)
        if not source_room_id then
            return nil, "source_room_id is required for join_session"
        end
        if source_room_id == room_id then
            return nil, "Cannot join own session"
        end
        local source_room = c4_home.get_room(source_room_id)
        if not source_room then
            return nil, "Source room " .. source_room_id .. " not found"
        end
        if not c4_home.is_media_room(source_room_id) then
            return nil, "Source room is not media-capable"
        end
        -- Read source room's current device
        local source_selected = tonumber(C4:GetDeviceVariable(source_room_id, ROOM_VAR.CURRENT_SELECTED_DEVICE)) or 0
        local source_power = C4:GetDeviceVariable(source_room_id, ROOM_VAR.POWER_STATE)
        if source_power ~= "1" or source_selected == 0 then
            return nil, "Source room is not playing media"
        end
        local da_id = c4_home.get_da_device_id()
        if source_selected == da_id then
            -- Streaming source: ROOM_OFF target first, then delayed ADD_ROOMS_TO_SESSION
            send_fn(room_id, "ROOM_OFF", {})
            C4:SetTimer(3000, function()
                local ok, timer_err = pcall(send_fn, da_id, "ADD_ROOMS_TO_SESSION", {
                    ROOM_ID = tostring(source_room_id),
                    ROOM_ID_LIST = tostring(room_id),
                })
                if not ok then
                    C4:ErrorLog("join_session ADD_ROOMS_TO_SESSION failed: " .. tostring(timer_err))
                end
            end, false)
        else
            -- Hardware source: ADD_ROOMS_TO_SESSION + SELECT_AUDIO_DEVICE
            send_fn(da_id, "ADD_ROOMS_TO_SESSION", {
                ROOM_ID = tostring(source_room_id),
                ROOM_ID_LIST = tostring(room_id),
            })
            -- Only send SELECT_AUDIO_DEVICE if the source device is available in the target room
            if c4_home.is_room_source(room_id, source_selected) then
                send_fn(room_id, "SELECT_AUDIO_DEVICE", { deviceid = source_selected })
            end
        end
        return "join_session initiated for " .. source_room.name
    end

    return nil, "Unknown action '" .. tostring(action) .. "'"
end

--------------------------------------------------------------------------------
-- MCP Tool Registration
--------------------------------------------------------------------------------

function M.register_media_tools(mcp_server)
    -- get_media
    mcp_server:register_tool("get_media", {
        description = "Get media/entertainment status for rooms. Returns what's playing, volume, available sources (with broadcast audio stations/favorites for streaming services), and controls. Use station mediaid values with select_station action.",
        inputSchema = {
            type = "object",
            properties = {
                room_id = { type = "number", description = "Room ID. Omit to get all media-capable rooms." },
            },
        },
    }, function(args)
        -- Fetch session map once for all rooms
        local session_map = fetch_session_map()

        if args.room_id ~= nil then
            local room_id = tonumber(args.room_id)
            if not room_id then
                return { content = {{ type = "text", text = "Error: room_id must be a number" }}, isError = true }
            end
            if not c4_home.is_media_room(room_id) then
                local room = c4_home.get_room(room_id)
                if not room then
                    return { content = {{ type = "text", text = "Error: Room " .. room_id .. " not found" }}, isError = true }
                end
                return { content = {{ type = "text", text = "Error: Room " .. room.name .. " (" .. room_id .. ") is not media-capable" }}, isError = true }
            end
            local status, err = build_room_media_status(room_id, session_map)
            if not status then
                return { content = {{ type = "text", text = "Error: " .. err }}, isError = true }
            end
            return status
        end

        -- No room_id: return all media-capable rooms
        local media_rooms = c4_home.list_media_rooms()
        local result = {}
        for _, room_id in ipairs(media_rooms) do
            local status = build_room_media_status(room_id, session_map)
            if status then
                result[#result + 1] = status
            end
        end
        return result
    end)

    -- control_media
    mcp_server:register_tool("control_media", {
        description = "Control media playback and volume in a room. Actions: play, pause, play_pause, stop, skip_fwd, skip_rev, set_volume, volume_up, volume_down, mute, unmute, mute_toggle, room_off, select_source, join_session, set_channel, channel_up, channel_down, select_station.",
        inputSchema = {
            type = "object",
            properties = {
                room_id = { description = "Target room ID (number), or \"all\" for all media-capable rooms" },
                action = {
                    type = "string",
                    enum = {"play", "pause", "play_pause", "stop", "skip_fwd", "skip_rev", "set_volume", "volume_up", "volume_down", "mute", "unmute", "mute_toggle", "room_off", "select_source", "join_session", "set_channel", "channel_up", "channel_down", "select_station"},
                    description = "Media action to perform",
                },
                params = {
                    type = "object",
                    description = "Action parameters. set_volume: {level: 0-100}. volume_up/down: {step: 1-20, default 5}. select_source: {device_id: N}. join_session: {source_room_id: N}. set_channel: {channel: N}. select_station: {mediaid: N}.",
                },
            },
            required = {"room_id", "action"},
        },
    }, function(args)
        if not args.action then
            return { content = {{ type = "text", text = "Error: action is required" }}, isError = true }
        end

        local send_fn = function(device_id, command, params)
            C4:SendToDevice(device_id, command, params or {})
        end

        -- room_id = "all": dispatch to all media-capable rooms
        if args.room_id == "all" then
            -- Reject actions that require per-room device/session context.
            -- set_channel is allowed (same channel to all rooms is reasonable).
            if args.action == "select_source" or args.action == "join_session" or args.action == "select_station" then
                return { content = {{ type = "text", text = "Error: " .. args.action .. " requires a specific room_id, cannot use 'all'" }}, isError = true }
            end
            local media_rooms = c4_home.list_media_rooms()
            local count = 0
            local skipped = 0
            for _, rid in ipairs(media_rooms) do
                if not control_mod.is_write_allowed(rid) then
                    skipped = skipped + 1
                else
                    local msg = dispatch_action(rid, args.action, args.params, send_fn)
                    if msg then
                        count = count + 1
                    else
                        skipped = skipped + 1
                    end
                end
            end
            local text = args.action .. " sent to " .. count .. " rooms"
            if skipped > 0 then
                text = text .. " (" .. skipped .. " skipped)"
            end
            return { content = {{ type = "text", text = text }}, isError = false }
        end

        -- Single room
        local room_id = tonumber(args.room_id)
        if not room_id then
            return { content = {{ type = "text", text = "Error: room_id must be a number or \"all\"" }}, isError = true }
        end
        if not c4_home.is_media_room(room_id) then
            local room = c4_home.get_room(room_id)
            if not room then
                return { content = {{ type = "text", text = "Error: Room " .. room_id .. " not found" }}, isError = true }
            end
            return { content = {{ type = "text", text = "Error: Room " .. room.name .. " (" .. room_id .. ") is not media-capable" }}, isError = true }
        end

        -- Check write access
        if not control_mod.is_write_allowed(room_id) then
            local room = c4_home.get_room(room_id)
            local room_name = room and room.name or tostring(room_id)
            return { content = {{ type = "text", text = "Error: Room " .. room_name .. " (" .. room_id .. ") is not allowed for write operations" }}, isError = true }
        end

        local msg, err = dispatch_action(room_id, args.action, args.params, send_fn)
        if not msg then
            return { content = {{ type = "text", text = "Error: " .. err }}, isError = true }
        end

        local room = c4_home.get_room(room_id)
        local room_name = room and room.name or tostring(room_id)
        return { content = {{ type = "text", text = room_name .. ": " .. msg }}, isError = false }
    end)
end

return M
