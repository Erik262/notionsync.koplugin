local SyncStateStore = {}

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

    local ok, result = pcall(chunk)
    if not ok then
        return nil, result
    end

    if type(result) ~= "table" then
        return nil, "sync state file must return a table"
    end

    return result, nil
end

return SyncStateStore
