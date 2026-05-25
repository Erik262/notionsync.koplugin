local logger = require("custom_logger")

local SyncManager = {}

local MAX_TEXT_LENGTH = 2000
local ANNOTATIONS_DB_TITLE = "Annotations"

local ANNOTATIONS_SCHEMA = {
    Text = { title = {} },
    Page = { number = { format = "number" } },
    Created = { date = {} },
    Note = { rich_text = {} },
    Chapter = { rich_text = {} },
    HighlightID = { rich_text = {} },
}

local function sanitizeText(text)
    if not text then return "" end
    text = tostring(text)
    if #text > MAX_TEXT_LENGTH then
        text = text:sub(1, MAX_TEXT_LENGTH)
    end
    return text
end

local function toNotionDate(date_str)
    if not date_str or date_str == "" then return nil end
    local iso = date_str:gsub(" ", "T"):sub(1, 19)
    if iso:match("^%d%d%d%d%-%d%d%-%d%d") then
        return iso
    end
    return nil
end

local function cleanDate(date_str)
    if not date_str then return nil end
    local iso = date_str:gsub("T", " "):gsub("%s+", " ")
    if not iso:find(" ") then
        iso = iso .. " 00:00:00"
    end
    return iso:sub(1, 19)
end

local function buildRowProperties(h)
    local full_text = sanitizeText(h.text)

    local props = {
        Text = { title = {{ text = { content = full_text } }} },
        Page = { number = tonumber(h.page) or 0 },
        HighlightID = { rich_text = {{ text = { content = h.id } }} },
    }

    local created = toNotionDate(h.created_at)
    if created then
        props.Created = { date = { start = created } }
    end

    if h.note and h.note ~= "" then
        props.Note = { rich_text = {{ text = { content = sanitizeText(h.note) } }} }
    end

    if h.chapter and h.chapter ~= "" then
        props.Chapter = { rich_text = {{ text = { content = sanitizeText(h.chapter) } }} }
    end

    return props
end

-- Check if a Notion page still exists (direct API call, no cache).
local function pageExists(client, page_id)
    local page, _ = client:request("GET", "/pages/" .. page_id)
    return page ~= nil and not page.archived
end

-- Check if a Notion database still exists (direct API call, no cache).
local function databaseExists(client, db_id)
    client:clearDatabaseCache(db_id)
    local db, _ = client:getDatabase(db_id)
    return db ~= nil and not db.archived
end

local function findAnnotationsDbInChildren(client, page_id)
    local children, err = client:getBlockChildren(page_id)
    if not children then return nil, err end

    for _, block in ipairs(children) do
        if block.type == "child_database"
            and block.child_database
            and block.child_database.title == ANNOTATIONS_DB_TITLE then
            logger.info("Found existing annotations DB: " .. block.id)
            return block.id
        end
    end
    return nil
end

-- Resolve the per-book annotations database.
-- Returns db_id, is_new_db
local function resolveAnnotationsDb(client, page_id, cached_db_id, yield_func)
    -- 1. Try the cached ID
    if cached_db_id and cached_db_id ~= "" then
        logger.info("Checking cached annotations DB: " .. cached_db_id)
        if databaseExists(client, cached_db_id) then
            return cached_db_id, false
        end
        logger.warn("Cached annotations DB is gone")
    end

    -- 2. Scan page children
    logger.info("Scanning page children for annotations DB...")
    if yield_func then yield_func() end
    local db_id, scan_err = findAnnotationsDbInChildren(client, page_id)
    if db_id then return db_id, false end
    if scan_err then
        logger.warn("Child scan error: " .. tostring(scan_err))
    end

    -- 3. Create new
    logger.info("Creating new annotations database on page " .. page_id)
    if yield_func then yield_func() end
    local new_db, create_err = client:createInlineDatabase(
        page_id, ANNOTATIONS_DB_TITLE, ANNOTATIONS_SCHEMA
    )
    if not new_db then
        logger.err("Failed to create annotations DB: " .. tostring(create_err))
        return nil, create_err
    end
    if not new_db.id then
        logger.err("Annotations DB created but response has no id")
        return nil, "No id in response"
    end
    logger.info("Created annotations DB: " .. new_db.id)
    return new_db.id, true
end

-- Resolve the book page: verify cached -> search -> create.
local function resolveBookPage(client, title, cached_page_id, extra_props, yield_func)
    -- 1. Try cached page_id
    if cached_page_id and cached_page_id ~= "" then
        logger.info("Checking cached page: " .. cached_page_id)
        if pageExists(client, cached_page_id) then
            return cached_page_id, false
        end
        logger.warn("Cached page is gone, searching by title")
        client:clearPageCache(title)
    end

    -- 2. Search by title
    if yield_func then yield_func() end
    local page, search_err = client:findPage(title)
    if page then
        logger.info("Found page by title: " .. page.id)
        return page.id, false
    end
    if search_err then
        logger.err("Page search failed: " .. tostring(search_err))
        return nil, search_err
    end

    -- 3. Create new page
    logger.info("Creating new page: " .. title)
    if yield_func then yield_func() end
    local new_page, create_err = client:createPage(title, extra_props)
    if not new_page then
        logger.err("Failed to create page: " .. tostring(create_err))
        return nil, create_err
    end
    logger.info("Created page: " .. new_page.id)
    return new_page.id, true
end

-- Extract HighlightID from a Notion row
local function extractHighlightId(row)
    local prop = row.properties and row.properties.HighlightID
    if not prop or not prop.rich_text or #prop.rich_text == 0 then return nil end
    return prop.rich_text[1].plain_text
end

-- Rebuild known_highlight_ids by scanning remote rows (recovery path).
local function rebuildStateFromRemote(client, ann_db_id, yield_func)
    logger.info("Rebuilding sync state from remote rows...")
    local rows, err = client:queryDatabaseRows(ann_db_id)
    if not rows then
        logger.warn("Could not query rows for recovery: " .. tostring(err))
        return {}
    end
    local recovered = {}
    for _, row in ipairs(rows) do
        local hid = extractHighlightId(row)
        if hid and hid ~= "" then
            recovered[hid] = row.id
        end
    end
    logger.info("Recovered " .. #rows .. " rows from remote")
    if yield_func then yield_func() end
    return recovered
end

-- yield_func signature: yield_func(progress_info)
-- progress_info = { current = N, total = N, new = N, updated = N, failed = N } or nil
function SyncManager.sync(client, payload, notify_func, yield_func, book_state)
    book_state = book_state or {}
    local title = payload.title
    logger.info("=== SYNC START: " .. title .. " ===")
    if yield_func then yield_func() end

    -- == 1. Build metadata properties ==
    local metadata_sync = true
    if client.config and client.config.metadata_sync ~= nil then
        metadata_sync = client.config.metadata_sync and true or false
    end

    local valid_props = {}
    if metadata_sync then
        local db_schema, db_err = client:getDatabase(client.database_id)
        if db_schema and db_schema.properties then
            valid_props = db_schema.properties
        else
            logger.warn("Could not fetch parent DB schema: " .. tostring(db_err))
        end
    end

    local function getRealPropName(target)
        for k, _ in pairs(valid_props) do
            if k:lower() == target:lower() then return k end
        end
        return nil
    end

    local function formatValue(key, val_type, value)
        if not value or value == "" then return nil end
        if val_type == "rich_text" or val_type == "title" then
            return { rich_text = {{ text = { content = tostring(value) } }} }
        elseif val_type == "number" then
            return { number = tonumber(value) }
        elseif val_type == "select" then
            return { select = { name = tostring(value) } }
        elseif val_type == "multi_select" then
            local tags = {}
            local val_str = tostring(value)
            if val_str:find(";") then
                for part in string.gmatch(val_str, "([^;]+)") do
                    local clean = part:match("^%s*(.-)%s*$")
                    if clean and clean ~= "" then table.insert(tags, { name = clean }) end
                end
            else
                table.insert(tags, { name = val_str })
            end
            return { multi_select = tags }
        elseif val_type == "date" then
            local d = tostring(value):sub(1, 10)
            if d:match("^%d%d%d%d%-%d%d%-%d%d$") then
                return { date = { start = d } }
            end
            return nil
        elseif val_type == "url" then
            return { url = tostring(value) }
        end
        return nil
    end

    local extra_props = {}
    if metadata_sync then
        local mappings = {
            { targets = {"Authors", "Author"}, value = payload.author },
            { targets = {"ISBN"}, value = payload.isbn },
            { targets = {"Progress"}, value = payload.progress },
            { targets = {"Language"}, value = payload.language },
            { targets = {"Pages"}, value = payload.pages and payload.pages > 0 and payload.pages or nil },
            { targets = {"Start Reading"}, value = payload.start_date },
        }
        for _, m in ipairs(mappings) do
            if m.value then
                for _, target in ipairs(m.targets) do
                    local real = getRealPropName(target)
                    if real and valid_props[real] then
                        extra_props[real] = formatValue(real, valid_props[real].type, m.value)
                        break
                    end
                end
            end
        end
    end

    -- == 2. Resolve book page ==
    local page_id, page_err = resolveBookPage(
        client, title, book_state.page_id, extra_props, yield_func
    )
    if not page_id then
        return { success = false, msg = "Page: " .. tostring(page_err) }
    end

    -- Update metadata on existing pages (only if props actually changed)
    if page_id == book_state.page_id and next(extra_props) ~= nil then
        local old_meta = book_state.last_metadata or {}
        local meta_changed = false
        for k, _ in pairs(extra_props) do
            if old_meta[k] == nil then meta_changed = true; break end
        end
        -- Simple change detection: compare serialized metadata
        if not meta_changed then
            local json = require("json")
            local ok1, s1 = pcall(json.encode, extra_props)
            local ok2, s2 = pcall(json.encode, old_meta)
            if not ok1 or not ok2 or s1 ~= s2 then meta_changed = true end
        end
        if meta_changed then
            logger.info("Metadata changed, updating book page")
            client:updatePageProperties(page_id, extra_props)
        end
    end
    if yield_func then yield_func() end

    -- == 3. Resolve annotations database ==
    local ann_db_id, is_new_or_err = resolveAnnotationsDb(
        client, page_id, book_state.annotations_db_id, yield_func
    )
    if not ann_db_id then
        return { success = false, msg = "Annotations DB: " .. tostring(is_new_or_err) }
    end

    local is_fresh_db = (is_new_or_err == true)
        or (book_state.annotations_db_id ~= nil and ann_db_id ~= book_state.annotations_db_id)
    if yield_func then yield_func() end

    -- == 4. Determine sync mode ==
    -- known_highlight_ids from sync_state: { highlight_id = row_id, ... }
    local known = book_state.known_highlight_ids or {}
    local has_state = (next(known) ~= nil)

    if is_fresh_db then
        -- Brand new DB, nothing to recover
        logger.info("Fresh DB — full sync")
        known = {}
    elseif not has_state then
        -- Existing DB but lost state: recover mapping via HighlightID column
        known = rebuildStateFromRemote(client, ann_db_id, yield_func)
        logger.info("Recovered " .. (next(known) and "some" or "no") .. " row mappings from remote")
    end

    local last_sync_clean
    if is_fresh_db then
        -- New DB: everything needs creating
        last_sync_clean = "1970-01-01 00:00:00"
    elseif not has_state and next(known) ~= nil then
        -- Recovered from remote: rows already exist with correct content, skip updates
        -- Use far-future date so no existing row triggers an update
        last_sync_clean = "9999-12-31 23:59:59"
    else
        last_sync_clean = cleanDate(book_state.last_successful_sync) or "1970-01-01 00:00:00"
    end

    -- == 5. Sort highlights by page, then created ==
    table.sort(payload.highlights, function(a, b)
        local pa = tonumber(a.page) or 0
        local pb = tonumber(b.page) or 0
        if pa ~= pb then return pa < pb end
        return (a.created_at or "") < (b.created_at or "")
    end)

    -- Build set of current local highlight IDs
    local current_ids = {}
    for _, h in ipairs(payload.highlights) do
        current_ids[h.id] = true
    end

    -- == 6. Upsert (using sync_state mapping, no remote scan needed) ==
    -- Track the latest updated_at across all highlights for next sync's cursor
    local max_updated_at = "1970-01-01 00:00:00"
    local total_highlights = #payload.highlights
    local count_new = 0
    local count_updated = 0
    local count_failed = 0

    for i, h in ipairs(payload.highlights) do
        local h_date = cleanDate(h.updated_at)
        if h_date and h_date > max_updated_at then
            max_updated_at = h_date
        end

        local existing_row_id = known[h.id]

        if existing_row_id and type(existing_row_id) == "string" then
            -- Row exists in our mapping — update only if changed since last sync
            if h_date and h_date > last_sync_clean then
                local props = buildRowProperties(h)
                local _, upd_err = client:updatePageProperties(existing_row_id, props)
                if upd_err then
                    -- Row might have been deleted in Notion — recreate
                    if tostring(upd_err):find("404") then
                        logger.warn("Row " .. i .. " was deleted in Notion, recreating")
                        local new_row, row_err = client:createRow(ann_db_id, props)
                        if new_row and new_row.id then
                            known[h.id] = new_row.id
                            count_new = count_new + 1
                        else
                            logger.err("Recreate row " .. i .. " failed: " .. tostring(row_err))
                            count_failed = count_failed + 1
                        end
                    else
                        logger.err("Update row " .. i .. " failed: " .. tostring(upd_err))
                        count_failed = count_failed + 1
                    end
                else
                    count_updated = count_updated + 1
                end
            end
        else
            -- New highlight — create row
            local props = buildRowProperties(h)
            local new_row, row_err = client:createRow(ann_db_id, props)
            if new_row and new_row.id then
                known[h.id] = new_row.id
                count_new = count_new + 1
            else
                logger.err("Create row " .. i .. " failed: " .. tostring(row_err))
                count_failed = count_failed + 1
            end
        end

        if yield_func then
            yield_func({
                current = i,
                total = total_highlights,
                new = count_new,
                updated = count_updated,
                failed = count_failed,
            })
        end
    end

    -- == 7. Remove orphaned rows (highlights deleted locally) ==
    local count_removed = 0
    for hid, row_id in pairs(known) do
        if not current_ids[hid] and type(row_id) == "string" then
            local _, archive_err = client:archivePage(row_id)
            if archive_err then
                logger.warn("Remove orphan failed: " .. tostring(archive_err))
            else
                count_removed = count_removed + 1
            end
            known[hid] = nil
            if yield_func then yield_func() end
        end
    end

    if count_removed > 0 then
        logger.info("Removed " .. count_removed .. " orphaned rows")
    end

    -- == 8. Record sync timestamp (stored locally in sync_state, not in Notion) ==

    -- Build clean known_highlight_ids (only current highlights)
    local clean_ids = {}
    for _, h in ipairs(payload.highlights) do
        if known[h.id] then
            clean_ids[h.id] = known[h.id]
        end
    end

    logger.info(string.format(
        "=== SYNC DONE: new=%d updated=%d removed=%d failed=%d ===",
        count_new, count_updated, count_removed, count_failed
    ))

    return {
        success = true,
        new = count_new,
        updated = count_updated,
        removed = count_removed,
        next_state = {
            page_id = page_id,
            annotations_db_id = ann_db_id,
            last_successful_sync = max_updated_at,
            known_highlight_ids = clean_ids,
            last_metadata = extra_props,
        }
    }
end

return SyncManager
