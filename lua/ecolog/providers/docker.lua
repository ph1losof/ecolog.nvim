local M = {}

M.providers = {
  {
    pattern = "ENV%s+[%w_]+",
    filetype = "dockerfile",
    extract_var = function(line, col)
      local before_cursor = line:sub(1, col + 1)
      return before_cursor:match("ENV%s+([%w_]+)")
    end,
    get_completion_trigger = function()
      return "ENV "
    end,
  },
  {
    pattern = "ARG%s+[%w_]+",
    filetype = "dockerfile",
    extract_var = function(line, col)
      local before_cursor = line:sub(1, col + 1)
      return before_cursor:match("ARG%s+([%w_]+)")
    end,
    get_completion_trigger = function()
      return "ARG "
    end,
  }
}

return M.providers 