local M = {}

M.provider = {
  pattern = "Bun%.env%.[%w_]+",
  filetype = { "typescript", "javascript" },
  extract_var = function(line, col)
    local before_cursor = line:sub(1, col + 1)
    return before_cursor:match("Bun%.env%.([%w_]+)$")
  end,
  get_completion_trigger = function()
    return "Bun.env."
  end,
}

return M 