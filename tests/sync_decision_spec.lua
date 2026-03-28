local TestHelper = require("test_helper")
local SyncDecision = require("sync_decision")

local decision = SyncDecision.plan({
    page_id = "page-123",
    last_successful_sync = "2026-03-28 12:00:00",
    known_highlight_ids = {
        abc = true,
    },
}, {
    {
        id = "abc",
        updated_at = "2026-03-28 11:59:00",
    },
})

TestHelper.assert_equal(true, decision.use_cached_page_id, "cached page id should be reused")
TestHelper.assert_equal(false, decision.needs_remote_scan, "remote scan should be skipped")
TestHelper.assert_equal({}, decision.pending_highlights, "matched highlights should not remain pending")

local stale_known_decision = SyncDecision.plan({
    page_id = "page-123",
    last_successful_sync = "2026-03-28 12:00:00",
    known_highlight_ids = {
        abc = true,
    },
}, {
    {
        id = "abc",
        updated_at = "2026-03-28 12:30:00",
    },
})

TestHelper.assert_equal(true, stale_known_decision.use_cached_page_id, "cached page id should still be reused")
TestHelper.assert_equal(false, stale_known_decision.needs_remote_scan, "known highlights should not force a remote scan")
TestHelper.assert_equal(1, #stale_known_decision.pending_highlights, "newer known highlights should remain pending")

local new_mapped_decision = SyncDecision.plan({
    page_id = "page-123",
    last_successful_sync = "2026-03-28 12:00:00",
    known_highlight_ids = {
        abc = true,
    },
}, {
    {
        id = "def",
        updated_at = "2026-03-28 12:05:00",
    },
})

TestHelper.assert_equal(true, new_mapped_decision.use_cached_page_id, "cached page id should still be reused for new highlights")
TestHelper.assert_equal(false, new_mapped_decision.needs_remote_scan, "new highlights should stay pending without forcing a scan when mapping exists")
TestHelper.assert_equal(1, #new_mapped_decision.pending_highlights, "new highlights should remain pending when mapping exists")
