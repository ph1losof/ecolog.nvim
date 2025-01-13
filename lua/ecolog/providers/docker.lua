local M = {}
local utils = require("ecolog.utils")

M.providers = {
  {
    pattern = "^ENV%s+[%w_]*$",
    filetype = { "dockerfile", "Dockerfile" },
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "^ENV%s+([%w_]*)$")
    end,
    get_completion_trigger = function()
      return "ENV "
    end,
  },
  {
    pattern = "^ARG%s+[%w_]*$",
    filetype = { "dockerfile", "Dockerfile" },
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "^ARG%s+([%w_]*)$")
    end,
    get_completion_trigger = function()
      return "ARG "
    end,
  },
  -- Support for ${} syntax in values
  {
    pattern = "${[%w_]*}?$",
    filetype = { "dockerfile", "Dockerfile" },
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "${([%w_]*)}?$")
    end,
    get_completion_trigger = function()
      return "${"
    end,
  },
}

return M.providers