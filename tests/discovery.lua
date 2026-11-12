package.path = './c4mcp/?.lua;' .. package.path
local home = require('modules.c4_home')
local function set_upvalue(fn, name, value)
    for i = 1, 100 do
        local key = debug.getupvalue(fn, i)
        if not key then break end
        if key == name then debug.setupvalue(fn, i, value); return end
    end
    error('Missing upvalue: ' .. name)
end
local function node(name, value, children)
    return {Name = name, Value = value, ChildNodes = children}
end
local function item(kind, id, name, driver, children)
    return node('item', nil, {
        node('type', tostring(kind)), node('id', tostring(id)), node('name', name),
        node('c4i', driver),
        node('itemdata', nil, {node('config_data_file', driver)}),
        node('subitems', nil, children or {}),
    })
end
local tree = node('systemitems', nil, {
    item(8, 37, 'Example Room', '', {
        item(6, 1252, 'Example Driver', 'example_sensor.c4z', {
            item(7, 1253, 'Example Sensor', 'example_sensor.c4z'),
        }),
    }),
})
C4 = {
    GetProjectItems = function(_, filter) return filter and '' or 'fixture' end,
    ParseXml = function() return tree end,
}
set_upvalue(home.refresh_cache, 'refresh_source_cache', function() end)
home.refresh_cache()
local tools = {}
home.register_read_tools({register_tool = function(_, name, spec, handler, permission)
    tools[name] = {handler = handler, permission = permission}
end})
local reads = 0
C4 = {GetDeviceVariables = function(_, id)
    reads = reads + 1
    assert(id == 1253)
    return {[1] = {name = 'MOTION', value = 'Active'}, [2] = {name = 'BATTERY', value = 'Good'}}
end}
local discover = tools.discover_devices.handler
assert(tools.discover_devices.permission == 'read')
assert(discover({}).count == 2)
assert(discover({room_id = 37}).count == 2)
assert(reads == 0, 'Inventory must not read all device variables')
assert(discover({room_id = 99}).count == 0)
local result = discover({device_id = 1253, variable_names = {'MOTION'}})
assert(result.variables_available and #result.variables == 1)
assert(result.variables[1].value == 'Active')
assert(result.device.recognized_type == nil)
assert(result.device.parent_id == 1252)
assert(result.device.room_name == 'Example Room')
assert(#home.list_devices() == 0, 'Discovery must not enable unknown devices for control')
assert(discover({device_id = 999}).isError)
C4.GetDeviceVariables = function() error('Unavailable') end
assert(discover({device_id = 1253}).variables_available == false)
C4.GetDeviceVariables = function() return nil end
assert(discover({device_id = 1253}).variables_available == false)
print('Discovery checks passed')
