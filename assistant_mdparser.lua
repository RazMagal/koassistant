-- markdown parser wrapper module
-- This module provides a simple interface to use hoedown (C binding of full features markdown)
-- or the pure Lua implementation of markdown.lua (building on KOReader)
local Parser = nil

local logger = require("logger")
local DataStorage = require("datastorage")
local plugin_lib_dir = DataStorage:getDataDir() .. "/plugins/assistant.koplugin/lib"
local ffi = require("ffi")
local LibHoedown = nil

-- check if hoedown is natively available
-- mostly it's unavailable on KOReader, but available on some other platforms
local ok, _lib = pcall(ffi.loadlib, "hoedown", 3)
if ok then LibHoedown = _lib end -- (was a stray global `Libhoedown`, so this path never worked)

-- check if hoedown is available in the plugin directory
-- in order to use native hoedown, a "lib" directory containing "libhoedown.so.3" and resty-hoedown 
-- should be present in the plugin directory, see documents for more details
if not LibHoedown then
    local ok, _lib = pcall(ffi.load, plugin_lib_dir .. "/libhoedown.so.3")
    if ok then LibHoedown = _lib end
end

if LibHoedown then
    -- hook the C binding of hoedown to the resty.hoedown library
    package.preload["resty.hoedown.library"] = function()
        return LibHoedown
    end

    -- load the resty.hoedown library from the plugin's libs directory
    package.path = string.format("%s;%s/?.lua", package.path, plugin_lib_dir)
    local ok, hoedownMD = pcall(require, "resty.hoedown")
    if ok then
        Parser = function (text)
            return hoedownMD(text, {
                rendered    = "html",
                nesting     = 1,
                extensions  = {
                    "space_headers", "tables", "fenced_code", "footnotes", "autolink", "strikethrough",
                    "underline", "highlight", "quote", "superscript", "math", "math_explicit",
                },
            })
        end
        logger.info("Using hoedown (C binding) for markdown parsing")
    end
end

-- Post-processor: convert pipe-table <p> blocks that luamd passes through
-- verbatim into proper <table> HTML that CRE can render.
-- Safe for hoedown too: hoedown already emits <table> tags, so no <p>|...|</p>
-- blocks will match and this becomes a no-op.
local function render_tables(html)
    return (html:gsub("<p>([%s%S]-)</p>", function(block)
        if not block:match("^%s*|") then
            return nil
        end

        local rows = {}
        for line in block:gmatch("[^\r\n]+") do
            local trimmed = line:match("^%s*(.-)%s*$")
            if trimmed ~= "" then
                rows[#rows + 1] = trimmed
            end
        end

        if #rows < 3 then return nil end

        -- Separator row: only pipes/dashes/colons/spaces, with at least one dash.
        -- Both the leading and the trailing pipe are optional (|---|--- is valid).
        if not (rows[2]:match("^[%s%-:|]+$") and rows[2]:find("%-")) then return nil end

        local out = { "<table>" }

        for i, row in ipairs(rows) do
            if i == 2 then
                -- skip separator row
            else
                local tag = (i == 1) and "th" or "td"
                -- strip one optional leading and trailing pipe, then split on the rest
                local inner = row:gsub("^%s*|", ""):gsub("|%s*$", "")
                out[#out + 1] = "<tr>"
                for cell in (inner .. "|"):gmatch("(.-)|") do
                    local c = cell:match("^%s*(.-)%s*$")
                    -- emit EVERY cell, empty ones included: skipping empties
                    -- shifted all following columns left
                    out[#out + 1] = string.format("<%s>%s</%s>", tag, c, tag)
                end
                out[#out + 1] = "</tr>"
            end
        end

        out[#out + 1] = "</table>"
        return table.concat(out)
    end))
end

-- fallback to pure Lua implementation
if not Parser then
    local puremd = require("apps/filemanager/lib/md")
    Parser = function(text)
        return render_tables(puremd(text))
    end
    logger.info("Using markdown.lua (puremd) for markdown parsing")
end

return Parser