local M = {}
local providers_module = require("ecolog.providers")
local utils = require("ecolog.utils")

-- Ruby environment variable access patterns
M.providers = {}

local filetype = "ruby"

-- ENV["VAR"] and ENV['VAR'] (hash access with string keys)
vim.list_extend(M.providers, providers_module.create_bracket_patterns("ENV", filetype, "both"))

-- ENV.fetch("VAR") and ENV.fetch('VAR')
vim.list_extend(M.providers, providers_module.create_function_call_patterns("ENV.fetch", filetype, "both"))

-- ENV[:VAR] (hash access with symbol key) - completion
table.insert(M.providers, {
  pattern = "ENV%[:[%w_]*$",
  filetype = filetype,
  extract_var = function(line, col)
    return utils.extract_env_var(line, col, "ENV%[:([%w_]*)$")
  end,
  get_completion_trigger = function()
    return "ENV[:"
  end,
})

-- ENV[:VAR] (hash access with symbol key) - complete expression
table.insert(M.providers, {
  pattern = "ENV%[:[%w_]+%]",
  filetype = filetype,
  extract_var = function(line, col)
    return utils.extract_env_var(line, col, "ENV%[:([%w_]+)%]")
  end,
})

-- ENV.fetch(:VAR) (with symbol) - completion
table.insert(M.providers, {
  pattern = "ENV%.fetch%(:[%w_]*$",
  filetype = filetype,
  extract_var = function(line, col)
    return utils.extract_env_var(line, col, "ENV%.fetch%(:([%w_]*)$")
  end,
  get_completion_trigger = function()
    return "ENV.fetch(:"
  end,
})

-- ENV.fetch(:VAR) (with symbol) - complete expression
table.insert(M.providers, {
  pattern = "ENV%.fetch%(:[%w_]+%)",
  filetype = filetype,
  extract_var = function(line, col)
    return utils.extract_env_var(line, col, "ENV%.fetch%(:([%w_]+)%)")
  end,
})

return M.providers
