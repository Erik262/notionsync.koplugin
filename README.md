# NotionSync for KOReader

**NotionSync** is a plugin for **KOReader** that synchronizes your book highlights and notes to a **Notion database**. Each book gets its own page with an inline annotations table — sortable, filterable, and visible directly on the page.

## Features

- **Per-Book Annotations Table**: Each book page contains an inline Notion database with columns for Text, Chapter, Created, Note, and Page.
- **Efficient Incremental Sync**: Only new or changed highlights are synced. Re-syncing a book with no changes makes zero annotation API calls.
- **HighlightID Tracking**: Each annotation carries a unique ID for reliable matching. If local sync state is lost, the plugin recovers by reading IDs from Notion — no duplicates.
- **Orphan Cleanup**: Highlights deleted locally are automatically archived in Notion on the next sync.
- **Self-Healing**: If a row is deleted in Notion manually, the plugin detects the 404 and recreates it. If a book page or annotations database is deleted, the plugin recreates them.
- **Rich Metadata Sync**: Automatically fills in Authors, ISBN, Progress, Language, Pages, and Start Reading date (if those columns exist in your books database). Metadata is only updated when values actually change.
- **Live Progress Display**: Shows real-time progress during sync (e.g. "Syncing 10 / 115") with running counters for new, updated, and failed highlights.
- **Managed Wi-Fi**: If Wi-Fi is off, the plugin turns it on for the sync and off again afterward.
- **Gesture Support**: Assign sync to a tap gesture for one-tap syncing.
- **Bulk Sync**: Sync all books from KOReader history without opening each one. Pre-filters to books that actually have annotations.
- **Network Resilience**: Retries failed requests with delays to handle the Kobo's limited network stack. Uses `Connection: close` to prevent socket exhaustion.
- **Debug Logging**: All API requests and errors are logged to `notion_debug.log` in the plugin folder. Log auto-rotates at 256 KB.

## Notion Setup

### 1. Books Database

Create a Notion database for your books. Only the **Name** column is required. All metadata columns are optional — if you don't add them, the plugin skips them.

| Column | Type | Description |
|--------|------|-------------|
| **Name** | Title | **Required.** Book title. |
| Authors | Multi-select or Text | Author names (multiple separated by `;`). |
| ISBN | Text | The book's ISBN. |
| Progress | Number | Reading percentage (0.0 to 1.0). Format as `%` in Notion. |
| Language | Select or Text | Language code (e.g. `de-DE`, `en`). |
| Pages | Number | Total pages in the book. |
| Start Reading | Date | Date the first highlight was created. |

Column names are **case-insensitive** (e.g. "progress", "Progress", "PROGRESS" all work).

### 2. Annotations Table (Auto-Created)

When you sync a book for the first time, the plugin automatically creates an inline **Annotations** database on the book's page with these columns:

| Column | Type | Description |
|--------|------|-------------|
| Text | Title | The highlighted text (first column). |
| Chapter | Text | Chapter name, if available. |
| Created | Date | When the highlight was created. |
| Note | Text | Your note on the highlight, if any. |
| Page | Number | Page number. |
| HighlightID | Text | Unique ID for sync tracking. |

You can sort and filter this table in Notion however you like.

## Installation

1. Download the latest release or clone this repo.
2. Connect your KOReader device via USB.
3. Copy the `notionsync.koplugin` folder to `koreader/plugins/`.
4. Eject the device properly and restart KOReader.

## Setup

1. **Get a Notion Token**: Go to [Notion Integrations](https://www.notion.so/my-integrations), create a new integration, and copy the secret (`ntn_...`).
2. **Connect your database**: Open your Notion database page, click **...** (menu) > **Connect to** > select your integration.
3. **Configure on device**:
   - Open any book in KOReader.
   - Go to **Tools** > **NotionSync** > **Settings**.
   - Set your Notion token and select your database.
   - Toggle **Metadata Sync** on or off as needed.

Your credentials are saved to `notionsync_credentials.lua` in KOReader's
settings directory — **outside** the plugin folder — so updating or
reinstalling the plugin never overwrites them.

Alternatively, for a fresh install you can create `notion_credentials.lua`
inside the plugin folder and the plugin will import it on first launch (the
values are then migrated to the external settings file):

```lua
return {
    notion_token = "ntn_...",
    database_id = "your-database-id",
    notion_version = "2022-06-28",
}
```

## Updating

Copy the new `notionsync.koplugin` folder over the existing one (or download
the latest release and extract it in place). Your token, database ID, and sync
state are preserved across updates because they are not part of the release.

## Usage

### Sync Current Book

1. Open a book with highlights.
2. Go to **Tools** > **NotionSync** > **Sync Highlights to Notion**.

The progress popup shows: `Syncing 10 / 115` with live New/Updated counters.

### Sync All Books

1. Go to **Tools** > **NotionSync** > **Sync All Highlights to Notion**.
2. The popup shows per-highlight progress within each book, plus which book is being synced (e.g. "Book 2/8: My Book Title").

### Gesture Sync

Assign **NotionSync: Sync Current Book** to a tap gesture in **Settings** > **Taps and gestures** > **Gesture manager**. This syncs only the currently open book.

### Reset Sync State

If sync gets into a bad state, use **Tools** > **NotionSync** > **Reset Sync State**. The next sync will rebuild its tracking data from Notion using HighlightIDs — no duplicates will be created.

## Config Files

| File | Location | Purpose |
|------|----------|---------|
| `notionsync_credentials.lua` | KOReader settings dir | Notion token, database ID, API version. Stored outside the plugin folder so updates don't overwrite it. |
| `config.json` | Plugin folder | Runtime settings (metadata sync toggle). |
| `sync_state.lua` | Plugin folder | Local per-book sync cache (page IDs, highlight mappings, last sync time). |
| `notion_debug.log` | Plugin folder | Debug log with all API requests and errors. Auto-rotates at 256 KB. |

## Troubleshooting

- **"Plugin not configured"**: Set your Notion token and select a database in Settings.
- **DNS / network errors**: The Kobo's network stack can exhaust sockets. The plugin retries up to 5 times with 2-second delays. Make sure Wi-Fi signal is stable.
- **Duplicates after reset**: Should not happen — the plugin recovers row mappings from HighlightID. If it does, check `notion_debug.log` for errors.
- **Missing columns in Notion**: The plugin only populates columns that exist in your database. Add the columns from the table above if you want metadata filled in.
