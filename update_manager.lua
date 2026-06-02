-- update_manager.lua
-- Network layer for the in-app updater. Talks to the GitHub REST API to find
-- the latest release and download the files that make up the plugin.
--
-- Mirrors the TLS/options used by notion_client.lua, which is known to work on
-- Kobo's limited network stack. All requests set a User-Agent header because
-- the GitHub API rejects requests without one (HTTP 403).

local https = require("ssl.https")
local ltn12 = require("ltn12")
local socket = require("socket")
local json = require("json")
local logger = require("custom_logger")

local UpdateManager = {
    owner = "Erik262",
    repo = "notionsync.koplugin",
    user_agent = "NotionSync-KOReader-Updater",
    max_retries = 4,
    max_redirects = 5,
}

-- Perform a single HTTPS GET, collecting the body into a string.
-- Returns body (string), http_code (number) on success, or nil, err.
local function http_get_once(url, accept_json)
    local headers = { ["User-Agent"] = UpdateManager.user_agent }
    if accept_json then
        headers["Accept"] = "application/vnd.github+json"
    end

    local current = url
    for _ = 1, UpdateManager.max_redirects do
        local chunks = {}
        local res, code, rheaders = https.request({
            url = current,
            method = "GET",
            headers = headers,
            sink = ltn12.sink.table(chunks),
            -- Match notion_client.lua's TLS settings (works on Kobo).
            options = { "all", "no_sslv2", "no_sslv3" },
        })

        if not res then
            return nil, "request failed: " .. tostring(code)
        end

        if code == 301 or code == 302 or code == 303 or code == 307 or code == 308 then
            local loc = rheaders and (rheaders.location or rheaders.Location)
            if not loc or loc == "" then
                return nil, "redirect without Location header"
            end
            current = loc
        elseif code == 200 then
            return table.concat(chunks), 200
        else
            local body = table.concat(chunks)
            return nil, "HTTP " .. tostring(code) .. (body ~= "" and (": " .. body:sub(1, 160)) or "")
        end
    end

    return nil, "too many redirects"
end

-- GET with retries for transient network failures (Kobo sockets are flaky).
-- max_attempts defaults to UpdateManager.max_retries; pass 1 for a quick,
-- non-blocking single try (used by the silent startup check).
function UpdateManager.get(url, accept_json, max_attempts)
    max_attempts = max_attempts or UpdateManager.max_retries
    local last_err
    for attempt = 1, max_attempts do
        local body, err = http_get_once(url, accept_json)
        if body then
            return body, err
        end
        last_err = err
        logger.warn("NotionSync update: GET failed (attempt " .. attempt .. "): " .. tostring(err))
        if attempt < max_attempts then
            socket.sleep(2)
        end
    end
    return nil, last_err
end

-- Parse a version string like "v1.2.3-beta.4" into release numbers { 1, 2, 3 }
-- and a prerelease string ("beta.4") or nil. Leading "v" is ignored.
function UpdateManager.parseVersion(v)
    v = tostring(v or ""):gsub("^[vV]", "")
    local main, pre = v:match("^([^%-]*)%-?(.*)$")
    local release = {}
    for n in (main or ""):gmatch("%d+") do
        release[#release + 1] = tonumber(n)
    end
    if pre == "" then pre = nil end
    return release, pre
end

local function split_identifiers(s)
    local ids = {}
    for id in s:gmatch("[^%.]+") do
        ids[#ids + 1] = id
    end
    return ids
end

-- Returns -1 if a < b, 0 if equal, 1 if a > b (semantic version compare,
-- including prerelease precedence: 1.1.0-beta.1 < 1.1.0).
function UpdateManager.compareVersions(a, b)
    local ra, pa = UpdateManager.parseVersion(a)
    local rb, pb = UpdateManager.parseVersion(b)

    -- Compare release numbers first.
    for i = 1, math.max(#ra, #rb) do
        local x = ra[i] or 0
        local y = rb[i] or 0
        if x ~= y then
            return x < y and -1 or 1
        end
    end

    -- Release numbers equal: a version WITH a prerelease tag is lower than one
    -- without (1.1.0-beta < 1.1.0).
    if pa and not pb then return -1 end
    if pb and not pa then return 1 end
    if not pa and not pb then return 0 end

    -- Both have prerelease tags: compare dot-separated identifiers.
    local ia = split_identifiers(pa)
    local ib = split_identifiers(pb)
    for i = 1, math.max(#ia, #ib) do
        local xa = ia[i]
        local xb = ib[i]
        if xa == nil then return -1 end  -- fewer identifiers = lower precedence
        if xb == nil then return 1 end
        local na = tonumber(xa)
        local nb = tonumber(xb)
        if na and nb then
            if na ~= nb then return na < nb and -1 or 1 end
        elseif na and not nb then
            return -1  -- numeric identifiers are lower than alphanumeric
        elseif nb and not na then
            return 1
        elseif xa ~= xb then
            return xa < xb and -1 or 1
        end
    end
    return 0
end

-- True if release tag `latest` is newer than installed version `current`.
function UpdateManager.isNewer(latest, current)
    return UpdateManager.compareVersions(latest, current) > 0
end

-- Fetch metadata for the latest published release.
-- Returns { tag, name, body, html_url } or nil, err.
function UpdateManager.getLatestRelease(single_try)
    local url = string.format(
        "https://api.github.com/repos/%s/%s/releases/latest",
        UpdateManager.owner, UpdateManager.repo)
    local body, err = UpdateManager.get(url, true, single_try and 1 or nil)
    if not body then
        return nil, err
    end

    local ok, data = pcall(json.decode, body)
    if not ok or type(data) ~= "table" or not data.tag_name then
        return nil, "could not parse release info"
    end

    return {
        tag = data.tag_name,
        name = data.name,
        body = data.body,
        html_url = data.html_url,
    }
end

-- List the top-level files in the repo at a given ref (tag/branch/sha).
-- Returns an array of { name = ..., url = <raw download url> } or nil, err.
function UpdateManager.listReleaseFiles(ref)
    local url = string.format(
        "https://api.github.com/repos/%s/%s/contents?ref=%s",
        UpdateManager.owner, UpdateManager.repo, ref)
    local body, err = UpdateManager.get(url, true)
    if not body then
        return nil, err
    end

    local ok, data = pcall(json.decode, body)
    if not ok or type(data) ~= "table" then
        return nil, "could not parse file list"
    end

    local files = {}
    for _, item in ipairs(data) do
        if type(item) == "table" and item.type == "file"
                and item.name and item.download_url then
            files[#files + 1] = { name = item.name, url = item.download_url }
        end
    end

    if #files == 0 then
        return nil, "no files found for " .. tostring(ref)
    end
    return files
end

-- Download a single file's raw contents. Returns content (string) or nil, err.
function UpdateManager.fetchFile(url)
    return UpdateManager.get(url, false)
end

return UpdateManager
