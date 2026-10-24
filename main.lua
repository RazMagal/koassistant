local Device = require("device")
local logger = require("logger")
local Event = require("ui/event")
local InputContainer = require("ui/widget/container/inputcontainer")
local NetworkMgr = require("ui/network/manager")
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Font = require("ui/font")
local Trapper = require("ui/trapper")
local Language = require("ui/language")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local ConfirmBox  = require("ui/widget/confirmbox")
local T 		      = require("ffi/util").template
local FrontendUtil = require("util")
local TextViewer = require("ui/widget/textviewer")
local ButtonDialog = require("ui/widget/buttondialog")
local ffiutil = require("ffi/util")

local _ = require("assistant_gettext")
local N_ = _.ngettext
local AssistantDialog = require("assistant_dialog")
local UpdateChecker = require("assistant_update_checker")
local Prompts = require("assistant_prompts")
local SettingsDialog = require("assistant_settings")
local showDictionaryDialog = require("assistant_dictdialog")

local Assistant = InputContainer:new {
  name = "assistant",
  meta = nil,           -- reference to the _meta module
  is_doc_only = false,   -- available in both doc and filemanager models
  settings_file = DataStorage:getSettingsDir() .. "/assistant.lua",
  settings = nil,
  querier = nil,
  updated = false, -- flag to track if settings were updated
  assistant_dialog = nil, -- reference to the main dialog instance
  ui_language = nil,
  ui_language_is_rtl = nil,
  CONFIGURATION = nil,  -- reference to the main configuration
}

-- NOTE: LuaJIT's loadfile() ignores the 5.2-style mode/env arguments, so there is
-- no point pretending to sandbox the chunk; load once and reuse the result so the
-- user's configuration.lua does not execute twice.
local function loadConfigFile(filePath)
    local chunk, err = loadfile(filePath) -- checks syntax errors
    if not chunk then return nil, err end
    local success, result = pcall(chunk) -- run the code, checks runtime errors
    if not success then return nil, result end
    return result, nil
end

-- configuration locations
local ASSISTANT_DIR = T("%1/plugins/%2.koplugin/", DataStorage:getDataDir(), Assistant.name)
local CONFIG_FILE_PATH = ASSISTANT_DIR .. "configuration.lua"
local META_FILE_PATH = ASSISTANT_DIR .. "_meta.lua"
local CONFIG_LOAD_ERROR = nil
local CONFIGURATION = nil

-- Load the configuration.lua (single execution) and store the error message if any
local config_result, config_err = loadConfigFile(CONFIG_FILE_PATH)
if config_err then
  CONFIG_LOAD_ERROR = config_err
  logger.warn(config_err)
else
  CONFIGURATION = config_result
end

-- Flag to ensure the update message is shown only once per session
local updateMessageShown = false

-- forward declaration (assigned below; must be a local, not a global)
local BookLevelCustomPrompts

function Assistant:onDispatcherRegisterActions()
  -- Register main AI ask action
  Dispatcher:registerAction("ai_ask_question", {
    category = "none", 
    event = "AskAIQuestion", 
    title = _("Ask the AI a question"), 
    general = true
  })
  
  -- Register AI recap action
  Dispatcher:registerAction("ai_recap", {
    category = "none", 
    event = "AskAIRecap", 
    title = _("AI Recaps"), 
    general = true
  })
  
  -- Register AI X-Ray action (available for gesture binding)
  Dispatcher:registerAction("ai_xray", {
    category = "none",
    event = "AskAIXRay",
    title = _("AI X-Ray"),
    general = true
  })

  -- Register Quick Notes action (available for gesture binding)
  Dispatcher:registerAction("ai_quick_note", {
    category = "none", 
    event = "AskAIQuickNote", 
    title = _("Take Quick Notes"), 
    general = true
  })

  -- Register Book Information action (available for gesture binding)
  Dispatcher:registerAction("ai_book_info", {
    category = "none",
    event = "AskAIBookInfo",
    title = _("Book Summary & Recs"),
    general = true
  })

  -- Register Annotations Analysis action (available for gesture binding)
  Dispatcher:registerAction("ai_annotations", {
    category = "none",
    event = "AskAIAnnotations",
    title = _("Highlight & Note Analysis"),
    general = true
  })

  -- Register Annotations Analysis action (available for gesture binding)
  Dispatcher:registerAction("ai_summary_using_annotations", {
    category = "none",
    event = "AskSummaryUsingAnnotations",
    title = _("Summary Using Highlights & Notes"),
    general = true,
    separator = true
  })
end

-- tricky hack: make our menu be the first under tools menu
table.insert(require("ui/elements/reader_menu_order").tools, 1, "ai_assistant")
table.insert(require("ui/elements/filemanager_menu_order").tools, 1, "ai_assistant")
function Assistant:addToMainMenu(menu_items)
    if self.ui.document then
        -- Reader menu
        menu_items.ai_assistant = {
            text = _("AI Assistant"),
            sorting_hint = "tools",
            hold_callback = function ()
              self:_help_dialog()
            end,
            sub_item_table = {
              {
                text = _("Ask the AI a question"),
                callback = function ()
                  self:onAskAIQuestion()
                end,
                hold_callback = function ()
                  UIManager:show(InfoMessage:new{
                    text = _("Enter a question to ask AI.")
                  })
                end
              },
              {
                text = _("Book-Level Built-in Prompts"),
                sub_item_table = {
                  {
                    text = _("Book Summary & Recs"),
                    callback = function ()
                      self:onAskAIBookInfo()
                    end,
                    hold_callback = function ()
                      UIManager:show(InfoMessage:new{
                        text = _("Summary of the book, author biography, historical context, and a list of similar book recommendations with descriptions.")
                      })
                    end
                  },
                  {
                    text = _("AI X-Ray"),
                    callback = function ()
                      self:onAskAIXRay()
                    end,
                    hold_callback = function ()
                      UIManager:show(InfoMessage:new{
                        text = _("\"X-Ray\" summary for a book, structured into specific sections like Characters, Locations, Themes, Terms & Concepts, Timeline, and Re-immersion.")
                      })
                    end
                  },
                  {
                    text = _("AI Recaps"),
                    callback = function ()
                      self:onAskAIRecap()
                    end,
                    hold_callback = function ()
                      UIManager:show(InfoMessage:new{
                        text = _("A very brief, spoiler-free summary of the book up to current reading progress.")
                      })
                    end,
                  },
                  {
                    text = _("Highlight & Note Analysis"),
                    callback = function ()
                      self:onAskAIAnnotations()
                    end,
                    hold_callback = function ()
                      UIManager:show(InfoMessage:new{
                        text = _("Analysis of your highlights, notes, and notebook content from the book.")
                      })
                    end,
                  },
                  {
                    text = _("Summary Using Highlights & Notes"),
                    callback = function ()
                      self:onAskSummaryUsingAnnotations()
                    end,
                    hold_callback = function ()
                      UIManager:show(InfoMessage:new{
                        text = _("Summary of the book using your highlights and notes.")
                      })
                    end,
                  },
                }
              },
              {
                text = _("Book-Level Custom Prompts"),
                enabled = not not FrontendUtil.tableGetValue(CONFIGURATION, "features", "book_level_prompts"),
                sub_item_table_func = function ()
                  return BookLevelCustomPrompts(self)
                end,
                hold_callback = function ()
                  UIManager:show(InfoMessage:new{
                    text = _("Includes user defined book level prompts from Config file")
                  })
                end,
                separator = true,
              },
              {
                text = _("Take Quick Notes"),
                callback = function ()
                  self:onAskAIQuickNote()
                end,
                hold_callback = function ()
                  UIManager:show(InfoMessage:new{
                    text = _("Take quick notes that will be saved to your notebook.")
                  })
                end,
              },
              {
                text = _("NoteBook (AI Conversation Log)"),
                callback = function ()
                  local notebookfile = self.ui.bookinfo:getNotebookFile(self.ui.doc_settings)
                  if not notebookfile then
                    UIManager:show(InfoMessage:new{ icon = "notice-warning",
                      text = _("Could not determine the notebook file location.") })
                    return
                  end
                  UIManager:show(ConfirmBox:new{
                    icon = "appbar.pageview",
                    face = Font:getFace("smallinfofont"),
                    text = _("Notebook file: \n\n") .. notebookfile,
                    ok_text = _("View"),
                    ok_callback = function()
                      if not FrontendUtil.pathExists(notebookfile) then
                        UIManager:show(InfoMessage:new{
                          text = T(_("File does not exist.\n\n%1"), notebookfile)
                        })
                        return
                      end
                      TextViewer.openFile(notebookfile)
                    end,
                    other_buttons = {{
                      {
                        text = _("Delete"),
                        callback = function ()
                          UIManager:show(ConfirmBox:new{
                            text = T(_("Delete file?\n%1\nThis operation is not reversible."), notebookfile),
                            ok_text = _("Delete"),
                            ok_callback = function ()
                              local ok, err = FrontendUtil.removeFile(notebookfile)
                              if not ok then
                                UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err })
                              end
                            end
                          })
                        end
                      },
                      {
                        text = _("Edit"),
                        callback = function ()
                          UIManager:broadcastEvent(Event:new("ShowNotebookFile"))
                        end
                      },
                    }}
                  })
                end,
                separator = true,
              },
              {
                text_func = function ()
                  return T(_("AI Provider: %1(%2)"),
                    self:getModelProvider() or _("Not configured"),
                    self:getModelId() or _("Not configured")
                  )
                end,
                keep_menu_open = true,
                callback = function (touchmenu_instance)
                  self:showSettings(function ()
                    touchmenu_instance:updateItems()
                  end)
                end,
              },
              {
                text = _("AI Assistant Settings"),
                sub_item_table_func = function ()
                  return SettingsDialog.genMenuSettings(self)
                end
              }
            },
        }
    else
        -- Filemanager menu
        menu_items.ai_assistant = {
            text = _("AI Assistant"),
            sorting_hint = "tools",
            sub_item_table = {
                {
                    text = _("Ask a Question"),
                    callback = function ()
                      self:onAskAIQuestion()
                    end,
                    hold_callback = function ()
                      UIManager:show(InfoMessage:new{
                        text = _("Ask a general question to the AI (not book-related).")
                      })
                    end
                },
                {
                  text = _("Take Quick Notes"),
                  callback = function ()
                    self:onAskAIQuickNote()
                  end,
                  hold_callback = function ()
                    UIManager:show(InfoMessage:new{
                      text = _("Take quick notes that will be saved to your notebook.")
                    })
                  end,
                },
                {
                  text = _("NoteBook (AI Conversation Log)"),
                  callback = function ()
                    local assistant_utils = require("assistant_utils")
                    local notebookfile = assistant_utils.getGeneralNotebookFilePath(self)
                    if not notebookfile then
                      UIManager:show(InfoMessage:new{ icon = "notice-warning",
                        text = _("Could not determine the notebook file location.") })
                      return
                    end
                    UIManager:show(ConfirmBox:new{
                      icon = "appbar.pageview",
                      face = Font:getFace("smallinfofont"),
                      text = _("Notebook file: \n\n") .. notebookfile,
                      ok_text = _("View"),
                      ok_callback = function()
                        if not FrontendUtil.pathExists(notebookfile) then
                          UIManager:show(InfoMessage:new{
                            text = T(_("File does not exist.\n\n%1"), notebookfile)
                          })
                          return
                        end
                        TextViewer.openFile(notebookfile)
                      end,
                      other_buttons = {{
                        {
                          text = _("Delete"),
                          callback = function ()
                            UIManager:show(ConfirmBox:new{
                              text = T(_("Delete file?\n%1\nThis operation is not reversible."), notebookfile),
                              ok_text = _("Delete"),
                              ok_callback = function ()
                                local ok, err = FrontendUtil.removeFile(notebookfile)
                                if not ok then
                                  UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err })
                                end
                              end
                            })
                          end
                        },
                        {
                          text = _("Edit"),
                          enabled = self.ui.texteditor,
                          callback = function ()
                            self.ui.texteditor:openFile(notebookfile)
                          end
                        },
                      }}
                    })
                  end,
                  separator = true,
                },
                {
                    text_func = function ()
                      return T(_("AI Provider: %1(%2)"),
                        self:getModelProvider() or _("Not configured"),
                        self:getModelId() or _("Not configured")
                      )
                    end,
                    keep_menu_open = true,
                    callback = function (touchmenu_instance)
                      self:showSettings(function ()
                        touchmenu_instance:updateItems()
                      end)
                    end,
                },
                {
                    text = _("AI Assistant Settings"),
                    sub_item_table_func = function ()
                      return SettingsDialog.genMenuSettings(self)
                    end
                }
            }
        }
    end
end

local function getDocumentInfo(document)
  local DocSettings = require("docsettings")
  local doc_settings = DocSettings:open(document.file)
  local percent_finished = doc_settings:readSetting("percent_finished") or 0
  local doc_props = doc_settings:child("doc_props")
  local title = doc_props:readSetting("title") or document:getProps().title or "Unknown Title"
  local authors = doc_props:readSetting("authors") or document:getProps().authors or "Unknown Author"
  return {
    title = title,
    authors = authors,
    percent_finished = percent_finished,
  }
end

function BookLevelCustomPrompts(assistant) -- assigns the forward-declared local
  local sub_item_table = {}

  -- Read book_level_prompts from configuration
  local book_level_prompts = FrontendUtil.tableGetValue(CONFIGURATION, "features", "book_level_prompts") or {}

  for key, prompt_config in ffiutil.orderedPairs(book_level_prompts) do
    -- visible defaults to true, like every other prompt type
    if prompt_config.visible ~= false and prompt_config.type == "feature" then
      local button = {
        text = prompt_config.text or key,
        callback = function()
          if not assistant:isConfigured() then return end
          if not assistant.ui.document then return end
          assistant:runWhenOnline(function()
            local book = getDocumentInfo(assistant.ui.document)
            local showFeatureDialog = require("assistant_featuredialog")
            Trapper:wrap(function()
              showFeatureDialog(assistant, prompt_config, book.title, book.authors, book.percent_finished)
            end)
          end)
        end,
        hold_callback = function()
          UIManager:show(InfoMessage:new{
            text = prompt_config.description or _("This is a custom prompt")
          })
        end,
      }
      table.insert(sub_item_table, button)
    end
  end

  if #sub_item_table == 0 then
    local button = {
      text = _("No valid book-level custom prompt found"),
      enabled = false,
    }
    table.insert(sub_item_table, button)
    local button = {
      text = _("For details, visit the 'Configuration' wiki page on github."),
      enabled = false,
    }
    table.insert(sub_item_table, button)
  end
  return sub_item_table
end

function Assistant:showSettings(close_callback)
  if not self:isConfigured() then return end

  if self._settings_dialog then
    -- If settings dialog is already open, just show it again
    UIManager:show(self._settings_dialog)
    return
  end

  local settingDlg = SettingsDialog:new{
      assistant = self,
      CONFIGURATION = CONFIGURATION,
      settings = self.settings,
      close_callback = close_callback,
  }

  self._settings_dialog = settingDlg -- store reference to the dialog
  UIManager:show(settingDlg)
end

function Assistant:getModelId()
  local key = self:getModelProvider()
  if key == nil then return nil end
  if key:sub(1, 10) == "openrouter" then
      local model = self.settings:readSetting("openrouter_model_" .. key)
      if model then return model end
  end
  return FrontendUtil.tableGetValue(CONFIGURATION, "provider_settings", key, "model")
end

function Assistant:getModelProvider()

  if type(CONFIGURATION) ~= "table" then
    return nil
  end

  local provider_settings = CONFIGURATION.provider_settings -- provider settings table from configuration.lua
  if type(provider_settings) ~= "table" then
    return nil
  end
  local setting_provider = self.settings:readSetting("provider")

  local function is_provider_valid(key)
    if not key then return false end
    local provider = FrontendUtil.tableGetValue(CONFIGURATION, "provider_settings", key)
    if not provider then return false end
    -- azure_openai entries use endpoint/deployment_name/api_version instead of
    -- model/base_url; without this they could never be selected
    if FrontendUtil.tableGetValue(provider, "endpoint")
        and FrontendUtil.tableGetValue(provider, "deployment_name") then
      return FrontendUtil.tableGetValue(provider, "api_key") ~= nil
    end
    return FrontendUtil.tableGetValue(provider, "model") and
        FrontendUtil.tableGetValue(provider, "base_url") and
        FrontendUtil.tableGetValue(provider, "api_key")
  end

  local function find_setting_provider(filter_func)
    for key, tab in pairs(provider_settings) do
      if is_provider_valid(key) then
        if filter_func and filter_func(key, tab) then return key end
        if not filter_func then return key end
      end
    end
    return nil
  end

  if is_provider_valid(setting_provider) then
    -- If the setting provider is valid, use it
    return setting_provider
  else
    -- If the setting provider is invalid, delete this selection
    self.settings:delSetting("provider")

    local conf_provider = CONFIGURATION.provider -- provider name from configuration.lua
    if is_provider_valid(conf_provider) then
      -- if the configuration provider is valid, use it
      setting_provider = conf_provider
    else
      -- try to find the one defined with `default = true`
      setting_provider = find_setting_provider(function(key, tab)
        return FrontendUtil.tableGetValue(tab, "default") == true
      end)
      
      -- still invalid (none of them defined `default`)
      if not setting_provider then
        setting_provider = find_setting_provider()
        logger.warn("Invalid provider setting found, using a random one: ", setting_provider)
      end
    end

    if not setting_provider then
      CONFIG_LOAD_ERROR = _("No valid model provider is found in the configuration.lua")
      return nil
    end -- if still not found, the configuration is wrong
    self.settings:saveSetting("provider", setting_provider)
    self.updated = true -- mark settings as updated
  end
  return setting_provider
end

-- Flush settings to disk, triggered by koreader
function Assistant:onFlushSettings()
    if self.updated then
        self.settings:flush()
        self.updated = nil
    end
end

function Assistant:isConfigured()
    local err_text = _("Configuration Error.\nPlease set up configuration.lua.")

    -- handle error message during loading
    if CONFIG_LOAD_ERROR and type(CONFIG_LOAD_ERROR) == "string" then
      -- keep the error message clean
      local cut = CONFIG_LOAD_ERROR:find("configuration.lua", 1, true) or 0 -- find as plain
      err_text = string.format("%s\n\n%s", err_text,
              (cut > 0) and CONFIG_LOAD_ERROR:sub(cut) or CONFIG_LOAD_ERROR)
      UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err_text })
      return nil
    end

    if not CONFIGURATION then
      UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err_text })
      return nil
    end

    return true
end

-- Run `callback`, going through NetworkMgr:runWhenOnline unless the current
-- provider points at a local (on-device) server. KOReader's online check would
-- prompt to enable Wi-Fi and never run the callback, which breaks fully-offline
-- use with a server on 127.0.0.1 (see docs/OFFLINE_MODELS.md).
function Assistant:runWhenOnline(callback)
  -- The regex isn't working for some reason, dropping the wifi requirement. if continued, implement this for local llms.
  -- local provider = self.settings and self.settings:readSetting("provider")
  -- local base_url = FrontendUtil.tableGetValue(CONFIGURATION, "provider_settings", provider or "", "base_url") or ""
  -- if base_url:match("^https?://127%.0%.0%.1[:/]")
  --    or base_url:match("^https?://localhost[:/]")
  --    or base_url:match("^https?://0%.0%.0%.0[:/]") then
    callback()
  -- else
  --  NetworkMgr:runWhenOnline(callback)
  -- end
end

function Assistant:init()
  -- loading our own _meta.lua
  self.meta = dofile(META_FILE_PATH)

  -- init settings
  self.settings = LuaSettings:open(self.settings_file)

  -- store the UI language (before any early return: the settings menu reads
  -- ui_language even when configuration.lua is missing)
  local ui_locale = G_reader_settings:readSetting("language") or "en"
  self.ui_language = Language:getLanguageName(ui_locale) or "English"
  self.ui_language_is_rtl = Language:isLanguageRTL(ui_locale)

  -- Register actions with dispatcher for gesture assignment
  self:onDispatcherRegisterActions()

  -- Register menu to main menu (under "tools") - for both reader and filemanager
  self.ui.menu:registerToMainMenu(self)

  if self.ui.document then
    -- Reader specific initialization
    -- Assistant button in highlight dialog
    self.ui.highlight:addToHighlightDialog("ai_assistant", function(_reader_highlight_instance)
      return {
        text = _("AI Assistant"),
        enabled = Device:hasClipboard(),
        callback = function()
          if not self:isConfigured() then
            return
          end

          -- capture the highlight synchronously: it can be cleared before the
          -- deferred callbacks below run (e.g. while the Wi-Fi prompt is up)
          local selected_text = _reader_highlight_instance.selected_text
              and _reader_highlight_instance.selected_text.text
          self:runWhenOnline(function()
            if not updateMessageShown then
              UpdateChecker.checkForUpdates(self)
              updateMessageShown = true
            end
            UIManager:nextTick(function()
              -- Show the main AI dialog with highlighted text
              self.assistant_dialog:show(selected_text)
            end)
          end)
        end,
        hold_callback = function()
          self:_help_dialog()
        end,
      }
    end)
  end

  -- skip initialization if configuration.lua is not found
  if not CONFIGURATION then return end
  self.CONFIGURATION = CONFIGURATION

  -- Sync provider selection from configuration if configuration provider changed
  self:syncProviderSelectionFromConfig()

  local model_provider = self:getModelProvider()
  if not model_provider then
    CONFIG_LOAD_ERROR = _("configuration.lua: model providers are invalid.")
    return
  end

  -- Load the model provider from settings or default configuration
  self.querier = require("assistant_querier"):new({
    assistant = self,
    settings = self.settings,
  })

  local ok, err = self.querier:load_model(model_provider)
  if not ok then
    CONFIG_LOAD_ERROR = err
    UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err })
    return
  end

  -- Conditionally override translate method based on user setting
  self:syncTranslateOverride()

  -- Register Assistant buttons with new KOReader dict API (PR #15184+)
  -- Safe no-op on older versions where addToDictButtons doesn't exist.
  if self.ui and self.ui.dictionary
      and type(self.ui.dictionary.addToDictButtons) == "function" then
    local buttons = self:_buildAssistantDictButtons(nil)
    for _, button in ipairs(buttons) do
      self.ui.dictionary:addToDictButtons(button)
    end
  end


  self.assistant_dialog = AssistantDialog:new(self, CONFIGURATION)
  
  -- Ensure custom prompts from configuration are merged before building menus
  -- so that `show_on_main_popup` and `visible` overrides take effect.
  Prompts.getMergedCustomPrompts(FrontendUtil.tableGetValue(CONFIGURATION, "features", "prompts"))
  
  if self.ui.document then
    -- Reader specific
    -- Auto Recap Feature (hook before a book is opened).
    -- Always track the live per-document instance: the doShowReader hook must
    -- never use a stale instance from a previously-opened book.
    Assistant._recap_instance = self
    if self.settings:readSetting("enable_auto_recap", false) then
      self:_hookRecap()
    end

    -- Add Custom buttons to main select popup menu
    local showOnMain = Prompts.getSortedCustomPrompts(function (prompt, idx)
      if prompt.visible == false then
        return false
      end

      --  set in runtime settings (by holding the prompt button)
      local menukey = string.format("assistant_%02d_%s", prompt.order or 1000, idx)
      local settingkey = "showOnMain_" .. menukey
      if self.settings:has(settingkey) then
        return self.settings:isTrue(settingkey)
      end

      -- set in configure file
      if prompt.show_on_main_popup then
        return true
      end

      return false -- only show if `show_on_main_popup` is true
    end) or {}

    -- Add buttons in sorted order
    for _, tab in ipairs(showOnMain) do
      self:addMainButton(tab.idx, tab)
    end
  end
end

function Assistant:_help_dialog()
    local info_text = string.format("%s %s  ", self.meta.fullname, self.meta.version) .. _([[Usage Tips

Select:
Highlight text (or a word) in the book, then press [AI assistant] in the poped up menu.

Long Press:
- On a Prompt Button: Add to the highlight menu.
- On a highlight menu button to remove it.
- On the Close button to go back to the book in 1 step.

Very-Long Press (over 3 seconds):
On a single word in the book to show the highlight menu (instead of the dictionary).

Multi-Swipe (e.g., ⮠, ⮡, ↺):
On the result dialog to close (as the Close button is far to reach).
]])
    UIManager:show(ConfirmBox:new{
        icon = "info",
        text = info_text,
        face = Font:getFace("xx_smallinfofont"),
        ok_text = _("Purge Settings"),
        ok_callback = function()
          UIManager:show(ConfirmBox:new{
            text = _([[Are you sure to purge the assistant plugin settings? 
This resets the assistant plugin to the status the first time you installed it.

configuration.lua is safe, only the settings are purged.]]),
            ok_text = _("Purge"),
            ok_callback = function()
              self.settings:reset({})
              self.settings:flush()
              UIManager:askForRestart()
            end
          })
        end
    })
end

function Assistant:addMainButton(prompt_idx, prompt)
  local menukey = string.format("assistant_%02d_%s", prompt.order, prompt_idx)
  self.ui.highlight:removeFromHighlightDialog(menukey) -- avoid duplication
  self.ui.highlight:addToHighlightDialog(menukey, function(_reader_highlight_instance)
    local btntext = prompt.text .. " (AI)"  -- append "(AI)" to identify as our function
    return {
      text = btntext,
      callback = function()
        -- capture the highlight synchronously: it can be cleared before the
        -- deferred callbacks below run (e.g. while the Wi-Fi prompt is up)
        local selected_text = _reader_highlight_instance.selected_text
            and _reader_highlight_instance.selected_text.text
        if prompt_idx == "quick_note" then
          Trapper:wrap(function()
            if not self.quicknote then
              local QuickNote = require("assistant_quicknote")
              self.quicknote = QuickNote:new(self)
            end
            self.quicknote:saveNote(nil, selected_text)
          end)
        else
          self:runWhenOnline(function()
            Trapper:wrap(function()
              if prompt.order == -10 and prompt_idx == "dictionary" then
                -- Dictionary prompt, show dictionary dialog
                showDictionaryDialog(self, selected_text)
              elseif prompt_idx == "term_xray" then
                -- Special case for term_xray prompt - use dictionary dialog with enhanced context
                showDictionaryDialog(self, selected_text, nil, "term_xray")
              else
                -- For other prompts, show the custom prompt dialog
                self.assistant_dialog:showCustomPrompt(selected_text, prompt_idx)
              end
            end)
          end)
        end
      end,
      hold_callback = function() -- hold to remove
        UIManager:nextTick(function()
          UIManager:show(ConfirmBox:new{
            text = string.format(_("Remove [%s] from Highlight Menu?"), btntext),
            ok_text = _("Remove"),
            ok_callback = function()
              self:handleEvent(Event:new("AssistantSetButton", {order=prompt.order, idx=prompt_idx}, "remove"))
            end
          })
        end)
      end,
    }
  end)
end

-- Builds the Assistant button specs for the dict popup.
-- Used by both the new addToDictButtons API and the legacy onDictButtonsReady hook.
-- Returns an array of button specs.
function Assistant:_buildAssistantDictButtons(dict_popup_arg)
  if not CONFIGURATION then return {} end

  local plugin_buttons = {}
  
  if self.settings:readSetting("dict_popup_show_wikipedia", true) then
    table.insert(plugin_buttons, {
      id = "assistant_wikipedia",
      font_bold = true,
      text = _("Wikipedia") .. " (AI)",
      callback = function(widget_instance)
          local popup = widget_instance or dict_popup_arg
          local word = popup and popup.word
          self:runWhenOnline(function()
              Trapper:wrap(function()
                self.assistant_dialog:showCustomPrompt(word, "wikipedia")
              end)
          end)
      end,
    })
  end

  if self.settings:readSetting("dict_popup_show_term_xray", false) then
    table.insert(plugin_buttons, {
      id = "assistant_term_xray",
      font_bold = true,
      text = _("Term X-Ray") .. " (AI)",
      callback = function(widget_instance)
          local popup = widget_instance or dict_popup_arg
          local word = popup and popup.word
          self:runWhenOnline(function()
              Trapper:wrap(function()
                showDictionaryDialog(self, word, nil, "term_xray")
              end)
          end)
      end,
    })
  end

  if self.settings:readSetting("dict_popup_show_dictionary", true) then
    table.insert(plugin_buttons, {
      id = "assistant_dictionary",
      text = _("Dictionary") .. " (AI)",
      font_bold = true,
      callback = function(widget_instance)
          local popup = widget_instance or dict_popup_arg
          local word = popup and popup.word
          self:runWhenOnline(function()
              Trapper:wrap(function()
                showDictionaryDialog(self, word)
              end)
          end)
      end,
    })
  end

  if self.settings:readSetting("dict_popup_show_custom_prompts", false) then
    -- Collect custom prompts with show_on_dictionary_popup = true
    local custom_prompts = {}
    if CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.prompts then
      for prompt_key, prompt_config in pairs(CONFIGURATION.features.prompts) do
        if prompt_config.show_on_dictionary_popup == true and prompt_config.visible ~= false then
          table.insert(custom_prompts, {
            id = prompt_key,
            config = prompt_config
          })
        end
      end
    end

    -- Calculate how many custom prompts to add (max 3 total buttons)
    local max_custom_to_add = math.max(0, 3 - #plugin_buttons)
    local custom_to_add = math.min(#custom_prompts, max_custom_to_add)

    -- Add custom prompts as buttons
    for i = 1, custom_to_add do
      local prompt = custom_prompts[i]
      table.insert(plugin_buttons, {
        id = "assistant_" .. prompt.id,
        font_bold = true,
        text = (prompt.config.text or prompt.id) .. " (AI)",
        callback = function(widget_instance)
            local popup = widget_instance or dict_popup_arg
            local word = popup and popup.word
            self:runWhenOnline(function()
                Trapper:wrap(function()
                  self.assistant_dialog:showCustomPrompt(word, prompt.id)
                end)
            end)
        end,
      })
    end
  end

  return plugin_buttons
end

function Assistant:onDictButtonsReady(dict_popup, dict_buttons)
  if not CONFIGURATION then return end
  -- If new KOReader API is present, we already registered at init() time.
  -- This hook won't be called on new KOReader anyway, but guard for safety.
  if self.ui and self.ui.dictionary
      and type(self.ui.dictionary.addToDictButtons) == "function" then
    return
  end

  local plugin_buttons = {}
  local buttons = self:_buildAssistantDictButtons(dict_popup)
  for _, btn in ipairs(buttons) do
    table.insert(plugin_buttons, {
      id = btn.id,
      font_bold = btn.font_bold,
      text = btn.text,
      callback = function() btn.callback(nil) end,
    })
  end

  if #plugin_buttons > 0 and #dict_buttons > 1 then
    table.insert(dict_buttons, 2, plugin_buttons)
  elseif #plugin_buttons > 0 then
    logger.warn("Assistant: dict popup has too few button rows, plugin buttons not added")
  end
end

  -- Event handlers for gesture-triggered actions
  function Assistant:onAskAIQuestion()
    if not self:isConfigured() then
      return
    end
    
    self:runWhenOnline(function()
      -- Show dialog without highlighted text
      Trapper:wrap(function()
        self.assistant_dialog:show()
      end)
    end)
    return true
  end

  function Assistant:onAskAIRecap()
    if not self:isConfigured() then return end
    if not self.ui.document then
      -- these actions are registered with `general = true`, so a gesture can
      -- trigger them from the FileManager where there is no open book
      UIManager:show(InfoMessage:new{ text = _("This action needs an open book.") })
      return true
    end
    self:runWhenOnline(function()
      local book = getDocumentInfo(self.ui.document)
      local showFeatureDialog = require("assistant_featuredialog")
      Trapper:wrap(function()
        showFeatureDialog(self, "recap", book.title, book.authors, book.percent_finished)
      end)
    end)
    return true
  end

  function Assistant:onAskAIXRay()
    if not self:isConfigured() then return end
    if not self.ui.document then
      -- these actions are registered with `general = true`, so a gesture can
      -- trigger them from the FileManager where there is no open book
      UIManager:show(InfoMessage:new{ text = _("This action needs an open book.") })
      return true
    end
    self:runWhenOnline(function()
      local book = getDocumentInfo(self.ui.document)
      local showFeatureDialog = require("assistant_featuredialog")
      Trapper:wrap(function()
        showFeatureDialog(self, "xray", book.title, book.authors, book.percent_finished)
      end)
    end)
    return true
  end

  function Assistant:onAskAIBookInfo()
    if not self:isConfigured() then return end
    if not self.ui.document then
      -- these actions are registered with `general = true`, so a gesture can
      -- trigger them from the FileManager where there is no open book
      UIManager:show(InfoMessage:new{ text = _("This action needs an open book.") })
      return true
    end
    self:runWhenOnline(function()
      local book = getDocumentInfo(self.ui.document)
      local showFeatureDialog = require("assistant_featuredialog")
      Trapper:wrap(function()
        showFeatureDialog(self, "book_info", book.title, book.authors, book.percent_finished)
      end)
    end)
    return true
  end

  function Assistant:onAskAIAnnotations()
    if not self:isConfigured() then return end
    if not self.ui.document then
      -- these actions are registered with `general = true`, so a gesture can
      -- trigger them from the FileManager where there is no open book
      UIManager:show(InfoMessage:new{ text = _("This action needs an open book.") })
      return true
    end
    self:runWhenOnline(function()
      local book = getDocumentInfo(self.ui.document)
      local showFeatureDialog = require("assistant_featuredialog")
      Trapper:wrap(function()
        showFeatureDialog(self, "annotations", book.title, book.authors, book.percent_finished)
      end)
    end)
    return true
  end

  function Assistant:onAskSummaryUsingAnnotations()
    if not self:isConfigured() then return end
    if not self.ui.document then
      -- these actions are registered with `general = true`, so a gesture can
      -- trigger them from the FileManager where there is no open book
      UIManager:show(InfoMessage:new{ text = _("This action needs an open book.") })
      return true
    end
    self:runWhenOnline(function()
      local book = getDocumentInfo(self.ui.document)
      local showFeatureDialog = require("assistant_featuredialog")
      Trapper:wrap(function()
        showFeatureDialog(self, "summary_using_annotations", book.title, book.authors, book.percent_finished)
      end)
    end)
    return true
  end

  function Assistant:onAskAIQuickNote()
    if not self:isConfigured() then return end
    -- Initialize quicknote if not already done
    if not self.quicknote then
      local QuickNote = require("assistant_quicknote")
      self.quicknote = QuickNote:new(self)
    end
    self.quicknote:show()
    return true
  end

-- Sync Overriding translate method with setting
function Assistant:syncTranslateOverride()

  local Translator = require("ui/translator")
  local should_override = self.settings:readSetting("ai_translate_override", false) -- default to false

  if should_override then
    -- Store original translate method if not already stored
    if not Translator._original_showTranslation then
      Translator._original_showTranslation = Translator.showTranslation
    end

    -- Override translate method with AI Assistant
    Translator.showTranslation = function(ts_self, text, detailed_view, source_lang, target_lang, from_highlight, index)
      if not CONFIGURATION then
        UIManager:show(InfoMessage:new{
          icon = "notice-warning",
          text = _("Configuration not found. Please set up configuration.lua first.")
        })
        return
      end

      local words = FrontendUtil.splitToWords(text)
      self:runWhenOnline(function()
        Trapper:wrap(function()
          -- splitToWords result like this: { "The", " ", "good", " ", "news" }
          if #words > 5 then
              self.assistant_dialog:showCustomPrompt(text, "translate")
          else
            -- Show AI Dictionary dialog
            showDictionaryDialog(self, text)
          end
        end)
      end)
    end
    logger.info("Assistant: translate method overridden with AI Assistant")
  else
    -- Restore the override
    if Translator._original_showTranslation then
      -- Restore the original method
      Translator.showTranslation = Translator._original_showTranslation
      Translator._original_showTranslation = nil
      logger.info("Assistant: translate method restored")
    end
  end
end

function Assistant:onAssistantSetButton(btnconf, action)
  local menukey = string.format("assistant_%02d_%s", btnconf.order, btnconf.idx)
  local settingkey = "showOnMain_" .. menukey

  local idx = btnconf.idx
  -- Must look up the *merged* prompts: idx may name a prompt defined only in
  -- configuration.lua, which the built-in table doesn't contain
  local merged_prompts = Prompts.getMergedCustomPrompts(
      FrontendUtil.tableGetValue(CONFIGURATION, "features", "prompts"))
  local prompt = merged_prompts[idx]
  if not prompt then
    logger.warn("AssistantSetButton: unknown prompt index", idx)
    return true
  end

  if action == "add" then
    self.settings:makeTrue(settingkey)
    self.updated = true
    self:addMainButton(idx, prompt)
    UIManager:show(InfoMessage:new{
      text = T(_("Added [%1 (AI)] to Highlight Menu."), prompt.text),
      icon = "notice-info",
      timeout = 3
    })
  elseif action == "remove" then
    self.settings:makeFalse(settingkey)
    self.updated = true
    self.ui.highlight:removeFromHighlightDialog(menukey)
    UIManager:show(InfoMessage:new{
      text = string.format(_("Removed [%s (AI)] from Highlight Menu."), prompt.text),
      icon = "notice-info",
      timeout = 3
    })
  else
    logger.warn("wrong event args", menukey, action)
  end

  return true
end

-- Adds hook on opening a book, the recap feature
function Assistant:_hookRecap()
  local ReaderUI    = require("apps/reader/readerui")
  -- avoid recurive overrides here
  -- pulgin is loaded on every time file opened
  if not ReaderUI._original_doShowReader then

    -- Save a reference to the original doShowReader method.
    ReaderUI._original_doShowReader = ReaderUI.doShowReader

    local lfs         = require("libs/libkoreader-lfs")   -- for file attributes
    local DocSettings = require("docsettings")			      -- for document progress

    -- Override to hook into the reader's doShowReader method.
    -- NOTE: the plugin is re-instantiated for every book, so the hook must not
    -- capture `self`: it resolves the live instance (Assistant._recap_instance,
    -- updated in init) at call time, and checks the setting at call time so the
    -- feature can be turned off without uninstalling the hook.
    function ReaderUI:doShowReader(file, provider, seamless)

      local assistant = Assistant._recap_instance
      local recap_enabled = assistant and assistant.settings
          and assistant.settings:readSetting("enable_auto_recap", false)

      -- Get file metadata; here we use the file's "access" attribute.
      local attr = recap_enabled and lfs.attributes(file) or nil
      local lastAccess = attr and attr.access or nil

      if lastAccess and lastAccess > 0 then -- Has been opened
        local doc_settings = DocSettings:open(file)
        local percent_finished = doc_settings:readSetting("percent_finished") or 0
        local timeDiffHours = math.floor((os.time() - lastAccess) / 3600)

        -- More than 28hrs since last open and less than 95% complete
        -- percent = 0 may means the book is not started yet, the docsettings maybe empty
        if timeDiffHours >= 28 and percent_finished > 0 and percent_finished <= 0.95 then
          -- Construct the message to display.
          local doc_props = doc_settings:child("doc_props")
          local title = doc_props:readSetting("title", "Unknown Title")
          local authors = doc_props:readSetting("authors", "Unknown Author")
          local message = T(_("Do you want an AI Recap?\nFor %1 by %2.\n\n"), title, authors)
                    .. T(N_("Last read an hour ago.", "Last read %1 hours ago.", timeDiffHours), timeDiffHours)

          -- Display the request popup using ConfirmBox.
          UIManager:show(ConfirmBox:new{
            text            = message,
            ok_text         = _("Yes"),
            ok_callback     = function()
              -- resolve again: by now the new book's plugin instance is live
              local live_assistant = Assistant._recap_instance
              if not live_assistant then return end
              live_assistant:runWhenOnline(function()
                local showFeatureDialog = require("assistant_featuredialog")
                Trapper:wrap(function()
                  showFeatureDialog(live_assistant, "recap", title, authors, percent_finished)
                end)
              end)
            end,
            cancel_text     = _("No"),
          })
        end
      end
      return ReaderUI._original_doShowReader(self, file, provider, seamless)
    end
  end
end

function Assistant:syncProviderSelectionFromConfig()
  -- Sync the selected provider from configuration.lua into settings only when
  -- configuration provider changes compared to the last remembered value.
  -- The remembered value is stored in settings as "previous_config_ai_provider".
  local conf = self.CONFIGURATION
  if not conf then return end

  local config_provider = FrontendUtil.tableGetValue(conf, "provider")
  if not config_provider or config_provider == "" then return end

  local previous_config_ai_provider = self.settings:readSetting("previous_config_ai_provider")
  if previous_config_ai_provider ~= config_provider then
    -- Config changed (or first install). Mark config's provider as selected and remember it.
    self.settings:saveSetting("provider", config_provider)
    self.settings:saveSetting("previous_config_ai_provider", config_provider)
    self.updated = true
  end
end

return Assistant
