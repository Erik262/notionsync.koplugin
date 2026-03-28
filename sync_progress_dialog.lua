local SyncProgressDialog = {}

local STAGE_LABELS = {
    preparing = "Preparing sync",
    enabling_wifi = "Turning Wi-Fi on",
    waiting_for_wifi = "Waiting for Wi-Fi",
    scanning_remote = "Scanning remote blocks",
    syncing_changes = "Syncing changes",
    disabling_wifi = "Turning Wi-Fi off",
    complete = "Sync complete",
    failed = "Sync failed",
}

local function readNumber(value, fallback)
    if value == nil then
        return fallback
    end

    return value
end

function SyncProgressDialog.buildState(input)
    input = input or {}

    return {
        title = input.mode == "single" and "Syncing Current Book" or "Syncing All Books",
        progress_current = readNumber(input.completed_books, 0),
        progress_total = readNumber(input.total_books, 0),
        stage_label = STAGE_LABELS[input.stage] or "Working...",
        detail_text = input.current_book or "",
        new_count = readNumber(input.new_count, 0),
        updated_count = readNumber(input.updated_count, 0),
        failed_count = readNumber(input.failed_count, 0),
    }
end

return SyncProgressDialog
