local M = {}
local utils = require("ecolog.utils")

M.providers = {
  -- Double quotes completion
  {
    pattern = 'os%.getenv%("[%w_]*$',
    filetype = "lua",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, 'os%.getenv%("([%w_]*)$')
    end,
    get_completion_trigger = function()
      return 'os.getenv("'
    end,
  },
  -- Single quotes completion
  {
    pattern = "os%.getenv%('[%w_]*$",
    filetype = "lua",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "os%.getenv%('([%w_]*)$")
    end,
    get_completion_trigger = function()
      return "os.getenv('"
    end,
  },
}

return M.providers
