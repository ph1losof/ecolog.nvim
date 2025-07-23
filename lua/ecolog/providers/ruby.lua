local M = {}
local utils = require("ecolog.utils")

M.providers = {
  -- ENV[] with single quotes completion
  {
    pattern = "ENV%['[%w_]*$",
    filetype = "ruby",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "ENV%['([%w_]*)$")
    end,
    get_completion_trigger = function()
      return "ENV['"
    end,
  },
  -- ENV[] with double quotes completion
  {
    pattern = 'ENV%["[%w_]*$',
    filetype = "ruby",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, 'ENV%["([%w_]*)$')
    end,
    get_completion_trigger = function()
      return 'ENV["'
    end,
  },
  -- ENV[] with symbol completion
  {
    pattern = "ENV%[:[%w_]*$",
    filetype = "ruby",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "ENV%[:([%w_]*)$")
    end,
    get_completion_trigger = function()
      return "ENV[:"
    end,
  },
  -- ENV.fetch with single quotes completion
  {
    pattern = "ENV%.fetch%('[%w_]*$",
    filetype = "ruby",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "ENV%.fetch%('([%w_]*)$")
    end,
    get_completion_trigger = function()
      return "ENV.fetch('"
    end,
  },
  -- ENV.fetch with double quotes completion
  {
    pattern = 'ENV%.fetch%("[%w_]*$',
    filetype = "ruby",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, 'ENV%.fetch%("([%w_]*)$')
    end,
    get_completion_trigger = function()
      return 'ENV.fetch("'
    end,
  },
  -- ENV.fetch with symbol completion
  {
    pattern = "ENV%.fetch%([%s]*:[%w_]*$",
    filetype = "ruby",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "ENV%.fetch%([%s]*:([%w_]*)$")
    end,
    get_completion_trigger = function()
      return "ENV.fetch(:"
    end,
  },
}

return M.providers

