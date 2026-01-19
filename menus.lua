local Menus = {}

function Menus.register(plugin, menu_items)
    -- Create NotionSync submenu on first page of tools
    menu_items.notion_sync_menu = {
        text = "NotionSync",
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = "Sync Highlights to Notion",
                callback = function()
                    plugin:onSyncRequested()
                end
            },
            {
                text = "Sync All Highlights to Notion",
                callback = function()
                    plugin:onSyncAllBooksRequested()
                end
            },
            {
                text = "Settings",
                callback = function()
                    plugin:showConfigMenu()
                end
            }
        }
    }
end

return Menus