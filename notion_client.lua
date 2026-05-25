local https = require("ssl.https")
local ltn12 = require("ltn12")
local json = require("json")
local logger = require("custom_logger")

local NotionClient = {}
local MAX_NOTION_TEXT_LENGTH = 2000

local function resolveNotionVersion(config)
    if config and config.notion_version and config.notion_version ~= "" then
        return config.notion_version
    end
    return "2022-06-28"
end

local function sanitizeTextValue(value, fallback)
    local text = tostring(value or "")
    text = text:gsub("\r\n", " "):gsub("\n", " "):gsub("%s+", " ")
    text = text:match("^%s*(.-)%s*$") or ""

    if text == "" then
        text = fallback or ""
    end
    if #text > MAX_NOTION_TEXT_LENGTH then
        text = text:sub(1, MAX_NOTION_TEXT_LENGTH)
    end

    return text
end

function NotionClient:new(config)
    local o = {
        token = config.notion_token,
        database_id = config.database_id,
        version = resolveNotionVersion(config),
        api_url = "https://api.notion.com/v1",
        TIMEOUT = 10,
        config = config,
        cache = {
            databases = {},
            pages = {},
            missing_pages = {},
        }
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

function NotionClient:request(method, endpoint, body_table)
    local socket = require("socket")
    local url = self.api_url .. endpoint
    local response_body = {}

    local headers = {
        ["Authorization"] = "Bearer " .. self.token,
        ["Notion-Version"] = self.version,
        ["Connection"] = "close"
    }

    local json_body = nil
    if body_table then
        json_body = json.encode(body_table)
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#json_body)
    end

    logger.info("REQUEST: " .. method .. " " .. url)
    if json_body then
        logger.dbg("REQUEST BODY: " .. json_body)
    end

    local max_retries = 5
    local code, status

    for i = 1, max_retries do
        response_body = {}

        local request_params = {
            url = url,
            method = method,
            headers = headers,
            sink = ltn12.sink.table(response_body),
            protocol = "any",
            options = {"all", "no_sslv2", "no_sslv3"},
            verify = "none",
            timeout = self.TIMEOUT
        }

        if json_body then
            request_params.source = ltn12.source.string(json_body)
        end

        local _, r_code, _, r_status = https.request(request_params)
        code = r_code
        status = r_status

        if code == 200 then break end

        if type(code) ~= "number" then
            -- Network/DNS error (not an HTTP status code) — wait and retry
            logger.warn("Network error (attempt " .. i .. "/" .. max_retries .. "): " .. tostring(code))
            if i < max_retries then
                socket.sleep(2)
            end
        elseif code == 429 and i < max_retries then
            logger.warn("Rate limited, retry " .. i)
            socket.sleep(1)
        elseif code >= 400 and code < 500 then
            break
        end
    end

    local response_str = table.concat(response_body)

    if code ~= 200 then
        logger.err("HTTP " .. tostring(code) .. " from " .. method .. " " .. endpoint)
        logger.err("RESPONSE: " .. response_str)
        if json_body then
            logger.err("SENT BODY: " .. json_body)
        end
        return nil, "HTTP " .. tostring(code) .. ": " .. response_str
    end

    if response_str == "" then return {} end
    local ok, decoded = pcall(json.decode, response_str)
    if not ok then
        logger.err("JSON decode failed: " .. tostring(decoded))
        logger.err("RAW RESPONSE: " .. response_str)
        return nil, "JSON decode failed"
    end
    return decoded
end

function NotionClient:listDatabases()
    local body = { filter = { value = "database", property = "object" } }
    return self:request("POST", "/search", body)
end

function NotionClient:getDatabase(database_id)
    if self.cache.databases[database_id] then
        return self.cache.databases[database_id]
    end

    local res, err = self:request("GET", "/databases/" .. database_id)
    if res then
        self.cache.databases[database_id] = res
    end
    return res, err
end

function NotionClient:clearDatabaseCache(database_id)
    if database_id then
        self.cache.databases[database_id] = nil
    end
end

function NotionClient:findPage(title)
    if not self.database_id then return nil, "No Database Selected" end
    local safe_title = sanitizeTextValue(title, "Unknown Title")
    if self.cache.pages[safe_title] ~= nil then
        return self.cache.pages[safe_title]
    end
    if self.cache.missing_pages[safe_title] then
        return nil
    end

    local query = { filter = { property = "Name", title = { equals = safe_title } } }
    local res, err = self:request("POST", "/databases/" .. self.database_id .. "/query", query)
    if not res then return nil, err end
    if res.results and #res.results > 0 then
        self.cache.pages[safe_title] = res.results[1]
        self.cache.missing_pages[safe_title] = nil
        return res.results[1]
    end
    self.cache.missing_pages[safe_title] = true
    return nil
end

function NotionClient:clearPageCache(title)
    if title then
        local safe_title = sanitizeTextValue(title, "Unknown Title")
        self.cache.pages[safe_title] = nil
        self.cache.missing_pages[safe_title] = nil
    end
end

function NotionClient:createPage(title, extra_props)
    if not self.database_id then return nil, "No Database Selected" end
    local safe_title = sanitizeTextValue(title, "Unknown Title")
    local properties = {
        Name = { title = {{ text = { content = safe_title } }} }
    }

    if extra_props then
        for k, v in pairs(extra_props) do
            properties[k] = v
        end
    end

    local body = {
        parent = { database_id = self.database_id },
        properties = properties
    }
    local res, err = self:request("POST", "/pages", body)
    if res then
        self.cache.pages[safe_title] = res
        self.cache.missing_pages[safe_title] = nil
    end
    return res, err
end

function NotionClient:updatePageProperties(page_id, properties)
    local body = { properties = properties }
    return self:request("PATCH", "/pages/" .. page_id, body)
end

function NotionClient:getBlockChildren(block_id)
    local all_results = {}
    local cursor = nil
    repeat
        local endpoint = "/blocks/" .. block_id .. "/children?page_size=100"
        if cursor then endpoint = endpoint .. "&start_cursor=" .. cursor end
        local res, err = self:request("GET", endpoint)
        if not res then return nil, err end
        for _, block in ipairs(res.results or {}) do table.insert(all_results, block) end
        if res.has_more then cursor = res.next_cursor else cursor = nil end
    until not cursor
    return all_results
end

function NotionClient:createInlineDatabase(parent_page_id, title, schema_properties)
    -- Build JSON manually to guarantee column order in Notion
    -- (Lua tables with string keys have no order; json.encode shuffles them)
    local prop_json = '{'
        .. '"Text":{"title":{}},'
        .. '"Chapter":{"rich_text":{}},'
        .. '"Created":{"date":{}},'
        .. '"Note":{"rich_text":{}},'
        .. '"Page":{"number":{"format":"number"}},'
        .. '"HighlightID":{"rich_text":{}}'
        .. '}'

    local body_json = '{'
        .. '"parent":{"type":"page_id","page_id":"' .. parent_page_id .. '"},'
        .. '"is_inline":true,'
        .. '"title":[{"type":"text","text":{"content":"' .. title .. '"}}],'
        .. '"properties":' .. prop_json
        .. '}'

    logger.info("Creating inline DB on page " .. parent_page_id .. " with title '" .. title .. "'")

    -- Use raw JSON request to preserve property order
    local socket = require("socket")
    local response_body = {}
    local headers = {
        ["Authorization"] = "Bearer " .. self.token,
        ["Notion-Version"] = self.version,
        ["Connection"] = "close",
        ["Content-Type"] = "application/json",
        ["Content-Length"] = tostring(#body_json),
    }

    local url = self.api_url .. "/databases"
    logger.info("REQUEST: POST " .. url)
    logger.dbg("REQUEST BODY: " .. body_json)

    local max_retries = 5
    local code
    for i = 1, max_retries do
        response_body = {}
        local _, r_code = https.request({
            url = url,
            method = "POST",
            headers = headers,
            source = ltn12.source.string(body_json),
            sink = ltn12.sink.table(response_body),
            protocol = "any",
            options = {"all", "no_sslv2", "no_sslv3"},
            verify = "none",
            timeout = self.TIMEOUT,
        })
        code = r_code
        if code == 200 then break end
        if type(code) ~= "number" then
            logger.warn("Network error (attempt " .. i .. "/" .. max_retries .. "): " .. tostring(code))
            if i < max_retries then socket.sleep(2) end
        elseif code >= 400 and code < 500 then
            break
        end
    end

    local response_str = table.concat(response_body)
    if code ~= 200 then
        logger.err("HTTP " .. tostring(code) .. " from POST /databases")
        logger.err("RESPONSE: " .. response_str)
        logger.err("SENT BODY: " .. body_json)
        return nil, "HTTP " .. tostring(code) .. ": " .. response_str
    end

    if response_str == "" then return {} end
    local ok, decoded = pcall(json.decode, response_str)
    if not ok then return nil, "JSON decode failed" end
    return decoded
end

function NotionClient:queryDatabaseRows(database_id, options)
    options = options or {}
    local all_results = {}
    local cursor = nil
    repeat
        local body = { page_size = 100 }
        if options.sorts then body.sorts = options.sorts end
        if options.filter then body.filter = options.filter end
        if cursor then body.start_cursor = cursor end

        local res, err = self:request("POST", "/databases/" .. database_id .. "/query", body)
        if not res then return nil, err end
        for _, row in ipairs(res.results or {}) do
            table.insert(all_results, row)
        end
        if res.has_more then cursor = res.next_cursor else cursor = nil end
    until not cursor
    return all_results
end

function NotionClient:createRow(database_id, properties)
    local body = {
        parent = { database_id = database_id },
        properties = properties
    }
    return self:request("POST", "/pages", body)
end

function NotionClient:archivePage(page_id)
    local body = { archived = true }
    return self:request("PATCH", "/pages/" .. page_id, body)
end

return NotionClient
