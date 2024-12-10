local M = {}

M.provider = {
    pattern = "os%.Getenv%(['\"]%w+['\"]%)",
    filetype = "go",
    extract_var = function(line, col)
        local before_cursor = line:sub(1, col)
        local var = before_cursor:match("os%.Getenv%(['\"]([%w_]+)['\"]%)$")
        return var
    end,
    get_completion_trigger = function()
        return "os.Getenv("
    end
}

return M 