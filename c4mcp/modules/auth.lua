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
-- @param opts table {validate_fn(token) → bool}
-- @return table Validator with :check(headers) method
function M.create_auth_validator(opts)
    opts = opts or {}
    local validator = {
        _validate = opts.validate_fn or function() return false end,
    }

    --- Check authorization from HTTP headers
    -- @param headers table HTTP headers (lowercase keys)
    -- @return table {ok=true} or {ok=false, status=401, body={error="Unauthorized"}}
    function validator:check(headers)
        local token = M.extract_bearer_token(headers)
        if not token then
            return { ok = false, status = 401, body = { error = "Unauthorized" } }
        end
        ---@diagnostic disable-next-line: redundant-parameter
        if self._validate(token) then
            return { ok = true }
        end
        return { ok = false, status = 401, body = { error = "Unauthorized" } }
    end

    return validator
end

--- Hash an API key (uses C4:Hash on controller, deterministic in tests)
-- @param key string The API key
-- @return string SHA-256 hex hash
function M.hash_api_key(key)
    return C4:Hash("SHA256", key, { encoding = "HEX" })
end

return M
