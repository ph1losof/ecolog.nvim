local M = {}
local providers_module = require("ecolog.providers")

-- Java environment variable access patterns
M.providers = {}

local filetype = "java"

-- System.getenv("VAR") and System.getenv('VAR')
vim.list_extend(M.providers, providers_module.create_function_call_patterns("System.getenv", filetype, "both"))

-- System.getProperty("VAR") and System.getProperty('VAR')
vim.list_extend(M.providers, providers_module.create_function_call_patterns("System.getProperty", filetype, "both"))

-- processBuilder.environment().get("VAR") and processBuilder.environment().get('VAR')
vim.list_extend(M.providers, providers_module.create_function_call_patterns("processBuilder.environment().get", filetype, "both"))

-- env.get("VAR") and env.get('VAR') - generic Map<String, String> access
vim.list_extend(M.providers, providers_module.create_function_call_patterns("env.get", filetype, "both"))

return M.providers
