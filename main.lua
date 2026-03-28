local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local logger = require("custom_logger")
local json = require("json")
local NetworkMgr = require("ui/network/manager")
local Dispatcher = require("dispatcher")

local Menus = require("menus")
local GetHighlights = require("get_highlights")
local NotionClient = require("notion_client")
local SyncManager = require("sync_manager")
local SyncProgressDialog = require("sync_progress_dialog")
local SyncStateStore = require("sync_state_store")

local function getPluginDir()
    local source = debug.getinfo(1, "S").source or ""
    if source:sub(1, 1) == "@" then
        source = source:sub(2)
    end
    return source:match("^(.*)/[^/]+$") or "."
end

local function joinPath(...)
    local parts = { ... }
    return table.concat(parts, "/")
end

local function loadLuaTable(path)
    local chunk, err = loadfile(path)
    if not chunk then
        return nil, err
    end

    local ok, result = pcall(chunk)
    if not ok then
        return nil, result
    end
    if type(result) ~= "table" then
        return nil, "Config must return a table"
    end

    return result
end

local NotionSync = WidgetContainer:new{
    name = "NotionSync",
    config = {
        notion_token = "",
        database_id = "",
        notion_version = "2022-06-28",
        metadata_sync = true
    },
    client = nil,
    plugin_dir = nil,
    config_file = nil,
    credentials_file = nil,
    sync_state_file = nil,
    sync_state = nil,
}

function NotionSync:init()
    self.plugin_dir = getPluginDir()
    self.config_file = joinPath(self.plugin_dir, "config.json")
    self.credentials_file = joinPath(self.plugin_dir, "notion_credentials.lua")
    self.sync_state_file = joinPath(self.plugin_dir, "sync_state.lua")
    self.ui.menu:registerToMainMenu(self)
    self:loadConfig()
    self:loadSyncState()

    Dispatcher:registerAction("notionsync_current_book", {
        category = "none",
        event = "NotionSyncTrigger",
        title = "NotionSync: Sync Current Book",
        general = true,
    })
end

function NotionSync:addToMainMenu(menu_items)
    Menus.register(self, menu_items)
end

function NotionSync:onNotionSyncTrigger()
    self:onSyncRequested()
end

-- =========================================================
-- CONFIGURATION LOGIC
-- =========================================================

function NotionSync:loadConfig()
    local loaded_anything = false

    local file = io.open(self.config_file, "r")
    if file then
        local content = file:read("*a")
        file:close()
        local loaded = json.decode(content)
        if loaded then
            if loaded.database_id ~= nil then
                self.config.database_id = loaded.database_id or ""
            end
            if loaded.notion_version ~= nil and loaded.notion_version ~= "" then
                self.config.notion_version = loaded.notion_version
            end
            if loaded.metadata_sync ~= nil then
                self.config.metadata_sync = loaded.metadata_sync and true or false
            end
            if loaded.notion_token ~= nil and loaded.notion_token ~= "" then
                self.config.notion_token = loaded.notion_token
            end
            loaded_anything = true
        end
    end

    local credentials, cred_err = loadLuaTable(self.credentials_file)
    if credentials then
        if credentials.notion_token ~= nil then
            self.config.notion_token = credentials.notion_token or ""
        end
        if credentials.database_id ~= nil then
            self.config.database_id = credentials.database_id or ""
        end
        if credentials.notion_version ~= nil and credentials.notion_version ~= "" then
            self.config.notion_version = credentials.notion_version
        end
        loaded_anything = true
    elseif cred_err and not tostring(cred_err):match("No such file") then
        logger.warn("NotionSync: Could not load credentials file: " .. tostring(cred_err))
    end

    if not loaded_anything then
        self:saveConfig()
    end

    if self.config.notion_token and self.config.notion_token ~= "" then
        self.client = NotionClient:new(self.config)
    end
end

function NotionSync:saveConfig()
    local runtime_file = io.open(self.config_file, "w")
    if runtime_file then
        runtime_file:write(json.encode({
            notion_version = self.config.notion_version or "2022-06-28",
            metadata_sync = self.config.metadata_sync and true or false
        }))
        runtime_file:close()
    else
        self:notify("Error saving config.json")
        return
    end

    local credentials_file = io.open(self.credentials_file, "w")
    if credentials_file then
        credentials_file:write(string.format(
            "return {\n    notion_token = %q,\n    database_id = %q,\n    notion_version = %q,\n}\n",
            self.config.notion_token or "",
            self.config.database_id or "",
            self.config.notion_version or "2022-06-28"
        ))
        credentials_file:close()
        if self.config.notion_token and self.config.notion_token ~= "" then
            self.client = NotionClient:new(self.config)
        else
            self.client = nil
        end
    else
        self:notify("Error saving notion_credentials.lua")
    end
end

function NotionSync:loadSyncState()
    local state, err = SyncStateStore.load(self.sync_state_file)
    if not state then
        logger.warn("NotionSync: Could not load sync state: " .. tostring(err))
        self.sync_state = { books = {} }
        return
    end

    state.books = state.books or {}
    self.sync_state = state
end

function NotionSync:getBookSyncState(file_path)
    if not file_path or not self.sync_state or type(self.sync_state.books) ~= "table" then
        return nil
    end

    return self.sync_state.books[file_path]
end

function NotionSync:saveBookSyncState(file_path, book_state)
    if not file_path or not book_state then
        return
    end

    self.sync_state = self.sync_state or {}
    self.sync_state.books = self.sync_state.books or {}
    self.sync_state.books[file_path] = book_state

    local ok, err = SyncStateStore.save(self.sync_state_file, self.sync_state)
    if not ok then
        logger.warn("NotionSync: Could not save sync state: " .. tostring(err))
    end
end

function NotionSync:showConfigMenu()
    local db_info = "Not Configured"
    if self.config.database_id and self.config.database_id ~= "" then
        db_info = "Configured (" .. self.config.database_id:sub(1, 4) .. "...)"
    end

    local token_info = "Not Set"
    if self.config.notion_token and self.config.notion_token ~= "" then
        token_info = "Set (Ends in ..." .. self.config.notion_token:sub(-4) .. ")"
    end

    local metadata_info = self.config.metadata_sync and "Enabled" or "Disabled"

    local settings_menu -- Forward declaration
    
    settings_menu = Menu:new{
        title = "NotionSync Settings",
        item_table = {
            {
                text = "Set Notion Token",
                sub_text = token_info,
                callback = function() 
                    self:promptForToken(settings_menu) 
                end
            },
            {
                text = "Select Database",
                sub_text = db_info,
                callback = function() 
                    self:promptForDatabase(settings_menu) 
                end
            },
            {
                text = "Metadata Sync",
                sub_text = metadata_info,
                callback = function()
                    self.config.metadata_sync = not self.config.metadata_sync
                    self:saveConfig()
                    self:notify("Metadata Sync " .. (self.config.metadata_sync and "Enabled" or "Disabled"))
                    if settings_menu then UIManager:close(settings_menu) end
                    self:showConfigMenu()
                end
            },
            {
                text = "Credentials File",
                sub_text = self.credentials_file,
                callback = function()
                    self:notify(self.credentials_file)
                end,
            }
        }
    }
    UIManager:show(settings_menu)
end

function NotionSync:promptForToken(parent_menu)
    local input_dialog
    input_dialog = InputDialog:new{
        title = "Enter Notion Integration Token",
        input = self.config.notion_token,
        buttons = {
            {
                {
                    text = "Cancel",
                    id = "close",
                    callback = function()
                        UIManager:close(input_dialog)
                    end
                },
                {
                    text = "Save",
                    callback = function()
                        local token = input_dialog:getInputValue()
                        if token and token ~= "" then
                            self.config.notion_token = token
                            self:saveConfig()
                            self:notify("Token Saved")
                            if parent_menu then UIManager:close(parent_menu) end
                            self:showConfigMenu()
                        end
                        UIManager:close(input_dialog)
                    end
                }
            }
        }
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function NotionSync:promptForDatabase(parent_menu)
    if not NetworkMgr:isOnline() then self:notify("Enable Wi-Fi first") return end
    if not self.client then self:notify("Set Token first!") return end

    -- 1. Show Persistent Loading Popup
    local loading_popup = InfoMessage:new{
        text = "Fetching Databases...",
        timeout = nil, -- Persistent
    }
    UIManager:show(loading_popup)

    -- 2. Create Coroutine
    local co = coroutine.create(function()
        -- IMPORTANT: Yield immediately to allow the popup to draw on screen
        coroutine.yield()

        -- Now perform the blocking network request
        local res, err = self.client:listDatabases()
        
        -- Close the loading popup immediately after data returns
        if loading_popup then UIManager:close(loading_popup) end

        if not res or not res.results then
            self:notify("Error: " .. tostring(err))
            return
        end

        local db_list = {}
        local db_menu -- Forward declaration

        for _, item in ipairs(res.results) do
            local title = "Untitled"
            if item.title and item.title[1] then
                title = item.title[1].plain_text
            end
            
            table.insert(db_list, {
                text = title,
                callback = function()
                    self.config.database_id = item.id
                    self:saveConfig()
                    
                    if db_menu then UIManager:close(db_menu) end
                    self:notify("Selected: " .. title)
                    
                    if parent_menu then UIManager:close(parent_menu) end
                    self:showConfigMenu()
                end
            })
        end

        if #db_list == 0 then
            self:notify("No databases found accessible by this token.")
        else
            -- Show the Menu (Yielding first ensures cleanup of previous popup)
            coroutine.yield()
            local show_menu = function()
                db_menu = Menu:new{
                    title = "Select Target Database",
                    item_table = db_list
                }
                UIManager:show(db_menu)
            end
            UIManager:nextTick(show_menu)
        end
    end)

    -- 3. Pump the coroutine
    local function pump()
        if coroutine.status(co) == "suspended" then
            local status, res = coroutine.resume(co)
            if not status then
                if loading_popup then UIManager:close(loading_popup) end
                logger.err("NotionSync DB List Crash: " .. tostring(res))
                self:notify("Crash: " .. tostring(res))
            else
                UIManager:nextTick(pump)
            end
        end
    end
    UIManager:nextTick(pump)
end

-- =========================================================
-- SYNC LOGIC
-- =========================================================

function NotionSync:notify(msg)
    UIManager:nextTick(function()
        UIManager:show(InfoMessage:new{
            text = msg,
            timeout = 3
        })
    end)
end

local function buildProgressMessage(state)
    local lines = {
        state.title or "NotionSync",
        state.stage_label or "Working...",
    }

    if state.progress_total ~= nil then
        table.insert(lines, string.format("%d/%d", state.progress_current or 0, state.progress_total))
    end

    if state.detail_text and state.detail_text ~= "" then
        table.insert(lines, state.detail_text)
    end

    local count_line = string.format(
        "New: %d  Updated: %d  Failed: %d",
        state.new_count or 0,
        state.updated_count or 0,
        state.failed_count or 0
    )
    table.insert(lines, count_line)

    return table.concat(lines, "\n")
end

function NotionSync:updateProgressPopup(dialog_ref, dialog_input)
    local state = SyncProgressDialog.buildState(dialog_input)

    if dialog_ref[1] then
        UIManager:close(dialog_ref[1])
    end

    dialog_ref[1] = InfoMessage:new{
        text = buildProgressMessage(state),
        timeout = nil,
    }
    UIManager:show(dialog_ref[1])
end

function NotionSync:closeProgressPopup(dialog_ref)
    if dialog_ref[1] then
        UIManager:close(dialog_ref[1])
        dialog_ref[1] = nil
    end
end

function NotionSync:withManagedWifi(sync_mode, sync_func)
    if type(sync_mode) == "function" then
        sync_func = sync_mode
        sync_mode = "bulk"
    end

    local dialog_ref = { nil }
    local wifi_enabled_by_plugin = false

    local co = coroutine.create(function()
        if not NetworkMgr:isOnline() then
            self:updateProgressPopup(dialog_ref, {
                mode = sync_mode,
                stage = "enabling_wifi",
            })
            coroutine.yield()
            wifi_enabled_by_plugin = true
            local ok = pcall(function()
                NetworkMgr:enableWifi()
            end)
            if not ok then
                self:closeProgressPopup(dialog_ref)
                self:notify("Failed to turn Wi-Fi on")
                return
            end

            local attempts = 0
            while not NetworkMgr:isOnline() and attempts < 30 do
                attempts = attempts + 1
                self:updateProgressPopup(dialog_ref, {
                    mode = sync_mode,
                    stage = "waiting_for_wifi",
                })
                coroutine.yield()
            end

            if not NetworkMgr:isOnline() then
                self:closeProgressPopup(dialog_ref)
                self:notify("Wi-Fi did not come online")
                return
            end
        end

        self:updateProgressPopup(dialog_ref, {
            mode = sync_mode,
            stage = "preparing",
        })
        coroutine.yield()

        local ok, err = pcall(sync_func, dialog_ref)

        if wifi_enabled_by_plugin then
            self:updateProgressPopup(dialog_ref, {
                mode = sync_mode,
                stage = "disabling_wifi",
            })
            coroutine.yield()
            pcall(function()
                if NetworkMgr.disableWifi then
                    NetworkMgr:disableWifi()
                elseif NetworkMgr.turnOffWifi then
                    NetworkMgr:turnOffWifi()
                elseif NetworkMgr.setWifiState then
                    NetworkMgr:setWifiState(false)
                end
            end)
        end

        self:closeProgressPopup(dialog_ref)

        if not ok then
            logger.err("NotionSync Managed Sync Crash: " .. tostring(err))
            self:notify("Crash: " .. tostring(err))
        end
    end)

    local function pump()
        if coroutine.status(co) == "suspended" then
            local status, res = coroutine.resume(co)
            if not status then
                self:closeProgressPopup(dialog_ref)
                logger.err("NotionSync Pump Crash: " .. tostring(res))
                self:notify("Crash: " .. tostring(res))
            else
                UIManager:nextTick(pump)
            end
        end
    end

    UIManager:nextTick(pump)
end

-- Helper function to calculate progress from document
local function calculateProgress(doc)
    local progress = 0
    pcall(function()
         -- 1. Try calculation from summary OR direct methods (Stronger Doc Option)
         local current_page = 0
         local total_pages = 0
         
         -- Try getting pages from summary
         if doc.info and doc.info.summary then
             current_page = doc.info.summary.curr_page or 0
             total_pages = doc.info.summary.num_pages or 0
         end

         -- If summary missing/zero, try direct doc methods/properties
         if total_pages == 0 and doc.getTotalPages then
             total_pages = doc:getTotalPages()
         elseif total_pages == 0 and doc.info and doc.info.number_of_pages then
             total_pages = doc.info.number_of_pages
         end
         
         if current_page == 0 and doc.getCurrentPage then
             current_page = doc:getCurrentPage()
         end
         
         if total_pages > 0 and current_page > 0 then
             progress = math.floor((current_page / total_pages) * 100) / 100
         end
         
         -- 2. Fallback: Try reading pre-calculated percent from settings or props OR FILE
         if progress == 0 then
             local pf = nil
             if doc.settings and doc.settings.percent_finished then pf = doc.settings.percent_finished end
             if not pf and doc.percent_finished then pf = doc.percent_finished end
             if not pf and doc.props and doc.props.percent_finished then pf = doc.props.percent_finished end
             
             if pf then
                progress = math.floor(pf * 100) / 100
             end
         end
         
         -- 3. PLAN B: File Read
         if progress == 0 and doc.file then
            local sdr_path = doc.file .. ".sdr"
            local meta_name = "metadata" .. (doc.file:match("%.([^%.]+)$") or "") .. ".lua"
            local meta_path = sdr_path .. "/" .. meta_name
            
            -- Check file existence via lfs
            local lfs = require("libs/libkoreader-lfs")
            if lfs.attributes(meta_path) then
                 pcall(function()
                     local chunk = loadfile(meta_path)
                     if chunk then
                         local meta_data = chunk()
                         if meta_data and meta_data.percent_finished then
                             progress = math.floor(meta_data.percent_finished * 100) / 100
                         end
                     end
                 end)
            end
        end
    end) 
    return progress
end

local function loadAnnotationsForPath(file_path)
    if not file_path then
        return nil
    end

    local DocSettings = require("docsettings")
    local doc_settings = DocSettings:open(file_path)
    if not doc_settings then
        return nil
    end

    local candidates = {
        "annotations",
        "highlight",
        "highlights",
        "bookmarks",
    }

    for _, key in ipairs(candidates) do
        local value = doc_settings:readSetting(key)
        if type(value) == "table" and next(value) ~= nil then
            return value
        end
    end

    return {}
end

-- Helper function to sync ONE book (takes doc and annotations)
function NotionSync:syncOneBook(doc, annotations, yield_func)
    if not doc then 
        return { success = false, msg = "No document" }
    end
    
    local payload, err = GetHighlights.transform(doc, annotations)
    
    if not payload then 
        return { success = false, msg = err or "Error extracting highlights" }
    end

    payload.progress = calculateProgress(doc)

    local result = SyncManager.sync(
        self.client,
        payload,
        nil,
        yield_func,
        self:getBookSyncState(doc.file)
    )

    if result and result.success and result.next_state then
        self:saveBookSyncState(doc.file, result.next_state)
    end

    return result
end

-- Get all books from history
function NotionSync:getAllBooks()
    local books = {}
    
    -- Try to load history.lua file directly
    local history_paths = {
        "./history.lua",
        "history.lua",
        os.getenv("HOME") .. "/.local/share/koreader/history.lua",
        "/koreader/history.lua",
    }
    
    local history_data = nil
    
    -- Try to load history file from various possible locations
    for _, path in ipairs(history_paths) do
        local lfs = require("libs/libkoreader-lfs")
        if lfs.attributes(path) then
            local chunk = loadfile(path)
            if chunk then
                local success, result = pcall(chunk)
                if success and result then
                    history_data = result
                    break
                end
            end
        end
    end
    
    -- Fallback: try using History module if direct file loading fails
    if not history_data then
        pcall(function()
            local History = require("ui/data/history")
            if History then
                history_data = History:getHistory()
            end
        end)
    end
    
    -- Extract file paths from history data
    if history_data then
        for _, item in pairs(history_data) do
            local file_path = type(item) == "table" and (item.file or item.path or item.filename) or nil
            if file_path and file_path ~= "" then
                table.insert(books, file_path)
            elseif type(item) == "string" and item ~= "" then
                table.insert(books, item)
            end
        end
    end
    
    return books
end

-- Sync current book to notion
function NotionSync:onSyncRequested()
    if not self.client or not self.config.database_id or self.config.database_id == "" then
        self:notify("Plugin not configured. Check settings.")
        self:showConfigMenu()
        return
    end

    local doc = self.ui.document
    local annotations = self.ui.annotation and self.ui.annotation.annotations
    
    if not doc then
        self:notify("No document open")
        return
    end
    
    if (not annotations or next(annotations) == nil) and doc and doc.file then
        annotations = loadAnnotationsForPath(doc.file)
    end

    if not annotations or next(annotations) == nil then
        self:notify("No annotations found in current book")
        return
    end

    self:withManagedWifi("single", function(dialog_ref)
        self:updateProgressPopup(dialog_ref, {
            mode = "single",
            stage = "syncing_changes",
            completed_books = 0,
            total_books = 0,
            current_book = doc.file and (doc.file:match("([^/]+)$") or doc.file) or "",
        })
        coroutine.yield()

        local yield_func = function()
            self:updateProgressPopup(dialog_ref, {
                mode = "single",
                stage = "syncing_changes",
                completed_books = 0,
                total_books = 0,
                current_book = doc.file and (doc.file:match("([^/]+)$") or doc.file) or "",
            })
            coroutine.yield()
        end

        local result = self:syncOneBook(doc, annotations, yield_func)

        if result.success then
            self:updateProgressPopup(dialog_ref, {
                mode = "single",
                stage = "complete",
                completed_books = 0,
                total_books = 0,
                current_book = doc.file and (doc.file:match("([^/]+)$") or doc.file) or "",
                new_count = result.new or 0,
                updated_count = result.updated or 0,
                failed_count = 0,
            })
            coroutine.yield()
            self:notify(string.format("Success! New: %d, Updated: %d", result.new or 0, result.updated or 0))
        else
            self:updateProgressPopup(dialog_ref, {
                mode = "single",
                stage = "failed",
                completed_books = 0,
                total_books = 0,
                current_book = doc.file and (doc.file:match("([^/]+)$") or doc.file) or "",
                failed_count = 1,
            })
            coroutine.yield()
            self:notify("Failed: " .. result.msg)
        end
    end)
end

-- Load document and annotations from file path
local function loadBookFromPath(file_path)
    local DocumentRegistry = require("document/documentregistry")
    
    if not file_path then
        return nil, nil
    end
    
    -- Check if file exists
    local lfs = require("libs/libkoreader-lfs")
    if not lfs.attributes(file_path) then
        logger.warn("NotionSync: File does not exist: " .. tostring(file_path))
        return nil, nil
    end
    
    local doc = nil
    local annotations = nil
    
    -- Try to open the document using DocumentRegistry (standard KOReader way)
    pcall(function()
        if DocumentRegistry and DocumentRegistry.openDocument then
            doc = DocumentRegistry:openDocument(file_path)
        elseif DocumentRegistry and DocumentRegistry.open then
            doc = DocumentRegistry:open(file_path)
        else
            -- Fallback: try direct Document require
            local Document = require("document/document")
            if Document and Document.openDocument then
                doc = Document.openDocument(file_path)
            elseif Document and Document.new then
                doc = Document:new{ file = file_path }
            end
        end
        
        -- Ensure document has file path set (needed for metadata extraction)
        if doc and not doc.file then
            doc.file = file_path
        end
        
        -- Try to ensure document metadata is loaded
        if doc and doc.loadDocument then
            pcall(function() doc:loadDocument() end)
        end
    end)
    
    annotations = loadAnnotationsForPath(file_path)
    
    return doc, annotations
end

-- Sync all books to Notion
function NotionSync:onSyncAllBooksRequested()
    if not self.client or not self.config.database_id or self.config.database_id == "" then
        self:notify("Plugin not configured. Check settings.")
        self:showConfigMenu()
        return
    end

    -- Get all books and pre-filter to actual sync candidates.
    local books = {}
    for _, book_path in ipairs(self:getAllBooks()) do
        local annotations = loadAnnotationsForPath(book_path)
        if annotations and next(annotations) ~= nil then
            table.insert(books, book_path)
        end
    end
    
    if #books == 0 then
        self:notify("No books found to sync")
        return
    end

    self:withManagedWifi("bulk", function(dialog_ref)
        local total_success = 0
        local total_new = 0
        local total_updated = 0
        local total_failed = 0

        for i, book_path in ipairs(books) do
            local book_name = book_path:match("([^/]+)$") or book_path
            self:updateProgressPopup(dialog_ref, {
                mode = "bulk",
                stage = "syncing_changes",
                completed_books = i - 1,
                total_books = #books,
                current_book = book_name,
                new_count = total_new,
                updated_count = total_updated,
                failed_count = total_failed,
            })
            coroutine.yield()

            local doc, annotations = loadBookFromPath(book_path)

            if doc and annotations and next(annotations) ~= nil then
                local yield_func = function()
                    self:updateProgressPopup(dialog_ref, {
                        mode = "bulk",
                        stage = "syncing_changes",
                        completed_books = i - 1,
                        total_books = #books,
                        current_book = book_name,
                        new_count = total_new,
                        updated_count = total_updated,
                        failed_count = total_failed,
                    })
                    coroutine.yield()
                end

                local result = self:syncOneBook(doc, annotations, yield_func)

                if result.success then
                    total_success = total_success + 1
                    total_new = total_new + (result.new or 0)
                    total_updated = total_updated + (result.updated or 0)
                else
                    total_failed = total_failed + 1
                    logger.warn("NotionSync: Failed to sync " .. book_name .. ": " .. tostring(result.msg))
                end
            else
                logger.info("NotionSync: Skipping " .. book_name .. " (no annotations)")
            end

            if doc then
                pcall(function()
                    if doc.closeDocument then
                        doc:closeDocument()
                    elseif doc.close then
                        doc:close()
                    end
                end)
            end
        end

        local summary = string.format("Sync complete!\nBooks: %d/%d\nNew: %d, Updated: %d",
            total_success, #books, total_new, total_updated)
        if total_failed > 0 then
            summary = summary .. string.format("\nFailed: %d", total_failed)
        end

        self:updateProgressPopup(dialog_ref, {
            mode = "bulk",
            stage = "complete",
            completed_books = #books,
            total_books = #books,
            current_book = "",
            new_count = total_new,
            updated_count = total_updated,
            failed_count = total_failed,
        })
        coroutine.yield()
        self:notify(summary)
    end)
end

return NotionSync
