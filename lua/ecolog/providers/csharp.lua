local M = {}
local utils = require("ecolog.utils")

M.providers = {
  -- Environment.GetEnvironmentVariable completion
  {
    pattern = "Environment%.GetEnvironmentVariable%([\"'][%w_]*$",
    filetype = "cs",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "Environment%.GetEnvironmentVariable%([\"']([%w_]*)$")
    end,
    get_completion_trigger = function()
      return 'Environment.GetEnvironmentVariable("'
    end,
  },
  -- Environment.GetEnvironmentVariable with System namespace completion
  {
    pattern = "System%.Environment%.GetEnvironmentVariable%([\"'][%w_]*$",
    filetype = "cs",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "System%.Environment%.GetEnvironmentVariable%([\"']([%w_]*)$")
    end,
    get_completion_trigger = function()
      return 'System.Environment.GetEnvironmentVariable("'
    end,
  },
  -- Environment variable from dictionary completion
  {
    pattern = "Environment%.GetEnvironmentVariables%(%)[%[\"'][%w_]*$",
    filetype = "cs",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "Environment%.GetEnvironmentVariables%(%)[%[\"']([%w_]*)$")
    end,
    get_completion_trigger = function()
      return 'Environment.GetEnvironmentVariables()["'
    end,
  },
  -- Environment variable from dictionary with System namespace completion
  {
    pattern = "System%.Environment%.GetEnvironmentVariables%(%)[%[\"'][%w_]*$",
    filetype = "cs",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "System%.Environment%.GetEnvironmentVariables%(%)[%[\"']([%w_]*)$")
    end,
    get_completion_trigger = function()
      return 'System.Environment.GetEnvironmentVariables()["'
    end,
  },
}

return M.providers

