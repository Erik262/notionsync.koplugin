# NotionSync for KOReader

**NotionSync** is a powerful plugin for **KOReader** that automatically synchronizes your book highlights and notes directly to a **Notion database**. 

> [!IMPORTANT]
> To upgrade to v0.2.0 "Gwyhyr" you will need to change the type of the *Last Sync* column from *Date* to *Text* in your Notion Database. See the details [here](https://github.com/CezaryPukownik/notionsync.koplugin/pull/5)

## Features

- **Sync All Highlights**: Instantly export all your highlights and notes to your Notion database.
- **Incremental Updates**: Only new or changed highlights are synced for efficiency.
- **Rich Formatting**: Highlights are formatted into blocks including page number, chapter, date, your notes and a hidden link to the highlight anchor.
- **Rich Metadata Sync**: Automatically fills in book info like authors, ISBN, reading progress, language, pages, and start date (if those columns exist in selected database).
- **One-Click Sync**: You can asign the sync as gesture (for example as corner click) to quickly sync your highlights.

## Roadmap to v0.3.0

- [ ] **Improve performance**: Implement caching to reduce API requests and improve sync speeds, particularly when working with a large number of highlights. 
- [ ] **Optional metadata sync**: A configurable setting that lets you choose whether to populate the metadata columns, even if they already exist.

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
3. **Configure on Device**:
   - Open any book in KOReader.
   - Go to **Tools (Gear/Wrench)** -> (Page 2) -> **More tools** -> **NotionSync Settings**.
   - **Set Notion Token**: Enter your key.
   - **Select Database**: Pick your database from the list.

## Usage

### Sync current book
1. Open a book.
2. Go to **Tools Menu**.
3. Tap **NotionSync > Sync Highlights to Notion**.

### Sync all books

From version v0.2.0 you can sync all books from you history that contains highlights. To sync all books. For example for initial load when you want to dump all you current highlights to Notion you can.
1. Go to **Top Menu > Tools**
2. Tap **NotionSync > Sync All Highlights to Notion**. 

> [!WARNING]
> Depending on you history size, this process can take a while.

### Gesture Sync
You can assign "Sync to Notion" to a corner tap in **Settings -> Taps and gestures -> Gesture manager**.
