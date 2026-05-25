local SyncProgressDialog = {}

local STAGE_LABELS = {
    preparing = "Preparing...",
    enabling_wifi = "Turning Wi-Fi on...",
    waiting_for_wifi = "Waiting for Wi-Fi...",
    syncing_changes = "Syncing",
    disabling_wifi = "Turning Wi-Fi off...",
    complete = "Done",
    failed = "Failed",
}

function SyncProgressDialog.buildMessage(input)
    input = input or {}
    local is_bulk = (input.mode == "bulk")
    local lines = {}

    -- Line 1: stage + highlight progress
    local stage = STAGE_LABELS[input.stage] or "Working..."
    if input.progress_current and input.progress_total and input.progress_total > 0 then
        stage = stage .. "  " .. input.progress_current .. " / " .. input.progress_total
    end
    table.insert(lines, stage)

    -- Line 2: book name (only in bulk mode)
    if is_bulk and input.current_book and input.current_book ~= "" then
        local name = input.current_book:gsub("%.[^%.]+$", "")  -- strip extension
        if #name > 40 then name = name:sub(1, 37) .. "..." end
        if input.total_books and input.total_books > 0 then
            local book_num = (input.completed_books or 0) + 1
            table.insert(lines, "Book " .. book_num .. "/" .. input.total_books .. ": " .. name)
        else
            table.insert(lines, name)
        end
    end

    -- Line 3: counters
    local parts = {}
    local new_c = input.new_count or 0
    local upd_c = input.updated_count or 0
    local fail_c = input.failed_count or 0
    if new_c > 0 then table.insert(parts, "New: " .. new_c) end
    if upd_c > 0 then table.insert(parts, "Updated: " .. upd_c) end
    if fail_c > 0 then table.insert(parts, "Failed: " .. fail_c) end
    if #parts > 0 then
        table.insert(lines, table.concat(parts, "  "))
    end

    return table.concat(lines, "\n")
end

return SyncProgressDialog
