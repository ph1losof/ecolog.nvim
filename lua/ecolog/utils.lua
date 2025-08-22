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
  env_file_combined = "^.+/%.env[%.%w]*$",
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

  if opts and opts._monorepo_root then
    local relative_path = file_path:sub(#opts._monorepo_root + 2)
    local workspace_parts = vim.split(relative_path, "/")

    if #workspace_parts >= 2 then
      local workspace_context = workspace_parts[1] .. "/" .. workspace_parts[2]
      display_name = string.format("%s (%s)", display_name, workspace_context)
    elseif #workspace_parts == 1 then
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

---Filter a list of files based on glob patterns
---@param files string[]|nil The files to filter
---@param patterns string[]|nil The glob patterns to match against
---@return string[] Filtered files
function M.filter_env_files(files, patterns)
  if not files then
    return {}
  end

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

  if pattern:match("[%^%$%(%)%+%|\\]") then
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
    -- Use vim regex escaping for exact patterns
    local escaped = pattern:gsub("([%.%[%]%(%)%+%-%^%$%*%?%\\])", "\\%1")
    return "^" .. escaped .. "$"
  elseif pattern_type == PATTERN_TYPES.EXTENDED_GLOB then
    return convert_extended_glob(pattern)
  elseif pattern_type == PATTERN_TYPES.REGEX then
    return pattern
  else
    -- For glob patterns, use vim.fn.glob2regpat but ensure proper anchoring
    local glob_pattern = vim.fn.glob2regpat(pattern)
    -- vim.fn.glob2regpat should handle the conversion properly
    return glob_pattern
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

    -- For directory patterns, always try glob matching first to handle path normalization
    if not pattern:find("**", 1, true) then
      local matches = vim.fn.glob(full_pattern, false, true)
      if matches and #matches > 0 then
        -- Normalize paths before comparison to handle symlinks like /var vs /private/var
        local normalized_filename = vim.fn.resolve(vim.fn.fnamemodify(filename, ":p"))
        for _, match in ipairs(matches) do
          local normalized_match = vim.fn.resolve(vim.fn.fnamemodify(match, ":p"))
          if normalized_filename == normalized_match then
            return true
          end
        end
      end
    else
      -- Handle ** patterns with regex matching
      local lua_pattern = convert_to_matching_pattern(full_pattern)
      return vim.fn.match(filename, lua_pattern) >= 0
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

    if config._monorepo_root then
      local monorepo_patterns = {}

      for _, pattern in ipairs(DEFAULT_ENV_PATTERNS) do
        table.insert(monorepo_patterns, config._monorepo_root .. "/" .. pattern)
        table.insert(monorepo_patterns, config._monorepo_root .. "/**/" .. pattern)
      end

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

  if config._monorepo_root then
    local monorepo_patterns = {}
    local base_patterns = patterns or DEFAULT_ENV_PATTERNS

    for _, pattern in ipairs(base_patterns) do
      if type(pattern) == "string" then
        table.insert(monorepo_patterns, config._monorepo_root .. "/" .. pattern)
        table.insert(monorepo_patterns, config._monorepo_root .. "/**/" .. pattern)
      end
    end

    for _, pattern in ipairs(monorepo_patterns) do
      table.insert(watch_patterns, pattern)
    end
  end

  if #watch_patterns == 0 then
    return { path .. "/.env*" }
  end

  return watch_patterns
end

---Find environment files based on provided options
---@param opts? {path?: string, project_root?: string|function, env_file_patterns?: string[], preferred_environment?: string, sort_file_fn?: function, sort_fn?: function}
---@return string[] List of found environment files
function M.find_env_files(opts)
  opts = opts or {}
  local path = normalize_path(opts.path, opts)

  local files = {}

  if opts._is_monorepo_workspace and opts._monorepo_root then
    local monorepo = require("ecolog.monorepo")
    local workspace = opts._workspace_info
    local root_path = opts._monorepo_root

    local provider = opts._detected_info and opts._detected_info.provider
    if not provider then
      local Detection = require("ecolog.monorepo.detection")
      _, provider = Detection.detect_monorepo(root_path)
    end

    if not provider then
      files = M.find_env_files_in_path(opts.path, opts.env_file_patterns)
    else
      files = monorepo.resolve_env_files(workspace, root_path, provider, opts.env_file_patterns, opts)
    end

    return files
  end

  if opts._is_monorepo_manual_mode and opts._all_workspaces then
    local monorepo = require("ecolog.monorepo")
    local root_path = opts._monorepo_root

    local monorepo_config = {
      strategy = "workspace_first",
      inheritance = true,
    }

    if type(opts.monorepo) == "table" and opts.monorepo.env_resolution then
      monorepo_config = opts.monorepo.env_resolution
    elseif opts._detected_info and opts._detected_info.provider and opts._detected_info.provider.env_resolution then
      monorepo_config = opts._detected_info.provider.env_resolution
    end

    local all_files = {}

    for _, workspace in ipairs(opts._all_workspaces) do
      local workspace_files =
        monorepo.resolve_env_files(workspace, root_path, monorepo_config, opts.env_file_patterns, opts)
      vim.list_extend(all_files, workspace_files)
    end

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

    return M.sort_env_files(files, opts)
  end

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

  -- Handle specific env file priorities (base files first, then specific ones)
  -- This ensures that when files are merged, more specific files override base files
  local a_base = a:match("%.env$") ~= nil
  local b_base = b:match("%.env$") ~= nil
  local a_specific = a:match("%.env%.%w+") ~= nil or a:match("%.env%.local") ~= nil
  local b_specific = b:match("%.env%.%w+") ~= nil or b:match("%.env%.local") ~= nil
  
  -- Base .env files should come before specific ones (so specific ones override)
  if a_base and b_specific then
    return true
  elseif a_specific and b_base then
    return false
  end
  
  -- Among specific files, prioritize .local files last (highest priority)
  if a_specific and b_specific then
    local a_local = a:match("%.env%.local") ~= nil
    local b_local = b:match("%.env%.local") ~= nil
    if a_local ~= b_local then
      return not a_local -- .local files come after others
    end
  end

  if opts and opts._monorepo_root and opts._current_workspace_info then
    local current_workspace = opts._current_workspace_info
    local workspace_path = current_workspace.path

    local a_in_current = a:find(workspace_path, 1, true) == 1
    local b_in_current = b:find(workspace_path, 1, true) == 1

    if opts._is_monorepo_manual_mode and a_in_current ~= b_in_current then
      return a_in_current
    end

    local workspace_priority = nil
    if type(opts.monorepo) == "table" and opts.monorepo.workspace_priority then
      workspace_priority = opts.monorepo.workspace_priority
    elseif opts._detected_info and opts._detected_info.provider and opts._detected_info.provider.workspace_priority then
      workspace_priority = opts._detected_info.provider.workspace_priority
    end

    if workspace_priority then
      local function get_workspace_priority(file_path)
        if not opts._monorepo_root then
          return 999
        end

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

---@class MultiLineState
---@field in_multi_line boolean Whether we're parsing a multi-line value
---@field key string The key being parsed
---@field value_lines string[] Lines accumulated for multi-line value
---@field comments string[] Comments accumulated for multi-line value
---@field quote_char string The quote character for multi-line parsing
---@field is_triple_quoted boolean Whether using triple-quoted syntax
---@field continuation_type string Type of continuation: 'quoted', 'backslash'

local ML_PATTERNS = {
  backslash_comment = "^(.-)\\%s*#%s*(.*)$",
  backslash_only = "^(.-)\\%s*$",
  comment_with_space = "#",
  leading_whitespace = "^%s*",
  trailing_whitespace = "%s*$",
}

---Extract parts from an environment file line with multi-line support
---@param line string The line to parse
---@param state MultiLineState? Optional state for multi-line parsing
---@return string|nil key The environment variable key
---@return string|nil value The environment variable value
---@return string|nil comment Any inline comment
---@return string|nil quote_char The quote character used (if any)
---@return MultiLineState|nil state Updated multi-line state
function M.extract_line_parts(line, state)
  state = state or {}

  if state.in_multi_line then
    return M.handle_multi_line_continuation(line, state)
  end

  if line:match("^%s*#") or line:match("^%s*$") then
    return nil, nil, nil, nil, state
  end

  local key, value = line:match("^%s*([^=]+)%s*=%s*(.-)%s*$")
  if not key or not value then
    return nil, nil, nil, nil, state
  end

  if value:match("\\%s*#") or value:match("\\%s*$") then
    local clean_value, comment = value:match(ML_PATTERNS.backslash_comment)
    if not clean_value then
      clean_value = value:match(ML_PATTERNS.backslash_only)
    end
    state.in_multi_line = true
    state.key = key
    state.value_lines = { clean_value }
    state.comments = comment and { comment } or {}
    state.quote_char = nil
    state.is_triple_quoted = false
    state.continuation_type = "backslash"
    return nil, nil, nil, nil, state
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
      return key, quoted_value, nil, first_char, state
    else
      state.in_multi_line = true
      state.key = key
      state.value_lines = { value:sub(2) }
      state.quote_char = first_char
      state.is_triple_quoted = false
      state.continuation_type = "quoted"
      return nil, nil, nil, nil, state
    end
  end

  local hash_pos = value:find("#")
  if hash_pos then
    if hash_pos > 1 and value:sub(hash_pos - 1, hash_pos - 1):match("%s") then
      local comment = value:sub(hash_pos + 1):match("^%s*(.-)%s*$")
      value = value:sub(1, hash_pos - 1):match("^%s*(.-)%s*$")
      return key, value, comment, nil, state
    end
  end

  return key, value, nil, nil, state
end

---Handle multi-line continuation parsing
---@param line string The current line
---@param state MultiLineState The current multi-line state
---@return string|nil key The environment variable key if complete
---@return string|nil value The environment variable value if complete
---@return string|nil comment Any inline comment
---@return string|nil quote_char The quote character used (if any)
---@return MultiLineState|nil state Updated multi-line state
function M.handle_multi_line_continuation(line, state)
  if state.continuation_type == "backslash" then
    if line:match("\\%s*#") or line:match("\\%s*$") then
      local clean_line, comment = line:match(ML_PATTERNS.backslash_comment)
      if not clean_line then
        clean_line = line:match(ML_PATTERNS.backslash_only)
      end
      table.insert(state.value_lines, clean_line)
      if comment then
        table.insert(state.comments, comment)
      end
      return nil, nil, nil, nil, state
    else
      local final_line = line
      local comment = nil
      local hash_pos = line:find("#")
      if hash_pos then
        if hash_pos > 1 and line:sub(hash_pos - 1, hash_pos - 1):match("%s") then
          comment = line:sub(hash_pos + 1):match("^%s*(.-)%s*$")
          final_line = line:sub(1, hash_pos - 1):match("^%s*(.-)%s*$")
        end
      end

      table.insert(state.value_lines, final_line)
      if comment then
        table.insert(state.comments, comment)
      end

      local final_value = table.concat(state.value_lines, "")
      local final_comment = state.comments and #state.comments > 0 and table.concat(state.comments, "\n") or nil

      local key = state.key

      state.in_multi_line = false
      state.key = nil
      state.value_lines = nil
      state.comments = nil
      state.quote_char = nil
      state.is_triple_quoted = false
      state.continuation_type = nil

      return key, final_value, final_comment, nil, state
    end
  elseif state.continuation_type == "quoted" then
    local end_quote_pos = line:find(state.quote_char)
    if end_quote_pos then
      local escaped = false
      if end_quote_pos > 1 then
        local escape_count = 0
        for i = end_quote_pos - 1, 1, -1 do
          if line:sub(i, i) == "\\" then
            escape_count = escape_count + 1
          else
            break
          end
        end
        escaped = escape_count % 2 == 1
      end

      if not escaped then
        local final_line = line:sub(1, end_quote_pos - 1)
        table.insert(state.value_lines, final_line)
        local final_value = table.concat(state.value_lines, "\n")

        local rest = line:sub(end_quote_pos + 1)
        local comment = rest:match("^%s*#%s*(.-)%s*$")

        local key = state.key
        local quote_char = state.quote_char

        state.in_multi_line = false
        state.key = nil
        state.value_lines = nil
        state.quote_char = nil
        state.is_triple_quoted = false
        state.continuation_type = nil

        return key, final_value, comment, quote_char, state
      end
    end

    table.insert(state.value_lines, line)
    return nil, nil, nil, nil, state
  end

  return nil, nil, nil, nil, state
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
  local value = line:sub(eq_pos + 1) -- Don't trim the value to preserve whitespace
  
  -- Handle edge cases:
  -- 1. Empty key (lines like "=value") - return nil
  if not key or key == "" then
    return nil, nil, nil
  end
  
  -- 2. Lines with only equals signs (like "=" or "===") - return nil
  if key:match("^=*$") then
    return nil, nil, nil
  end
  
  -- 3. Value can be empty string, nil, or contain content
  if value == nil then
    value = ""
  end

  return key, value, eq_pos
end

---Parse an environment file
---@param file_path string The path to the .env file
---@return table env_vars A table of environment variables with structure {key = {value = string, line = number}}
function M.parse_env_file(file_path)
  local env_vars = {}
  
  if not file_path or file_path == "" then
    return env_vars
  end
  
  -- Check if path exists and is a file
  local stat = vim.loop.fs_stat(file_path)
  if not stat then
    return env_vars
  end
  
  if stat.type ~= "file" then
    -- Return empty table for directories instead of throwing error
    return env_vars
  end
  
  local file = io.open(file_path, "r")
  if not file then
    return env_vars
  end
  
  -- Read entire file to handle different line endings
  local content = file:read("*all")
  file:close()
  
  if not content then
    return env_vars
  end
  
  -- Handle different line endings (CRLF, LF, CR) more robustly
  content = content:gsub("\r\n", "\n"):gsub("\r", "\n")
  
  -- Split lines more carefully to handle edge cases
  local lines = {}
  if content ~= "" then
    for line in (content .. "\n"):gmatch("([^\n]*)\n") do
      table.insert(lines, line)
    end
    -- Remove the extra empty line we might have added
    if #lines > 0 and lines[#lines] == "" and content:sub(-1) ~= "\n" then
      table.remove(lines)
    end
  end
  
  local line_number = 0
  local in_multiline = false
  local multiline_key = nil
  local multiline_value = {}
  local multiline_quote_char = nil
  local multiline_start_line = 0
  
  for _, line in ipairs(lines) do
    line_number = line_number + 1
    
    if in_multiline then
      -- Handle multiline quoted values more robustly
      local found_end_quote = false
      local i = 1
      while i <= #line do
        if line:sub(i, i) == multiline_quote_char then
          -- Check if it's escaped
          local escape_count = 0
          local j = i - 1
          while j >= 1 and line:sub(j, j) == "\\" do
            escape_count = escape_count + 1
            j = j - 1
          end
          
          -- If even number of backslashes (including 0), quote is not escaped
          if escape_count % 2 == 0 then
            found_end_quote = true
            table.insert(multiline_value, line:sub(1, i - 1))
            break
          end
        end
        i = i + 1
      end
      
      if found_end_quote then
        in_multiline = false
        local full_value = table.concat(multiline_value, "\n")
        -- Handle escape sequences more comprehensively
        full_value = M.process_escape_sequences(full_value)
        env_vars[multiline_key] = {
          value = full_value,
          line = multiline_start_line,
        }
        multiline_key = nil
        multiline_value = {}
        multiline_quote_char = nil
        multiline_start_line = 0
      else
        table.insert(multiline_value, line)
      end
    else
      local key, value = M.parse_env_line(line)
      
      if key and key ~= "" then
        -- Handle quoted values more robustly
        if value then
          local first_char = value:sub(1, 1)
          if first_char == '"' or first_char == "'" then
            -- Look for matching end quote
            local end_quote_pos = nil
            local i = 2
            while i <= #value do
              if value:sub(i, i) == first_char then
                -- Check if it's escaped
                local escape_count = 0
                local j = i - 1
                while j >= 1 and value:sub(j, j) == "\\" do
                  escape_count = escape_count + 1
                  j = j - 1
                end
                
                -- If even number of backslashes, quote is not escaped
                if escape_count % 2 == 0 then
                  end_quote_pos = i
                  break
                end
              end
              i = i + 1
            end
            
            if end_quote_pos then
              -- Complete quoted value on single line
              local quoted_value = value:sub(2, end_quote_pos - 1)
              quoted_value = M.process_escape_sequences(quoted_value)
              env_vars[key] = {
                value = quoted_value,
                line = line_number,
              }
            else
              -- No closing quote found - check if it contains a different quote character (mismatched)
              local other_quote = (first_char == '"') and "'" or '"'
              if value:find(other_quote) then
                -- Mismatched quotes - treat as unquoted but process escape sequences
                local unquoted_value = value:sub(2) -- Remove opening quote
                unquoted_value = M.process_escape_sequences(unquoted_value)
                env_vars[key] = {
                  value = unquoted_value,
                  line = line_number,
                }
              else
                -- Could be unclosed quote for single line or multiline
                -- Check if the next line looks like a new variable assignment
                local rest_of_value = value:sub(2)
                local should_be_multiline = false
                
                -- Check if there are more lines and if the next line doesn't look like a variable assignment
                if line_number < #lines then
                  local next_line = lines[line_number + 1]
                  -- If next line doesn't contain '=' or is empty/comment, might be multiline
                  if next_line and not next_line:match("^%s*$") and not next_line:match("^%s*#") and not next_line:find("=") then
                    should_be_multiline = true
                  end
                end
                
                if should_be_multiline then
                  -- Enter multiline mode
                  in_multiline = true
                  multiline_key = key
                  multiline_value = {rest_of_value} -- Remove opening quote
                  multiline_quote_char = first_char
                  multiline_start_line = line_number
                else
                  -- Treat as unclosed quote and remove the opening quote
                  local unquoted_value = rest_of_value
                  unquoted_value = M.process_escape_sequences(unquoted_value)
                  env_vars[key] = {
                    value = unquoted_value,
                    line = line_number,
                  }
                end
              end
            end
          else
            -- Unquoted value - preserve original but handle trailing whitespace consistently
            local trimmed_value = value
            -- Don't trim leading whitespace to preserve user intent, but trim trailing whitespace after comments
            local comment_pos = value:find("#")
            if comment_pos then
              -- Only trim if there's whitespace before the comment
              local before_comment = value:sub(1, comment_pos - 1)
              if before_comment:match("%s$") then
                trimmed_value = before_comment:match("^(.-)%s*$")
              end
            end
            
            env_vars[key] = {
              value = trimmed_value,
              line = line_number,
            }
          end
        else
          -- Empty value
          env_vars[key] = {
            value = "",
            line = line_number,
          }
        end
      end
    end
  end
  
  -- Handle case where file ends in middle of multiline value
  if in_multiline and multiline_key then
    local full_value = table.concat(multiline_value, "\n")
    full_value = M.process_escape_sequences(full_value)
    env_vars[multiline_key] = {
      value = full_value,
      line = multiline_start_line,
    }
  end
  
  return env_vars
end

---Process escape sequences in a string
---@param str string The string to process
---@return string The processed string
function M.process_escape_sequences(str)
  if not str then
    return ""
  end
  
  -- Handle escape sequences comprehensively
  -- NOTE: Order matters! Process \\ first, then other escapes
  local result = str
  result = result:gsub("\\\\", "\1") -- Temporary marker for escaped backslash
  result = result:gsub("\\n", "\n")
  result = result:gsub("\\t", "\t")
  result = result:gsub("\\r", "\r")
  result = result:gsub("\\v", "\v")
  result = result:gsub("\\f", "\f")
  result = result:gsub("\\a", "\a")
  result = result:gsub("\\b", "\b")
  result = result:gsub('\\"', '"')
  result = result:gsub("\\'", "'")
  result = result:gsub("\1", "\\") -- Restore escaped backslashes
  
  return result
end

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
  if line:match("=") then
    return line:match("^(.-)%s*=")
  end

  local var_name = line:match("^%s*([^%s]+)")
  return var_name
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

---Generate an example environment file
---@param env_file string Path to the source .env file
---@return boolean success Whether the file was generated successfully
function M.generate_example_file(env_file)
  if not env_file or type(env_file) ~= "string" then
    vim.notify("Invalid environment file path provided", vim.log.levels.ERROR)
    return false
  end

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

  local write_success, write_err = pcall(function()
    out:write(table.concat(example_content, "\n"))
  end)

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

  local all_files = {}

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

  local all_files = {}

  for _, workspace in ipairs(workspaces) do
    local workspace_path = workspace.path
    local workspace_files = M.find_env_files_in_path_bulk(workspace_path, patterns)
    vim.list_extend(all_files, workspace_files)
  end

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
