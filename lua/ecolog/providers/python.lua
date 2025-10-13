local M = {}
local providers_module = require("ecolog.providers")

-- Python environment variable access patterns
M.providers = {}

local filetype = "python"

-- os.environ["VAR"] and os.environ['VAR'] (dictionary access)
vim.list_extend(M.providers, providers_module.create_bracket_patterns("os.environ", filetype, "both"))

-- os.environ.get("VAR") and os.environ.get('VAR')
vim.list_extend(M.providers, providers_module.create_function_call_patterns("os.environ.get", filetype, "both"))

-- os.getenv("VAR") and os.getenv('VAR')
vim.list_extend(M.providers, providers_module.create_function_call_patterns("os.getenv", filetype, "both"))

return M.providers
