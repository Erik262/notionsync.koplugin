# NotionSync for KOReader

**NotionSync** is a powerful plugin for **KOReader** that automatically synchronizes your book highlights and notes directly to a **Notion database**. 

## Features

- **Sync All Highlights**: Instantly export all your highlights and notes to your Notion database.
- **Incremental Updates**: Only new or changed highlights are synced for efficiency.
- **Cached Notion Lookups**: Database schema and page lookups are cached during a sync session to reduce repeated API requests, especially when syncing many books.
- **Rich Formatting**: Highlights are formatted into blocks including page number, chapter, date, your notes and a hidden link to the highlight anchor.
- **Rich Metadata Sync**: Automatically fills in book info like authors, ISBN, reading progress, language, pages, and start date (if those columns exist in selected database).
- **Optional Metadata Sync**: Metadata updates can be disabled from the NotionSync settings menu if you only want highlight content.
- **Visible Sync Status**: The plugin shows status popups while it prepares the sync, waits for Wi-Fi, syncs content, and finishes.
- **Managed Wi-Fi**: If Wi-Fi is off, NotionSync can turn it on for the sync and turn it off again afterward.
- **One-Click Sync**: You can asign the sync as gesture (for example as corner click) to quickly sync your highlights.
- **Bulk Sync Without Opening Books**: Sync all books from KOReader history that have saved annotations, without opening each one manually.

## ️ Notion Setup

Create a Notion Database with the following columns. **All metadata columns are optional**—if you don't add them, the plugin simply skips them.

| Property Name | Verified Types | Description |
|--------------|-------|-------------|
| **Name**     | Title | **Required**. Book title. |
| **Last Sync**| Text  | **Required**. Used to track updates. |
| **Authors**  | Multi-select *or* Text | Smart splitting of multiple authors (e.g. "Author A; Author B"). |
| **ISBN**     | Text  | The book's ISBN. |
| **Progress** | Number *or* Text | Reading percentage (0.0 to 1.0). Best formatted as `%` in Notion. |
| **Language** | Select *or* Text | Language code (e.g., `en`). |
| **Pages**    | Number *or* Text | Total pages in the book. |
| **Start Reading** | Date | Date the book was first opened/highlighted. |

> **Note**: Column names in Notion Database are **case-insensitive** (e.g., "progress", "Progress", "PROGRESS" all work).

## Installation

1. Download the latest `notionsync.koplugin.zip` from the **Releases** page (or clone this repo).
2. Connect your KOReader device via USB.
3. Navigate to `koreader/plugins/`.
4. Extract the `notionsync.koplugin` folder there.
5. Restart KOReader

## ️ Setup

1. **Get Notion Token**: Go to [Notion My Integrations](https://www.notion.so/my-integrations), create a new integration, and copy the Secret (`ntn_...`).
2. **Connect Database**: Open your Notion Database page -> **... (menu)** -> **Connect to** -> Select your integration.
3. **Add credentials in the plugin folder**:
   - Edit `notionsync.koplugin/notion_credentials.lua`
   - Set `notion_token = "..."` and `database_id = "..."`.
   - Leave `notion_version` at `2022-06-28` unless you need a different Notion API version.
4. **Configure on Device**:
   - Open any book in KOReader.
   - Go to **Tools (Gear/Wrench)** -> **NotionSync** -> **Settings**.
   - You can still use **Set Notion Token** and **Select Database** from the plugin menu if you prefer. These values are now written to `notion_credentials.lua`.
   - Use **Metadata Sync** to choose whether book metadata columns should be updated in Notion during sync.

## Config Files

- `notion_credentials.lua`: editable credentials file for `notion_token`, `database_id`, and `notion_version`.
- `config.json`: runtime plugin settings only, such as `metadata_sync`. Credentials are no longer stored here by default.

## Usage

### Sync current book
1. Open a book.
2. Go to **Tools Menu**.
3. Tap **NotionSync > Sync Highlights to Notion**.

When started from the menu or gesture, the plugin now shows progress popups such as preparing, waiting for Wi-Fi, syncing, and finishing.

### Sync all books

You can sync all books from your KOReader history that contain highlights without opening each book manually. This is useful for an initial import or for catching up after reading across multiple books.
1. Go to **Top Menu > Tools**
2. Tap **NotionSync > Sync All Highlights to Notion**. 

> [!WARNING]
> Depending on you history size, this process can take a while.

### Gesture Sync
You can assign **NotionSync: Sync Current Book** to a tap gesture in **Settings -> Taps and gestures -> Gesture manager**. This action only syncs the book that is currently open.

If Wi-Fi is currently off, the plugin will try to turn it on, perform the sync, and turn it off again when the sync finishes.

## Known Issues

### HTTP 400 on some books

Older versions could fail with `HTTP 400` on some books during page creation, while manually creating the page in Notion first would make syncing work. A likely cause was book titles containing unsupported formatting for Notion requests, such as embedded line breaks, empty titles, or titles that exceeded Notion's text limits.

This plugin now normalizes book titles before querying or creating pages in Notion:

- line breaks are converted to spaces
- surrounding whitespace is trimmed
- empty titles fall back to `Unknown Title`
- very long titles are truncated to Notion's text limit

If you still hit `HTTP 400` after this update, the next most likely cause is a database schema mismatch or a specific highlight payload that Notion rejects.
