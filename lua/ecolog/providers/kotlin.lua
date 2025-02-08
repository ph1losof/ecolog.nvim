local M = {}
local utils = require("ecolog.utils")

M.providers = {
  -- System.getenv() with double quotes completion
  {
    pattern = 'System%.getenv%("[%w_]*$',
    filetype = "kotlin",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, 'System%.getenv%("([%w_]*)$')
    end,
    get_completion_trigger = function()
      return 'System.getenv("'
    end,
  },
  -- System.getenv() with single quotes completion
  {
    pattern = "System%.getenv%('[%w_]*$",
    filetype = "kotlin",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "System%.getenv%('([%w_]*)$")
    end,
    get_completion_trigger = function()
      return "System.getenv('"
    end,
  },
  -- System.getenv() with double quotes full pattern
  {
    pattern = 'System%.getenv%("[%w_]+"%)?$',
    filetype = "kotlin",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, 'System%.getenv%("([%w_]+)"%)?$')
    end,
    get_completion_trigger = function()
      return 'System.getenv("'
    end,
  },
  -- System.getenv() with single quotes full pattern
  {
    pattern = "System%.getenv%('[%w_]+'%)?$",
    filetype = "kotlin",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "System%.getenv%('([%w_]+)'%)?$")
    end,
    get_completion_trigger = function()
      return "System.getenv('"
    end,
  },
}

return M.providers 