local M = {}

M.provider = {
  pattern = "Deno%.env%.get%(['\"]%w+['\"]%)",
  filetype = "typescript",
  extract_var = function(line, col)
    local before_cursor = line:sub(1, col + 1)
    return before_cursor:match("Deno%.env%.get%(['\"]([%w_]+)['\"]%)$")
  end,
  get_completion_trigger = function()
    return "Deno.env.get("
  end,
}

return M 