local BaseHandler = require("api_handlers.base")
local json = require("json")
local koutil = require("util")
local logger = require("logger")

local OpenAIHandler = BaseHandler:new()

function OpenAIHandler:query(message_history, openai_settings)
    
    local requestBodyTable = {
        model = openai_settings.model,
        messages = message_history,
        -- Backward compat: some older configs set max_tokens at the top level.
        max_tokens = openai_settings.max_tokens,
    }

    -- Copy recognized OpenAI chat-completions options from additional_parameters
    -- (matches the deepseek/groq/mistral handlers). Previously only `stream` was read
    -- here, so temperature / max_tokens set under additional_parameters had no effect —
    -- which matters for local/offline servers where you want to cap output length.
    if openai_settings.additional_parameters then
        for _, option in ipairs({"temperature", "top_p", "max_tokens", "max_completion_tokens",
                                 "frequency_penalty", "presence_penalty", "stop", "seed",
                                 "stream", "reasoning_effort", "response_format", "tools"}) do
            if openai_settings.additional_parameters[option] then
                requestBodyTable[option] = openai_settings.additional_parameters[option]
            end
        end
    end

    if requestBodyTable.stream == nil then
        requestBodyTable.stream = false
    end

    local requestBody = json.encode(requestBodyTable)
    local headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. (openai_settings.api_key)
    }

    if requestBodyTable.stream then
        -- For streaming responses, we need to handle the response differently
        headers["Accept"] = "text/event-stream"
        return self:backgroundRequest(openai_settings.base_url, headers, requestBody)
    end
    

    -- `timeout` (per-request inactivity/block timeout) and `maxtime` (total wall-clock
    -- budget for the whole response) are optional and default in makeRequest(). Local /
    -- on-device servers (llama.cpp, Ollama on a Boox) are much slower than cloud APIs, so
    -- offline provider configs should set generous values, e.g. timeout=600, maxtime=600.
    local status, code, response = self:makeRequest(openai_settings.base_url, headers, requestBody,
        openai_settings.timeout, openai_settings.maxtime)

    if status then
        local success, responseData = pcall(json.decode, response)
        if success then
            local content = koutil.tableGetValue(responseData, "choices", 1, "message", "content")
            if content then return content end
        end
        
        -- server response error message
        logger.warn("API Error", code, response)
        if success then
            local err_msg = koutil.tableGetValue(responseData, "error", "message")
            if err_msg then return nil, err_msg end
        end
    end
    
    if code == BaseHandler.CODE_CANCELLED then
        return nil, response
    end
    return nil, "Error: " .. (code or "unknown") .. " - " .. response
end

return OpenAIHandler