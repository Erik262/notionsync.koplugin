local _ = require("gettext")

-- KOReader reads plugin metadata from this file. It is REQUIRED: without it
-- `description` is nil and the Plugin management menu errors out.
--
-- Keep this minimal. PluginLoader merges every key in here over the values set
-- in main.lua, so do NOT define `version` — that would clobber PLUGIN_VERSION
-- and break the in-app updater. (`name` is deprecated and ignored.)
return {
    fullname = _("NotionSync"),
    description = _([[Syncs your book highlights and notes to a Notion database.]]),
}
