local runner_source = debug.getinfo(1, "S").source or ""
if runner_source:sub(1, 1) == "@" then
    runner_source = runner_source:sub(2)
end

local tests_dir = runner_source:match("^(.*)/[^/]+$") or "."
local root = tests_dir:match("^(.*)/[^/]+$") or "."

package.path = table.concat({
    tests_dir .. "/?.lua",
    root .. "/?.lua",
    package.path,
}, ";")

local function resolve_spec_path(spec_path)
    if spec_path:match("^/") then
        return spec_path
    end

    local direct_path = tests_dir .. "/" .. spec_path
    local direct_file = io.open(direct_path, "r")
    if direct_file then
        direct_file:close()
        return direct_path
    end

    local root_spec_path = root .. "/" .. spec_path
    local root_spec_file = io.open(root_spec_path, "r")
    if root_spec_file then
        root_spec_file:close()
        return root_spec_path
    end

    if spec_path:match("^tests/") then
        return root .. "/" .. spec_path
    end

    return direct_path
end

local spec_path = assert(arg and arg[1], "spec path required")
dofile(resolve_spec_path(spec_path))
print("PASS")
