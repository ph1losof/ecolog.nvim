local M = {}

M.providers = {
  {
    pattern = "process%.env%.[%w_]*$",
    filetype = { "typescript", "typescriptreact" },
    extract_var = function(line, col)
      local before_cursor = line:sub(1, col)
      return before_cursor:match("process%.env%.([%w_]+)$")
    end,
    get_completion_trigger = function()
      return "process.env."
    end,
  },
  -- process.env square brackets with double quotes
  {
    pattern = 'process%.env%["[%w_]*$',
    filetype = { "typescript", "typescriptreact" },
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
    pattern = "process%.env%['[%w_]*$",
    filetype = { "typescript", "typescriptreact" },
    extract_var = function(line, col)
      local before_cursor = line:sub(1, col)
      return before_cursor:match("process%.env%['([%w_]*)$")
    end,
    get_completion_trigger = function()
      return "process.env['"
    end,
  },
  {
    pattern = "import%.meta%.env%.[%w_]*$",
    filetype = { "typescript", "typescriptreact" },
    extract_var = function(line, col)
      local before_cursor = line:sub(1, col + 1)
      return before_cursor:match("import%.meta%.env%.([%w_]+)$")
    end,
    get_completion_trigger = function()
      return "import.meta.env."
    end,
  },
  -- import.meta.env square brackets with double quotes
  {
    pattern = 'import%.meta%.env%["[%w_]*$',
    filetype = { "typescript", "typescriptreact" },
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
    pattern = "import%.meta%.env%['[%w_]*$",
    filetype = { "typescript", "typescriptreact" },
    extract_var = function(line, col)
      local before_cursor = line:sub(1, col)
      return before_cursor:match("import%.meta%.env%['([%w_]*)$")
    end,
    get_completion_trigger = function()
      return "import.meta.env['"
    end,
  },
  {
    pattern = "Bun%.env%.[%w_]*$",
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
  -- Bun.env square brackets with double quotes
  {
    pattern = 'Bun%.env%["[%w_]*$',
    filetype = { "typescript", "javascript" },
    extract_var = function(line, col)
      local before_cursor = line:sub(1, col)
      return before_cursor:match('Bun%.env%["([%w_]*)$')
    end,
    get_completion_trigger = function()
      return 'Bun.env["'
    end,
  },
  -- Bun.env square brackets with single quotes
  {
    pattern = "Bun%.env%['[%w_]*$",
    filetype = { "typescript", "javascript" },
    extract_var = function(line, col)
      local before_cursor = line:sub(1, col)
      return before_cursor:match("Bun%.env%['([%w_]*)$")
    end,
    get_completion_trigger = function()
      return "Bun.env['"
    end,
  },
  -- Deno double quotes completion
  {
    pattern = 'Deno%.env%.get%("[%w_]*$',
    filetype = "typescript",
    extract_var = function(line, col)
      local before_cursor = line:sub(1, col)
      return before_cursor:match('Deno%.env%.get%("([%w_]*)$')
    end,
    get_completion_trigger = function()
      return 'Deno.env.get("'
    end,
  },
  -- Deno single quotes completion
  {
    pattern = "Deno%.env%.get%('[%w_]*$",
    filetype = "typescript",
    extract_var = function(line, col)
      local before_cursor = line:sub(1, col)
      return before_cursor:match("Deno%.env%.get%('([%w_]*)$")
    end,
    get_completion_trigger = function()
      return "Deno.env.get('"
    end,
  },
  -- Deno full pattern with double quotes
  {
    pattern = 'Deno%.env%.get%("[%w_]+"%)?$',
    filetype = "typescript",
    extract_var = function(line, col)
      local before_cursor = line:sub(1, col)
      return before_cursor:match('Deno%.env%.get%("([%w_]+)"%)?$')
    end,
    get_completion_trigger = function()
      return 'Deno.env.get("'
    end,
  },
  -- Deno full pattern with single quotes
  {
    pattern = "Deno%.env%.get%('[%w_]+'%)?$",
    filetype = "typescript",
    extract_var = function(line, col)
      local before_cursor = line:sub(1, col)
      return before_cursor:match("Deno%.env%.get%('([%w_]+)'%)?$")
    end,
    get_completion_trigger = function()
      return "Deno.env.get('"
    end,
  }
}

return M.providers

