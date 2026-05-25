local logger = require("logger") -- Keep system logger for redundancy

local CustomLogger = {}

local function getPluginDir()
    local source = debug.getinfo(1, "S").source or ""
    if source:sub(1, 1) == "@" then
        source = source:sub(2)
    end
    return source:match("^(.*)/[^/]+$") or "."
end

local LOG_FILE = getPluginDir() .. "/notion_debug.log"
local MAX_LOG_SIZE = 256 * 1024  -- 256 KB

local function rotate_if_needed()
    local f = io.open(LOG_FILE, "r")
    if not f then return end
    local size = f:seek("end")
    f:close()
    if size and size > MAX_LOG_SIZE then
        os.remove(LOG_FILE .. ".old")
        os.rename(LOG_FILE, LOG_FILE .. ".old")
    end
end

local function append_to_file(level, msg)
    local f = io.open(LOG_FILE, "a")
    if f then
        local timestamp = os.date("%Y-%m-%d %H:%M:%S")
        f:write(string.format("[%s] [%s] %s\n", timestamp, level, tostring(msg)))
        f:close()
    end
end

function CustomLogger.info(msg)
    append_to_file("INFO", msg)
    -- Also print to standard log for now, just in case
    logger.info("[NotionSync] " .. tostring(msg))
end

function CustomLogger.warn(msg)
    append_to_file("WARN", msg)
    logger.warn("[NotionSync] " .. tostring(msg))
end

function CustomLogger.err(msg)
    append_to_file("ERROR", msg)
    logger.err("[NotionSync] " .. tostring(msg))
end

function CustomLogger.dbg(msg)
    append_to_file("DEBUG", msg)
    logger.dbg("[NotionSync] " .. tostring(msg))
end

-- Rotate and initialize with a separator
rotate_if_needed()
local f = io.open(LOG_FILE, "a")
if f then
    f:write("\n\n================= NEW SESSION =================\n")
    f:close()
end

return CustomLogger
