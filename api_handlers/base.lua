local logger = require("logger")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local https = require("ssl.https")
local Device = require("device")
local Trapper = require("ui/trapper")

local ffi = require("ffi")
local ffiutil = require("ffi/util")

local BaseHandler = {
    trap_widget = nil,  -- widget to trap the request
}

BaseHandler.CODE_CANCELLED = "USER_CANCELED"
BaseHandler.CODE_NETWORK_ERROR = "NETWORK_ERROR"
BaseHandler.PROTOCOL_NON_200 = "X-NON-200-STATUS:"

function BaseHandler:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function BaseHandler:setTrapWidget(trap_widget)
    self.trap_widget = trap_widget
end

function BaseHandler:resetTrapWidget()
    self.trap_widget = nil
end

--- Query method to be implemented by specific handlers
--- @param message_history table: conversation history, a list of messages
--- @param provider_setting table: settings for the specific provider
--- @return string response_content, string error_message
function BaseHandler:query(message_history, provider_setting)
    -- To be implemented by specific handlers
    error("query method must be implemented")
end

--- Post URL content with optional headers and body with timeout setting
--- code references: KOReader/frontend/ui/wikipedia.lua `getURLContent`
--- @param url any
--- @param headers any
--- @param body any
--- @param timeout any blocking timtout
--- @param maxtime any total response finished max time
--- @return boolean success, string status_code, string content
local function postURLContent(url, headers, body, timeout, maxtime)
    -- NOTE: disabling certificate verification is a deliberate (upstream) compatibility
    -- tradeoff for devices with stale CA bundles, but it is a process-global flag, so we
    -- save and restore it to avoid weakening every other HTTPS request KOReader makes.
    local old_cert_verify
    if string.sub(url, 1, 8) == "https://" then
        old_cert_verify = https.cert_verify
        https.cert_verify = false  -- disable CA verify
    end

    local sink = {}
    socketutil:set_timeout(timeout, maxtime)
    local request = {
        url = url,
        method = "POST",
        headers = headers or {},
        source = ltn12.source.string(body or ""),
        sink = maxtime and socketutil.table_sink(sink) or ltn12.sink.table(sink),
    }
    -- pcall so an error inside http.request cannot skip the timeout/cert restore below
    local ok, code, headers, status = pcall(function()
        return socket.skip(1, http.request(request)) -- skip the first return value, not needed
    end)
    socketutil:reset_timeout()
    if old_cert_verify ~= nil then
        https.cert_verify = old_cert_verify
    end
    if not ok then
        logger.warn("http.request error:", code)
        return false, BaseHandler.CODE_NETWORK_ERROR, "Network Error: " .. tostring(code)
    end
    local content = table.concat(sink)  -- response body

    -- check for timeouts
    if code == socketutil.TIMEOUT_CODE or
       code == socketutil.SSL_HANDSHAKE_CODE or
       code == socketutil.SINK_TIMEOUT_CODE then
        logger.warn("request interrupted/timed out:", code)
        return false, code, "Request interrupted/timed out"
    end

    -- check for network errors
    if headers == nil then
        logger.warn("No HTTP headers:", status or code or "network unreachable")
        return false, BaseHandler.CODE_NETWORK_ERROR, "Network Error: " .. tostring(status or code)
    end

    -- check response length
    if headers and headers["content-length"] then
        -- Check we really got the announced content size
        local content_length = tonumber(headers["content-length"])
        if #content ~= content_length then
            return false, code, "Incomplete content received"
        end
    end
    return true, code, content
end

--- func description: Make a request to the specified URL with headers and body.
function BaseHandler:makeRequest(url, headers, body, timeout, maxtime)
    local completed, success, code, content
    if self.trap_widget then
        -- Use larger timeout and maxtime when running a large book analysis
        local request_timeout, request_maxtime
        if body and #body > 10000 then
            request_timeout = timeout or 300
            request_maxtime = maxtime or 300 -- total budget must be >= block timeout, or it caps the request
        else
            request_timeout = timeout or 45
            request_maxtime = maxtime or 120
        end
        -- If a trap widget is set, run the request in a subprocess
        completed, success, code, content = Trapper:dismissableRunInSubprocess(function()
                return postURLContent(url, headers, body, request_timeout, request_maxtime)
            end, self.trap_widget)
        if not completed then
            return false, self.CODE_CANCELLED, self.CODE_CANCELLED
        end
    else
        -- If no trap widget is set, run the request directly
        -- use smaller timeout because we are blocking the UI
        success, code, content = postURLContent(url, headers, body, timeout or 20, maxtime or 45)
    end

    return success, code, content
end

--- Wrap a file descriptor into a Lua file-like object
--- that has :write() and :close() methods, suitable for ltn12.
--- @param fd integer file descriptor
--- @return table file-like object
local function wrap_fd(fd)
    local file_object = {}
    function file_object:write(chunk)
        ffiutil.writeToFD(fd, chunk)
        return self
    end

    function file_object:close()
        -- null close op,
        -- we need to use the fd later, then close manually
        return true
    end

    return file_object
end

-- Background request function
--- This function is used to make a request in the background,
--- typically in a subprocess, and write the response to a pipe.
--- @param timeout any optional blocking timeout (seconds); honors per-provider `timeout`
--- @param maxtime any optional total budget (seconds); only the block timeout is fully
---        enforced with a file sink, but setting it keeps the semantics of makeRequest
function BaseHandler:backgroundRequest(url, headers, body, timeout, maxtime)
    return function(pid, child_write_fd)
        if not pid or not child_write_fd then
            logger.warn("Invalid parameters for background request")
            return
        end

        if timeout or maxtime then
            -- This function body runs in the forked subprocess, so the global
            -- socket timeouts set here cannot leak into the main process.
            socketutil:set_timeout(timeout or 45, maxtime or timeout or 600)
        end

        local pipe_w = wrap_fd(child_write_fd)  -- wrap the write end of the pipe
        local request = {
            url = url,
            method = "POST",
            headers = headers or {},
            source = ltn12.source.string(body or ""),
            sink = ltn12.sink.file(pipe_w),  -- response body write to pipe
        }
        local code, headers, status = socket.skip(1, http.request(request)) -- skip the first return value
        if code ~= 200 then -- non-200 response code, write error to pipe
            logger.warn("Background request non-200:", code, "status:", status, "url:", url)
            ffiutil.writeToFD(child_write_fd, string.format("\r\n%s [%s %s] URL:%s\n\n", self.PROTOCOL_NON_200, status or "", code or "", url))  -- write end of response
        end
        ffi.C.close(child_write_fd)  -- close the write end of the pipe
    end
end

return BaseHandler
