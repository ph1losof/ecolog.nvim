local M = {}
local providers_module = require("ecolog.providers")

-- JavaScript/Node.js environment variable access patterns
M.providers = {}

local filetype = { "javascript", "javascriptreact" }

-- process.env.VAR (dot notation)
vim.list_extend(M.providers, providers_module.create_dot_notation_patterns("process.env", filetype))

-- process.env["VAR"] and process.env['VAR'] (bracket notation)
vim.list_extend(M.providers, providers_module.create_bracket_patterns("process.env", filetype, "both"))

-- import.meta.env.VAR (Vite, modern bundlers)
vim.list_extend(M.providers, providers_module.create_dot_notation_patterns("import.meta.env", filetype))

-- import.meta.env["VAR"] and import.meta.env['VAR']
vim.list_extend(M.providers, providers_module.create_bracket_patterns("import.meta.env", filetype, "both"))

-- Deno.env.get("VAR") and Deno.env.get('VAR')
vim.list_extend(
  M.providers,
  providers_module.create_function_call_patterns("Deno.env.get", { "javascript", "javascriptreact", "typescript", "typescriptreact" }, "both")
)

return M.providers
