local M = {}
local providers_module = require("ecolog.providers")

-- Lua environment variable access patterns
M.providers = {}

local filetype = "lua"

-- os.getenv("VAR") and os.getenv('VAR')
vim.list_extend(M.providers, providers_module.create_function_call_patterns("os.getenv", filetype, "both"))

return M.providers
