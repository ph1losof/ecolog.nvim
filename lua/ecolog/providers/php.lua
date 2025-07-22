local M = {}
local utils = require("ecolog.utils")

M.providers = {
  -- getenv completion
  {
    pattern = "getenv%(['\"][%w_]*$",
    filetype = "php",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "getenv%(['\"]([%w_]*)$")
    end,
    get_completion_trigger = function()
      return "getenv('"
    end,
  },
  -- getenv full pattern
  {
    pattern = "getenv%(['\"][%w_]+['\"]%)?$",
    filetype = "php",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "getenv%(['\"]([%w_]+)['\"]%)?$")
    end,
    get_completion_trigger = function()
      return "getenv('"
    end,
  },
  -- getenv pattern (anywhere in line)
  {
    pattern = "getenv%(['\"][%w_]+['\"]%)",
    filetype = "php",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "getenv%(['\"]([%w_]+)['\"]%)")
    end,
    get_completion_trigger = function()
      return "getenv('"
    end,
  },
  -- $_ENV array completion
  {
    pattern = "%$_ENV%[['\"][%w_]*$",
    filetype = "php",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "%$_ENV%[['\"]([%w_]*)$")
    end,
    get_completion_trigger = function()
      return "$_ENV['"
    end,
  },
  -- $_ENV array full pattern
  {
    pattern = "%$_ENV%[['\"][%w_]+['\"]%]$",
    filetype = "php",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "%$_ENV%[['\"]([%w_]+)['\"]%]$")
    end,
    get_completion_trigger = function()
      return "$_ENV['"
    end,
  },
  -- $_ENV array pattern (anywhere in line)
  {
    pattern = "%$_ENV%[['\"][%w_]+['\"]%]",
    filetype = "php",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "%$_ENV%[['\"]([%w_]+)['\"]%]")
    end,
    get_completion_trigger = function()
      return "$_ENV['"
    end,
  },
  -- $_SERVER array completion
  {
    pattern = "%$_SERVER%[['\"][%w_]*$",
    filetype = "php",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "%$_SERVER%[['\"]([%w_]*)$")
    end,
    get_completion_trigger = function()
      return "$_SERVER['"
    end,
  },
  -- $_SERVER array full pattern
  {
    pattern = "%$_SERVER%[['\"][%w_]+['\"]%]$",
    filetype = "php",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "%$_SERVER%[['\"]([%w_]+)['\"]%]$")
    end,
    get_completion_trigger = function()
      return "$_SERVER['"
    end,
  },
  -- $_SERVER array pattern (anywhere in line)
  {
    pattern = "%$_SERVER%[['\"][%w_]+['\"]%]",
    filetype = "php",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "%$_SERVER%[['\"]([%w_]+)['\"]%]")
    end,
    get_completion_trigger = function()
      return "$_SERVER['"
    end,
  },
}

return M.providers
