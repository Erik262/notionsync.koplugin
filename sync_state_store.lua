local SyncStateStore = {}

local lua_keywords = {
    ["and"] = true,
    ["break"] = true,
    ["do"] = true,
    ["else"] = true,
    ["elseif"] = true,
    ["end"] = true,
    ["false"] = true,
    ["for"] = true,
    ["function"] = true,
    ["goto"] = true,
    ["if"] = true,
    ["in"] = true,
    ["local"] = true,
    ["nil"] = true,
    ["not"] = true,
    ["or"] = true,
    ["repeat"] = true,
    ["return"] = true,
    ["then"] = true,
    ["true"] = true,
    ["until"] = true,
    ["while"] = true,
}

local function is_identifier(value)
    return type(value) == "string" and value:match("^[%a_][%w_]*$") and not lua_keywords[value]
end

local function serialize_string(value)
    return string.format("%q", value)
end

local function serialize_value(value)
    local value_type = type(value)
    if value_type == "string" then
        return serialize_string(value)
    elseif value_type == "number" or value_type == "boolean" then
        return tostring(value)
    elseif value_type == "table" then
        local keys = {}
        for key in pairs(value) do
            keys[#keys + 1] = key
        end
        table.sort(keys, function(left, right)
            return tostring(left) < tostring(right)
        end)

        local parts = {}
        for _, key in ipairs(keys) do
            local serialized_key
            if is_identifier(key) then
                serialized_key = key
            else
                serialized_key = "[" .. serialize_value(key) .. "]"
            end
            parts[#parts + 1] = serialized_key .. " = " .. serialize_value(value[key])
        end
        return "{ " .. table.concat(parts, ", ") .. " }"
    end

    error("unsupported sync state value type: " .. value_type)
end

local function write_file(path, contents)
    local file, err = io.open(path, "w")
    if not file then
        return nil, err
    end

    local write_ok, write_err = file:write(contents)
    if not write_ok then
        file:close()
        return nil, write_err
    end

    local flush_ok, flush_err = file:flush()
    if not flush_ok then
        file:close()
        return nil, flush_err
    end

    local close_ok, close_err = file:close()
    if not close_ok then
        return nil, close_err
    end

    return true, nil
end

local temp_file_counter = 0

local function temp_path_for(path)
    local directory = path:match("^(.*)/[^/]+$") or "."
    temp_file_counter = temp_file_counter + 1
    return string.format(
        "%s/.sync_state_store-%d-%d-%d.tmp",
        directory,
        os.time(),
        math.random(0, 2147483647),
        temp_file_counter
    )
end

function SyncStateStore.save(path, state)
    local ok, serialized_or_err = pcall(serialize_value, state)
    if not ok then
        return nil, serialized_or_err
    end

    local temp_path = temp_path_for(path)
    local write_ok, write_err = write_file(temp_path, "return " .. serialized_or_err .. "\n")
    if not write_ok then
        os.remove(temp_path)
        return nil, write_err
    end

    local rename_ok, rename_err = os.rename(temp_path, path)
    if not rename_ok then
        os.remove(temp_path)
        return nil, rename_err
    end

    return true, nil
end

function SyncStateStore.load(path)
    local file, err, code = io.open(path, "r")
    if not file then
        local missing = code == 2
        if not missing and code == nil and err ~= nil then
            local err_text = tostring(err)
            missing = err_text:match("No such file") or err_text:match("not found")
        end
        if missing then
            return {}, nil
        end
        return nil, err
    end
    file:close()

    local chunk, err = loadfile(path)
    if not chunk then
        return nil, err
    end

    if setfenv then
        setfenv(chunk, {})
    end

    local ok, result = pcall(chunk)
    if not ok then
        return nil, result
    end

    if type(result) ~= "table" then
        return nil, "sync state file must return a table"
    end

    if result.books ~= nil and type(result.books) ~= "table" then
        return nil, "sync state books must be a table"
    end

    return result, nil
end

return SyncStateStore
