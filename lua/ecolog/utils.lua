local M = {}
local api = vim.api
local fn = vim.fn

-- Pre-compile patterns for better performance
M.PATTERNS = {
  env_file = "^.+/%.env$",
  env_with_suffix = "^.+/%.env%.[^.]+$",
  env_line = "^[^#](.+)$",
  key_value = "([^=]+)=(.+)",
  quoted = "^['\"](.*)['\"]$",
  trim = "^%s*(.-)%s*$",
  word = "[%w_]",
  env_var = "^[%w_]+$"
}

-- Find word boundaries around cursor position
function M.find_word_boundaries(line, col)
  local word_start = col
  while word_start > 0 and line:sub(word_start, word_start):match(M.PATTERNS.word) do
    word_start = word_start - 1
  end

  local word_end = col
  while word_end <= #line and line:sub(word_end + 1, word_end + 1):match(M.PATTERNS.word) do
    word_end = word_end + 1
  end

  return word_start + 1, word_end
end

-- Lazy load modules with caching
local _cached_modules = {}
function M.require_on_demand(name)
  if not _cached_modules[name] then
    _cached_modules[name] = require(name)
  end
  return _cached_modules[name]
end

-- Get module with lazy loading
function M.get_module(name)
  return setmetatable({}, {
    __index = function(_, key)
      return M.require_on_demand(name)[key]
    end,
  })
end

-- Create minimal window options
function M.create_minimal_win_opts(width, height)
  local screen_width = vim.o.columns
  local screen_height = vim.o.lines

  return {
    height = height,
    width = width,
    relative = "editor",
    row = math.floor((screen_height - height) / 2),
    col = math.floor((screen_width - width) / 2),
    border = "rounded",
    style = "minimal",
    focusable = true,
  }
end

-- Restore window options
function M.minimal_restore()
  local minimal_opts = {
    ["number"] = vim.opt.number,
    ["relativenumber"] = vim.opt.relativenumber,
    ["cursorline"] = vim.opt.cursorline,
    ["cursorcolumn"] = vim.opt.cursorcolumn,
    ["foldcolumn"] = vim.opt.foldcolumn,
    ["spell"] = vim.opt.spell,
    ["list"] = vim.opt.list,
    ["signcolumn"] = vim.opt.signcolumn,
    ["colorcolumn"] = vim.opt.colorcolumn,
    ["fillchars"] = vim.opt.fillchars,
    ["statuscolumn"] = vim.opt.statuscolumn,
    ["winhl"] = vim.opt.winhl,
  }

  return function()
    for opt, val in pairs(minimal_opts) do
      if type(val) ~= "function" then
        vim.opt[opt] = val
      end
    end
  end
end

return M 