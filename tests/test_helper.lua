local TestHelper = {}

local function deep_equal(expected, actual, seen)
    if expected == actual then
        return true
    end

    if type(expected) ~= type(actual) then
        return false
    end

    if type(expected) ~= "table" then
        return false
    end

    seen = seen or {}
    if seen[expected] and seen[expected] == actual then
        return true
    end
    seen[expected] = actual

    for key, expected_value in pairs(expected) do
        if not deep_equal(expected_value, actual[key], seen) then
            return false
        end
    end

    for key, _ in pairs(actual) do
        if expected[key] == nil then
            return false
        end
    end

    return true
end

function TestHelper.assert_equal(expected, actual, message)
    if not deep_equal(expected, actual) then
        error(message or "expected values to be equal", 2)
    end
end

function TestHelper.assert_truthy(value, message)
    if not value then
        error(message or "expected value to be truthy", 2)
    end
end

return TestHelper
