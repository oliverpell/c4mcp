-- Bearer Token Authentication Module
-- Extracts and validates Bearer tokens from HTTP headers

local M = {}

--- Extract bearer token from HTTP headers
-- @param headers table HTTP headers (lowercase keys)
-- @return string|nil Token string or nil if not found
function M.extract_bearer_token(headers)
    if not headers then return nil end
    local auth = headers["authorization"]
    if not auth then return nil end
    local token = auth:match("^Bearer%s+(.+)$")
    return token
end

--- Create an auth validator
-- @param opts table {validate_fn(token) → caller table {key_name, scope}, or nil/false}
-- @return table Validator with :check(headers) method
function M.create_auth_validator(opts)
    opts = opts or {}
    local validator = {
        _validate = opts.validate_fn or function() return false end,
    }

    --- Check authorization from HTTP headers
    -- @param headers table HTTP headers (lowercase keys)
    -- @return table {ok=true, caller={key_name, scope}} or {ok=false, status=401, body={error="Unauthorized"}}
    --   A validate_fn that returns a bare true authenticates but gives no caller, so no tool access.
    function validator:check(headers)
        local token = M.extract_bearer_token(headers)
        if not token then
            return { ok = false, status = 401, body = { error = "Unauthorized" } }
        end
        ---@diagnostic disable-next-line: redundant-parameter
        local result = self._validate(token)
        if result then
            return { ok = true, caller = type(result) == "table" and result or nil }
        end
        return { ok = false, status = 401, body = { error = "Unauthorized" } }
    end

    return validator
end

--- Compare two strings in time that does not depend on where they differ
-- @param a string
-- @param b string
-- @return boolean True if equal
function M.constant_time_equals(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then return false end
    local diff = (#a == #b) and 0 or 1
    for i = 1, math.max(#a, #b) do
        if (a:byte(i) or 0) ~= (b:byte(i) or 0) then diff = 1 end
    end
    return diff == 0
end

--- Hash an API key (uses C4:Hash on controller, deterministic in tests)
-- @param key string The API key
-- @return string SHA-256 hex hash
function M.hash_api_key(key)
    return (C4:Hash("SHA256", key, { return_encoding = "HEX" }) or ""):lower()
end

return M
