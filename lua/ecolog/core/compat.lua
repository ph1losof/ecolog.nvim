---Compatibility layer for Neovim version differences
---@module ecolog.core.compat
local M = {}

-- UV compatibility: vim.uv (Neovim 0.10+) or vim.loop (older versions)
M.uv = vim.uv or vim.loop

return M
