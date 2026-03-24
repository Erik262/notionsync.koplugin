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
    local url = self.api_url .. endpoint
    local response_body = {}
    
    local headers = {
        ["Authorization"] = "Bearer " .. self.token,
        ["Notion-Version"] = self.version,
        ["Content-Type"] = "application/json",
        ["Connection"] = "keep-alive"
    }

    local source = nil
    if body_table then
        local json_body = json.encode(body_table)
        source = ltn12.source.string(json_body)
        headers["Content-Length"] = string.len(json_body)
    end

    logger.info("NotionSync: " .. method .. " " .. url)

    local max_retries = 3
    local code, status
    
    for i = 1, max_retries do
        response_body = {}
        if body_table then
            source = ltn12.source.string(json.encode(body_table))
        end

        local _, r_code, _, r_status = https.request{
            url = url,
            method = method,
            headers = headers,
            source = source,
            sink = ltn12.sink.table(response_body),
            protocol = "any",
            options = {"all", "no_sslv2", "no_sslv3"},
            verify = "none",
            timeout = self.TIMEOUT 
        }
        code = r_code
        status = r_status

        if code == 200 then break end
        if type(code) == "number" and code >= 400 and code < 500 then break end
    end

    if code ~= 200 then
        local response_str = table.concat(response_body)
        logger.warn("NotionSync HTTP Error Body: " .. response_str)
        return nil, "HTTP " .. tostring(code) .. ": " .. tostring(status)
    end

    local response_str = table.concat(response_body)
    if response_str == "" then return {} end
    return json.decode(response_str)
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

function NotionClient:createPage(title, extra_props)
    if not self.database_id then return nil, "No Database Selected" end
    local safe_title = sanitizeTextValue(title, "Unknown Title")
    local properties = {
        Name = { title = {{ text = { content = safe_title } }} }
    }
    
    -- Merge extra properties (ISBN, Author, Progress, etc)
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

function NotionClient:updateLastSync(page_id, iso_date)
    local body = { properties = { ["Last Sync"] = { rich_text = {{ text = { content = iso_date } }} } } }
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
        for _, block in ipairs(res.results) do table.insert(all_results, block) end
        if res.has_more then cursor = res.next_cursor else cursor = nil end
    until not cursor
    return all_results
end

function NotionClient:appendBlockChildren(block_id, blocks)
    local body = { children = blocks }
    return self:request("PATCH", "/blocks/" .. block_id .. "/children", body)
end

function NotionClient:updateBlock(block_id, content)
    -- CHANGE: We now check if 'content' is a string or a table.
    -- If it's a table, we assume it's a full 'rich_text' array.
    local rich_text_body
    if type(content) == "table" then
        rich_text_body = content
    else
        rich_text_body = {{ text = { content = content } }}
    end

    local body = {
        quote = { rich_text = rich_text_body }
    }
    return self:request("PATCH", "/blocks/" .. block_id, body)
end

return NotionClient
