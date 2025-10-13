local M = {}
local providers_module = require("ecolog.providers")

-- C# environment variable access patterns
M.providers = {}

local filetype = "cs"

-- Environment.GetEnvironmentVariable("VAR") and Environment.GetEnvironmentVariable('VAR')
vim.list_extend(M.providers, providers_module.create_function_call_patterns("Environment.GetEnvironmentVariable", filetype, "both"))

-- System.Environment.GetEnvironmentVariable("VAR") and System.Environment.GetEnvironmentVariable('VAR')
vim.list_extend(M.providers, providers_module.create_function_call_patterns("System.Environment.GetEnvironmentVariable", filetype, "both"))

-- Environment.GetEnvironmentVariables()["VAR"] and Environment.GetEnvironmentVariables()['VAR']
vim.list_extend(M.providers, providers_module.create_bracket_patterns("Environment.GetEnvironmentVariables()", filetype, "both"))

-- System.Environment.GetEnvironmentVariables()["VAR"] and System.Environment.GetEnvironmentVariables()['VAR']
vim.list_extend(M.providers, providers_module.create_bracket_patterns("System.Environment.GetEnvironmentVariables()", filetype, "both"))

return M.providers
