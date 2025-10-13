local M = {}
local providers_module = require("ecolog.providers")

-- PHP environment variable access patterns
M.providers = {}

local filetype = "php"

-- getenv("VAR") and getenv('VAR')
vim.list_extend(M.providers, providers_module.create_function_call_patterns("getenv", filetype, "both"))

-- $_ENV["VAR"] and $_ENV['VAR']
vim.list_extend(M.providers, providers_module.create_bracket_patterns("$_ENV", filetype, "both"))

-- $_SERVER["VAR"] and $_SERVER['VAR']
vim.list_extend(M.providers, providers_module.create_bracket_patterns("$_SERVER", filetype, "both"))

return M.providers
