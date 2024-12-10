local M = {}

M.provider = {
    pattern = "os%.getenv%(['\"]%w+['\"]%)",
    filetype = "lua",
    extract_var = function(line, col)
        local before_cursor = line:sub(1, col)
        local var = before_cursor:match("os%.getenv%(['\"]([%w_]+)['\"]%)$")
        return var
    end,
    get_completion_trigger = function()
        return "os.getenv("
    end
}

return M 