local M = {}

-- Pre-compile patterns for better performance
M.PATTERNS = {
  env_file = "^.+/%.env$",
  env_with_suffix = "^.+/%.env%.[^.]+$",
  env_line = "^[^#](.+)$",
  key_value = "([^=]+)=(.+)",
  quoted = "^['\"](.*)['\"]$",
  trim = "^%s*(.-)%s*$",
  word = "[%w_]",
  env_var = "^[%w_]+$",
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

---@param env_file string Path to the .env file
---@return boolean success
local function generate_example_file(env_file)
    local f = io.open(env_file, "r")
    if not f then
        vim.notify("Could not open .env file", vim.log.levels.ERROR)
        return false
    end

    local example_content = {}
    for line in f:lines() do
        -- Skip empty lines and comments
        if line:match("^%s*$") or line:match("^%s*#") then
            table.insert(example_content, line)
        else
            -- Match variable name and optional comment
            local name, comment = line:match("([^=]+)=[^#]*(#?.*)$")
            if name then
                -- Clean up the name and comment
                name = name:gsub("^%s*(.-)%s*$", "%1")
                comment = comment:gsub("^%s*(.-)%s*$", "%1")
                -- Create example entry with placeholder
                table.insert(example_content, name .. "=your_" .. name:lower() .. "_here " .. comment)
            end
        end
    end
    f:close()

    -- Write the example file
    local example_file = env_file:gsub("%.env$", "") .. ".env.example"
    local out = io.open(example_file, "w")
    if not out then
        vim.notify("Could not create .env.example file", vim.log.levels.ERROR)
        return false
    end

    out:write(table.concat(example_content, "\n"))
    out:close()
    vim.notify("Generated " .. example_file, vim.log.levels.INFO)
    return true
end

M.generate_example_file = generate_example_file

return M

