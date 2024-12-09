local M = {}

M.provider = {
    pattern = "os%.environ%.get%(%s*['\"]%w*['\"]%s*%)$",
    filetype = "python",
    
    extract_var = function(line, col)
        local before_cursor = line:sub(1, col + 1)
        return before_cursor:match("os%.environ%.get%(%s*['\"](%w+)['\"]%s*%)$")
    end,
    
    get_completion_trigger = function()
        return "os.environ.get("
    end
}

return M.provider 