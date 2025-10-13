local M = {}
local providers_module = require("ecolog.providers")

-- Kotlin environment variable access patterns
M.providers = {}

local filetype = "kotlin"

-- System.getenv("VAR") and System.getenv('VAR')
vim.list_extend(M.providers, providers_module.create_function_call_patterns("System.getenv", filetype, "both"))

return M.providers
