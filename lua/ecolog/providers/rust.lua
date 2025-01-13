local M = {}
local utils = require("ecolog.utils")

M.providers = {
  -- Single Quotes
  {
    pattern = [[std::env::var%(['"][%w_]+['"]%)]],
    filetype = "rust",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, [[[std::]*env::var%(['"]([%w_]+)['"]%)$]])
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
      return utils.extract_env_var(line, col, [[[std::]*env::var%(['"]([%w_]+)['"]%)$]])
    end,
    get_completion_trigger = function()
      return [[env::var("]]
    end,
  },
}

return M.providers