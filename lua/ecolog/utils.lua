local M = {}

---@class Patterns
---@field env_file_combined string Pattern for matching .env files
---@field env_line string Pattern for matching non-comment lines
---@field key_value string Pattern for matching key-value pairs
---@field quoted string Pattern for matching quoted values
---@field trim string Pattern for trimming whitespace
---@field word string Pattern for matching word characters
---@field env_var string Pattern for matching environment variable names
M.PATTERNS = {
  env_file_combined = "^.+/%.env[^.]*$",
  env_line = "^[^#](.+)$",
  key_value = "([^=]+)=(.+)",
  quoted = "^['\"](.*)['\"]$",
  trim = "^%s*(.-)%s*$",
  word = "[%w_]+",
  env_var = "^[%w_]+$",
}

-- Default patterns for .env files
local DEFAULT_ENV_PATTERNS = {
  ".env",
  ".envrc",
  ".env.*",
}

-- Pattern conversion utilities
---Convert a glob/wildcard pattern to a Lua pattern
---@param pattern string The pattern to convert
---@return string The converted Lua pattern
function M.convert_to_lua_pattern(pattern)
  local escaped = pattern:gsub("[%.%[%]%(%)%+%-%^%$%%]", "%%%1")
  return escaped:gsub("%*", ".*")
end

-- Path handling utilities
---Normalize a path to absolute form without trailing slash
---@param path string The path to normalize
---@return string The normalized path
local function normalize_path(path)
  if not path then
    return vim.fn.getcwd()
  end
  return vim.fn.fnamemodify(path, ":p:h")
end

---Make a pattern relative by removing leading slashes
---@param pattern string The pattern to process
---@return string The relative pattern
local function make_pattern_relative(pattern)
  return pattern:gsub("^/+", "")
end

---Combine base path with a pattern safely
---@param base string The base path
---@param pattern string The pattern to append
---@return string The combined path
local function combine_path_pattern(base, pattern)
  base = normalize_path(base)
  pattern = make_pattern_relative(pattern)
  return base .. "/" .. pattern
end

--[[ File Pattern Matching ]]

---Filter a list of files based on glob patterns
---@param files string[]|nil The files to filter
---@param patterns string[]|nil The glob patterns to match against
---@return string[] Filtered files
function M.filter_env_files(files, patterns)
  if not files then
    return {}
  end

  files = vim.tbl_filter(function(f)
    return f ~= nil
  end, files)

  if not patterns or type(patterns) ~= "table" then
    patterns = DEFAULT_ENV_PATTERNS
  end

  if #patterns == 0 then
    return files
  end

  return vim.tbl_filter(function(file)
    if not file then
      return false
    end
    local filename = vim.fn.fnamemodify(file, ":t")
    for _, pattern in ipairs(patterns) do
      if type(pattern) == "string" and vim.fn.match(filename, vim.fn.glob2regpat(pattern)) >= 0 then
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

  local patterns = config.env_file_patterns
  if not patterns or type(patterns) ~= "table" then
    patterns = DEFAULT_ENV_PATTERNS
  end

  filename = vim.fn.fnamemodify(filename, ":p")
  local path = normalize_path(config.path)

  for _, pattern in ipairs(patterns) do
    if type(pattern) ~= "string" then
      goto continue
    end

    pattern = make_pattern_relative(pattern)
    local is_path_pattern = pattern:find("/")

    if is_path_pattern then
      local full_pattern = combine_path_pattern(path, pattern)

      if pattern:find("[*?%[%]]") then
        local glob_result = vim.fn.glob(full_pattern, false, true)
        if glob_result and #glob_result > 0 then
          full_pattern = glob_result[1]
        end
      end
      
      if filename == full_pattern then
        return true
      end

      local glob_pattern = vim.fn.glob2regpat(full_pattern)
      if vim.fn.match(filename, glob_pattern) >= 0 then
        return true
      end
    else
      local basename = vim.fn.fnamemodify(filename, ":t")
      if vim.fn.match(basename, vim.fn.glob2regpat(pattern)) >= 0 then
        return true
      end
    end

    ::continue::
  end

  return false
end

---Generate watch patterns for file watching based on config
---@param config table The config containing path and env_file_patterns
---@return string[] List of watch patterns
function M.get_watch_patterns(config)
  local path = normalize_path(config.path)
  local patterns = config.env_file_patterns

  if not patterns or type(patterns) ~= "table" then
    local watch_patterns = {}
    for _, pattern in ipairs(DEFAULT_ENV_PATTERNS) do
      table.insert(watch_patterns, combine_path_pattern(path, pattern))
    end
    return watch_patterns
  end

  local watch_patterns = {}
  for _, pattern in ipairs(patterns) do
    if type(pattern) == "string" then
      table.insert(watch_patterns, combine_path_pattern(path, pattern))
    end
  end

  if #watch_patterns == 0 then
    return { path .. "/.env*" }
  end

  return watch_patterns
end

--[[ File Finding and Sorting ]]

---Find environment files based on provided options
---@param opts? {path?: string, env_file_patterns?: string[], preferred_environment?: string, sort_fn?: function}
---@return string[] List of found environment files
function M.find_env_files(opts)
  opts = opts or {}
  local path = opts.path or vim.fn.getcwd()

  local files = {}
  if not opts.env_file_patterns then
    -- Use default patterns
    local env_files = {}
    for _, pattern in ipairs(DEFAULT_ENV_PATTERNS) do
      local found = vim.fn.glob(path .. "/" .. pattern, false, true)
      if type(found) == "string" then
        found = { found }
      end
      vim.list_extend(env_files, found)
    end

    files = env_files
  else
    -- Use custom patterns only
    if type(opts.env_file_patterns) ~= "table" then
      vim.notify("env_file_patterns must be a table of glob patterns", vim.log.levels.WARN)
      return {}
    end

    -- Gather files using each glob pattern
    local all_files = {}
    for _, pattern in ipairs(opts.env_file_patterns) do
      if type(pattern) == "string" then
        local found = vim.fn.glob(path .. "/" .. pattern, false, true)
        if type(found) == "string" then
          found = { found }
        end
        vim.list_extend(all_files, found)
      end
    end

    files = all_files
  end

  return M.sort_env_files(files, opts)
end

---Default sorting function for environment files
---@param a string First file path
---@param b string Second file path
---@param opts table Options containing preferred_environment
---@return boolean Whether a should come before b
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

---Sort environment files based on preferences
---@param files string[]|nil Files to sort
---@param opts? {preferred_environment?: string, sort_fn?: function}
---@return string[] Sorted files
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

--[[ Environment File Parsing ]]

---Extract parts from an environment file line
---@param line string The line to parse
---@return string|nil key The environment variable key
---@return string|nil value The environment variable value
---@return string|nil comment Any inline comment
---@return string|nil quote_char The quote character used (if any)
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

---Parse a line from an environment file
---@param line string The line to parse
---@return string|nil key The environment variable key
---@return string|nil value The environment variable value
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

--[[ Text Processing ]]

---Find word boundaries in a line of text
---@param line string The line to search
---@param col number The column position
---@return number|nil start The start position of the word
---@return number|nil end_ The end position of the word
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

---Extract variable name from a line
---@param line string The line to extract from
---@return string|nil name The extracted variable name
function M.extract_var_name(line)
  return line:match("^(.-)%s*=")
end

---Extract quoted value from a string
---@param value string The string to extract from
---@return string|nil quote_char The quote character used
---@return string|nil extracted_value The extracted value
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

---Extract environment variable from a line at a position
---@param line string The line to extract from
---@param col number The column position
---@param pattern string The pattern to match
---@return string|nil var The extracted variable
function M.extract_env_var(line, col, pattern)
  if not line or not col then
    return nil
  end
  local before_cursor = line:sub(1, col)
  return before_cursor:match(pattern)
end

--[[ File Generation ]]
---Generate an example environment file
---@param env_file string Path to the source .env file
---@return boolean success Whether the file was generated successfully
function M.generate_example_file(env_file)
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

--[[ UI Utilities ]]

---Create options for a minimal floating window
---@param width number Window width
---@param height number Window height
---@return table opts Window options
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

---Create a function to restore minimal window options
---@return function restore Function to restore window options
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

--[[ Module Management ]]

local _cached_modules = {}

---Require a module on demand with caching
---@param name string Module name
---@return table module The required module
function M.require_on_demand(name)
  if not _cached_modules[name] then
    _cached_modules[name] = require(name)
  end
  return _cached_modules[name]
end

---Get a module with lazy loading
---@param name string Module name
---@return table module The module proxy
function M.get_module(name)
  return setmetatable({}, {
    __index = function(_, key)
      return M.require_on_demand(name)[key]
    end,
  })
end

--[[ Variable Extraction ]]

---Get the variable word under the cursor
---@param providers? table[] List of providers
---@return string var_name Variable name or empty string if not found
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
