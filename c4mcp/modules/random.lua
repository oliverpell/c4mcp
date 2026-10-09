-- Secure Random Module
-- Collects entropy from the strongest sources the controller allows and
-- hashes it into a secret. Never uses the Lua PRNG.

local M = {}

--- Read 32 bytes from lua-openssl (OS 3.4.1+)
local function from_openssl()
    local ok, openssl = pcall(require, "openssl")
    if not ok or type(openssl) ~= "table" or type(openssl.random) ~= "function" then return nil end
    local rok, bytes = pcall(openssl.random, 32)
    if rok and type(bytes) == "string" and #bytes >= 16 then return bytes end
    return nil
end

--- Read 32 bytes from /dev/urandom (the driver sandbox may refuse it)
local function from_urandom()
    local ok, bytes = pcall(function()
        local f = io.open("/dev/urandom", "rb")
        if not f then return nil end
        local data = f:read(32)
        f:close()
        return data
    end)
    if ok and type(bytes) == "string" and #bytes >= 16 then return bytes end
    return nil
end

--- Several random UUIDs (OS 3.3.0+)
local function from_uuid()
    if type(C4.UUID) ~= "function" then return nil end
    local parts = {}
    for _ = 1, 8 do
        local ok, id = pcall(C4.UUID, C4, "RANDOM")
        if ok and type(id) == "string" and #id >= 32 then parts[#parts + 1] = id end
    end
    if #parts == 0 then return nil end
    return table.concat(parts)
end

M.DEFAULT_SOURCES = { from_openssl, from_urandom, from_uuid }

--- Generate a 64-character lower-case hex secret
-- @param sources table|nil Entropy source functions (default: openssl, /dev/urandom, C4:UUID)
-- @return string|nil Secret, or nil if no strong source is available
-- @return string|nil Error message
function M.secret_hex(sources)
    local pool = {}
    for _, source in ipairs(sources or M.DEFAULT_SOURCES) do
        local ok, data = pcall(source)
        if ok and data then pool[#pool + 1] = data end
    end
    if #pool == 0 then
        return nil, "No secure random source available"
    end
    -- Timing only adds uniqueness on top of the strong sources, never replaces them
    pool[#pool + 1] = tostring(os.time()) .. tostring(os.clock())
    local hex = C4:Hash("SHA256", table.concat(pool), { return_encoding = "HEX" })
    return hex:lower()
end

return M
