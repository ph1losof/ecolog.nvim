local M = {}

M.providers = {
  {
    pattern = "os%.environ%.get%(%s*['\"]%w*['\"]?%s*%)$",
    filetype = "python",
    extract_var = function(line, col)
      local before_cursor = line:sub(1, col + 1)
      return before_cursor:match("os%.environ%.get%(%s*['\"](%w+)['\"]?%s*%)$")
    end,
    get_completion_trigger = function()
      return "os.environ.get('"
    end,
  },
  {
    pattern = "os%.environ%[['\"]%w*['\"]?%]?$",
    filetype = "python",
    extract_var = function(line, col)
      local before_cursor = line:sub(1, col + 1)
      return before_cursor:match("os%.environ%[['\"](%w+)['\"]?%]?$")
    end,
    get_completion_trigger = function()
      return "os.environ['"
    end,
  }
}

return M.providers

