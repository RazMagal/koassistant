local BaseHandler = require("api_handlers.base")
local json = require("json")
local koutil = require("util")
local logger = require("logger")

local OpenRouterProvider = BaseHandler:new()

function OpenRouterProvider:query(message_history, openrouter_settings)
    
    local requestBodyTable = {
        model = openrouter_settings.model,
        messages = message_history,
        -- Backward compat: top-level values, overridden by additional_parameters below.
        max_tokens = openrouter_settings.max_tokens,
        temperature = openrouter_settings.temperature,
    }

    -- Copy recognized options from additional_parameters (the sample config puts
    -- temperature/max_tokens there; matches the openai/deepseek/groq handlers).
    if openrouter_settings.additional_parameters then
        for _, option in ipairs({"temperature", "top_p", "max_tokens", "max_completion_tokens",
                                 "frequency_penalty", "presence_penalty", "stop", "seed",
                                 "stream", "reasoning_effort", "response_format", "tools"}) do
            if openrouter_settings.additional_parameters[option] ~= nil then
                requestBodyTable[option] = openrouter_settings.additional_parameters[option]
            end
        end
    end

    if requestBodyTable.stream == nil then
        requestBodyTable.stream = false
    end


    -- Handle reasoning tokens configuration
    local reasoning = koutil.tableGetValue(openrouter_settings, "additional_parameters", "reasoning")
    if reasoning then
        -- Create a copy of the reasoning configuration to avoid modifying the original settings
        requestBodyTable.reasoning = {}
        for k, v in pairs(reasoning) do
            requestBodyTable.reasoning[k] = v
        end

        -- Set exclude to true by default if not explicitly set
        if requestBodyTable.reasoning.exclude == nil then
            requestBodyTable.reasoning.exclude = true
        end
    end

    local requestBody = json.encode(requestBodyTable)
    local headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. openrouter_settings.api_key,
        ["HTTP-Referer"] = "https://github.com/omer-faruq/assistant.koplugin",
        ["X-Title"] = "assistant.koplugin"
    }

    if requestBodyTable.stream then
        -- For streaming responses, we need to handle the response differently
        headers["Accept"] = "text/event-stream"
        return self:backgroundRequest(openrouter_settings.base_url, headers, requestBody,
            openrouter_settings.timeout, openrouter_settings.maxtime)
    end

    local status, code, response = self:makeRequest(openrouter_settings.base_url, headers, requestBody,
        openrouter_settings.timeout, openrouter_settings.maxtime)

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
    return nil, "Error: " .. (code or "unknown") .. " - " .. tostring(response)
end

return OpenRouterProvider
