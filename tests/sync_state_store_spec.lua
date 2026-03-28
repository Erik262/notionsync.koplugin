local TestHelper = require("test_helper")
local SyncStateStore = require("sync_state_store")

local missing_path = os.tmpname()
os.remove(missing_path)

local result, err = SyncStateStore.load(missing_path)

TestHelper.assert_equal({}, result, "missing sync state should return an empty table")
TestHelper.assert_equal(nil, err, "missing sync state should not return an error")
