local M = {}
local providers_module = require("ecolog.providers")

-- Rust environment variable access patterns
M.providers = {}

local filetype = "rust"

-- env::var("VAR") and env::var('VAR')
vim.list_extend(M.providers, providers_module.create_function_call_patterns("env::var", filetype, "both"))

-- std::env::var("VAR") and std::env::var('VAR')
vim.list_extend(M.providers, providers_module.create_function_call_patterns("std::env::var", filetype, "both"))

-- env!("VAR") macro (compile-time)
vim.list_extend(M.providers, providers_module.create_function_call_patterns("env!", filetype, '"'))

-- option_env!("VAR") macro (compile-time, optional)
vim.list_extend(M.providers, providers_module.create_function_call_patterns("option_env!", filetype, '"'))

return M.providers
