local M = {}
local utils = require("ecolog.utils")

M.providers = {
  -- $VAR completion
  {
    pattern = "%$[%w_]*$",
    filetype = { "sh", "bash", "zsh" },
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "%$([%w_]*)$")
    end,
    get_completion_trigger = function()
      return "$"
    end,
  },
  -- ${VAR} completion
  {
    pattern = "%${[%w_]*$",
    filetype = { "sh", "bash", "zsh" },
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "%${([%w_]*)$")
    end,
    get_completion_trigger = function()
      return "${"
    end,
  },
  -- $VAR full pattern
  {
    pattern = "%$[%w_]+$",
    filetype = { "sh", "bash", "zsh" },
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "%$([%w_]+)$")
    end,
    get_completion_trigger = function()
      return "$"
    end,
  },
  -- ${VAR} full pattern
  {
    pattern = "%${[%w_]+%}$",
    filetype = { "sh", "bash", "zsh" },
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "%${([%w_]+)%}$")
    end,
    get_completion_trigger = function()
      return "${"
    end,
  },
  -- ${VAR} pattern (anywhere in line)
  {
    pattern = "%${[%w_]+%}",
    filetype = { "sh", "bash", "zsh" },
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "%${([%w_]+)%}")
    end,
    get_completion_trigger = function()
      return "${"
    end,
  },
  -- ${VAR:-default} pattern
  {
    pattern = "%${[%w_]+:-[^}]*%}",
    filetype = { "sh", "bash", "zsh" },
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "%${([%w_]+):-[^}]*%}")
    end,
    get_completion_trigger = function()
      return "${"
    end,
  },
  -- printenv completion
  {
    pattern = "printenv%s+[%w_]*$",
    filetype = { "sh", "bash", "zsh" },
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "printenv%s+([%w_]*)$")
    end,
    get_completion_trigger = function()
      return "printenv "
    end,
  },
  -- printenv full pattern
  {
    pattern = "printenv%s+[%w_]+$",
    filetype = { "sh", "bash", "zsh" },
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "printenv%s+([%w_]+)$")
    end,
    get_completion_trigger = function()
      return "printenv "
    end,
  },
  -- echo $VAR completion
  {
    pattern = "echo%s+%$[%w_]*$",
    filetype = { "sh", "bash", "zsh" },
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "echo%s+%$([%w_]*)$")
    end,
    get_completion_trigger = function()
      return "echo $"
    end,
  },
  -- echo ${VAR} completion
  {
    pattern = "echo%s+%${[%w_]*$",
    filetype = { "sh", "bash", "zsh" },
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "echo%s+%${([%w_]*)$")
    end,
    get_completion_trigger = function()
      return "echo ${"
    end,
  },
  -- echo $VAR full pattern
  {
    pattern = "echo%s+%$[%w_]+$",
    filetype = { "sh", "bash", "zsh" },
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "echo%s+%$([%w_]+)$")
    end,
    get_completion_trigger = function()
      return "echo $"
    end,
  },
  -- echo ${VAR} full pattern
  {
    pattern = "echo%s+%${[%w_]+%}$",
    filetype = { "sh", "bash", "zsh" },
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "echo%s+%${([%w_]+)%}$")
    end,
    get_completion_trigger = function()
      return "echo ${"
    end,
  },
  -- env | grep completion
  {
    pattern = "env%s*|%s*grep%s+[%w_]*$",
    filetype = { "sh", "bash", "zsh" },
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "env%s*|%s*grep%s+([%w_]*)$")
    end,
    get_completion_trigger = function()
      return "env | grep "
    end,
  },
  -- env | grep full pattern
  {
    pattern = "env%s*|%s*grep%s+[%w_]+$",
    filetype = { "sh", "bash", "zsh" },
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "env%s*|%s*grep%s+([%w_]+)$")
    end,
    get_completion_trigger = function()
      return "env | grep "
    end,
  },
}

return M.providers 