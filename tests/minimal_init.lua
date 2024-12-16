local plenary_dir = os.getenv("PLENARY_DIR") or "/tmp/plenary.nvim"
local is_windows = vim.loop.os_uname().version:match("Windows")

if is_windows then
  package.path = string.format("%s;%s\\lua\\?.lua;%s\\lua\\?\\init.lua", package.path, plenary_dir, plenary_dir)
else
  package.path = string.format("%s;%s/lua/?.lua;%s/lua/?/init.lua", package.path, plenary_dir, plenary_dir)
end

vim.cmd([[set runtimepath+=.]])
vim.cmd([[set runtimepath+=]] .. plenary_dir)
vim.cmd([[runtime plugin/plenary.vim]])

vim.o.swapfile = false
vim.bo.swapfile = false 