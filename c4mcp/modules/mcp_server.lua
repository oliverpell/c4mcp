-- Layer 2: MCP Protocol Handler (JSON-RPC 2.0)
-- Pure Lua, no C4 dependencies (except C4:JsonDecode via global)

local M = {}

local PROTOCOL_VERSION = "2025-03-26"

--- Check if a Lua table is an array (consecutive integer keys 1..n)
-- Sentinel key to force a table to serialize as a JSON object (not array).
-- Usage: { [JSON_OBJECT] = true }  -->  "{}"
local JSON_OBJECT = {}

local function is_array(t)
    if t[JSON_OBJECT] then return false end
    local n = #t
    if n == 0 then
        -- Empty table: array if no string keys
        return next(t) == nil
    end
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count == n
end

--- JSON-encode a value with proper array support.
-- json_encode doesn't distinguish arrays from objects, so we roll our own.
local json_encode
do
    local escape_chars = {
        ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n',
        ['\r'] = '\\r', ['\t'] = '\\t', ['\b'] = '\\b', ['\f'] = '\\f',
    }
    local function escape_string(s)
        return '"' .. s:gsub('[%z\1-\31\\"]', function(c)
            return escape_chars[c] or string.format("\\u%04x", string.byte(c))
        end) .. '"'
    end

    function json_encode(val)
        local t = type(val)
        if val == nil then return "null"
        elseif t == "boolean" then return val and "true" or "false"
        elseif t == "number" then
            if val ~= val then return "null" end  -- NaN
            if val == math.huge or val == -math.huge then return "null" end
            return tostring(val)
        elseif t == "string" then return escape_string(val)
        elseif t == "table" then
            if is_array(val) then
                local parts = {}
                for i = 1, #val do
                    parts[i] = json_encode(val[i])
                end
                return "[" .. table.concat(parts, ",") .. "]"
            else
                local parts = {}
                for k, v in pairs(val) do
                    if k ~= JSON_OBJECT then
                        parts[#parts + 1] = escape_string(tostring(k)) .. ":" .. json_encode(v)
                    end
                end
                return "{" .. table.concat(parts, ",") .. "}"
            end
        else
            return "null"
        end
    end
end

--- Create a new MCP server
-- @param opts table {server_name, server_version, instructions}
function M.create_mcp_server(opts)
    opts = opts or {}
    local server = {
        _name = opts.server_name or "c4mcp",
        _version = opts.server_version or "1.0.0",
        _instructions = opts.instructions or "",
        _tools = {},        -- {[name] = {schema, handler}}
        _resources = {},    -- {{uri, name, description, handler}}
        _templates = {},    -- {{uri_template, name, description}}
        _initialized = false,
    }

    --- Register a tool
    function server:register_tool(name, schema, handler_fn)
        self._tools[name] = { schema = schema, handler = handler_fn }
    end

    --- Register a static resource
    function server:register_resource(uri, name, description, handler_fn)
        self._resources[#self._resources + 1] = {
            uri = uri, name = name, description = description, handler = handler_fn,
        }
    end

    --- Register a resource template
    function server:register_resource_template(uri_template, name, description, handler_fn)
        self._templates[#self._templates + 1] = {
            uriTemplate = uri_template, name = name, description = description, handler = handler_fn,
        }
    end

    -- Internal: make a JSON-RPC error response
    local function rpc_error(id, code, message)
        return json_encode({
            jsonrpc = "2.0",
            id = id,
            error = { code = code, message = message },
        })
    end

    -- Internal: make a JSON-RPC success response
    local function rpc_result(id, result)
        return json_encode({
            jsonrpc = "2.0",
            id = id,
            result = result,
        })
    end

    -- Method handlers
    local methods = {}

    methods["initialize"] = function(id, params)
        server._initialized = true
        return rpc_result(id, {
            protocolVersion = PROTOCOL_VERSION,
            capabilities = {
                tools = { listChanged = false },
                resources = { subscribe = false, listChanged = false },
                logging = { [JSON_OBJECT] = true },
            },
            serverInfo = {
                name = server._name,
                version = server._version,
            },
            instructions = server._instructions,
        })
    end

    methods["notifications/initialized"] = function(id, params)
        if id ~= nil then return rpc_result(id, { [JSON_OBJECT] = true }) end
        return nil  -- notification, no response
    end

    methods["ping"] = function(id, params)
        return rpc_result(id, { [JSON_OBJECT] = true })
    end

    methods["tools/list"] = function(id, params)
        local tools = {}
        for name, tool in pairs(server._tools) do
            local schema = tool.schema.inputSchema or { type = "object", properties = { [JSON_OBJECT] = true } }
            -- Ensure properties serializes as JSON object {} not array []
            if schema.properties and not schema.properties[JSON_OBJECT] and next(schema.properties) == nil then
                schema = { type = schema.type, properties = { [JSON_OBJECT] = true }, required = schema.required }
            end
            tools[#tools + 1] = {
                name = name,
                description = tool.schema.description or "",
                inputSchema = schema,
            }
        end
        return rpc_result(id, { tools = tools })
    end

    methods["tools/call"] = function(id, params)
        if not params or not params.name then
            return rpc_error(id, -32602, "Missing tool name")
        end
        local tool = server._tools[params.name]
        if not tool then
            return rpc_result(id, {
                content = {{ type = "text", text = "Error: Unknown tool '" .. params.name .. "'" }},
                isError = true,
            })
        end
        local ok, result = pcall(tool.handler, params.arguments or {})
        if not ok then
            return rpc_result(id, {
                content = {{ type = "text", text = "Error: " .. tostring(result) }},
                isError = true,
            })
        end
        -- If handler returns a table with content already, use it
        if type(result) == "table" and result.content then
            return rpc_result(id, result)
        end
        -- Otherwise wrap as text content
        local text = type(result) == "string" and result or json_encode(result)
        return rpc_result(id, {
            content = {{ type = "text", text = text }},
            isError = false,
        })
    end

    methods["resources/list"] = function(id, params)
        local resources = {}
        for _, r in ipairs(server._resources) do
            resources[#resources + 1] = {
                uri = r.uri,
                name = r.name,
                description = r.description,
            }
        end
        return rpc_result(id, { resources = resources })
    end

    methods["resources/read"] = function(id, params)
        if not params or not params.uri then
            return rpc_error(id, -32602, "Missing resource URI")
        end
        -- Try static resources
        for _, r in ipairs(server._resources) do
            if r.uri == params.uri and r.handler then
                local ok, result = pcall(r.handler, params.uri)
                if ok then
                    return rpc_result(id, {
                        contents = {{ uri = params.uri, text = type(result) == "string" and result or json_encode(result) }},
                    })
                else
                    return rpc_error(id, -32603, tostring(result))
                end
            end
        end
        -- Try templates
        for _, t in ipairs(server._templates) do
            -- Simple pattern matching: escape Lua metacharacters, then convert {param} to capture
            local escaped = t.uriTemplate:gsub("([%.%+%-%*%?%[%]%^%$%(%)%%])", "%%%1")
            local pattern = "^" .. escaped:gsub("{[^}]+}", "([^/]+)") .. "$"
            local captures = { params.uri:match(pattern) }
            if #captures > 0 and t.handler then
                local ok, result = pcall(t.handler, params.uri, unpack(captures))
                if ok then
                    return rpc_result(id, {
                        contents = {{ uri = params.uri, text = type(result) == "string" and result or json_encode(result) }},
                    })
                else
                    return rpc_error(id, -32603, tostring(result))
                end
            end
        end
        return rpc_error(id, -32602, "Resource not found: " .. params.uri)
    end

    methods["resources/templates/list"] = function(id, params)
        local templates = {}
        for _, t in ipairs(server._templates) do
            templates[#templates + 1] = {
                uriTemplate = t.uriTemplate,
                name = t.name,
                description = t.description,
            }
        end
        return rpc_result(id, { resourceTemplates = templates })
    end

    methods["logging/setLevel"] = function(id, params)
        return rpc_result(id, { [JSON_OBJECT] = true })
    end

    --- Handle a JSON-RPC message
    -- @param json_string string Raw JSON-RPC request
    -- @return string|nil JSON-RPC response string, or nil for notifications
    function server:handle_message(json_string)
        -- Parse JSON
        local msg = C4:JsonDecode(json_string)
        if not msg then
            return rpc_error(nil, -32700, "Parse error")
        end

        -- Validate JSON-RPC format
        if msg.jsonrpc ~= "2.0" then
            return rpc_error(msg.id, -32600, "Invalid Request: missing jsonrpc field")
        end
        if not msg.method then
            return rpc_error(msg.id, -32600, "Invalid Request: missing method field")
        end

        -- Check if notification (no id)
        local is_notification = (msg.id == nil)

        -- Route to handler
        local handler = methods[msg.method]
        if not handler then
            if is_notification then return nil end
            return rpc_error(msg.id, -32601, "Method not found: " .. msg.method)
        end

        local result = handler(msg.id, msg.params)
        if is_notification then return nil end
        return result
    end

    return server
end

return M
