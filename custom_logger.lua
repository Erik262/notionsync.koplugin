local logger = require("logger") -- Keep system logger for redundancy

local CustomLogger = {}
-- Log file will be created in the KOReader running directory (usually next to koreader.sh or standard output dir)
local LOG_FILE = "notion_debug.log"

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

-- Initialize with a separator
local f = io.open(LOG_FILE, "a")
if f then
    f:write("\n\n================= NEW SESSION =================\n")
    f:close()
end

return CustomLogger
