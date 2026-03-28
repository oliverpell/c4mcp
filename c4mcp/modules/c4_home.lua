-- Layer 3: C4 Smart Home API
-- Project items parsing, device cache, state reading, and read tool registration

local device_config = require("modules.device_config")
local device_types = require("modules.device_types")

local M = {}

-- Internal caches
local _rooms = {}     -- {[roomId] = {id, name, floor}}
local _devices = {}   -- {[deviceId] = {id, name, type, room_id, room_name, driver_name}}
local _scale = "C"    -- Temperature scale from project
-- Media source caches (built in refresh_cache)
local _room_sources = {}  -- {[roomId] = {sources=[], listen_ids={}, watch_ids={}}}
local _media_rooms = {}   -- {[roomId] = true} for rooms with non-empty source lists
-- Universal Digital Audio system device ID. Same (100002) on all known
-- controllers and OS versions. Accessed via M.get_da_device_id().
local DA_DEVICE_ID = 100002
-- Forward declaration: refresh_source_cache is called at the end of refresh_cache
-- but defined after it. Lua 5.1 requires a local to be declared before closure capture.
local refresh_source_cache

-- Proxy type to MCP device type mapping
local PROXY_TYPE_MAP = {
    ["light_v2.c4i"]       = "light",
    ["light.c4i"]          = "light",
    ["thermostatV2.c4i"]   = "thermostat",
    ["lock.c4i"]           = "lock",
    ["blind.c4i"]          = "blind",
    ["uibutton.c4i"]       = "custom_device",
    ["relay.c4i"]          = "relay",
    ["contactsingle.c4i"]  = "sensor",
    ["motionsensor.c4i"]   = "sensor",
    ["securitysystem.c4i"] = "security",
    ["camera.c4i"]         = "camera",
    ["doorstation.c4i"]    = "door_station",
    -- Media devices (excluded from get_devices, used for name resolution in get_media)
    ["receiver.c4i"]       = "media",
    ["amplifier.c4i"]      = "media",
    ["avswitch.c4i"]       = "media",
    ["audioswitch.c4i"]    = "media",
    ["mediaplayer.c4i"]    = "media",
    ["media_player.c4i"]   = "media",
    ["media_service.c4i"]  = "media",
    ["tv.c4i"]             = "media",
    ["tuner.c4i"]          = "media",
    ["satellite.c4i"]      = "media",
    ["dvd.c4i"]            = "media",
    ["cd.c4i"]             = "media",
}

--- Find first child node with matching tag name
local function find_child(node, tagName)
    if not node or not node.ChildNodes then return nil end
    for _, child in ipairs(node.ChildNodes) do
        if child.Name == tagName then return child end
    end
    return nil
end

--- Get text content of a node
local function get_text(node)
    if not node then return nil end
    return node.Value
end

--- Recursively find all items of a given type in the tree
local function find_items_by_type(node, item_type, results)
    results = results or {}
    if not node then return results end
    if node.Name == "item" then
        local typeNode = find_child(node, "type")
        if typeNode and get_text(typeNode) == tostring(item_type) then
            results[#results + 1] = node
        end
        -- Recurse into subitems of this item
        local subitems = find_child(node, "subitems")
        if subitems then
            for _, child in ipairs(subitems.ChildNodes or {}) do
                find_items_by_type(child, item_type, results)
            end
        end
    else
        -- Non-item node (root, systemitems, etc): recurse all children
        for _, child in ipairs(node.ChildNodes or {}) do
            find_items_by_type(child, item_type, results)
        end
    end
    return results
end

--- Build a room_id → floor_name lookup table from the project tree
local function build_floor_lookup(root)
    local room_to_floor = {}
    local floors = find_items_by_type(root, 4)
    for _, floor in ipairs(floors) do
        local nameNode = find_child(floor, "name")
        local floor_name = get_text(nameNode) or "Unknown"
        local floor_subitems = find_child(floor, "subitems")
        if floor_subitems and floor_subitems.ChildNodes then
            for _, child in ipairs(floor_subitems.ChildNodes) do
                if child.Name == "item" then
                    local typeNode = find_child(child, "type")
                    local idNode = find_child(child, "id")
                    if typeNode and get_text(typeNode) == "8" and idNode then
                        local rid = tonumber(get_text(idNode))
                        if rid then room_to_floor[rid] = floor_name end
                    end
                end
            end
        end
    end
    return room_to_floor
end

--- Refresh the device and room caches from C4:GetProjectItems()
function M.refresh_cache()
    _rooms = {}
    _devices = {}

    local xml = C4:GetProjectItems()
    if not xml or xml == "" then return end

    local tree = C4:ParseXml(xml)
    if not tree then return end

    -- Extract scale from project item (type=1)
    local projects = find_items_by_type(tree, 1)
    if #projects > 0 then
        local itemdata = find_child(projects[1], "itemdata")
        if itemdata then
            local scaleNode = find_child(itemdata, "scale")
            if scaleNode then
                local scaleVal = get_text(scaleNode)
                if scaleVal == "FAHRENHEIT" then
                    _scale = "F"
                else
                    _scale = "C"
                end
            end
        end
    end

    -- Extract rooms (type=8) with floor lookup
    local room_to_floor = build_floor_lookup(tree)
    local room_items = find_items_by_type(tree, 8)
    for _, item in ipairs(room_items) do
        local idNode = find_child(item, "id")
        local nameNode = find_child(item, "name")
        if idNode then
            local id = tonumber(get_text(idNode))
            if id then
                _rooms[id] = {
                    id = id,
                    name = get_text(nameNode) or "Unknown",
                    floor = room_to_floor[id] or "Unknown",
                }
            end
        end
    end

    -- Helper: extract a proxy (type 7) item into _devices
    -- All proxies are stored for name resolution (media sources, etc.)
    -- Proxies with unrecognized c4i types get type=nil and are excluded from list_devices
    local function add_proxy(item, parent_id, parent_driver)
        local idNode = find_child(item, "id")
        local nameNode = find_child(item, "name")
        local c4iNode = find_child(item, "c4i")
        if not idNode then return end
        local id = tonumber(get_text(idNode))
        if not id then return end
        local c4i = c4iNode and get_text(c4iNode)
        local device_type = c4i and PROXY_TYPE_MAP[c4i] or nil

        local room_id = nil
        local room_name = ""
        local driver_name = parent_driver or ""

        -- Get driver name and room_id from proxy's own itemdata
        local itemdata = find_child(item, "itemdata")
        if itemdata then
            -- Only use proxy's config_data_file if no parent driver provided
            if driver_name == "" then
                local configFile = find_child(itemdata, "config_data_file")
                if configFile then
                    driver_name = get_text(configFile) or ""
                end
            end
            local roomIdNode = find_child(itemdata, "room_id")
            if roomIdNode then
                room_id = tonumber(get_text(roomIdNode))
            end
        end

        -- Resolve room name
        if room_id and _rooms[room_id] then
            room_name = _rooms[room_id].name
        end

        _devices[id] = {
            id = id,
            name = get_text(nameNode) or "Unknown",
            type = device_type,
            room_id = room_id,
            room_name = room_name,
            driver_name = driver_name,
            parent_id = parent_id,
            c4i = c4i,
        }
    end

    -- Extract devices (type 6) and find their proxy children (type 7)
    -- On real controllers, proxies are nested under their parent device.
    -- The parent's config_data_file has the real driver name (e.g. "garagedoor_relay_control.c4z"),
    -- while the proxy's config_data_file is just the proxy type (e.g. "uibutton.c4i").
    local device_items = find_items_by_type(tree, 6)
    for _, dev_item in ipairs(device_items) do
        local dev_id_node = find_child(dev_item, "id")
        local dev_id = dev_id_node and tonumber(get_text(dev_id_node))

        -- Get parent driver name from device's itemdata
        local parent_driver = ""
        local dev_itemdata = find_child(dev_item, "itemdata")
        if dev_itemdata then
            local cf = find_child(dev_itemdata, "config_data_file")
            if cf then parent_driver = get_text(cf) or "" end
        end

        -- Find proxy children (type 7) under this device's subitems
        local dev_subitems = find_child(dev_item, "subitems")
        if dev_subitems then
            for _, proxy in ipairs(find_items_by_type(dev_subitems, 7)) do
                add_proxy(proxy, dev_id, parent_driver)
            end
        end
    end

    -- Also scan for standalone type 7 proxies (mock XML format, or proxies
    -- not nested under a type 6 device). Skip any already found above.
    local proxy_items = find_items_by_type(tree, 7)
    for _, item in ipairs(proxy_items) do
        local idNode = find_child(item, "id")
        if idNode then
            local id = tonumber(get_text(idNode))
            if id and not _devices[id] then
                add_proxy(item, nil, nil)
            end
        end
    end

    -- Also check if devices are nested under rooms (real controller format)
    -- Build reverse map: proxy_id → room_id (single pass)
    local proxy_to_room = {}
    for _, room_item in ipairs(room_items) do
        local ridNode = find_child(room_item, "id")
        local room_subitems = find_child(room_item, "subitems")
        if ridNode and room_subitems then
            local rid = tonumber(get_text(ridNode))
            for _, proxy in ipairs(find_items_by_type(room_subitems, 7)) do
                local pidNode = find_child(proxy, "id")
                if pidNode then
                    proxy_to_room[tonumber(get_text(pidNode))] = rid
                end
            end
        end
    end
    for did, dev in pairs(_devices) do
        if not dev.room_id then
            local rid = proxy_to_room[did]
            if rid then
                dev.room_id = rid
                dev.room_name = _rooms[rid] and _rooms[rid].name or ""
            end
        end
    end

    -- Enrich devices with capabilities from JUST_CAPABILITIES filter
    local caps_xml = C4:GetProjectItems("JUST_CAPABILITIES")
    if caps_xml and caps_xml ~= "" then
        local caps_tree = C4:ParseXml(caps_xml)
        if caps_tree then
            -- Find all items in the capabilities XML (any type)
            local function find_all_items(node, results)
                results = results or {}
                if not node then return results end
                if node.Name == "item" then
                    results[#results + 1] = node
                end
                for _, child in ipairs(node.ChildNodes or {}) do
                    find_all_items(child, results)
                end
                return results
            end
            for _, item in ipairs(find_all_items(caps_tree)) do
                local idNode = find_child(item, "id")
                local id = idNode and tonumber(get_text(idNode))
                if id and _devices[id] then
                    local caps_node = find_child(item, "capabilities")
                    if caps_node then
                        local caps = {}
                        for _, child in ipairs(caps_node.ChildNodes or {}) do
                            caps[child.Name] = get_text(child)
                        end
                        _devices[id].capabilities = caps
                    end
                end
            end
        end
    end

    -- Build media source cache for all rooms (must be after _rooms and _devices are populated)
    refresh_source_cache()
end

--------------------------------------------------------------------------------
-- Media Source Discovery
--------------------------------------------------------------------------------

-- Source types to exclude from user-facing lists
local INTERNAL_SOURCE_TYPES = {
    DIGITAL_AUDIO_CLIENT = true,
    SPECIAL_AUDIO = true,
    UIButton = true,
}

-- Built-in C4 browse-only MSP sources (UI navigation only, no MCP value)
local BROWSE_ONLY_DRIVERS = {
    ["AddMusic.c4z"]  = true,
    ["MyMusic.c4z"]   = true,
    ["Stations.c4z"]  = true,
    ["Channels.c4z"]  = true,
    ["MyMovies.c4z"]  = true,
}

--- Parse source XML into {[id] = type} table, excluding internal types
local function parse_source_xml(xml)
    local sources = {}
    for id, typ in (xml or ""):gmatch("<source>%s*<id>(%d+)</id>%s*<type>(.-)</type>%s*</source>") do
        local nid = tonumber(id)
        if nid and not INTERNAL_SOURCE_TYPES[typ] then
            sources[nid] = typ
        end
    end
    return sources
end

--- Build combined source list for a room
-- GET_LISTEN_DEVICES and GET_WATCH_DEVICES are synchronous room queries that
-- return XML directly (verified on real controller). This is an intentional
-- exception to the normal fire-and-forget pattern for C4:SendToDevice.
local function build_room_sources(room_id)
    local listen_xml = C4:SendToDevice(room_id, "GET_LISTEN_DEVICES", {})
    local watch_xml = C4:SendToDevice(room_id, "GET_WATCH_DEVICES", {})

    local listen = parse_source_xml(listen_xml)
    local watch = parse_source_xml(watch_xml)

    local sources = {}
    local seen = {}

    -- Video sources first (watch list takes priority for overlap)
    for id, _ in pairs(watch) do
        seen[id] = true
        local dev = _devices[id]
        if not (dev and BROWSE_ONLY_DRIVERS[dev.driver_name]) then
            sources[#sources + 1] = {
                id = id,
                name = dev and dev.name or ("Device " .. id),
                category = "video",
            }
        end
    end
    -- Audio sources (skip any already added from watch)
    for id, _ in pairs(listen) do
        if not seen[id] then
            local dev = _devices[id]
            if not (dev and BROWSE_ONLY_DRIVERS[dev.driver_name]) then
                sources[#sources + 1] = {
                    id = id,
                    name = dev and dev.name or ("Device " .. id),
                    category = "audio",
                }
            end
        end
    end

    table.sort(sources, function(a, b) return a.id < b.id end)
    return sources, listen, watch
end

--- Refresh the media source cache for all rooms
refresh_source_cache = function()
    _room_sources = {}
    _media_rooms = {}
    for roomId, _ in pairs(_rooms) do
        local sources, listen_ids, watch_ids = build_room_sources(roomId)
        _room_sources[roomId] = {
            sources = sources,
            listen_ids = listen_ids,
            watch_ids = watch_ids,
        }
        if #sources > 0 then
            _media_rooms[roomId] = true
        end
    end
end

--- Get cached source list for a room
function M.get_room_sources(room_id)
    local cache = _room_sources[room_id]
    return cache and cache.sources or {}
end

--- Check if a room has media capability
function M.is_media_room(room_id)
    return _media_rooms[room_id] == true
end

--- List all media-capable room IDs
function M.list_media_rooms()
    local result = {}
    for roomId, _ in pairs(_media_rooms) do
        result[#result + 1] = roomId
    end
    table.sort(result)
    return result
end

--- Check if a device is a video (watch) source in a room
function M.is_watch_source(room_id, device_id)
    local cache = _room_sources[room_id]
    return cache and cache.watch_ids[device_id] ~= nil
end

--- Check if a device is in a room's source list (audio or video)
function M.is_room_source(room_id, device_id)
    local cache = _room_sources[room_id]
    if not cache then return false end
    return cache.listen_ids[device_id] ~= nil or cache.watch_ids[device_id] ~= nil
end

--- Get the DA device ID constant
function M.get_da_device_id()
    return DA_DEVICE_ID
end

--------------------------------------------------------------------------------
-- Room Media Status Helpers
--------------------------------------------------------------------------------

--- Decode XML entities in a string
local function xml_decode(s)
    if not s then return s end
    -- Decode &amp; last to avoid double-decoding (e.g. &amp;lt; → &lt; → <)
    s = s:gsub("&lt;", "<")
    s = s:gsub("&gt;", ">")
    s = s:gsub("&apos;", "'")
    s = s:gsub("&quot;", '"')
    s = s:gsub("&amp;", "&")
    return s
end

--- Parse now-playing from var 1031 (CURRENT MEDIA INFO) XML.
-- Returns nil if both title and artist are absent.
-- Returns a partial object if only one is present (some stations omit one).
-- @param xml string|nil Variable 1031 value
-- @return table|nil {title, artist, album, media_type, state} or nil
function M.parse_now_playing(xml)
    if not xml or xml == "" then return nil end

    local title = xml:match("<title>(.-)</title>")
    local artist = xml:match("<artist>(.-)</artist>")
    local album = xml:match("<album>(.-)</album>")
    local media_type = xml:match("<mediatype>(.-)</mediatype>")
    local stream_status = xml:match("<streamStatus>(.-)</streamStatus>")

    -- Parse stream status for playback state
    local state = nil
    if stream_status then
        if stream_status:find("status=OK_playing") then state = "playing"
        elseif stream_status:find("status=OK_paused") then state = "paused"
        end
    end

    if not title and not artist then return nil end

    return {
        title = xml_decode(title),
        artist = xml_decode(artist),
        album = (album and album ~= "" and album ~= "content") and xml_decode(album) or nil,
        media_type = media_type,
        state = state,
    }
end

--- Resolve the selected device name for a room given room variables
-- For streaming (var 1000 == DA device), uses var 1036 (PLAYING_AUDIO_DEVICE)
-- @param selected number CURRENT_SELECTED_DEVICE value
-- @param playing_audio number PLAYING_AUDIO_DEVICE value
-- @return number|nil device_id, string name
function M.resolve_selected_device(selected, playing_audio)
    if not selected or selected == 0 then return nil, nil end
    if selected == DA_DEVICE_ID then
        -- Streaming: resolve from PLAYING_AUDIO_DEVICE
        if playing_audio and playing_audio > 0 then
            local dev = _devices[playing_audio]
            return playing_audio, dev and dev.name or ("Device " .. playing_audio)
        end
        return DA_DEVICE_ID, "Digital Audio"
    end
    local dev = _devices[selected]
    return selected, dev and dev.name or ("Device " .. selected)
end

--- Get the temperature scale
function M.get_scale()
    return _scale
end

--- List all rooms
-- @return table Array of {id, name, floor}
function M.list_rooms()
    local result = {}
    for _, room in pairs(_rooms) do
        result[#result + 1] = { id = room.id, name = room.name, floor = room.floor }
    end
    table.sort(result, function(a, b) return a.id < b.id end)
    return result
end

--- List devices with optional filtering
-- @param opts table {room_id, device_type}
-- @return table Array of device info
function M.list_devices(opts)
    opts = opts or {}
    local result = {}
    for _, dev in pairs(_devices) do
        -- Only include devices with recognized non-media types
        -- (media devices controlled via get_media/control_media, unknown types excluded)
        if dev.type and dev.type ~= "media" then
            local match = true
            if opts.room_id and dev.room_id ~= opts.room_id then match = false end
            if opts.device_type and dev.type ~= opts.device_type then match = false end
            if match then
                result[#result + 1] = {
                    id = dev.id,
                    name = dev.name,
                    type = dev.type,
                    room_id = dev.room_id,
                    room_name = dev.room_name,
                }
            end
        end
    end
    table.sort(result, function(a, b) return a.id < b.id end)
    return result
end

--- Get a device from cache
-- @param deviceId number
-- @return table|nil
function M.get_device(deviceId)
    return _devices[deviceId]
end

--- Get a room from cache
-- @param roomId number
-- @return table|nil
function M.get_room(roomId)
    return _rooms[roomId]
end

--- Get device capabilities from cache
-- @param deviceId number
-- @return table Capabilities table (empty if none)
function M.get_device_capabilities(deviceId)
    local dev = _devices[deviceId]
    return dev and dev.capabilities or {}
end


--- Get device state by type (delegates to device_types registry)
-- @param deviceId number
-- @param vars_cache table|nil Optional cache of {[deviceId] = vars} to avoid duplicate GetDeviceVariables calls
-- @return table|nil State table or nil if device not found
function M.get_device_state(deviceId, vars_cache)
    local dev = _devices[deviceId]
    if not dev then return nil end

    local handler = device_types.get_handler(dev.type)
    if not handler or not handler.get_state then return {} end

    local vars
    if vars_cache and vars_cache[deviceId] then
        vars = vars_cache[deviceId]
    else
        vars = C4:GetDeviceVariables(deviceId)
        if vars_cache then vars_cache[deviceId] = vars end
    end
    return handler.get_state(deviceId, dev, vars, vars_cache)
end

--- Check if a light is on (lightweight — avoids building full state)
-- @param deviceId number
-- @param vars table|nil Optional pre-fetched variables
-- @return boolean
function M.is_light_on(deviceId, vars)
    if not vars then
        vars = C4:GetDeviceVariables(deviceId)
    end
    if not vars then return false end
    local light_state, brightness
    for _, v in pairs(vars) do
        if v.name == "LIGHT_STATE" then light_state = v.value
        elseif v.name == "Brightness Percent" then brightness = v.value
        end
    end
    if light_state ~= nil then return light_state == "1" end
    if brightness ~= nil then return (tonumber(brightness) or 0) > 0 end
    return false
end


--- Register read tools with an MCP server
-- @param mcp_server table MCP server from mcp_server.lua
function M.register_read_tools(mcp_server)
    -- get_home
    mcp_server:register_tool("get_home", {
        description = "Get an overview of the smart home: room list and device summary stats. Call this first to orient yourself.",
        inputSchema = { type = "object", properties = {} },
    }, function(args)
        local rooms = M.list_rooms()
        local devices = M.list_devices()
        local active_lights = 0
        local type_counts = {}
        local vars_cache = {}
        local room_stats = {}
        for _, dev in ipairs(devices) do
            type_counts[dev.type] = (type_counts[dev.type] or 0) + 1
            local rs = room_stats[dev.room_id]
            if not rs then
                rs = { device_count = 0, active_lights = 0 }
                room_stats[dev.room_id] = rs
            end
            rs.device_count = rs.device_count + 1
            if dev.type == "light" then
                if not vars_cache[dev.id] then
                    vars_cache[dev.id] = C4:GetDeviceVariables(dev.id)
                end
                if M.is_light_on(dev.id, vars_cache[dev.id]) then
                    active_lights = active_lights + 1
                    rs.active_lights = rs.active_lights + 1
                end
            end
        end
        for _, room in ipairs(rooms) do
            local rs = room_stats[room.id]
            if rs then
                room.device_count = rs.device_count
                room.active_lights = rs.active_lights
            else
                rs = {}
                room_stats[room.id] = rs
                room.device_count = 0
                room.active_lights = 0
            end
            -- Get temperature from Composer-configured temperature source
            local room_vars = C4:GetDeviceVariables(room.id)
            if room_vars then
                -- Scan room vars by name for temperature source
                local temp_id
                for _, v in pairs(room_vars) do
                    if v.name == "TEMPERATURE_ID" then
                        temp_id = tonumber(v.value)
                        break
                    end
                end
                if temp_id and temp_id > 0 then
                    local temp_vars = C4:GetDeviceVariables(temp_id)
                    if temp_vars then
                        for _, v in pairs(temp_vars) do
                            if v.name == "TEMPERATURE_C" then room.temperature_c = tonumber(v.value)
                            elseif v.name == "TEMPERATURE_F" then room.temperature_f = tonumber(v.value)
                            end
                        end
                    end
                end

                -- Add media summary for media-capable rooms (zero extra API calls)
                if M.is_media_room(room.id) then
                    local rv = {}  -- quick lookup by numeric var ID
                    for varId, v in pairs(room_vars) do
                        local nid = tonumber(varId)
                        if nid then rv[nid] = v.value end
                    end
                    local power = rv[1010] == "1"
                    local selected = tonumber(rv[1000]) or 0
                    local playing_audio = tonumber(rv[1036]) or 0
                    local device_group = rv[1032] or ""
                    local dev_id, dev_name = M.resolve_selected_device(selected, playing_audio)
                    local media_type = nil
                    if device_group == "watch" or device_group == "video" then media_type = "video"
                    elseif device_group == "listen" or device_group == "audio" then media_type = "audio"
                    end
                    room.media = {
                        power = power,
                        selected_device = dev_name,
                        selected_device_id = dev_id,
                        media_type = media_type,
                    }
                end
            end
        end
        return {
            rooms = rooms,
            device_count = #devices,
            active_lights = active_lights,
            device_types = type_counts,
        }
    end)

    -- get_devices
    mcp_server:register_tool("get_devices", {
        description = "Get devices with their current state. Filter by device_id (single device), room_id, or device_type. Always includes state with available actions in controls.actions — call this before control_device.",
        inputSchema = {
            type = "object",
            properties = {
                device_id = { type = "number", description = "Get a single device by ID" },
                room_id = { type = "number", description = "Filter by room ID" },
                device_type = { type = "string", description = "Filter by device type" },
                state_fields = { type = "array", description = "Optional: only include these state fields (e.g. ['power', 'level']). Omit for all fields.", items = { type = "string" } },
            },
        },
    }, function(args)
        -- Filter state to only requested fields (always keeps controls.actions)
        local function filter_state(state)
            if not state then return {} end
            if not args.state_fields then return state end
            local fields = args.state_fields
            if #fields == 0 then return state end
            local filtered = {}
            for _, field in ipairs(fields) do
                if state[field] ~= nil then filtered[field] = state[field] end
            end
            -- Always include controls (actions are essential for LLM)
            if state.controls then filtered.controls = state.controls end
            return filtered
        end

        if args.device_id ~= nil then
            local device_id = tonumber(args.device_id)
            local dev = M.get_device(device_id)
            if not dev then
                return { content = {{ type = "text", text = "Error: Device " .. tostring(device_id) .. " not found" }}, isError = true }
            end
            local state = filter_state(M.get_device_state(device_id, {}))
            return { device_id = dev.id, name = dev.name, type = dev.type, room_id = dev.room_id, room_name = dev.room_name, state = state }
        end
        if args.room_id ~= nil then
            args.room_id = tonumber(args.room_id)
            local room = M.get_room(args.room_id)
            if not room then
                return { content = {{ type = "text", text = "Error: Room " .. tostring(args.room_id) .. " not found" }}, isError = true }
            end
        end
        local devices = M.list_devices({ room_id = args.room_id, device_type = args.device_type })
        local vars_cache = {}
        for _, dev in ipairs(devices) do
            dev.state = filter_state(M.get_device_state(dev.id, vars_cache))
        end
        return devices
    end)

    -- get_device_profiles
    mcp_server:register_tool("get_device_profiles", {
        description = "Get the current Device Profiles configuration. Device Profiles define how custom devices and thermostats are exposed — mapping device IDs to categories, state labels, parameterized actions (with valid values), and extra variables. Returns user-configured overrides and a count of built-in profiles.",
        inputSchema = { type = "object", properties = {} },
    }, function(args)
        local user_cfg = device_config.get_user_config()
        local user_count = 0
        for _ in pairs(user_cfg) do user_count = user_count + 1 end
        local builtin_count = 0
        for _ in pairs(device_config.BUILTIN_PROFILES) do builtin_count = builtin_count + 1 end
        return {
            profiles = user_cfg,
            summary = {
                user_configured = user_count,
                builtin_profiles = builtin_count,
            },
        }
    end)

    -- configure_device_profiles
    mcp_server:register_tool("configure_device_profiles", {
        description = "Get a step-by-step workflow for configuring Device Profiles. Use this when custom devices show generic actions (toggle/on/off) but need device-specific commands (e.g. SetCountdown with preset values, setState with level ranges). Returns a prompt with the full JSON format spec and instructions to discover devices, ask the user about supported commands, build the config, and apply it.",
        inputSchema = { type = "object", properties = {} },
    }, function(args)
        return {
            content = {{ type = "text", text = [[Device Profiles Configuration Workflow
========================================

Follow these steps to configure device profiles:

1. Call `get_devices` to discover all devices in the project.

2. For each `custom_device`, call `get_devices` with its device_id to see its current profile (category, actions, extra variables). Built-in profiles already map real commands for known drivers. Unconfigured devices default to "select" (SELECT proxy command).

3. Ask the user about each device that needs configuration:
   - What commands does the device actually support? (e.g. SetCountdown, SetState, OPEN)
   - For parameterized commands: what are the valid parameter values?
   - Are there extra variables to expose (e.g. COUNTDOWN, RUNTIME)?
   - Does the device use a variable other than "STATE" for its primary state?
     (e.g. flood sensors use "FLOOD_DETECTED"). If so, set "state_var".

   IMPORTANT: Only configure commands that the device actually supports.
   Do NOT invent convenience actions or shortcuts — every action in the
   profile must map to a real command that the device handles. If the user
   says a device supports "setState(Level[0-4])", configure only that one
   action, not separate actions per level. Ask the user to confirm which
   commands exist before adding them.

   NOTE: Custom devices are typically experience button proxies (uibutton).
   Their ExecuteCommand handlers (EX_CMDS) live on the parent driver, not
   the proxy. Most custom device actions need "@parent" in the action
   string, otherwise the command is sent to the proxy and silently ignored.

4. For thermostats:
   a. Ask about setpoint type:
      - "single" (default) — uses SINGLE_SETPOINT_C, sends SET_SETPOINT_SINGLE
      - "heat" — uses HEAT_SETPOINT_C only, sends SET_SETPOINT_HEAT
      - "cool" — uses COOL_SETPOINT_C only, sends SET_SETPOINT_COOL
      - "heat_cool" — uses both HEAT_SETPOINT_C + COOL_SETPOINT_C, sends SET_SETPOINT_HEAT/COOL with target selection

   b. Ask about custom actions — some thermostats have extra ExecuteCommands
      beyond the built-in set_mode/set_setpoint/set_fan/set_hold. For example,
      a thermostat might support SET_DAY_TEMPERATURE or SET_SETBACK_TEMPERATURE
      to change the permanent schedule temperatures (as opposed to set_setpoint
      which creates a temporary override). These are configured in "actions"
      just like custom_device actions, and are sent via control_device.
      Use "@parent" if the command goes to the parent device, not the proxy.

      IMPORTANT: These actions change real thermostat schedules. Always confirm
      the exact command names, parameter names, and valid ranges with the user.

5. Build the Device Profiles JSON using this format:

   Keys are device IDs (as strings). Each entry can have:
   - "category": string — device category label
   - "states": {"0": "off", "1": "on"} — state value to label mapping
   - "actions": {name: "COMMAND(Param[values])"} — compact action syntax
   - "extra_vars": ["VAR1", "VAR2"] — extra variables to read
   - "state_var": "VAR_NAME" — variable to read as primary state (default: "STATE")
   - "setpoint_type": "single", "heat", "cool", or "heat_cool" — for thermostats only

   Compact action syntax:
   - "COMMAND" — no params
   - "COMMAND(Param[A,B,C])" — enum values
   - "COMMAND(Param[0-100])" — numeric range
   - "COMMAND(Param)" — any value
   - "COMMAND(P1[a,b], P2[0-5])" — multiple params
   - "... @parent" — send to parent device

   Example (custom device):
   {
     "243": {
       "category": "extract_fan",
       "states": {"0": "off", "1": "on"},
       "actions": {
         "on": "ON",
         "off": "OFF",
         "toggle": "TOGGLE",
         "set_countdown": "SetCountdown(Time[10,15,20,25,30,45,60]) @parent"
       },
       "extra_vars": ["COUNTDOWN", "RUNTIME"]
     }
   }

   Example (flood sensor with state_var):
   {
     "656": {
       "category": "flood_sensor",
       "state_var": "FLOOD_DETECTED",
       "states": {"0": "dry", "1": "flood detected"}
     }
   }

   Example (thermostat with custom actions):
   {
     "200": {
       "setpoint_type": "single",
       "actions": {
         "set_day_temperature": "SET_DAY_TEMPERATURE(Degrees[5-30]) @parent",
         "set_setback_temperature": "SET_SETBACK_TEMPERATURE(Degrees[5-30]) @parent"
       }
     }
   }

6. Call `set_device_profiles` with the JSON to apply it.

7. Verify by calling `get_devices` with device_id on configured devices to confirm the new profiles appear correctly.]] }},
        }
    end)
end

--- Register MCP resources
-- @param mcp_server table MCP server from mcp_server.lua
function M.register_resources(mcp_server)
    mcp_server:register_resource("c4://project", "Project", "Project information", function(uri)
        local rooms = M.list_rooms()
        local devices = M.list_devices()
        return { name = "Control4 Project", rooms = #rooms, devices = #devices, scale = _scale }
    end)

    mcp_server:register_resource_template("c4://rooms/{room_id}", "Room", "Room details", function(uri, room_id_str)
        local room_id = tonumber(room_id_str)
        local room = M.get_room(room_id)
        if not room then error("Room not found: " .. tostring(room_id)) end
        local devices = M.list_devices({ room_id = room_id })
        local vars_cache = {}
        for _, dev in ipairs(devices) do
            dev.state = M.get_device_state(dev.id, vars_cache)
        end
        return { room = room, devices = devices }
    end)

    mcp_server:register_resource_template("c4://devices/{device_id}", "Device", "Device details", function(uri, device_id_str)
        local device_id = tonumber(device_id_str)
        local dev = M.get_device(device_id)
        if not dev then error("Device not found: " .. tostring(device_id)) end
        local state = M.get_device_state(device_id)
        return { device = dev, state = state }
    end)
end

return M
