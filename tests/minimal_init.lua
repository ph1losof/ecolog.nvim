local plenary_dir = os.getenv("PLENARY_DIR") or "/tmp/plenary.nvim"
local telescope_dir = os.getenv("TELESCOPE_DIR") or "/tmp/telescope.nvim"
local fzf_lua_dir = os.getenv("FZF_LUA_DIR") or "/tmp/fzf-lua"
local snacks_dir = os.getenv("SNACKS_DIR") or "/tmp/snacks.nvim"
local nvim_cmp_dir = os.getenv("NVIM_CMP_DIR") or "/tmp/nvim-cmp"
local blink_cmp_dir = os.getenv("BLINK_CMP_DIR") or "/tmp/blink.cmp"
local lspsaga_dir = os.getenv("LSPSAGA_DIR") or "/tmp/lspsaga.nvim"

local is_windows = vim.loop.os_uname().version:match("Windows")

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

vim.cmd([[set runtimepath+=.]])
vim.cmd([[set runtimepath+=]] .. plenary_dir)
vim.cmd([[set runtimepath+=]] .. telescope_dir)
vim.cmd([[set runtimepath+=]] .. fzf_lua_dir)
vim.cmd([[set runtimepath+=]] .. snacks_dir)
vim.cmd([[set runtimepath+=]] .. nvim_cmp_dir)
vim.cmd([[set runtimepath+=]] .. blink_cmp_dir)
vim.cmd([[set runtimepath+=]] .. lspsaga_dir)
vim.cmd([[runtime plugin/plenary.vim]])

vim.o.swapfile = false

-- Load required plugins
require('telescope')
require('fzf-lua')
require('snacks')

-- Try to load completion engines if they exist
pcall(require, 'cmp')
pcall(require, 'blink.cmp')
pcall(require, 'lspsaga')

