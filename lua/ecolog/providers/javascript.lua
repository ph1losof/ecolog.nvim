local M = {}

M.providers = {
  {
    pattern = "process%.env%.%w*$",
    filetype = { "javascript", "javascriptreact" },
    extract_var = function(line, col)
      local before_cursor = line:sub(1, col + 1)
      return before_cursor:match("process%.env%.(%w+)$")
    end,
    get_completion_trigger = function()
      return "process.env."
    end,
  },
  -- process.env square brackets with double quotes
  {
    pattern = 'process%.env%["%w*$',
    filetype = { "javascript", "javascriptreact" },
    extract_var = function(line, col)
      local before_cursor = line:sub(1, col)
      return before_cursor:match('process%.env%["([%w_]*)$')
    end,
    get_completion_trigger = function()
      return 'process.env["'
    end,
  },
  -- process.env square brackets with single quotes
  {
    pattern = "process%.env%['%w*$",
    filetype = { "javascript", "javascriptreact" },
    extract_var = function(line, col)
      local before_cursor = line:sub(1, col)
      return before_cursor:match("process%.env%['([%w_]*)$")
    end,
    get_completion_trigger = function()
      return "process.env['"
    end,
  },
  {
    pattern = "import%.meta%.env%.%w*$",
    filetype = { "javascript", "javascriptreact" },
    extract_var = function(line, col)
      local before_cursor = line:sub(1, col + 1)
      return before_cursor:match("import%.meta%.env%.(%w+)$")
    end,
    get_completion_trigger = function()
      return "import.meta.env."
    end,
  },
  -- import.meta.env square brackets with double quotes
  {
    pattern = 'import%.meta%.env%["%w*$',
    filetype = { "javascript", "javascriptreact" },
    extract_var = function(line, col)
      local before_cursor = line:sub(1, col)
      return before_cursor:match('import%.meta%.env%["([%w_]*)$')
    end,
    get_completion_trigger = function()
      return 'import.meta.env["'
    end,
  },
  -- import.meta.env square brackets with single quotes
  {
    pattern = "import%.meta%.env%['%w*$",
    filetype = { "javascript", "javascriptreact" },
    extract_var = function(line, col)
      local before_cursor = line:sub(1, col)
      return before_cursor:match("import%.meta%.env%['([%w_]*)$")
    end,
    get_completion_trigger = function()
      return "import.meta.env['"
    end,
  },
}

return M.providers

