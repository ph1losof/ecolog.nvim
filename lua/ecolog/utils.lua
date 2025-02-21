local M = {}

-- Constants and Patterns
M.PATTERNS = {
  env_file_combined = "^.+/%.env[^.]*$",
  env_line = "^[^#](.+)$",
  key_value = "([^=]+)=(.+)",
  quoted = "^['\"](.*)['\"]$",
  trim = "^%s*(.-)%s*$",
  word = "[%w_]+",
  env_var = "^[%w_]+$",
}

local DEFAULT_ENV_PATTERNS = {
  "^.+/%.env$",
  "^.+/%.env%.[^.]+$",
}

-- Pattern conversion utilities
---Convert a glob/wildcard pattern to a Lua pattern
---@param pattern string The pattern to convert
---@return string The converted Lua pattern
function M.convert_to_lua_pattern(pattern)
  local escaped = pattern:gsub("[%.%[%]%(%)%+%-%^%$%%]", "%%%1")
  return escaped:gsub("%*", ".*")
end

---Convert a Lua pattern to a glob pattern for file watching
---@param pattern string The Lua pattern to convert
---@return string The converted glob pattern
function M.convert_pattern_to_glob(pattern)
  local glob = pattern:gsub("^%^", ""):gsub("%$$", "")
  glob = glob:gsub("%%.", "")
  glob = glob:gsub("%.%+", "*")
  return glob
end

-- File filtering and pattern matching utilities
---@param files string[]|nil The files to filter
---@param patterns string|string[]|nil The patterns to match against
---@return string[] Filtered files
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

---Match a filename against env file patterns
---@param filename string The filename to check
---@param config table The config containing env_file_patterns
---@return boolean Whether the file matches any pattern
function M.match_env_file(filename, config)
  if not filename then
    return false
  end

  local patterns = config.env_file_patterns or { "%.env.*" }
  for _, pattern in ipairs(patterns) do
    if filename:match(pattern) then
      return true
    end
  end

  return false
end

---Generate watch patterns for file watching based on config
---@param config table The config containing path and env_file_pattern
---@param opts? {use_absolute_path?: boolean} Optional settings
---@return string[] List of watch patterns
function M.get_watch_patterns(config, opts)
  opts = opts or {}
  if not config.env_file_pattern then
    return opts.use_absolute_path and config.path and { config.path .. "/.env*" } or { ".env*" }
  end

  local patterns = type(config.env_file_pattern) == "string" and { config.env_file_pattern }
    or config.env_file_pattern
    or {}

  local watch_patterns = {}
  for _, pattern in ipairs(patterns) do
    if type(pattern) == "string" then
      local glob_pattern = M.convert_pattern_to_glob(pattern)
      local final_pattern = glob_pattern:gsub("^%.%+/", "")
      if opts.use_absolute_path and config.path then
        table.insert(watch_patterns, config.path .. "/" .. final_pattern)
      else
        table.insert(watch_patterns, final_pattern)
      end
    end
  end

  if #watch_patterns == 0 then
    return opts.use_absolute_path and config.path and { config.path .. "/.env*" } or { ".env*" }
  end

  return watch_patterns
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

  local a_is_env = a:match(M.PATTERNS.env_file_combined) ~= nil
  local b_is_env = b:match(M.PATTERNS.env_file_combined) ~= nil
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

function M.extract_line_parts(line)
  if line:match("^%s*#") or line:match("^%s*$") then
    return nil
  end

  local key, value = line:match("^%s*([^=]+)%s*=%s*(.-)%s*$")
  if not key or not value then
    return nil
  end

  local first_char = value:sub(1, 1)
  if first_char == '"' or first_char == "'" then
    local end_quote_pos = nil
    local pos = 2
    while pos <= #value do
      if value:sub(pos, pos) == first_char and value:sub(pos - 1, pos - 1) ~= "\\" then
        end_quote_pos = pos
        break
      end
      pos = pos + 1
    end

    if end_quote_pos then
      local quoted_value = value:sub(2, end_quote_pos - 1)
      local rest = value:sub(end_quote_pos + 1)
      if rest then
        local comment = rest:match("^%s*#%s*(.-)%s*$")
        if comment then
          return key, quoted_value, comment, first_char
        end
      end
      return key, quoted_value, nil, first_char
    end
  end

  local hash_pos = value:find("#")
  if hash_pos then
    if hash_pos > 1 and value:sub(hash_pos - 1, hash_pos - 1):match("%s") then
      local comment = value:sub(hash_pos + 1):match("^%s*(.-)%s*$")
      value = value:sub(1, hash_pos - 1):match("^%s*(.-)%s*$")
      return key, value, comment, nil
    end
  end

  return key, value, nil, nil
end

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

function M.find_word_boundaries(line, col)
  if #line == 0 then
    return nil, nil
  end

  if col >= #line then
    col = #line - 1
  end

  if not line:sub(col + 1, col + 1):match(M.PATTERNS.word) then
    local back_col = col
    while back_col > 0 and not line:sub(back_col, back_col):match(M.PATTERNS.word) do
      back_col = back_col - 1
    end

    local forward_col = col
    while forward_col < #line and not line:sub(forward_col + 1, forward_col + 1):match(M.PATTERNS.word) do
      forward_col = forward_col + 1
    end

    if back_col > 0 and line:sub(back_col, back_col):match(M.PATTERNS.word) then
      col = back_col
    elseif forward_col < #line and line:sub(forward_col + 1, forward_col + 1):match(M.PATTERNS.word) then
      col = forward_col + 1
    else
      return nil, nil
    end
  end

  local word_start = col
  while word_start > 0 and line:sub(word_start, word_start):match(M.PATTERNS.word) do
    word_start = word_start - 1
  end

  local word_end = col
  while word_end < #line and line:sub(word_end + 1, word_end + 1):match(M.PATTERNS.word) do
    word_end = word_end + 1
  end

  if not line:sub(word_start + 1, word_end):match(M.PATTERNS.word) then
    return nil, nil
  end

  return word_start + 1, word_end
end

function M.extract_var_name(line)
  return line:match("^(.-)%s*=")
end

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

function M.extract_env_var(line, col, pattern)
  if not line or not col then
    return nil
  end
  local before_cursor = line:sub(1, col)
  return before_cursor:match(pattern)
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

  if provider_patterns and provider_patterns.extract then
    for _, provider in ipairs(providers) do
      local extracted = provider.extract_var(line, word_end)
      if extracted then
        return extracted
      end
    end
    return ""
  end

  return line:sub(word_start, word_end)
end

return M
