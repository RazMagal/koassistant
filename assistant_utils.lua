local util = require("util")
local logger = require("logger")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local T = require("ffi/util").template
local koutil = require("util")
local _ = require("assistant_gettext")

local function getGeneralNotebookFilePath(assistant)
  local notebookfile = nil
  local default_folder = util.tableGetValue(assistant.CONFIGURATION, "features", "default_folder_for_logs")
  local home_dir = G_reader_settings:readSetting("home_dir")
  local current_dir = assistant.ui.file_chooser and assistant.ui.file_chooser.path or assistant.ui:getLastDirFile()
  local target_dir = default_folder and default_folder ~= "" and util.pathExists(default_folder) and default_folder or (home_dir or current_dir)
  if target_dir then
    local notebookfile_path = target_dir .. "/general_notebook.md"
    notebookfile = notebookfile_path
  end
  return notebookfile
end

local function extractBookTextForAnalysis(CONFIGURATION, ui)
    local book_text = nil
      if not ui.document.info.has_pages then
          -- Only extract text for EPUB documents
          local current_xp = ui.document:getXPointer()
          ui.document:gotoPos(0)
          local start_xp = ui.document:getXPointer()
          ui.document:gotoXPointer(current_xp)
          book_text = ui.document:getTextFromXPointers(start_xp, current_xp) or ""
          local max_text_length_for_analysis = koutil.tableGetValue(CONFIGURATION, "features", "max_text_length_for_analysis") or 100000
          if #book_text > max_text_length_for_analysis then
              book_text = book_text:sub(-max_text_length_for_analysis)
              book_text = book_text:gsub("^[\128-\191]+", "")
              book_text = util.fixUtf8(book_text, "_")
          end
      else
        -- Extract text from the last n pages up to current reading position for page-based documents
        local current_page = ui.view.state.page
        local max_page_size_for_analysis = koutil.tableGetValue(CONFIGURATION, "features", "max_page_size_for_analysis") or 250
        -- +1: the loop below is inclusive, so without it we'd read n+1 pages
        local start_page = math.max(1, current_page - max_page_size_for_analysis + 1)
        book_text = ""
        for page = start_page, current_page do
            local page_text = ui.document:getPageText(page) or ""
            if type(page_text) == "table" then
                local texts = {}
                for _, block in ipairs(page_text) do
                    if type(block) == "table" then
                        for i = 1, #block do
                            local span = block[i]
                            if type(span) == "table" and span.word then
                                table.insert(texts, span.word)
                            end
                        end
                    end
                end
                page_text = table.concat(texts, " ")
            end
            book_text = book_text .. page_text .. "\n"
        end
        local max_text_length_for_analysis = koutil.tableGetValue(CONFIGURATION, "features", "max_text_length_for_analysis") or 100000
        if #book_text > max_text_length_for_analysis then
            book_text = book_text:sub(-max_text_length_for_analysis)
            book_text = book_text:gsub("^[\128-\191]+", "")
            book_text = util.fixUtf8(book_text, "_")
        end
    end
    return book_text
end

local function extractHighlightsNotesAndNotebook(CONFIGURATION, ui, include_notebook)
    local highlights_and_notes = ""
    if ui.annotation and ui.annotation.annotations then
        for _, annotation in ipairs(ui.annotation.annotations) do
            if annotation.text and annotation.text ~= "" then
                highlights_and_notes = highlights_and_notes .. "Highlight: " .. annotation.text .. "\n"
            end
            if annotation.note and annotation.note ~= "" then
                highlights_and_notes = highlights_and_notes .. "Note: " .. annotation.note .. "\n"
            end
            if annotation.chapter then
                highlights_and_notes = highlights_and_notes .. "Chapter: " .. annotation.chapter .. "\n"
            end
            if annotation.pageno then
                highlights_and_notes = highlights_and_notes .. "Page: " .. annotation.pageno .. "\n"
            end
            highlights_and_notes = highlights_and_notes .. "\n"
        end
    end
    
    local notebook_content = ""
    if include_notebook then
      pcall(function()
          local notebookfile = ui.bookinfo:getNotebookFile(ui.doc_settings)
          if notebookfile then
              local json = require("json")
              local file = io.open(notebookfile, "r")
              if file then
                  local content = file:read("*all")
                  file:close()
                  local success, data = pcall(json.decode, content)
                  if success and data then
                      notebook_content = "Notebook Data:\n" .. json.encode(data)
                  else
                      notebook_content = "Notebook Content (raw):\n" .. content
                  end
              end
          end
      end)
    end
    
    local combined = highlights_and_notes
    if notebook_content ~= "" then
        if combined ~= "" then
            combined = combined .. "\n--- Notebook Content ---\n" .. notebook_content
        else
            combined = notebook_content
        end
    end
    
    local max_text_length_for_analysis = koutil.tableGetValue(CONFIGURATION, "features", "max_text_length_for_analysis") or 100000
    if #combined > max_text_length_for_analysis then
        combined = combined:sub(-max_text_length_for_analysis)
        combined = combined:gsub("^[\128-\191]+", "")
        combined = util.fixUtf8(combined, "_")
    end
    
    return combined
end

local function getPageInfo(ui)
  local page_number = nil
  local percentage = 0
  local total_pages = nil
  local chapter_title = nil
  if ui.highlight and ui.highlight.selected_text and ui.highlight.selected_text.pos0 then
    if ui.paging then
      page_number = ui.highlight.selected_text.pos0.page
    else
      -- For rolling mode, we could get page number using document:getPageFromXPointer
      page_number = ui.document:getPageFromXPointer(ui.highlight.selected_text.pos0)
    end
    
    total_pages = ui.document.info.number_of_pages
    if page_number and total_pages and total_pages ~= 0 then
      percentage = math.floor((page_number / total_pages) * 100 + 0.5)
    end
    
    if ui.toc and page_number then
      chapter_title = ui.toc:getTocTitleByPage(page_number)
    end
  end

  local page_lbl = _("Page")
  local page_info = ""
  if page_number and total_pages then
    page_info = string.format(" (%s %s - %s%%)", page_lbl, page_number, percentage)
  elseif page_number then
    page_info = string.format(" (%s %s)", page_lbl, page_number)
  end

  if chapter_title then
    page_info = page_info .. " - " .. chapter_title
  end

  return page_info
end

local function saveToNotebookFile(assistant, log_entry)
  local success, err = pcall(function()
    local notebookfile
    local default_folder = util.tableGetValue(assistant.CONFIGURATION, "features", "default_folder_for_logs")
    if assistant.ui.doc_settings then
      -- only resolvable with an open document: ui.bookinfo/doc_settings are
      -- absent in the FileManager, where the general-notebook branch below
      -- must be reachable (calling this above the guard threw inside the
      -- pcall and made saving from the FileManager silently fail)
      notebookfile = assistant.ui.bookinfo:getNotebookFile(assistant.ui.doc_settings)
      if default_folder and default_folder ~= "" then
        if not notebookfile:find("^" .. default_folder:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")) then
          if not util.pathExists(default_folder) then
            UIManager:show(InfoMessage:new{
                icon = "notice-warning",
                text = T(_("Cannot access default folder for logs: %1\nUsing original location."), default_folder),
                timeout = 5,
              })
          else
            local original_filename = notebookfile:match("([^/\\]+)$")
            if original_filename then
              original_filename = original_filename:gsub("%.[^.]*$", ".md")
            else
              local doc_path = assistant.ui.document.file
              if doc_path then
                local doc_filename = doc_path:match("([^/\\]+)$")
                if doc_filename then
                  original_filename = doc_filename..".md"
                else
                  original_filename = "notebook.md"
                end
              else
                original_filename = "notebook.md"
              end
            end
            local new_notebookfile = default_folder .. "/" .. original_filename

            assistant.ui.doc_settings:saveSetting("notebook_file", new_notebookfile)

            notebookfile = new_notebookfile
          end
        end
      end

      if notebookfile and not notebookfile:find("%.md$") then
        notebookfile = notebookfile:gsub("%.[^.]*$", ".md")
        if not notebookfile:find("%.md$") then
          notebookfile = notebookfile .. ".md"
        end
        assistant.ui.doc_settings:saveSetting("notebook_file", notebookfile)
      end
    else
      notebookfile = getGeneralNotebookFilePath(assistant)
    end

    if notebookfile then
      local file = io.open(notebookfile, "a")
      if file then
        file:write(log_entry)
        file:close()
      else
        logger.warn("Assistant: Could not open notebook file:", notebookfile)
      end
    end
  end)

  if not success then
    logger.warn("Assistant: Error during notebook save:", err)
    UIManager:show(InfoMessage:new{
      icon = "notice-warning",
      text = _("Notebook save failed. Continuing..."),
      timeout = 3,
    })
  end
end

local function normalizeMarkdownHeadings(content, heading_offset, max_heading_level)
  if type(content) ~= "string" or content == "" then
    return content
  end

  heading_offset = tonumber(heading_offset) or 0
  max_heading_level = tonumber(max_heading_level) or 6

  if heading_offset <= 0 then
    return content
  end

  -- Shift by the SHALLOWEST heading in the answer: it must land on
  -- heading_offset + 1. Shifting by the deepest one (as before) produced a
  -- zero/negative shift whenever the answer contained any deep heading,
  -- leaving `# Top` rendered larger than the surrounding section titles.
  local min_heading_level_found = nil
  for line in content:gmatch("[^\n]+") do
    local hashes = line:match("^%s*(#+)")
    if hashes then
      local level = #hashes
      if not min_heading_level_found or level < min_heading_level_found then
        min_heading_level_found = level
      end
    end
  end

  if not min_heading_level_found then
    return content
  end

  local target_top_level = heading_offset + 1
  local heading_shift = target_top_level - min_heading_level_found
  if heading_shift <= 0 then
    return content
  end

  local normalized_lines = {}
  local start_index = 1
  local content_length = #content
  local has_trailing_newline = content:sub(-1) == "\n"

  local function processLine(line)
    local leading_spaces, hashes, spacing_after_hashes, heading_text = line:match("^(%s*)(#+)(%s*)(.*)$")
    if not hashes then
      return line
    end

    local adjusted_heading_text = heading_text or ""
    if spacing_after_hashes then
      adjusted_heading_text = spacing_after_hashes .. adjusted_heading_text
    end
    adjusted_heading_text = adjusted_heading_text:gsub("^%s*", "")
    adjusted_heading_text = adjusted_heading_text:gsub("%s*$", "")

    local new_level = #hashes + heading_shift
    if new_level > max_heading_level then
      if adjusted_heading_text ~= "" then
        return leading_spaces .. "**" .. adjusted_heading_text .. "**"
      end
      return leading_spaces .. "**" .. "**"
    end

    local new_hashes = string.rep("#", new_level)
    if adjusted_heading_text == "" then
      return leading_spaces .. new_hashes
    end
    return leading_spaces .. new_hashes .. " " .. adjusted_heading_text
  end

  while start_index <= content_length do
    local newline_index = content:find("\n", start_index, true)
    if newline_index then
      local line = content:sub(start_index, newline_index - 1)
      table.insert(normalized_lines, processLine(line))
      start_index = newline_index + 1
    else
      local line = content:sub(start_index)
      if line ~= "" or not has_trailing_newline then
        table.insert(normalized_lines, processLine(line))
      end
      break
    end
  end

  local normalized_content = table.concat(normalized_lines, "\n")
  if has_trailing_newline then
    normalized_content = normalized_content .. "\n"
  end
  return normalized_content
end

-- Enhanced uncompress that natively tolerates the Gzip-to-Zlib trailer mismatch
require("ffi/zlib_h")
local libz = ffi.loadlib("z", 1)

local bit = require("bit")

local function zlib_uncompress_gzip(gzip_data, max_datalen)
    if #gzip_data < 18 then return nil, "Data truncated" end
    if gzip_data:byte(1) ~= 0x1f or gzip_data:byte(2) ~= 0x8b then
        return nil, "Not gzip data (bad magic)"
    end

    -- 1. Compute the real header size: 10 fixed bytes plus the optional
    --    FEXTRA/FNAME/FCOMMENT/FHCRC fields announced by the FLG byte.
    --    (Assuming a fixed 10-byte header breaks on any origin/proxy that
    --    emits FNAME, which is common for pre-compressed files.)
    local flg = gzip_data:byte(4)
    local offset = 11 -- 1-based index of the first deflate byte
    if bit.band(flg, 0x04) ~= 0 then -- FEXTRA: 2-byte little-endian length + data
        if #gzip_data < offset + 1 then return nil, "Data truncated (FEXTRA)" end
        local xlen = gzip_data:byte(offset) + gzip_data:byte(offset + 1) * 256
        offset = offset + 2 + xlen
    end
    if bit.band(flg, 0x08) ~= 0 then -- FNAME: zero-terminated
        local z = gzip_data:find("\0", offset, true)
        if not z then return nil, "Data truncated (FNAME)" end
        offset = z + 1
    end
    if bit.band(flg, 0x10) ~= 0 then -- FCOMMENT: zero-terminated
        local z = gzip_data:find("\0", offset, true)
        if not z then return nil, "Data truncated (FCOMMENT)" end
        offset = z + 1
    end
    if bit.band(flg, 0x02) ~= 0 then -- FHCRC: 2 bytes
        offset = offset + 2
    end
    if offset > #gzip_data - 8 then return nil, "Data truncated (no deflate payload)" end

    -- Strip header and the 8-byte Gzip trailer (CRC32 + ISIZE)
    local raw_deflate = gzip_data:sub(offset, -9)

    -- 2. Prepend a valid standard Zlib header (0x78 0x9C)
    local zlib_header = string.char(0x78, 0x9C)
    local hybrid_payload = zlib_header .. raw_deflate

    -- 3. Prepare the memory buffers
    local buf = ffi.new("uint8_t[?]", max_datalen)
    local buflen = ffi.new("unsigned long[1]", max_datalen)

    -- 4. Invoke the low-level libz
    local res = libz.uncompress(buf, buflen, ffi.cast("const unsigned char*", hybrid_payload), #hybrid_payload)

    -- res == 0 means perfect zlib format
    -- res == -3 (Z_DATA_ERROR) happens here because the tail has a Gzip CRC32 instead of Zlib Adler32.
    -- But since the Deflate payload itself is 100% correct, the bytes in 'buf' are ALREADY completely deflated!
    if res == 0 or res == -3 then
        local actual_len = tonumber(buflen[0])
        -- Cross-check against the trailer's ISIZE (uncompressed size mod 2^32):
        -- zlib < 1.2.9 does not update buflen on error, which would otherwise
        -- return max_datalen bytes of trailing NULs on a corrupt payload.
        local isize = gzip_data:byte(-4) + gzip_data:byte(-3) * 256
            + gzip_data:byte(-2) * 65536 + gzip_data:byte(-1) * 16777216
        if isize > 0 and isize <= max_datalen then
            actual_len = math.min(actual_len, isize)
        end
        if actual_len > 0 then
            return ffi.string(buf, actual_len)
        end
    end

    return nil, "Zlib core uncompress failed with severe code: " .. tostring(res)
end

--- GET HTTP HEADER VALUE
--- @param headers table
--- @param header_name string
--- @return string|nil
local function http_get_header(headers, header_name)
    if not headers then return nil end
    local lower_name = header_name:lower()

    for k, v in pairs(headers) do
        if k:lower() == lower_name then
            return v
        end
    end
    return nil
end

--- Checks content-encoding
local function http_is_encoded(headers, encoding)
    local value = http_get_header(headers, "content-encoding")
    if not value then return false end
    return value:lower():find((encoding or "gzip"):lower()) ~= nil
end

return {
    getGeneralNotebookFilePath = getGeneralNotebookFilePath,
    extractBookTextForAnalysis = extractBookTextForAnalysis,
    extractHighlightsNotesAndNotebook = extractHighlightsNotesAndNotebook,
    getPageInfo = getPageInfo,
    saveToNotebookFile = saveToNotebookFile,
    normalizeMarkdownHeadings = normalizeMarkdownHeadings,
    zlib_uncompress_gzip = zlib_uncompress_gzip,
    http_get_header = http_get_header,
    http_is_encoded = http_is_encoded,
}
