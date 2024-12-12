local M = {}

M.providers = {
  {
    pattern = "process%.env%.%w*$",
    filetype = { "typescript", "typescriptreact" },
    extract_var = function(line, col)
      local before_cursor = line:sub(1, col + 1)
      return before_cursor:match("process%.env%.(%w+)$")
    end,
    get_completion_trigger = function()
      return "process.env."
    end,
  },
  {
    pattern = "import%.meta%.env%.%w*$",
    filetype = { "typescript", "typescriptreact" },
    extract_var = function(line, col)
      local before_cursor = line:sub(1, col + 1)
      return before_cursor:match("import%.meta%.env%.(%w+)$")
    end,
    get_completion_trigger = function()
      return "import.meta.env."
    end,
  },
  {
    pattern = "Bun%.env%.%w*$",
    filetype = { "typescript", "javascript" },
    extract_var = function(line, col)
      local before_cursor = line:sub(1, col)
      local var = before_cursor:match("Bun%.env%.([%w_]+)$")
      return var
    end,
    get_completion_trigger = function()
      return "Bun.env."
    end,
  },
  {
    pattern = "Deno%.env%.get%(['\"]%w+['\"]%)",
    filetype = "typescript",
    extract_var = function(line, col)
      local before_cursor = line:sub(1, col + 1)
      return before_cursor:match("Deno%.env%.get%(['\"]([%w_]+)['\"]%)$")
    end,
    get_completion_trigger = function()
      return "Deno.env.get("
    end,
  },
}

return M.providers

