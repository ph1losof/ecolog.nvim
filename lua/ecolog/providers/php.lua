local M = {}

M.providers = {
  {
    pattern = "getenv%(['\"][%w_]*['\"]%s*%)$",
    filetype = "php",
    extract_var = function(line, col)
      local before_cursor = line:sub(1, col + 1)
      return before_cursor:match("getenv%(['\"]([%w_]+)['\"]%s*%)$")
    end,
    get_completion_trigger = function()
      return "getenv('"
    end,
  },
  {
    pattern = "_ENV%[['\"][%w_]*['\"]%]$",
    filetype = "php",
    extract_var = function(line, col)
      local before_cursor = line:sub(1, col + 1)
      return before_cursor:match("_ENV%[['\"]([%w_]+)['\"]%]$")
    end,
    get_completion_trigger = function()
      return "_ENV['"
    end,
  },
}

return M.providers
