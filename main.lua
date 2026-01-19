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

local NotionSync = WidgetContainer:new{
    name = "NotionSync",
    config = {
        notion_token = "",
        database_id = ""
    },
    client = nil,
    config_file = "plugins/notionsync.koplugin/config.json"
}

function NotionSync:init()
    self.ui.menu:registerToMainMenu(self)
    self:loadConfig()

    Dispatcher:registerAction("notionsync_action", {
        category = "none",
        event = "NotionSyncTrigger",
        title = "Sync to Notion",
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
    local file = io.open(self.config_file, "r")
    if file then
        local content = file:read("*a")
        file:close()
        local loaded = json.decode(content)
        if loaded then
            self.config = loaded
            if self.config.notion_token and self.config.notion_token ~= "" then
                self.client = NotionClient:new(self.config)
            end
        end
    end
end

function NotionSync:saveConfig()
    local file = io.open(self.config_file, "w")
    if file then
        file:write(json.encode(self.config))
        file:close()
        self.client = NotionClient:new(self.config)
    else
        self:notify("Error saving config.json")
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

    local result = SyncManager.sync(self.client, payload, nil, yield_func)
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
        for _, item in ipairs(history_data) do
            if item.file then
                table.insert(books, item.file)
            end
        end
    end
    
    return books
end

-- Sync current book to notion
function NotionSync:onSyncRequested()

    -- Enable Wi-Fi if not online
    if not NetworkMgr:isOnline() then
        NetworkMgr:enableWifi()
        return
    end

    -- Check if plugin is configured
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
    
    if not annotations or next(annotations) == nil then
        self:notify("No annotations found in current book")
        return
    end

    local loading_popup = InfoMessage:new{
        text = "Syncing highlights to Notion...",
        timeout = nil,
    }
    UIManager:show(loading_popup)

    local yield_func = function() coroutine.yield() end

    local co = coroutine.create(function()
        local result = self:syncOneBook(doc, annotations, yield_func)
        if loading_popup then UIManager:close(loading_popup) end
        
        if result.success then
            coroutine.yield() 
            self:notify(string.format("Success! New: %d, Updated: %d", result.new, result.updated))
        else
            self:notify("Failed: " .. result.msg)
        end
    end)

    local function pump()
        if coroutine.status(co) == "suspended" then
            local status, res = coroutine.resume(co)
            if not status then
                if loading_popup then UIManager:close(loading_popup) end
                logger.err("NotionSync Crash: " .. tostring(res))
                self:notify("Crash: " .. tostring(res))
            else
                UIManager:nextTick(pump)
            end
        end
    end
    UIManager:nextTick(pump)
end

-- Load document and annotations from file path
local function loadBookFromPath(file_path)
    local DocSettings = require("docsettings")
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
        if DocumentRegistry then
            doc = DocumentRegistry:openDocument(file_path)
        else
            -- Fallback: try direct Document require
            local Document = require("document/document")
            if Document and Document.openDocument then
                doc = Document.openDocument(file_path)
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
    
    -- Load annotations from sidecar file
    local doc_settings = DocSettings:open(file_path)
    if doc_settings then
        annotations = doc_settings:readSetting("annotations") or {}
        -- Also try to get from UI.annotation structure if available
        if not annotations or next(annotations) == nil then
            -- Try alternative annotation locations
            local alt_annotations = doc_settings:readSetting("highlight") or {}
            if next(alt_annotations) ~= nil then
                annotations = alt_annotations
            end
        end
    end
    
    return doc, annotations
end

-- Sync all books to Notion
function NotionSync:onSyncAllBooksRequested()

    -- Enable Wi-Fi if not online
    if not NetworkMgr:isOnline() then
        NetworkMgr:enableWifi()
        return
    end

    -- Check if plugin is configured
    if not self.client or not self.config.database_id or self.config.database_id == "" then
        self:notify("Plugin not configured. Check settings.")
        self:showConfigMenu()
        return
    end

    -- Get all books
    local books = self:getAllBooks()
    
    if #books == 0 then
        self:notify("No books found to sync")
        return
    end

    local progress_popup = InfoMessage:new{
        text = string.format("Syncing all books: 0/%d", #books),
        timeout = nil,
    }
    UIManager:show(progress_popup)

    local yield_func = function() coroutine.yield() end

    local co = coroutine.create(function()
        coroutine.yield()  -- Allow popup to show
        
        local total_success = 0
        local total_new = 0
        local total_updated = 0
        local total_failed = 0
        
        for i, book_path in ipairs(books) do
            -- Update progress popup by closing and recreating
            local book_name = book_path:match("([^/]+)$") or book_path
            if progress_popup then UIManager:close(progress_popup) end
            progress_popup = InfoMessage:new{
                text = string.format("Syncing all books: %d/%d\n%s", i, #books, book_name),
                timeout = nil,
            }
            UIManager:show(progress_popup)
            coroutine.yield()  -- Allow UI to update
            
            -- Load document and annotations
            local doc, annotations = loadBookFromPath(book_path)
            
            if doc and annotations and next(annotations) ~= nil then
                -- Sync this book
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
                -- Skip books without annotations
                logger.info("NotionSync: Skipping " .. book_name .. " (no annotations)")
            end
            
            -- Close document to free memory
            if doc then
                pcall(function()
                    doc:closeDocument()
                end)
            end
        end
        
        -- Close progress popup
        if progress_popup then UIManager:close(progress_popup) end
        
        -- Show final summary
        coroutine.yield()
        local summary = string.format("Sync complete!\nBooks: %d/%d\nNew: %d, Updated: %d", 
            total_success+1, #books, total_new, total_updated)
        if total_failed > 0 then
            summary = summary .. string.format("\nFailed: %d", total_failed)
        end
        self:notify(summary)
    end)

    local function pump()
        if coroutine.status(co) == "suspended" then
            local status, res = coroutine.resume(co)
            if not status then
                if progress_popup then UIManager:close(progress_popup) end
                logger.err("NotionSync All Books Crash: " .. tostring(res))
                self:notify("Crash: " .. tostring(res))
            else
                UIManager:nextTick(pump)
            end
        end
    end
    UIManager:nextTick(pump)
end

return NotionSync