--[[
-- _meta.lua - Plugin metadata for NotionSync KOReader plugin
--]]

return {
    -- Plugin identification
    name = "NotionSync",
    display_name = "Notion Sync",
    description = "Sync your book highlights and notes to Notion databases",
    
    -- Plugin version
    version = "1.0.0",
    
    -- Author information
    author = {
        name = "Cezary Pukownik",
        url = "https://github.com/CezaryPukownik/notionsync.koplugin"
    },
    
    -- Plugin category
    category = "tools",
    
    -- Minimum KOReader version requirement
    koreader_version = "2023.06",
    
    -- Plugin dependencies (if any)
    dependencies = {},
    
    -- Plugin file structure
    main_file = "main.lua",
    
    -- Plugin configuration file
    config_file = "plugins/notionsync.koplugin/config.json",
    
    -- Plugin capabilities
    capabilities = {
        "sync",
        "notion_integration",
        "highlight_export"
    },
    
    -- Plugin settings
    settings = {
        {
            key = "notion_token",
            name = "Notion Integration Token",
            description = "Your Notion API integration token",
            type = "string",
            required = true,
            secret = true
        },
        {
            key = "database_id",
            name = "Notion Database ID",
            description = "The ID of your Notion database",
            type = "string",
            required = true
        }
    }
}
