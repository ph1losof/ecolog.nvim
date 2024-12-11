local M = {}

M.providers = {
  {
    pattern = "getenv%(['\"]%w*['\"]%s*%)$",
    filetype = "php",
    extract_var = function(line, col)
      local before_cursor = line:sub(1, col + 1)
      return before_cursor:match("getenv%(['\"](%w+)['\"]%s*%)$")
    end,
    get_completion_trigger = function()
      return "getenv('"
    end,
  },
  {
    pattern = "_ENV%[['\"]%w*['\"]%]$",
    filetype = "php",
    extract_var = function(line, col)
      local before_cursor = line:sub(1, col + 1)
      return before_cursor:match("_ENV%[['\"](%w+)['\"]%]$")
    end,
    get_completion_trigger = function()
      return "_ENV['"
    end,
  },
}

return M.providers
