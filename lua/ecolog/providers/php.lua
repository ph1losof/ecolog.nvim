local M = {}
local utils = require("ecolog.utils")

M.providers = {
  {
    pattern = "getenv%(['\"][%w_]*['\"]%s*%)$",
    filetype = "php",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "getenv%(['\"]([%w_]+)['\"]%s*%)$")
    end,
    get_completion_trigger = function()
      return "getenv('"
    end,
  },
  {
    pattern = "_ENV%[['\"][%w_]*['\"]%]$",
    filetype = "php",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "_ENV%[['\"]([%w_]+)['\"]%]$")
    end,
    get_completion_trigger = function()
      return "_ENV['"
    end,
  },
}

return M.providers
