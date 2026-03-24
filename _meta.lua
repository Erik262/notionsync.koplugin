--[[
-- _meta.lua - Plugin metadata for NotionSync KOReader plugin
--]]

return {
    -- Plugin identification
    name = "NotionSync",
    display_name = "Notion Sync",
    description = "Sync your book highlights and notes to Notion databases",
    
    -- Plugin version
    version = "1.0.1",
    
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
    
    -- Plugin capabilities
    capabilities = {
        "sync",
        "notion_integration",
        "highlight_export"
    },
    
    -- NotionSync keeps its settings in the plugin menu and local credentials file.
    settings = {}
}
