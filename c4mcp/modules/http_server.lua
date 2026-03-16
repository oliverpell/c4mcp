-- Layer 1: HTTP/1.1 Request Parser and Response Formatter
-- Parser and format_response are pure Lua; format_json_response requires C4:JsonEncode

local M = {}

local MAX_BODY_SIZE = 64 * 1024   -- 64KB
local MAX_HEADER_SIZE = 8 * 1024  -- 8KB

--- Create a new streaming HTTP request parser
function M.create_parser()
    local parser = {
        state = "READING_HEADERS",
        buffer = "",
        method = nil,
        path = nil,
        http_version = nil,
        headers = {},
        body = nil,
        error = nil,
        _content_length = 0,
    }

    --- Feed data into the parser
    -- @param data string Raw data chunk
    -- @return table|nil Parsed request {method, path, headers, body} or nil if incomplete
    function parser:feed(data)
        if self.error then return { error = self.error } end
        self.buffer = self.buffer .. data

        if self.state == "READING_HEADERS" then
            -- Look for end of headers (\r\n\r\n)
            local header_end = self.buffer:find("\r\n\r\n", 1, true)
            if not header_end then
                if #self.buffer > MAX_HEADER_SIZE then
                    self.error = "Headers too large"
                    return { error = self.error }
                end
                return nil  -- Need more data
            end

            local header_block = self.buffer:sub(1, header_end - 1)
            self.buffer = self.buffer:sub(header_end + 4)

            -- Parse request line
            local request_line = header_block:match("^([^\r\n]+)")
            if not request_line then
                self.error = "Missing request line"
                return { error = self.error }
            end

            self.method, self.path, self.http_version = request_line:match("^(%S+)%s+(%S+)%s+(%S+)")
            if not self.method then
                self.error = "Invalid request line"
                return { error = self.error }
            end

            -- Parse headers
            self.headers = {}
            for line in header_block:gmatch("\r\n([^\r\n]+)") do
                local name, value = line:match("^([^:]+):%s*(.*)")
                if name then
                    self.headers[name:lower()] = value
                end
            end

            -- Reject unsupported transfer encoding
            if self.headers["transfer-encoding"] then
                self.error = "Transfer-Encoding not supported"
                return { error = self.error }
            end

            -- Determine body size
            local cl = self.headers["content-length"]
            if cl then
                self._content_length = tonumber(cl)
                if not self._content_length or self._content_length < 0 then
                    self.error = "Invalid Content-Length"
                    return { error = self.error }
                end
                if self._content_length > MAX_BODY_SIZE then
                    self.error = "Body too large"
                    return { error = self.error }
                end
            else
                self._content_length = 0
            end

            if self._content_length > 0 then
                self.state = "READING_BODY"
            else
                self.state = "COMPLETE"
                self.body = ""
                return {
                    method = self.method,
                    path = self.path,
                    headers = self.headers,
                    body = "",
                }
            end
        end

        if self.state == "READING_BODY" then
            if #self.buffer >= self._content_length then
                self.body = self.buffer:sub(1, self._content_length)
                self.buffer = self.buffer:sub(self._content_length + 1)
                self.state = "COMPLETE"
                return {
                    method = self.method,
                    path = self.path,
                    headers = self.headers,
                    body = self.body,
                }
            end
            return nil  -- Need more data
        end

        return nil
    end

    --- Reset parser for next request (HTTP keep-alive)
    function parser:reset()
        self.state = "READING_HEADERS"
        -- Keep any remaining buffer data for next request
        self.method = nil
        self.path = nil
        self.http_version = nil
        self.headers = {}
        self.body = nil
        self.error = nil
        self._content_length = 0
    end

    return parser
end

--- Format an HTTP/1.1 response
-- @param status_code number HTTP status code
-- @param status_text string HTTP status text
-- @param headers table Response headers
-- @param body string Response body
-- @return string Complete HTTP response
function M.format_response(status_code, status_text, headers, body)
    headers = headers or {}
    body = body or ""

    -- Set defaults
    if not headers["Content-Length"] then
        headers["Content-Length"] = tostring(#body)
    end
    if not headers["Connection"] then
        headers["Connection"] = "close"
    end

    local parts = { "HTTP/1.1 " .. status_code .. " " .. status_text .. "\r\n" }
    for name, value in pairs(headers) do
        parts[#parts + 1] = name .. ": " .. value .. "\r\n"
    end
    parts[#parts + 1] = "\r\n"
    parts[#parts + 1] = body
    return table.concat(parts)
end

--- Format a JSON response
-- @param status_code number HTTP status code
-- @param body_table table Table to JSON-encode
-- @return string Complete HTTP response
function M.format_json_response(status_code, body_table)
    local json = C4:JsonEncode(body_table)
    local status_text = ({
        [200] = "OK",
        [202] = "Accepted",
        [400] = "Bad Request",
        [401] = "Unauthorized",
        [404] = "Not Found",
        [405] = "Method Not Allowed",
        [429] = "Too Many Requests",
        [500] = "Internal Server Error",
    })[status_code] or "Unknown"

    return M.format_response(status_code, status_text, {
        ["Content-Type"] = "application/json",
    }, json)
end

--- Format an error response
-- @param status_code number HTTP status code
-- @param message string Error message
-- @return string Complete HTTP response
function M.format_error_response(status_code, message)
    return M.format_json_response(status_code, { error = message })
end

return M
