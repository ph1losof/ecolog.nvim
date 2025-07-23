local M = {}
local utils = require("ecolog.utils")

M.providers = {
  {
    pattern = "process%.env%.[%w_]*$",
    filetype = { "javascript", "javascriptreact" },
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "process%.env%.([%w_]+)$")
    end,
    get_completion_trigger = function()
      return "process.env."
    end,
  },
  -- process.env square brackets with double quotes
  {
    pattern = 'process%.env%["[%w_]*$',
    filetype = { "javascript", "javascriptreact" },
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, 'process%.env%["([%w_]*)$')
    end,
    get_completion_trigger = function()
      return 'process.env["'
    end,
  },
  -- process.env square brackets with single quotes
  {
    pattern = "process%.env%['[%w_]*$",
    filetype = { "javascript", "javascriptreact" },
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "process%.env%['([%w_]*)$")
    end,
    get_completion_trigger = function()
      return "process.env['"
    end,
  },
  -- process.env square brackets with single quotes (complete)
  {
    pattern = "import%.meta%.env%.[%w_]*$",
    filetype = { "javascript", "javascriptreact" },
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "import%.meta%.env%.([%w_]+)$")
    end,
    get_completion_trigger = function()
      return "import.meta.env."
    end,
  },
  -- import.meta.env square brackets with double quotes
  {
    pattern = 'import%.meta%.env%["[%w_]*$',
    filetype = { "javascript", "javascriptreact" },
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, 'import%.meta%.env%["([%w_]*)$')
    end,
    get_completion_trigger = function()
      return 'import.meta.env["'
    end,
  },
  -- import.meta.env square brackets with single quotes
  {
    pattern = "import%.meta%.env%['[%w_]*$",
    filetype = { "javascript", "javascriptreact" },
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "import%.meta%.env%['([%w_]*)$")
    end,
    get_completion_trigger = function()
      return "import.meta.env['"
    end,
  },
  -- Deno.env.get() syntax
  {
    pattern = 'Deno%.env%.get%("([%w_]+)"%)',
    filetype = { "javascript", "javascriptreact", "typescript", "typescriptreact" },
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, 'Deno%.env%.get%("([%w_]+)"%)')
    end,
    get_completion_trigger = function()
      return 'Deno.env.get("'
    end,
  },
}

return M.providers
