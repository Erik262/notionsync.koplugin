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

local stale_cache_decision = SyncDecision.plan({
    page_id = "page-123",
    last_successful_sync = "2026-03-28 12:00:00",
    known_highlight_ids = nil,
}, {
    {
        id = "def",
        updated_at = "2026-03-28 12:30:00",
    },
})

TestHelper.assert_equal(true, stale_cache_decision.use_cached_page_id, "cached page id should still be reused when the cache is stale")
TestHelper.assert_equal(true, stale_cache_decision.needs_remote_scan, "stale caches should require a remote scan")
TestHelper.assert_equal({
    {
        id = "def",
        updated_at = "2026-03-28 12:30:00",
    },
}, stale_cache_decision.pending_highlights, "stale-cache highlights should remain pending")

local stale_cache_older_decision = SyncDecision.plan({
    page_id = "page-123",
    last_successful_sync = "2026-03-28 12:00:00",
    known_highlight_ids = nil,
}, {
    {
        id = "ghi",
        updated_at = "2026-03-28 11:30:00",
    },
})

TestHelper.assert_equal(true, stale_cache_older_decision.use_cached_page_id, "cached page id should still be reused when stale cache has older highlights")
TestHelper.assert_equal(true, stale_cache_older_decision.needs_remote_scan, "stale cache should still require a remote scan even with only older highlights")
TestHelper.assert_equal({}, stale_cache_older_decision.pending_highlights, "older highlights should not need mutation")
