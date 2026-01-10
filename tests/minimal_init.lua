-- Minimal init for testing ecolog.nvim
-- Run with: nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"

local plenary_path = vim.fn.stdpath("data") .. "/lazy/plenary.nvim"
if not vim.loop.fs_stat(plenary_path) then
  plenary_path = vim.fn.stdpath("data") .. "/site/pack/packer/start/plenary.nvim"
end

if vim.loop.fs_stat(plenary_path) then
  vim.opt.rtp:prepend(plenary_path)
end

-- Add current plugin to rtp
vim.opt.rtp:prepend(vim.fn.getcwd())

-- Disable swap files
vim.opt.swapfile = false

-- Setup for mocking
_G.MockLspClient = nil
_G.MockLspResults = {}
