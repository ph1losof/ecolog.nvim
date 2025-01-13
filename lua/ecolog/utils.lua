local M = {}

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

local DEFAULT_ENV_PATTERNS = {
  "^.+/%.env$",
  "^.+/%.env%.[^.]+$",
}

function M.filter_env_files(files, patterns)
  if not files then
    return {}
  end

  files = vim.tbl_filter(function(f)
    return f ~= nil
  end, files)

  if not patterns then
    patterns = DEFAULT_ENV_PATTERNS
  elseif type(patterns) == "string" then
    patterns = { patterns }
  elseif type(patterns) ~= "table" then
    return files
  end

  if #patterns == 0 then
    return files
  end

  return vim.tbl_filter(function(file)
    if not file then
      return false
    end
    for _, pattern in ipairs(patterns) do
      if type(pattern) == "string" and file:match(pattern) then
        return true
      end
    end
    return false
  end, files)
end

local function default_sort_fn(a, b, opts)
  if not a or not b then
    return false
  end

  if opts and opts.preferred_environment and opts.preferred_environment ~= "" then
    local pref_pattern = "%." .. vim.pesc(opts.preferred_environment) .. "$"
    local a_is_preferred = a:match(pref_pattern) ~= nil
    local b_is_preferred = b:match(pref_pattern) ~= nil
    if a_is_preferred ~= b_is_preferred then
      return a_is_preferred
    end
  end

  local a_is_env = a:match(M.PATTERNS.env_file) ~= nil
  local b_is_env = b:match(M.PATTERNS.env_file) ~= nil
  if a_is_env ~= b_is_env then
    return a_is_env
  end

  return a < b
end

function M.sort_env_files(files, opts)
  if not files or #files == 0 then
    return {}
  end

  opts = opts or {}
  local sort_fn = opts.sort_fn or default_sort_fn

  files = vim.tbl_filter(function(f)
    return f ~= nil
  end, files)

  table.sort(files, function(a, b)
    return sort_fn(a, b, opts)
  end)

  return files
end

function M.find_word_boundaries(line, col)
  if #line == 0 then
    return nil, nil
  end

  -- Adjust column if it's beyond line length
  if col >= #line then
    col = #line - 1
  end

  -- If we're not on a word character, search forward and backward
  if not line:sub(col + 1, col + 1):match(M.PATTERNS.word) then
    -- Search backward first
    local back_col = col
    while back_col > 0 and not line:sub(back_col, back_col):match(M.PATTERNS.word) do
      back_col = back_col - 1
    end

    -- Search forward if backward search failed
    local forward_col = col
    while forward_col < #line and not line:sub(forward_col + 1, forward_col + 1):match(M.PATTERNS.word) do
      forward_col = forward_col + 1
    end

    -- Choose the closest word boundary
    if back_col > 0 and line:sub(back_col, back_col):match(M.PATTERNS.word) then
      col = back_col
    elseif forward_col < #line and line:sub(forward_col + 1, forward_col + 1):match(M.PATTERNS.word) then
      col = forward_col + 1
    else
      return nil, nil
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

  -- Verify we found a valid word
  if not line:sub(word_start + 1, word_end):match(M.PATTERNS.word) then
    return nil, nil
  end

  return word_start + 1, word_end
end

local _cached_modules = {}
function M.require_on_demand(name)
  if not _cached_modules[name] then
    _cached_modules[name] = require(name)
  end
  return _cached_modules[name]
end

function M.get_module(name)
  return setmetatable({}, {
    __index = function(_, key)
      return M.require_on_demand(name)[key]
    end,
  })
end

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

---@return string Variable name or empty string if not found
function M.get_var_word_under_cursor(providers)
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local word_start, word_end = M.find_word_boundaries(line, col)

  if not word_start or not word_end then
    return ""
  end

  if not providers then
    local filetype = vim.bo.filetype
    providers = require("ecolog.providers").get_providers(filetype)
  end

  local ecolog = require("ecolog")
  local config = ecolog.get_config()
  local provider_patterns = config and config.provider_patterns

  -- Check if provider patterns are enabled for extraction
  if provider_patterns and provider_patterns.extract then
    for _, provider in ipairs(providers) do
      local extracted = provider.extract_var(line, word_end)
      if extracted then
        return extracted
      end
    end
    return ""
  end

  -- If provider patterns are disabled for extraction, return the word under cursor
  return line:sub(word_start, word_end)
end

function M.extract_var_name(line)
  return line:match("^(.-)%s*=")
end

function M.find_env_files(opts)
  opts = opts or {}
  local path = opts.path or vim.fn.getcwd()

  local files = {}
  if not opts.env_file_pattern then
    local env_files = vim.fn.glob(path .. "/.env*", false, true)

    if type(env_files) == "string" then
      env_files = { env_files }
    end

    files = M.filter_env_files(env_files, DEFAULT_ENV_PATTERNS)
  else
    local all_files = vim.fn.glob(path .. "/*", false, true)
    if type(all_files) == "string" then
      all_files = { all_files }
    end
    files = M.filter_env_files(all_files, opts.env_file_pattern)
  end

  return M.sort_env_files(files, opts)
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
    if line:match("^%s*$") or line:match("^%s*#") then
      table.insert(example_content, line)
    else
      local name, comment = line:match("([^=]+)=[^#]*(#?.*)$")
      if name then
        name = name:gsub("^%s*(.-)%s*$", "%1")
        comment = comment:gsub("^%s*(.-)%s*$", "%1")
        table.insert(example_content, name .. "=your_" .. name:lower() .. "_here " .. comment)
      end
    end
  end
  f:close()

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

---@param value string The value to check for quotes
---@return string|nil quote_char The quote character if found
---@return string|nil actual_value The value without quotes if found
function M.extract_quoted_value(value)
  if not value then
    return nil, nil
  end
  
  local quote_char = string.match(value, "^([\"'])")
  if not quote_char then
    return nil, string.match(value, "^([^%s#]+)")
  end
  
  return quote_char, string.match(value, "^" .. quote_char .. "(.-)" .. quote_char)
end

---@param line string The line to extract from
---@param col number The column position
---@param pattern string The pattern to match
---@return string|nil var_name The extracted variable name
function M.extract_env_var(line, col, pattern)
  if not line or not col then
    return nil
  end
  local before_cursor = line:sub(1, col)
  return before_cursor:match(pattern)
end

---@param line string The line to parse
---@return string|nil key The key if found
---@return string|nil value The value if found
---@return number|nil eq_pos The position of the equals sign
function M.parse_env_line(line)
  if not line or line:match("^%s*#") or line:match("^%s*$") then
    return nil, nil, nil
  end
  
  local eq_pos = line:find("=")
  if not eq_pos then
    return nil, nil, nil
  end
  
  local key = line:sub(1, eq_pos - 1):match("^%s*(.-)%s*$")
  local value = line:sub(eq_pos + 1):match("^%s*(.-)%s*$")
  
  return key, value, eq_pos
end

return M
