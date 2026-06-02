local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Menu = require("ui/widget/menu")
local json = require("json")
local NetworkMgr = require("ui/network/manager")
local Dispatcher = require("dispatcher")

-- Force-reload plugin-local modules so that Lua's global require() cache
-- cannot serve a stale or wrong version from another plugin.
for _, name in ipairs({
    "custom_logger", "menus", "get_highlights", "notion_client",
    "sync_manager", "sync_progress_dialog", "sync_state_store", "sync_decision",
    "update_manager",
}) do
    package.loaded[name] = nil
end

local logger = require("custom_logger")
local Menus = require("menus")
local GetHighlights = require("get_highlights")
local NotionClient = require("notion_client")
local SyncManager = require("sync_manager")
local SyncProgressDialog = require("sync_progress_dialog")
local SyncStateStore = require("sync_state_store")
local UpdateManager = require("update_manager")

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

-- Installed plugin version. MUST be bumped to match each GitHub release tag,
-- otherwise the in-app updater cannot tell when a newer release is available.
local PLUGIN_VERSION = "1.1.0-beta.1"

local NotionSync = WidgetContainer:new{
    name = "NotionSync",
    version = PLUGIN_VERSION,
    config = {
        notion_token = "",
        database_id = "",
        notion_version = "2022-06-28",
        metadata_sync = true,
        auto_update_check = true,
        skipped_version = "",
        last_update_check = 0,
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
    self.legacy_credentials_file = joinPath(self.plugin_dir, "notion_credentials.lua")
    self.credentials_file = self:getCredentialsPath()
    self.sync_state_file = joinPath(self.plugin_dir, "sync_state.lua")

    -- Diagnostic: write a marker file so we can confirm this code version ran
    pcall(function()
        local f = io.open(joinPath(self.plugin_dir, "LOADED_OK"), "w")
        if f then f:write(os.date("%Y-%m-%d %H:%M:%S")); f:close() end
    end)

    self.ui.menu:registerToMainMenu(self)
    self:loadConfig()
    self:loadSyncState()

    Dispatcher:registerAction("notionsync_current_book", {
        category = "none",
        event = "NotionSyncTrigger",
        title = "NotionSync: Sync Current Book",
        general = true,
    })

    -- Quietly check for a newer release shortly after startup. This never turns
    -- Wi-Fi on by itself (it only checks when already online) and runs at most
    -- once per day, so it stays out of the way.
    if self.config.auto_update_check ~= false then
        UIManager:scheduleIn(8, function()
            local now = os.time()
            local last = self.config.last_update_check or 0
            if NetworkMgr:isOnline() and (now - last) > 86400 then
                self:checkForUpdates({ silent = true })
            end
        end)
    end
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

-- Credentials are stored OUTSIDE the plugin folder (in KOReader's settings
-- directory) so that updating or reinstalling the plugin never overwrites the
-- user's Notion token and database ID. Falls back to the old in-plugin
-- location only if the settings directory cannot be resolved.
function NotionSync:getCredentialsPath()
    local ok, DataStorage = pcall(require, "datastorage")
    if ok and DataStorage and DataStorage.getSettingsDir then
        local settings_dir = DataStorage:getSettingsDir()
        if settings_dir and settings_dir ~= "" then
            return joinPath(settings_dir, "notionsync_credentials.lua")
        end
    end
    return self.legacy_credentials_file
end

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
            if loaded.auto_update_check ~= nil then
                self.config.auto_update_check = loaded.auto_update_check and true or false
            end
            if loaded.skipped_version ~= nil then
                self.config.skipped_version = loaded.skipped_version or ""
            end
            if loaded.last_update_check ~= nil then
                self.config.last_update_check = tonumber(loaded.last_update_check) or 0
            end
            if loaded.notion_token ~= nil and loaded.notion_token ~= "" then
                self.config.notion_token = loaded.notion_token
            end
            loaded_anything = true
        end
    end

    local migrated = false
    local credentials, cred_err = loadLuaTable(self.credentials_file)
    if not credentials and self.credentials_file ~= self.legacy_credentials_file then
        -- One-time migration: pull credentials saved by older versions from
        -- inside the plugin folder into the new external location.
        local legacy = loadLuaTable(self.legacy_credentials_file)
        if legacy and ((legacy.notion_token and legacy.notion_token ~= "")
                or (legacy.database_id and legacy.database_id ~= "")) then
            credentials = legacy
            migrated = true
        end
    end

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

    -- Persist on first run (creates config) or after migrating credentials to
    -- the new external location.
    if not loaded_anything or migrated then
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
            metadata_sync = self.config.metadata_sync and true or false,
            auto_update_check = self.config.auto_update_check ~= false,
            skipped_version = self.config.skipped_version or "",
            last_update_check = self.config.last_update_check or 0
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
    local autoupdate_info = (self.config.auto_update_check ~= false) and "Enabled" or "Disabled"

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
                text = "Check for Updates",
                sub_text = "Installed: v" .. tostring(self.version),
                callback = function()
                    if settings_menu then UIManager:close(settings_menu) end
                    self:checkForUpdates({ silent = false })
                end,
            },
            {
                text = "Check for Updates on Startup",
                sub_text = autoupdate_info,
                callback = function()
                    self.config.auto_update_check = not (self.config.auto_update_check ~= false)
                    self:saveConfig()
                    self:notify("Startup update check "
                        .. ((self.config.auto_update_check ~= false) and "Enabled" or "Disabled"))
                    if settings_menu then UIManager:close(settings_menu) end
                    self:showConfigMenu()
                end,
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

function NotionSync:updateProgressPopup(dialog_ref, dialog_input)
    if dialog_ref[1] then
        UIManager:close(dialog_ref[1])
    end

    dialog_ref[1] = InfoMessage:new{
        text = SyncProgressDialog.buildMessage(dialog_input),
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

-- =========================================================
-- IN-APP UPDATER
-- =========================================================

function NotionSync:disableWifiIfEnabled(enabled)
    if not enabled then return end
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

-- Ensure Wi-Fi is online, then call callback(enabled_by_us). enabled_by_us is
-- true if we had to turn Wi-Fi on (so the caller knows to turn it back off).
function NotionSync:ensureWifi(callback)
    if NetworkMgr:isOnline() then
        callback(false)
        return
    end

    local ok = pcall(function() NetworkMgr:enableWifi() end)
    if not ok then
        self:notify("Failed to turn Wi-Fi on")
        return
    end

    local waiting = InfoMessage:new{ text = "Turning Wi-Fi on...", timeout = nil }
    UIManager:show(waiting)

    local attempts = 0
    local function poll()
        if NetworkMgr:isOnline() then
            UIManager:close(waiting)
            callback(true)
            return
        end
        attempts = attempts + 1
        if attempts > 40 then
            UIManager:close(waiting)
            self:disableWifiIfEnabled(true)
            self:notify("Wi-Fi did not come online")
            return
        end
        UIManager:scheduleIn(0.5, poll)
    end
    UIManager:scheduleIn(0.5, poll)
end

-- Check GitHub for a newer release. opts.silent suppresses "up to date" /
-- failure messages and never turns Wi-Fi on by itself.
function NotionSync:checkForUpdates(opts)
    opts = opts or {}
    local silent = opts.silent and true or false

    local function doCheck(enabled_by_us)
        local checking
        if not silent then
            checking = InfoMessage:new{ text = "Checking for updates...", timeout = nil }
            UIManager:show(checking)
        end

        local latest, err = UpdateManager.getLatestRelease(silent)

        if checking then UIManager:close(checking) end

        -- Remember when we last checked so the daily silent check backs off.
        self.config.last_update_check = os.time()
        self:saveConfig()

        if not latest then
            self:disableWifiIfEnabled(enabled_by_us)
            if silent then
                logger.warn("NotionSync: silent update check failed: " .. tostring(err))
            else
                self:notify("Update check failed: " .. tostring(err))
            end
            return
        end

        if not UpdateManager.isNewer(latest.tag, self.version) then
            self:disableWifiIfEnabled(enabled_by_us)
            if not silent then
                self:notify("You're up to date (v" .. tostring(self.version) .. ")")
            end
            return
        end

        if silent and self.config.skipped_version == latest.tag then
            self:disableWifiIfEnabled(enabled_by_us)
            return
        end

        self:promptUpdate(latest, enabled_by_us)
    end

    if NetworkMgr:isOnline() then
        UIManager:nextTick(function() doCheck(false) end)
    elseif silent then
        return  -- never enable Wi-Fi for a background check
    else
        self:ensureWifi(doCheck)
    end
end

-- Ask the user whether to install the newer release.
function NotionSync:promptUpdate(latest, enabled_by_us)
    local text = "A new version of NotionSync is available.\n\n"
        .. "Installed: v" .. tostring(self.version) .. "\n"
        .. "Available: " .. tostring(latest.tag) .. "\n\n"
        .. "Update now over Wi-Fi?"

    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = "Update",
        ok_callback = function()
            self:performUpdate(latest, enabled_by_us)
        end,
        cancel_text = "Skip",
        cancel_callback = function()
            self.config.skipped_version = latest.tag
            self:saveConfig()
            self:disableWifiIfEnabled(enabled_by_us)
            self:notify("Skipped " .. tostring(latest.tag))
        end,
    })
end

-- Download every file in the release into memory, then (only if all succeed)
-- overwrite the plugin's files. Keeps the plugin intact if a download fails.
function NotionSync:performUpdate(latest, enabled_by_us)
    local popup = { nil }
    local function show(text)
        if popup[1] then UIManager:close(popup[1]) end
        popup[1] = InfoMessage:new{ text = text, timeout = nil }
        UIManager:show(popup[1])
    end
    local function closePopup()
        if popup[1] then UIManager:close(popup[1]); popup[1] = nil end
    end

    local co = coroutine.create(function()
        show("Preparing update...")
        coroutine.yield()

        local files, err = UpdateManager.listReleaseFiles(latest.tag)
        if not files then
            closePopup()
            self:disableWifiIfEnabled(enabled_by_us)
            self:notify("Update failed: " .. tostring(err))
            return
        end

        local contents = {}
        for i, f in ipairs(files) do
            show("Downloading " .. tostring(latest.tag) .. "\n"
                .. i .. " / " .. #files .. "  (" .. f.name .. ")")
            coroutine.yield()
            local data, derr = UpdateManager.fetchFile(f.url)
            if not data then
                closePopup()
                self:disableWifiIfEnabled(enabled_by_us)
                self:notify("Download failed (" .. f.name .. "): " .. tostring(derr))
                return
            end
            contents[f.name] = data
        end

        -- Wi-Fi no longer needed once everything is in memory.
        self:disableWifiIfEnabled(enabled_by_us)

        show("Installing update...")
        coroutine.yield()

        local write_failed
        for name, data in pairs(contents) do
            local fh = io.open(joinPath(self.plugin_dir, name), "wb")
            if not fh then
                write_failed = name
                break
            end
            fh:write(data)
            fh:close()
        end

        closePopup()

        if write_failed then
            self:notify("Install error writing " .. write_failed .. " — update incomplete")
            return
        end

        self.config.skipped_version = ""
        self:saveConfig()

        UIManager:show(InfoMessage:new{
            text = "NotionSync " .. tostring(latest.tag) .. " installed.\n\n"
                .. "Please fully close and reopen KOReader to finish updating.",
            timeout = nil,
        })
    end)

    local function pump()
        if coroutine.status(co) == "suspended" then
            local ok, res = coroutine.resume(co)
            if not ok then
                closePopup()
                self:disableWifiIfEnabled(enabled_by_us)
                logger.err("NotionSync update crash: " .. tostring(res))
                self:notify("Update crash: " .. tostring(res))
            else
                UIManager:nextTick(pump)
            end
        end
    end
    UIManager:nextTick(pump)
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
        local book_name = doc.file and (doc.file:match("([^/]+)$") or doc.file) or ""

        self:updateProgressPopup(dialog_ref, {
            mode = "single",
            stage = "syncing_changes",
            current_book = book_name,
        })
        coroutine.yield()

        local yield_func = function(progress)
            local info = {
                mode = "single",
                stage = "syncing_changes",
                current_book = book_name,
            }
            if progress then
                info.progress_current = progress.current
                info.progress_total = progress.total
                info.new_count = progress.new
                info.updated_count = progress.updated
                info.failed_count = progress.failed
            end
            self:updateProgressPopup(dialog_ref, info)
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
            local parts = {}
            if (result.new or 0) > 0 then table.insert(parts, "New: " .. result.new) end
            if (result.updated or 0) > 0 then table.insert(parts, "Updated: " .. result.updated) end
            if (result.removed or 0) > 0 then table.insert(parts, "Removed: " .. result.removed) end
            if #parts == 0 then table.insert(parts, "Already up to date") end
            self:notify("Success! " .. table.concat(parts, ", "))
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
                local yield_func = function(progress)
                    local info = {
                        mode = "bulk",
                        stage = "syncing_changes",
                        completed_books = i - 1,
                        total_books = #books,
                        current_book = book_name,
                        new_count = total_new,
                        updated_count = total_updated,
                        failed_count = total_failed,
                    }
                    if progress then
                        info.progress_current = progress.current
                        info.progress_total = progress.total
                        info.new_count = total_new + (progress.new or 0)
                        info.updated_count = total_updated + (progress.updated or 0)
                        info.failed_count = total_failed + (progress.failed or 0)
                    end
                    self:updateProgressPopup(dialog_ref, info)
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
