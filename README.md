# C4MCP — Control4 MCP Server

**[Download c4mcp.c4z](https://github.com/oliverpell/c4mcp/releases/latest/download/c4mcp.c4z)**

A Control4 DriverWorks driver that exposes your smart home via the [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) over HTTP. Point any MCP-compatible AI client — Claude Code, Claude Desktop, OpenClaw, etc. — at your controller and control your home with natural language.

**Requires**: Control4 OS 2.10.5+. HTTPS requires OS 3.3.0+.

## What It Does

- Runs an MCP server directly on the Control4 controller — no external server needed
- Exposes device state, room layout, and control via standard MCP tools
- Supports lights, thermostats, blinds, locks, relays, sensors, experience buttons, and more
- Room-centric media control — play/pause, volume, source selection, broadcast audio stations, multi-room sessions
- Bearer token authentication for LAN security
- HTTP and HTTPS transport

## Quick Start

1. [Download c4mcp.c4z](https://github.com/oliverpell/c4mcp/releases/latest/download/c4mcp.c4z) (or build from source — see [Building](#building))
2. Install `c4mcp.c4z` on your controller via Composer Pro (search under Controllers)
3. Go to the driver's **Actions** tab and press **Generate API Key**. Copy the key from the **Last Generated Key** property (auto-clears after 30s)
4. Configure your MCP client to connect to `http://<controller-ip>:9201/mcp` with the API key as a Bearer token

See the full [documentation](c4mcp/www/documentation.html) for client configuration examples, HTTPS setup, device profiles, troubleshooting, and more.

## Building

Requires [DriverPackager and DriverValidator](https://snap-one.github.io/docs-driverworks/) (Windows/WSL) in PATH.

```bash
make build    # Build c4mcp.c4z
make clean    # Remove build artifacts
```

Install the resulting `c4mcp/build/c4mcp.c4z` on your controller via Composer Pro.

## Project Structure

```
c4mcp/
├── driver.lua            # Entry point
├── driver.xml            # Driver manifest
├── c4mcp.c4zproj         # Build project file
├── modules/
│   ├── mcp_server.lua    # MCP JSON-RPC protocol handler
│   ├── http_server.lua   # Raw TCP → HTTP server
│   ├── server.lua        # Server lifecycle (HTTP/HTTPS)
│   ├── auth.lua          # API key authentication
│   ├── c4_home.lua       # Smart home data layer
│   ├── c4_media.lua      # Media status and control
│   ├── control.lua       # Device control dispatch
│   ├── device_config.lua # Custom device profiles
│   └── device_types.lua  # Per-type control handlers
└── www/
    └── documentation.html     # Full documentation
```

## License

[MIT](LICENSE)
