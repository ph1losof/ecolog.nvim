local M = {}

M.provider = {
  pattern = "os%.Getenv%(['\"]%w*['\"]?%s*%)$",
  filetype = "go",
  extract_var = function(line, col)
    local before_cursor = line:sub(1, col + 1)
    return before_cursor:match('os%.Getenv%([\'"](%w+)[\'"]?%s*%)$')
  end,
  get_completion_trigger = function()
    return 'os.Getenv("'
  end,
}

return M.provider

