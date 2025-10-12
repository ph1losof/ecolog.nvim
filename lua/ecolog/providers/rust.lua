local M = {}
local utils = require("ecolog.utils")

M.providers = {
  -- Complete expressions (for detection anywhere in code)
  {
    pattern = "env::var%('[%w_]+'%)",
    filetype = "rust",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "env::var%('([%w_]+)'%)")
    end,
  },
  {
    pattern = 'env::var%("[%w_]+"%)',
    filetype = "rust",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, 'env::var%("([%w_]+)"%)')
    end,
  },
  {
    pattern = "std::env::var%('[%w_]+'%)",
    filetype = "rust",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "std::env::var%('([%w_]+)'%)")
    end,
  },
  {
    pattern = 'std::env::var%("[%w_]+"%)',
    filetype = "rust",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, 'std::env::var%("([%w_]+)"%)')
    end,
  },
  {
    pattern = 'env!%("[%w_]+"%)',
    filetype = "rust",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, 'env!%("([%w_]+)"%)')
    end,
  },
  {
    pattern = 'option_env!%("[%w_]+"%)',
    filetype = "rust",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, 'option_env!%("([%w_]+)"%)')
    end,
  },

  -- Completion patterns (for autocomplete)
  {
    pattern = "env::var%('[%w_]*$",
    filetype = "rust",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "env::var%('([%w_]*)$")
    end,
    get_completion_trigger = function()
      return "env::var('"
    end,
  },
  {
    pattern = 'env::var%("[%w_]*$',
    filetype = "rust",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, 'env::var%("([%w_]*)$')
    end,
    get_completion_trigger = function()
      return 'env::var("'
    end,
  },
  {
    pattern = "std::env::var%('[%w_]*$",
    filetype = "rust",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "std::env::var%('([%w_]*)$")
    end,
    get_completion_trigger = function()
      return "std::env::var('"
    end,
  },
  {
    pattern = 'std::env::var%("[%w_]*$',
    filetype = "rust",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, 'std::env::var%("([%w_]*)$')
    end,
    get_completion_trigger = function()
      return 'std::env::var("'
    end,
  },
}

return M.providers