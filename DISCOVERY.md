# Read-only device discovery

Use `discover_devices` to list all project drivers and proxies. The list includes device types that `get_devices` omits. Discovery does not add control actions or change device profiles.

Call the tool with no arguments to list device metadata. Use `room_id` to filter the list. The list includes driver names, proxy types, parent IDs, and rooms where available.

Pass a `device_id` from the list to read that device's raw variables. Pass `variable_names` to return only variables with those exact names. Raw variable values can contain private data. Inventory calls do not read variable values.

A property visible in Composer may not be available as a device variable. `variables_available: false` means the read failed or returned no variable table. An empty variable list can also mean that no variables matched the requested names. Neither result means that motion is inactive.

The tool requires a Read key or higher. Use the existing Refresh Device Cache action after changing the Control4 project.

## Local checks

Run from the repository root:

```sh
luac -p c4mcp/modules/c4_home.lua
lua tests/discovery.lua
```

Build and install the driver with the normal project workflow. Reconnect the MCP client after installation to reload the tool list.
