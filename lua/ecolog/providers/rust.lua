local M = {}

M.provider = {
  pattern = "std::env::var%(['\"]%w+['\"]%)",
  filetype = "rust",
  extract_var = function(line, col)
    local before_cursor = line:sub(1, col)
    -- Match both std::env::var and env::var patterns
    local var = before_cursor:match("[std::]*env::var%(['\"]([%w_]+)['\"]%)$")
    return var
  end,
  get_completion_trigger = function()
    return "env::var("
  end,
}

return M

