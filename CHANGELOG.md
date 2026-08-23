# Changelog

All notable changes to NotionSync are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.1] - 2026-08-23

### Fixed
- **Restored the required `_meta.lua` plugin manifest.** It had been removed in an
  earlier commit, so releases up to and including 1.1.0 shipped without it.
  KOReader requires this file: when a plugin is disabled — or when
  "disable external plugins" is set, which some builds default to — KOReader loads
  `_meta.lua` in place of `main.lua`, so a missing file produced
  `Error when loading .../_meta.lua` and the plugin could not be listed or
  enabled in **Plugin management**. It also supplies the name and description
  shown there.

## [1.1.0] - 2026-06-02

### Added
- **In-app updater.** NotionSync can now update itself on-device over Wi-Fi — no
  computer needed. It checks GitHub for the latest release; when a newer version
  is available it prompts **Update** or **Skip**, and on confirmation downloads
  and installs the new files in place. Available via **Tools > NotionSync >
  Check for Updates** and from the Settings screen.
  - A quiet startup check runs at most once per day and only when Wi-Fi is
    already on — it never turns Wi-Fi on by itself. Toggle it under
    **Settings > Check for Updates on Startup**.
  - Downloads are verified entirely into memory before any file is overwritten,
    so a failed or interrupted download can't corrupt the installed plugin.
  - Credentials are untouched by updates (they live outside the plugin folder
    as of 1.0.0).

### Notes
- To use auto-update, install 1.1.0 once (manually), then future releases can be
  installed from the device. The updater compares your installed version against
  the latest GitHub release tag, so each release must bump the version.

## [1.0.0] - 2026-05-31

First public release.

### Added
- Per-book annotations table in Notion with columns for Text, Chapter, Created, Note, and Page.
- Efficient incremental sync — only new or changed highlights are sent; re-syncing an unchanged book makes zero annotation API calls.
- HighlightID tracking for reliable matching, with recovery from Notion if local sync state is lost (no duplicates).
- Orphan cleanup: highlights deleted locally are archived in Notion on the next sync.
- Self-healing: recreates rows, book pages, or annotation databases that were deleted manually in Notion.
- Rich metadata sync (Authors, ISBN, Progress, Language, Pages, Start Reading date), updated only when values change.
- Live progress display during sync with running counters for new, updated, and failed highlights.
- Managed Wi-Fi: turns Wi-Fi on for the sync and back off afterward.
- Gesture support and a "Sync Current Book" dispatcher action.
- Bulk sync of all books from KOReader history, pre-filtered to books that actually have annotations.
- Network resilience with retries and `Connection: close` to handle the Kobo's limited network stack.
- Debug logging to `notion_debug.log`, auto-rotating at 256 KB.

### Changed
- **Credentials are now stored outside the plugin folder** (in KOReader's settings
  directory, as `notionsync_credentials.lua`) so that updating or reinstalling the
  plugin no longer overwrites your Notion token and database ID. Credentials saved
  by older versions inside the plugin folder are migrated automatically on first launch.
- `config.json` and `notion_credentials.lua` are no longer shipped in the release
  archive, so installing an update over an existing installation preserves your settings.

[1.1.1]: https://github.com/Erik262/notionsync.koplugin/releases/tag/v1.1.1
[1.1.0]: https://github.com/Erik262/notionsync.koplugin/releases/tag/v1.1.0
[1.0.0]: https://github.com/Erik262/notionsync.koplugin/releases/tag/v1.0.0
