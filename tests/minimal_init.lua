local plenary_dir = os.getenv("PLENARY_DIR") or "/tmp/plenary.nvim"
local telescope_dir = os.getenv("TELESCOPE_DIR") or "/tmp/telescope.nvim"
local fzf_lua_dir = os.getenv("FZF_LUA_DIR") or "/tmp/fzf-lua"
local snacks_dir = os.getenv("SNACKS_DIR") or "/tmp/snacks.nvim"
local nvim_cmp_dir = os.getenv("NVIM_CMP_DIR") or "/tmp/nvim-cmp"
local blink_cmp_dir = os.getenv("BLINK_CMP_DIR") or "/tmp/blink.cmp"
local lspsaga_dir = os.getenv("LSPSAGA_DIR") or "/tmp/lspsaga.nvim"

-- Get the absolute path to the ecolog.nvim project directory
local ecolog_dir = vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":p:h:h")

local is_windows = vim.loop.os_uname().version:match("Windows")

-- Add dependency paths after current project paths
if is_windows then
  package.path = string.format(
    "%s;%s\\lua\\?.lua;%s\\lua\\?\\init.lua;%s\\lua\\?.lua;%s\\lua\\?\\init.lua;%s\\lua\\?.lua;%s\\lua\\?\\init.lua;%s\\lua\\?.lua;%s\\lua\\?\\init.lua;%s\\lua\\?.lua;%s\\lua\\?\\init.lua;%s\\lua\\?.lua;%s\\lua\\?\\init.lua;%s\\lua\\?.lua;%s\\lua\\?\\init.lua",
    package.path,
    plenary_dir, plenary_dir,
    telescope_dir, telescope_dir,
    fzf_lua_dir, fzf_lua_dir,
    snacks_dir, snacks_dir,
    nvim_cmp_dir, nvim_cmp_dir,
    blink_cmp_dir, blink_cmp_dir,
    lspsaga_dir, lspsaga_dir
  )
else
  package.path = string.format(
    "%s;%s/lua/?.lua;%s/lua/?/init.lua;%s/lua/?.lua;%s/lua/?/init.lua;%s/lua/?.lua;%s/lua/?/init.lua;%s/lua/?.lua;%s/lua/?/init.lua;%s/lua/?.lua;%s/lua/?/init.lua;%s/lua/?.lua;%s/lua/?/init.lua;%s/lua/?.lua;%s/lua/?/init.lua",
    package.path,
    plenary_dir, plenary_dir,
    telescope_dir, telescope_dir,
    fzf_lua_dir, fzf_lua_dir,
    snacks_dir, snacks_dir,
    nvim_cmp_dir, nvim_cmp_dir,
    blink_cmp_dir, blink_cmp_dir,
    lspsaga_dir, lspsaga_dir
  )
end

-- Add current project to runtimepath first using absolute path
vim.cmd([[set runtimepath+=]] .. ecolog_dir)
vim.cmd([[set runtimepath+=]] .. plenary_dir)
vim.cmd([[set runtimepath+=]] .. telescope_dir)
vim.cmd([[set runtimepath+=]] .. fzf_lua_dir)
vim.cmd([[set runtimepath+=]] .. snacks_dir)
vim.cmd([[set runtimepath+=]] .. nvim_cmp_dir)
vim.cmd([[set runtimepath+=]] .. blink_cmp_dir)
vim.cmd([[set runtimepath+=]] .. lspsaga_dir)
vim.cmd([[runtime plugin/plenary.vim]])

-- Add lua paths for the current project using absolute path
if is_windows then
  package.path = string.format(
    "%s\\lua\\?.lua;%s\\lua\\?\\init.lua;%s",
    ecolog_dir, ecolog_dir, package.path
  )
else
  package.path = string.format(
    "%s/lua/?.lua;%s/lua/?/init.lua;%s",
    ecolog_dir, ecolog_dir, package.path
  )
end

vim.o.swapfile = false

-- Try to load optional plugins if they exist
pcall(require, 'telescope')
pcall(require, 'fzf-lua')
pcall(require, 'snacks')

-- Try to load completion engines if they exist
pcall(require, 'cmp')
pcall(require, 'blink.cmp')
pcall(require, 'lspsaga')

-- Set test mode for ecolog
_G._ECOLOG_TEST_MODE = true

-- Helper function to ensure ecolog is available in tests
-- This is needed because tests change directory which can break module loading
_G.ensure_ecolog_available = function()
  local ecolog_dir = "/home/runner/work/ecolog.nvim/ecolog.nvim"
  local ecolog_lua_path = ecolog_dir .. "/lua/?.lua;" .. ecolog_dir .. "/lua/?/init.lua"
  
  -- Preserve the current package.path and add ecolog paths at the beginning
  if not package.path:find(ecolog_lua_path, 1, true) then
    package.path = ecolog_lua_path .. ";" .. package.path
  end
end

