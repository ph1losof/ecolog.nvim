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

-- Pattern types and handling
local PATTERN_TYPES = {
  EXACT = "exact", -- No special characters
  GLOB = "glob", -- Standard glob (*, ?, [], {})
  EXTENDED_GLOB = "ext", -- Extended glob (@, *, +, ?, !)
  REGEX = "regex", -- Regular expressions
}

-- Pattern conversion utilities
---Convert a glob/wildcard pattern to a Lua pattern
---@param pattern string The pattern to convert
---@return string The converted Lua pattern
function M.convert_to_lua_pattern(pattern)
  local escaped = pattern:gsub("[%.%[%]%(%)%+%-%^%$%%]", "%%%1")
  return escaped:gsub("%*", ".*")
end

---Generate display name for environment file with workspace context
---@param file_path string Full path to the environment file
---@param opts table Configuration options (should contain monorepo info)
---@return string display_name The display name with workspace context
function M.get_env_file_display_name(file_path, opts)
  local display_name = vim.fn.fnamemodify(file_path, ":t")
  
  -- Show workspace context for any monorepo setup (both manual and auto modes)
  if opts and opts._monorepo_root then
    local relative_path = file_path:sub(#opts._monorepo_root + 2) -- Remove root path + "/"
    local workspace_parts = vim.split(relative_path, "/")
    
    if #workspace_parts >= 2 then
      -- Show workspace type and name (e.g., "apps/api")
      local workspace_context = workspace_parts[1] .. "/" .. workspace_parts[2]
      display_name = string.format("%s (%s)", display_name, workspace_context)
    elseif #workspace_parts == 1 then
      -- Root level file
      display_name = string.format("%s (root)", display_name)
    end
  end
  
  return display_name
end

-- Path handling utilities
---Get the project root based on configuration
---@param config table The configuration containing path and project_root settings
---@return string root_path The resolved project root path
local function get_project_root(config)
  if config.project_root then
    if type(config.project_root) == "string" then
      return vim.fn.fnamemodify(config.project_root, ":p:h")
    elseif type(config.project_root) == "function" then
      local root = config.project_root()
      if type(root) == "string" then
        return vim.fn.fnamemodify(root, ":p:h")
      end
    end
  end

  if config.path then
    return vim.fn.fnamemodify(config.path, ":p:h")
  end

  return vim.fn.getcwd()
end

---Normalize a path to absolute form without trailing slash
---@param path string|nil The path to normalize
---@param config table|nil The configuration containing project_root settings
---@return string The normalized path
local function normalize_path(path, config)
  if not path then
    return config and get_project_root(config) or vim.fn.getcwd()
  end

  if not vim.fn.fnamemodify(path, ":p") == path and config then
    local root = get_project_root(config)
    return vim.fn.fnamemodify(root .. "/" .. path, ":p:h")
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
---@param config table|nil The configuration containing project_root settings
---@return string The combined path
local function combine_path_pattern(base, pattern, config)
  base = normalize_path(base, config)
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

  -- Filter out nil values more efficiently
  local valid_files = {}
  for i = 1, #files do
    local file = files[i]
    if file then
      valid_files[#valid_files + 1] = file
    end
  end
  files = valid_files

  if not patterns or type(patterns) ~= "table" then
    patterns = DEFAULT_ENV_PATTERNS
  end

  if #patterns == 0 then
    return files
  end

  local filtered_files = {}
  for i = 1, #files do
    local file = files[i]
    if file then
      local filename = vim.fn.fnamemodify(file, ":t")
      for j = 1, #patterns do
        local pattern = patterns[j]
        if type(pattern) == "string" and vim.fn.match(filename, vim.fn.glob2regpat(pattern)) >= 0 then
          filtered_files[#filtered_files + 1] = file
          break
        end
      end
    end
  end
  return filtered_files
end

---Detect pattern type based on its content
---@param pattern string The pattern to analyze
---@return string pattern_type The detected pattern type
local function detect_pattern_type(pattern)
  if not pattern or type(pattern) ~= "string" then
    return PATTERN_TYPES.EXACT
  end

  if pattern:match("^[@*+?!]%(.-%)") then
    return PATTERN_TYPES.EXTENDED_GLOB
  end

  if pattern:match("[%^%$%(%)%+%|\\]") or pattern:match("%.%*") then
    return PATTERN_TYPES.REGEX
  end

  if pattern:find("[*?%[%]{}]") then
    return PATTERN_TYPES.GLOB
  end

  return PATTERN_TYPES.EXACT
end

---Convert extended glob pattern to Lua pattern
---@param pattern string The extended glob pattern
---@return string lua_pattern The converted Lua pattern
local function convert_extended_glob(pattern)
  local conversions = {
    ["@%("] = "(",
    ["%*%("] = "(",
    ["%+%("] = "(",
    ["%?%("] = "(",
    ["!%("] = "^(?!",
    ["%)"] = ")",
  }

  local result = pattern
  for from, to in pairs(conversions) do
    result = result:gsub(from, to)
  end

  result = M.convert_to_lua_pattern(result)
  return result
end

---Convert a pattern to Lua pattern based on its type
---@param pattern string The pattern to convert
---@return string lua_pattern The converted Lua pattern
local function convert_to_matching_pattern(pattern)
  local pattern_type = detect_pattern_type(pattern)

  if pattern_type == PATTERN_TYPES.EXACT then
    return "^" .. vim.pesc(pattern) .. "$"
  elseif pattern_type == PATTERN_TYPES.EXTENDED_GLOB then
    return convert_extended_glob(pattern)
  elseif pattern_type == PATTERN_TYPES.REGEX then
    return pattern
  else
    return vim.fn.glob2regpat(pattern)
  end
end

---Match a file against a pattern
---@param filename string The filename to check
---@param pattern string The pattern to match against
---@param base_path string? The base path for relative patterns
---@param config table? The configuration containing project_root settings
---@return boolean matches Whether the file matches the pattern
local function match_file_pattern(filename, pattern, base_path, config)
  if not pattern or type(pattern) ~= "string" then
    return false
  end

  if pattern:find("/") then
    pattern = make_pattern_relative(pattern)
    local full_pattern = combine_path_pattern(base_path or get_project_root(config), pattern, config)

    local pattern_type = detect_pattern_type(pattern)

    if pattern_type == PATTERN_TYPES.GLOB or pattern_type == PATTERN_TYPES.EXTENDED_GLOB then
      if pattern:find("**") then
        local lua_pattern = convert_to_matching_pattern(full_pattern)
        return vim.fn.match(filename, lua_pattern) >= 0
      end

      local matches = vim.fn.glob(full_pattern, false, true)
      if matches and #matches > 0 then
        for _, match in ipairs(matches) do
          if filename == match then
            return true
          end
        end
      end
    end

    local lua_pattern = convert_to_matching_pattern(full_pattern)
    return vim.fn.match(filename, lua_pattern) >= 0
  end

  local basename = vim.fn.fnamemodify(filename, ":t")
  local lua_pattern = convert_to_matching_pattern(pattern)
  return vim.fn.match(basename, lua_pattern) >= 0
end

---Match a filename against env file patterns
---@param filename string The filename to check
---@param config table The config containing env_file_patterns and project_root settings
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
  local path = normalize_path(config.path, config)

  for _, pattern in ipairs(patterns) do
    if match_file_pattern(filename, pattern, path, config) then
      return true
    end
  end

  return false
end

---Process a pattern and return matching files or patterns
---@param pattern string The pattern to process
---@param path string The base path
---@param opts table Configuration options
---@param collect_fn function Function to collect results (either insert or extend)
---@return string[] files List of files or patterns
local function process_pattern(pattern, path, opts, collect_fn)
  if not type(pattern) == "string" then
    return {}
  end

  local results = {}
  local pattern_type = detect_pattern_type(pattern)

  if pattern_type == PATTERN_TYPES.GLOB or pattern_type == PATTERN_TYPES.EXTENDED_GLOB then
    if pattern:find("**") or pattern:find("@%(") or pattern:find("%*%(") then
      local full_pattern = combine_path_pattern(path, make_pattern_relative(pattern), opts)
      collect_fn(results, { full_pattern })
    else
      local full_pattern = combine_path_pattern(path, pattern, opts)
      local resolved = vim.fn.glob(full_pattern, false, true)
      if type(resolved) == "string" then
        resolved = { resolved }
      end
      if resolved and #resolved > 0 then
        collect_fn(results, resolved)
      else
        collect_fn(results, { combine_path_pattern(path, make_pattern_relative(pattern), opts) })
      end
    end
  else
    local full_pattern = combine_path_pattern(path, make_pattern_relative(pattern), opts)
    collect_fn(results, { full_pattern })
  end

  return results
end

---Generate watch patterns for file watching based on config
---@param config table The config containing path, project_root and env_file_patterns
---@return string[] List of watch patterns
function M.get_watch_patterns(config)
  local path = normalize_path(config.path, config)
  local patterns = config.env_file_patterns

  if not patterns or type(patterns) ~= "table" then
    local watch_patterns = {}
    for _, pattern in ipairs(DEFAULT_ENV_PATTERNS) do
      table.insert(watch_patterns, combine_path_pattern(path, pattern, config))
    end
    
    -- Add monorepo workspace patterns if in monorepo mode
    if config._monorepo_root then
      local monorepo_patterns = {}
      
      -- Add patterns for monorepo root and all workspaces
      for _, pattern in ipairs(DEFAULT_ENV_PATTERNS) do
        table.insert(monorepo_patterns, config._monorepo_root .. "/" .. pattern)
        table.insert(monorepo_patterns, config._monorepo_root .. "/**/" .. pattern)
      end
      
      -- Extend existing patterns with monorepo patterns
      for _, pattern in ipairs(monorepo_patterns) do
        table.insert(watch_patterns, pattern)
      end
    end
    
    return watch_patterns
  end

  local watch_patterns = {}
  local collect_fn = function(results, items)
    vim.list_extend(results, items)
  end

  for _, pattern in ipairs(patterns) do
    if type(pattern) == "string" then
      local pattern_results = process_pattern(pattern, path, config, collect_fn)
      vim.list_extend(watch_patterns, pattern_results)
    end
  end

  -- Add monorepo workspace patterns if in monorepo mode
  if config._monorepo_root then
    local monorepo_patterns = {}
    local base_patterns = patterns or DEFAULT_ENV_PATTERNS
    
    -- Add patterns for monorepo root and all workspaces
    for _, pattern in ipairs(base_patterns) do
      if type(pattern) == "string" then
        table.insert(monorepo_patterns, config._monorepo_root .. "/" .. pattern)
        table.insert(monorepo_patterns, config._monorepo_root .. "/**/" .. pattern)
      end
    end
    
    -- Extend existing patterns with monorepo patterns
    for _, pattern in ipairs(monorepo_patterns) do
      table.insert(watch_patterns, pattern)
    end
  end

  if #watch_patterns == 0 then
    return { path .. "/.env*" }
  end

  return watch_patterns
end

--[[ File Finding and Sorting ]]

---Find environment files based on provided options
---@param opts? {path?: string, project_root?: string|function, env_file_patterns?: string[], preferred_environment?: string, sort_file_fn?: function, sort_fn?: function}
---@return string[] List of found environment files
function M.find_env_files(opts)
  opts = opts or {}
  local path = normalize_path(opts.path, opts)

  local files = {}
  
  -- Handle monorepo workspace file discovery
  if opts._is_monorepo_workspace and opts._monorepo_root then
    local monorepo = require("ecolog.monorepo")
    local workspace = opts._workspace_info
    local root_path = opts._monorepo_root
    
    -- Get provider from detected info
    local provider = opts._detected_info and opts._detected_info.provider
    if not provider then
      -- Fall back to detecting provider
      local Detection = require("ecolog.monorepo.detection")
      _, provider = Detection.detect_monorepo(root_path)
    end
    
    if not provider then
      -- No provider found, fall back to default files
      files = M.find_env_files_in_path(opts.path, opts.env_file_patterns)
    else
      -- Get files using monorepo resolution strategy
      files = monorepo.resolve_env_files(workspace, root_path, provider, opts.env_file_patterns, opts)
    end
    
    -- Files are already sorted by resolve_env_files, just return them
    return files
  end
  
  -- Handle monorepo manual mode - collect files from all workspaces
  if opts._is_monorepo_manual_mode and opts._all_workspaces then
    local monorepo = require("ecolog.monorepo")
    local root_path = opts._monorepo_root
    
    -- Use provider-specific env_resolution if available, otherwise fall back to provider default
    local monorepo_config = {
      strategy = "workspace_first",
      inheritance = true
    }
    
    if type(opts.monorepo) == "table" and opts.monorepo.env_resolution then
      monorepo_config = opts.monorepo.env_resolution
    elseif opts._detected_info and opts._detected_info.provider and opts._detected_info.provider.env_resolution then
      monorepo_config = opts._detected_info.provider.env_resolution
    end
    
    local all_files = {}
    
    -- Iterate through all workspaces and collect environment files
    for _, workspace in ipairs(opts._all_workspaces) do
      local workspace_files = monorepo.resolve_env_files(workspace, root_path, monorepo_config, opts.env_file_patterns, opts)
      vim.list_extend(all_files, workspace_files)
    end
    
    -- Remove duplicates that might occur from overlapping workspace files
    local unique_files = {}
    local seen = {}
    for i = 1, #all_files do
      local file = all_files[i]
      if not seen[file] then
        seen[file] = true
        unique_files[#unique_files + 1] = file
      end
    end
    
    files = unique_files
    
    -- Sort and return
    return M.sort_env_files(files, opts)
  end
  
  -- Regular (non-monorepo) file discovery
  if not opts.env_file_patterns then
    local env_files = {}
    for _, pattern in ipairs(DEFAULT_ENV_PATTERNS) do
      local found = vim.fn.glob(combine_path_pattern(path, pattern, opts), false, true)
      if type(found) == "string" then
        found = { found }
      end
      vim.list_extend(env_files, found)
    end

    files = env_files
  else
    if type(opts.env_file_patterns) ~= "table" then
      vim.notify("env_file_patterns must be a table of glob patterns", vim.log.levels.WARN)
      return {}
    end

    local all_files = {}
    local collect_fn = function(results, items)
      for i = 1, #items do
        local item = items[i]
        local found = vim.fn.glob(item, false, true)
        if type(found) == "string" then
          found = { found }
        end
        if found and #found > 0 then
          vim.list_extend(all_files, found)
        end
      end
    end

    for _, pattern in ipairs(opts.env_file_patterns) do
      if type(pattern) == "string" then
        process_pattern(pattern, path, opts, collect_fn)
      end
    end

    files = all_files
  end

  -- Remove duplicates that might occur from overlapping patterns
  local unique_files = {}
  local seen = {}
  for i = 1, #files do
    local file = files[i]
    if not seen[file] then
      seen[file] = true
      unique_files[#unique_files + 1] = file
    end
  end

  return M.sort_env_files(unique_files, opts)
end

---Default sorting function for environment files
---@param a string First file path
---@param b string Second file path
---@param opts table Options containing preferred_environment and monorepo context
---@return boolean Whether a should come before b
local function default_sort_file_fn(a, b, opts)
  if not a or not b then
    return false
  end

  -- Preferred environment sorting (highest priority - same as non-monorepo)
  if opts and opts.preferred_environment and opts.preferred_environment ~= "" then
    local pref_pattern = "%." .. vim.pesc(opts.preferred_environment) .. "$"
    local a_is_preferred = a:match(pref_pattern) ~= nil
    local b_is_preferred = b:match(pref_pattern) ~= nil
    if a_is_preferred ~= b_is_preferred then
      return a_is_preferred
    end
  end

  -- Standard .env file priority (second priority - same as non-monorepo)
  local a_is_env = a:match(M.PATTERNS.env_file_combined) ~= nil
  local b_is_env = b:match(M.PATTERNS.env_file_combined) ~= nil
  if a_is_env ~= b_is_env then
    return a_is_env
  end

  -- Monorepo workspace-aware sorting (applied after preferred environment)
  if opts and opts._monorepo_root and opts._current_workspace_info then
    local current_workspace = opts._current_workspace_info
    local workspace_path = current_workspace.path
    
    local a_in_current = a:find(workspace_path, 1, true) == 1
    local b_in_current = b:find(workspace_path, 1, true) == 1
    
    -- Prioritize files from current workspace in manual mode
    if opts._is_monorepo_manual_mode and a_in_current ~= b_in_current then
      return a_in_current
    end
    
    -- In auto mode or when both files are from same workspace level,
    -- apply workspace type priority if configured
    local workspace_priority = nil
    if type(opts.monorepo) == "table" and opts.monorepo.workspace_priority then
      workspace_priority = opts.monorepo.workspace_priority
    elseif opts._detected_info and opts._detected_info.provider and opts._detected_info.provider.workspace_priority then
      workspace_priority = opts._detected_info.provider.workspace_priority
    end
    
    if workspace_priority then
      local function get_workspace_priority(file_path)
        if not opts._monorepo_root then return 999 end
        
        local relative_path = file_path:sub(#opts._monorepo_root + 2)
        local workspace_parts = vim.split(relative_path, "/")
        
        if #workspace_parts >= 1 then
          local workspace_type = workspace_parts[1]
          for i, priority_type in ipairs(workspace_priority) do
            if workspace_type == priority_type then
              return i
            end
          end
        end
        return 999
      end
      
      local a_priority = get_workspace_priority(a)
      local b_priority = get_workspace_priority(b)
      if a_priority ~= b_priority then
        return a_priority < b_priority
      end
    end
  end

  return a < b
end

---Sort environment files based on preferences
---@param files string[]|nil Files to sort
---@param opts? {preferred_environment?: string, sort_file_fn?: function, sort_fn?: function}
---@return string[] Sorted files
function M.sort_env_files(files, opts)
  if not files or #files == 0 then
    return {}
  end

  opts = opts or {}
  local sort_file_fn = opts.sort_file_fn

  if not sort_file_fn and opts.sort_fn then
    sort_file_fn = opts.sort_fn
  end

  sort_file_fn = sort_file_fn or default_sort_file_fn

  -- Filter out nil values more efficiently
  local valid_files = {}
  for i = 1, #files do
    local file = files[i]
    if file then
      valid_files[#valid_files + 1] = file
    end
  end
  files = valid_files

  table.sort(files, function(a, b)
    return sort_file_fn(a, b, opts)
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
  -- Validate input
  if not env_file or type(env_file) ~= "string" then
    vim.notify("Invalid environment file path provided", vim.log.levels.ERROR)
    return false
  end

  -- Check file readability
  if vim.fn.filereadable(env_file) == 0 then
    vim.notify("Environment file is not readable: " .. env_file, vim.log.levels.ERROR)
    return false
  end

  local f = io.open(env_file, "r")
  if not f then
    vim.notify("Could not open .env file: " .. env_file, vim.log.levels.ERROR)
    return false
  end

  local example_content = {}

  -- Use pcall to protect against file reading errors
  local read_success, read_err = pcall(function()
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
  end)

  -- Ensure input file is always closed
  local close_success, close_err = pcall(function()
    f:close()
  end)

  if not read_success then
    vim.notify("Error reading environment file: " .. tostring(read_err), vim.log.levels.ERROR)
    return false
  end

  if not close_success then
    vim.notify("Error closing environment file: " .. tostring(close_err), vim.log.levels.WARN)
  end

  local example_file = env_file:gsub("%.env$", "") .. ".env.example"

  -- Check if we can write to the directory
  local dir = vim.fn.fnamemodify(example_file, ":h")
  if vim.fn.isdirectory(dir) == 0 then
    vim.notify("Directory does not exist: " .. dir, vim.log.levels.ERROR)
    return false
  end

  local out = io.open(example_file, "w")
  if not out then
    vim.notify("Could not create .env.example file: " .. example_file, vim.log.levels.ERROR)
    return false
  end

  -- Use pcall to protect against file writing errors
  local write_success, write_err = pcall(function()
    out:write(table.concat(example_content, "\n"))
  end)

  -- Ensure output file is always closed
  local out_close_success, out_close_err = pcall(function()
    out:close()
  end)

  if not write_success then
    vim.notify("Error writing to example file: " .. tostring(write_err), vim.log.levels.ERROR)
    return false
  end

  if not out_close_success then
    vim.notify("Error closing example file: " .. tostring(out_close_err), vim.log.levels.WARN)
  end

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

---Optimized bulk file discovery for single path
---@param path string Directory path
---@param patterns string[] File patterns
---@return string[] files Found files
function M.find_env_files_in_path_bulk(path, patterns)
  if not patterns or #patterns == 0 then
    return {}
  end
  
  -- Use multiple glob operations but minimize them
  local all_files = {}
  
  -- Process patterns in batches to avoid vim.fn.glob issues
  for _, pattern in ipairs(patterns) do
    local search_pattern = path .. "/" .. pattern
    local found = vim.fn.glob(search_pattern, false, true)
    
    if type(found) == "string" then
      found = { found }
    end
    
    if found and #found > 0 then
      vim.list_extend(all_files, found)
    end
  end
  
  -- Remove duplicates efficiently
  local unique_files = {}
  local seen = {}
  for _, file in ipairs(all_files) do
    if not seen[file] then
      seen[file] = true
      table.insert(unique_files, file)
    end
  end
  
  return unique_files
end

---Optimized bulk file discovery for multiple workspaces
---@param workspaces table[] List of workspaces
---@param patterns string[] File patterns
---@return string[] files Found files
function M.find_env_files_bulk_workspaces(workspaces, patterns)
  if not workspaces or #workspaces == 0 or not patterns or #patterns == 0 then
    return {}
  end
  
  -- Collect all files from all workspaces
  local all_files = {}
  
  for _, workspace in ipairs(workspaces) do
    local workspace_path = workspace.path
    local workspace_files = M.find_env_files_in_path_bulk(workspace_path, patterns)
    vim.list_extend(all_files, workspace_files)
  end
  
  -- Remove duplicates efficiently
  local unique_files = {}
  local seen = {}
  for _, file in ipairs(all_files) do
    if not seen[file] then
      seen[file] = true
      table.insert(unique_files, file)
    end
  end
  
  return unique_files
end

return M
