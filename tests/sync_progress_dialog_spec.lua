local helper = require("test_helper")
local SyncProgressDialog = require("sync_progress_dialog")

local bulk_state = SyncProgressDialog.buildState({
    mode = "bulk",
    stage = "scanning_remote",
    completed_books = 2,
    total_books = 5,
    current_book = "Example.epub",
    new_count = 4,
    updated_count = 1,
    failed_count = 0,
})

helper.assert_equal("Syncing All Books", bulk_state.title)
helper.assert_equal(2, bulk_state.progress_current)
helper.assert_equal(5, bulk_state.progress_total)
helper.assert_equal("Scanning remote blocks", bulk_state.stage_label)
helper.assert_equal("Example.epub", bulk_state.detail_text)
helper.assert_equal(4, bulk_state.new_count)
helper.assert_equal(1, bulk_state.updated_count)
helper.assert_equal(0, bulk_state.failed_count)

local single_state = SyncProgressDialog.buildState({
    mode = "single",
    stage = "syncing_changes",
    completed_books = 0,
    total_books = 0,
    current_book = "CurrentBook.epub",
    new_count = 2,
    updated_count = 3,
    failed_count = 1,
})

helper.assert_equal("Syncing Current Book", single_state.title)
helper.assert_equal(0, single_state.progress_current)
helper.assert_equal(0, single_state.progress_total)
helper.assert_equal("Syncing changes", single_state.stage_label)
helper.assert_equal("CurrentBook.epub", single_state.detail_text)
helper.assert_equal(2, single_state.new_count)
helper.assert_equal(3, single_state.updated_count)
helper.assert_equal(1, single_state.failed_count)

local fallback_state = SyncProgressDialog.buildState({
    stage = "unexpected_stage",
})

helper.assert_equal("Working...", fallback_state.stage_label)
