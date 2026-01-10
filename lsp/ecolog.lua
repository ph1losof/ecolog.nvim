-- Neovim 0.11+ LSP configuration file for ecolog-lsp
-- This file is automatically loaded by Neovim when vim.lsp.enable('ecolog') is called
-- Place in: <plugin>/lsp/ecolog.lua

return {
  cmd = { "ecolog-lsp" },
  filetypes = {
    "javascript",
    "javascriptreact",
    "typescript",
    "typescriptreact",
    "python",
    "rust",
    "go",
    "lua",
    "dotenv",
    "sh",
    "conf",
  },
  settings = {},
  single_file_support = true,
}
