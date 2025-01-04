local M = {}

M.providers = {
  -- Single Quotes
  {
    pattern = [[std::env::var%(['"][%w_]+['"]%)]],
    filetype = "rust",
    extract_var = function(line, col)
      local before_cursor = line:sub(1, col)
      local var = before_cursor:match([[[std::]*env::var%(['"]([%w_]+)['"]%)$]])
      return var
    end,
    get_completion_trigger = function()
      return [[env::var(']]
    end,
  },
  -- Double Quotes
  {
    pattern = [[std::env::var%(['"][%w_]+['"]%)]],
    filetype = "rust",
    extract_var = function(line, col)
      local before_cursor = line:sub(1, col)
      local var = before_cursor:match([[[std::]*env::var%(['"]([%w_]+)['"]%)$]])
      return var
    end,
    get_completion_trigger = function()
      return [[env::var("]]
    end,
  },
}

return M.providers