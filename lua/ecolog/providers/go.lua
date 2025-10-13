local M = {}
local providers_module = require("ecolog.providers")

-- Go environment variable access patterns
M.providers = {}

local filetype = "go"

-- os.Getenv("VAR") and os.Getenv('VAR')
vim.list_extend(M.providers, providers_module.create_function_call_patterns("os.Getenv", filetype, "both"))

-- os.LookupEnv("VAR") and os.LookupEnv('VAR')
vim.list_extend(M.providers, providers_module.create_function_call_patterns("os.LookupEnv", filetype, "both"))

-- syscall.Getenv("VAR") and syscall.Getenv('VAR')
vim.list_extend(M.providers, providers_module.create_function_call_patterns("syscall.Getenv", filetype, "both"))

-- Add backtick support for Go (raw string literals)
local utils = require("ecolog.utils")

for _, func_name in ipairs({ "os.Getenv", "os.LookupEnv", "syscall.Getenv" }) do
  local escaped_func = func_name:gsub("%.", "%%.")

  -- Complete pattern for backticks
  table.insert(M.providers, {
    pattern = escaped_func .. "%(`[%w_]+`%)",
    filetype = filetype,
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, escaped_func .. "%(`([%w_]+)`%)")
    end,
  })

  -- Partial pattern for backticks (completion)
  table.insert(M.providers, {
    pattern = escaped_func .. "%(`[%w_]*$",
    filetype = filetype,
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, escaped_func .. "%(`([%w_]*)$")
    end,
    get_completion_trigger = function()
      return func_name .. "(`"
    end,
  })
end

return M.providers
