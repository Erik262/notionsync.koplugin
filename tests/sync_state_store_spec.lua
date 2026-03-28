local TestHelper = require("test_helper")
local SyncStateStore = require("sync_state_store")

local missing_path = os.tmpname()
os.remove(missing_path)

local result, err = SyncStateStore.load(missing_path)

TestHelper.assert_equal({}, result, "missing sync state should return an empty table")
TestHelper.assert_equal(nil, err, "missing sync state should not return an error")

local round_trip_path = os.tmpname()
os.remove(round_trip_path)

local state = {
    books = {
        ["/books/demo.epub"] = {
            page_id = "page-123",
            last_successful_sync = "2026-03-28 12:00:00",
        },
    },
}

local round_trip_save_ok, round_trip_save_err = SyncStateStore.save(round_trip_path, state)

TestHelper.assert_equal(true, round_trip_save_ok, "round-trip sync state should save successfully")
TestHelper.assert_equal(nil, round_trip_save_err, "round-trip sync state should save without error")

local loaded_state, load_err = SyncStateStore.load(round_trip_path)

TestHelper.assert_equal(nil, load_err, "saved sync state should load without error")
TestHelper.assert_equal("page-123", loaded_state.books["/books/demo.epub"].page_id, "saved sync state should preserve page_id")

os.remove(round_trip_path)

local keyword_path = os.tmpname()
os.remove(keyword_path)

local keyword_save_ok, keyword_save_err = SyncStateStore.save(keyword_path, {
    books = {
        ["end"] = {
            page_id = "page-keyword",
            last_successful_sync = "2026-03-28 12:30:00",
        },
    },
})

TestHelper.assert_equal(true, keyword_save_ok, "keyword-key sync state should save successfully")
TestHelper.assert_equal(nil, keyword_save_err, "keyword-key sync state should save without error")

local keyword_state, keyword_err = SyncStateStore.load(keyword_path)

TestHelper.assert_equal(nil, keyword_err, "keyword-key sync state should load without error")
TestHelper.assert_equal("page-keyword", keyword_state.books["end"].page_id, "keyword keys should round-trip safely")

os.remove(keyword_path)

local protected_path = os.tmpname()
os.remove(protected_path)

local malformed_path = os.tmpname()
os.remove(malformed_path)

local malformed_file = assert(io.open(malformed_path, "w"))
assert(malformed_file:write('return { books = "oops" }\n'))
assert(malformed_file:close())

local malformed_state, malformed_err = SyncStateStore.load(malformed_path)

TestHelper.assert_equal(nil, malformed_state, "malformed sync state should be rejected")
TestHelper.assert_equal(true, malformed_err ~= nil, "malformed sync state should return an error")

os.remove(malformed_path)

local protected_save_ok, protected_save_err = SyncStateStore.save(protected_path, {
    books = {
        ["/books/keep.epub"] = {
            page_id = "keep-page",
            last_successful_sync = "2026-03-28 12:45:00",
        },
    },
})

TestHelper.assert_equal(true, protected_save_ok, "existing cache state should save successfully before the failure case")
TestHelper.assert_equal(nil, protected_save_err, "existing cache state should save without error before the failure case")

local failed_save_result, failed_save_err = SyncStateStore.save(protected_path, {
    books = {
        ["/books/keep.epub"] = {
            page_id = "keep-page",
            last_successful_sync = "2026-03-28 12:45:00",
        },
    },
    broken = function()
        return true
    end,
})

TestHelper.assert_equal(nil, failed_save_result, "unsupported values should cause save to fail")
TestHelper.assert_equal(true, failed_save_err ~= nil, "unsupported values should report an error")

local protected_state, protected_err = SyncStateStore.load(protected_path)

TestHelper.assert_equal(nil, protected_err, "failed save should leave the previous cache file loadable")
TestHelper.assert_equal("keep-page", protected_state.books["/books/keep.epub"].page_id, "failed save should not truncate an existing cache file")

os.remove(protected_path)
