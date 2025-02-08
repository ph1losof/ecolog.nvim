local plenary_dir = os.getenv("PLENARY_DIR") or "/tmp/plenary.nvim"
local telescope_dir = os.getenv("TELESCOPE_DIR") or "/tmp/telescope.nvim"
local fzf_lua_dir = os.getenv("FZF_LUA_DIR") or "/tmp/fzf-lua"
local snacks_dir = os.getenv("SNACKS_DIR") or "/tmp/snacks.nvim"

local is_windows = vim.loop.os_uname().version:match("Windows")

if is_windows then
  package.path = string.format(
    "%s;%s\\lua\\?.lua;%s\\lua\\?\\init.lua;%s\\lua\\?.lua;%s\\lua\\?\\init.lua;%s\\lua\\?.lua;%s\\lua\\?\\init.lua;%s\\lua\\?.lua;%s\\lua\\?\\init.lua",
    package.path,
    plenary_dir, plenary_dir,
    telescope_dir, telescope_dir,
    fzf_lua_dir, fzf_lua_dir,
    snacks_dir, snacks_dir
  )
else
  package.path = string.format(
    "%s;%s/lua/?.lua;%s/lua/?/init.lua;%s/lua/?.lua;%s/lua/?/init.lua;%s/lua/?.lua;%s/lua/?/init.lua;%s/lua/?.lua;%s/lua/?/init.lua",
    package.path,
    plenary_dir, plenary_dir,
    telescope_dir, telescope_dir,
    fzf_lua_dir, fzf_lua_dir,
    snacks_dir, snacks_dir
  )
end

vim.cmd([[set runtimepath+=.]])
vim.cmd([[set runtimepath+=]] .. plenary_dir)
vim.cmd([[set runtimepath+=]] .. telescope_dir)
vim.cmd([[set runtimepath+=]] .. fzf_lua_dir)
vim.cmd([[set runtimepath+=]] .. snacks_dir)
vim.cmd([[runtime plugin/plenary.vim]])

vim.o.swapfile = false

-- Load required plugins
require('telescope')
require('fzf-lua')
require('snacks')

