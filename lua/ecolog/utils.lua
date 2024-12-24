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
  -- Handle empty line
  if #line == 0 then
    return nil, nil
  end

  -- If we're at the end of the line, move back one character
  if col >= #line then
    col = #line - 1
  end

  -- If we're not on a word character, check both directions
  if not line:sub(col + 1, col + 1):match(M.PATTERNS.word) then
    -- Try looking backwards first
    local temp_col = col
    while temp_col > 0 and not line:sub(temp_col, temp_col):match(M.PATTERNS.word) do
      temp_col = temp_col - 1
    end
    
    -- If we found a word character going backwards, use that position
    if temp_col > 0 and line:sub(temp_col, temp_col):match(M.PATTERNS.word) then
      col = temp_col
    else
      -- Otherwise, look forward
      temp_col = col
      while temp_col < #line and not line:sub(temp_col + 1, temp_col + 1):match(M.PATTERNS.word) do
        temp_col = temp_col + 1
      end
      -- If we found a word character going forwards, use that position
      if temp_col < #line and line:sub(temp_col + 1, temp_col + 1):match(M.PATTERNS.word) then
        col = temp_col
      else
        -- No word character found in either direction
        return nil, nil
      end
    end
  end

  -- Find start of word
  local word_start = col
  while word_start > 0 and line:sub(word_start, word_start):match(M.PATTERNS.word) do
    word_start = word_start - 1
  end

  -- Find end of word
  local word_end = col
  while word_end < #line and line:sub(word_end + 1, word_end + 1):match(M.PATTERNS.word) do
    word_end = word_end + 1
  end

  -- If we didn't find a word, return nil positions
  if not line:sub(word_start + 1, word_end):match(M.PATTERNS.word) then
    return nil, nil
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

-- Get word under cursor using word boundaries
function M.get_word_under_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local word_start, word_end = M.find_word_boundaries(line, col)
  
  -- Return empty string if no word found
  if not word_start or not word_end then
    return ""
  end
  
  return line:sub(word_start, word_end)
end

return M

