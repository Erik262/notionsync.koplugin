local SyncDecision = {}

local function has_cached_page_id(book_state)
    return book_state ~= nil and book_state.page_id ~= nil and book_state.page_id ~= ""
end

local function has_known_highlight_mapping(book_state)
    return book_state ~= nil and type(book_state.known_highlight_ids) == "table"
end

local function is_known_highlight(book_state, highlight_id)
    return has_known_highlight_mapping(book_state) and book_state.known_highlight_ids[highlight_id] == true
end

local function is_newer_than_last_successful_sync(book_state, updated_at)
    local last_sync = book_state and book_state.last_successful_sync or nil
    if last_sync == nil then
        return true
    end

    return updated_at ~= nil and updated_at > last_sync
end

function SyncDecision.plan(book_state, highlights)
    local pending_highlights = {}
    local has_mapping = has_known_highlight_mapping(book_state)

    for _, highlight in ipairs(highlights or {}) do
        if (has_mapping and not is_known_highlight(book_state, highlight.id))
            or is_newer_than_last_successful_sync(book_state, highlight.updated_at) then
            pending_highlights[#pending_highlights + 1] = highlight
        end
    end

    return {
        use_cached_page_id = has_cached_page_id(book_state),
        needs_remote_scan = #pending_highlights > 0 and not has_mapping,
        pending_highlights = pending_highlights,
    }
end

return SyncDecision
