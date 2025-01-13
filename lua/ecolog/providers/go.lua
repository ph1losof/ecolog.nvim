local M = {}
local utils = require("ecolog.utils")

M.provider = {
  pattern = "os%.Getenv%(['\"][%w_]*['\"]?%s*%)$",
  filetype = "go",
  extract_var = function(line, col)
    return utils.extract_env_var(line, col, "os%.Getenv%(['\"]([%w_]+)['\"]?%s*%)$")
  end,
  get_completion_trigger = function()
    return 'os.Getenv("'
  end,
}

return M.provider
