local M = {}
local providers_module = require("ecolog.providers")

-- TypeScript environment variable access patterns
M.providers = {}

local filetype = { "typescript", "typescriptreact" }

-- process.env.VAR (dot notation) - Node.js
vim.list_extend(M.providers, providers_module.create_dot_notation_patterns("process.env", filetype))

-- process.env["VAR"] and process.env['VAR'] (bracket notation)
vim.list_extend(M.providers, providers_module.create_bracket_patterns("process.env", filetype, "both"))

-- import.meta.env.VAR (Vite, modern bundlers)
vim.list_extend(M.providers, providers_module.create_dot_notation_patterns("import.meta.env", filetype))

-- import.meta.env["VAR"] and import.meta.env['VAR']
vim.list_extend(M.providers, providers_module.create_bracket_patterns("import.meta.env", filetype, "both"))

-- Bun.env.VAR (Bun runtime)
vim.list_extend(M.providers, providers_module.create_dot_notation_patterns("Bun.env", { "typescript", "javascript" }))

-- Bun.env["VAR"] and Bun.env['VAR']
vim.list_extend(M.providers, providers_module.create_bracket_patterns("Bun.env", { "typescript", "javascript" }, "both"))

-- Deno.env.get("VAR") and Deno.env.get('VAR') (Deno runtime)
vim.list_extend(
  M.providers,
  providers_module.create_function_call_patterns("Deno.env.get", filetype, "both")
)

return M.providers
