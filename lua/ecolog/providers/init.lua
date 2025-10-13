local M = {}

M.providers = setmetatable({}, {
  __index = function(t, k)
    t[k] = {}
    return t[k]
  end,
})

local _provider_cache = {}
local _provider_loading = {}

M.filetype_map = {
  typescript = { "typescript", "typescriptreact" },
  javascript = { "javascript", "javascriptreact" },
  python = { "python" },
  php = { "php" },
  lua = { "lua" },
  go = { "go" },
  rust = { "rust" },
  java = { "java" },
  csharp = { "cs", "csharp" },
  ruby = { "ruby" },
  shell = { "sh", "bash", "zsh" },
  kotlin = { "kotlin", "kt" },
}

local _filetype_provider_map = {}
for provider, filetypes in pairs(M.filetype_map) do
  for _, ft in ipairs(filetypes) do
    _filetype_provider_map[ft] = provider
  end
end

local function load_provider(name)
  -- Validate input
  if not name or type(name) ~= "string" or name == "" then
    vim.notify("Invalid provider name: " .. tostring(name), vim.log.levels.ERROR)
    return nil
  end

  -- Sanitize provider name to prevent path traversal
  local sanitized_name = name:gsub("[^%w_%-]", "")
  if sanitized_name ~= name then
    vim.notify("Provider name contains invalid characters, sanitized: " .. name, vim.log.levels.WARN)
    name = sanitized_name
  end

  if _provider_cache[name] then
    return _provider_cache[name]
  end

  if _provider_loading[name] then
    vim.notify("Circular dependency detected in provider loading: " .. name, vim.log.levels.WARN)
    return nil
  end

  local module_path = "ecolog.providers." .. name
  _provider_loading[name] = true
  local ok, provider = pcall(require, module_path)
  _provider_loading[name] = nil

  if ok then
    -- Validate provider structure
    if not provider or type(provider) ~= "table" then
      vim.notify("Invalid provider structure from: " .. name, vim.log.levels.ERROR)
      return nil
    end

    _provider_cache[name] = provider
    return provider
  else
    vim.notify("Failed to load provider: " .. name .. " - " .. tostring(provider), vim.log.levels.ERROR)
  end
  return nil
end

function M.load_providers_for_filetype(filetype)
  -- Validate input - empty filetype is normal for some buffers, so don't log as error
  if not filetype or type(filetype) ~= "string" or filetype == "" then
    return
  end

  local provider_name = _filetype_provider_map[filetype]
  if not provider_name then
    -- This is normal, not all filetypes have providers
    return
  end

  local provider = load_provider(provider_name)
  if not provider then
    vim.notify("Failed to load provider: " .. provider_name, vim.log.levels.WARN)
    return
  end

  -- Use pcall to protect against provider registration errors
  local success, err = pcall(function()
    if type(provider) == "table" then
      if provider.provider then
        -- Single provider wrapped in .provider field
        M.register(provider.provider)
      else
        -- Multiple providers or single provider table
        if #provider > 0 then
          -- Array of providers
          M.register_many(provider)
        else
          -- Single provider table
          M.register(provider)
        end
      end
    else
      vim.notify("Provider has invalid structure: " .. provider_name, vim.log.levels.ERROR)
    end
  end)

  if not success then
    vim.notify("Failed to register provider " .. provider_name .. ": " .. tostring(err), vim.log.levels.ERROR)
  end
end

local _pattern_cache = setmetatable({}, {
  __mode = "k",
})

-- Cache size limit to prevent memory leaks
local MAX_CACHE_SIZE = 100
local _cache_size = 0

-- Add cache cleanup function
function M.cleanup_cache()
  _provider_cache = {}
  _pattern_cache = setmetatable({}, { __mode = "k" })
  _cache_size = 0
end

-- Improved cache cleanup with selective retention
function M.cleanup_cache_selective()
  -- Keep essential providers in cache
  local essential_providers = {
    "lua",
  }

  local new_cache = {}
  for _, provider_name in ipairs(essential_providers) do
    if _provider_cache[provider_name] then
      new_cache[provider_name] = _provider_cache[provider_name]
    end
  end

  _provider_cache = new_cache
  _pattern_cache = setmetatable({}, { __mode = "k" })
  _cache_size = #essential_providers
end

-- Add cache size monitoring
local function check_cache_size()
  _cache_size = _cache_size + 1
  if _cache_size > MAX_CACHE_SIZE then
    vim.notify("Provider cache size limit exceeded, clearing cache", vim.log.levels.WARN)
    M.cleanup_cache_selective()
  end
end

-- Safe wrapper for provider function execution
local function safe_provider_call(provider, func_name, ...)
  if not provider then
    return nil
  end

  local func = provider[func_name]
  if not func or type(func) ~= "function" then
    return nil
  end

  local success, result = pcall(func, ...)
  if not success then
    vim.notify("Provider " .. func_name .. " failed: " .. tostring(result), vim.log.levels.ERROR)
    return nil
  end

  return result
end

---@class PatternSpec
---@field trigger string The completion trigger (e.g., "process.env.")
---@field pattern string The base pattern for matching (e.g., "process%.env%.")
---@field var_pattern string The variable capture pattern (e.g., "([%w_]+)")
---@field end_boundary string? Optional end boundary pattern (e.g., ")", "]", word boundary)
---@field filetype string|string[] Filetype(s) for this pattern

--- Create a unified pattern that works for both extraction and completion
--- This eliminates the need to define separate patterns for each use case
---@param spec PatternSpec Pattern specification
---@return table complete_provider Provider for complete expressions (peek/detection)
---@return table partial_provider Provider for partial expressions (completion)
local function create_pattern_pair(spec)
  local utils = require("ecolog.utils")

  if not spec or type(spec) ~= "table" then
    error("Pattern spec must be a table")
  end
  if not spec.trigger or not spec.pattern or not spec.var_pattern then
    error("Pattern spec must have trigger, pattern, and var_pattern fields")
  end

  local complete_pattern = spec.pattern .. spec.var_pattern
  if spec.end_boundary then
    complete_pattern = complete_pattern .. spec.end_boundary
  end

  local partial_var_pattern = spec.var_pattern:gsub("%+", "*")
  local partial_pattern = spec.pattern .. partial_var_pattern .. "$"

  local extract_pattern_complete = spec.pattern .. spec.var_pattern
  if spec.end_boundary then
    extract_pattern_complete = extract_pattern_complete .. spec.end_boundary
  end
  local extract_pattern_partial = spec.pattern .. partial_var_pattern

  local capture_pattern = spec.pattern .. "(" .. spec.var_pattern:gsub("[()]", "") .. ")"
  if spec.end_boundary then
    capture_pattern = capture_pattern .. spec.end_boundary
  end
  local trigger_len = #spec.trigger

  local complete_provider = {
    pattern = complete_pattern,
    filetype = spec.filetype,
    extract_var = function(line, col)
      local cursor_pos = col + 1

      local search_pos = 1
      while search_pos <= #line do
        local match_start, match_end, var_name = line:find(capture_pattern, search_pos)
        if not match_start or not var_name then
          break
        end

        local var_start = match_start + trigger_len
        local var_end = var_start + (#var_name - 1)

        if cursor_pos >= var_start and cursor_pos <= var_end then
          return var_name
        end

        search_pos = match_end + 1
      end

      return nil
    end,
  }

  local partial_provider = {
    pattern = partial_pattern,
    filetype = spec.filetype,
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, extract_pattern_partial .. "$")
    end,
    get_completion_trigger = function()
      return spec.trigger
    end,
  }

  return complete_provider, partial_provider
end

--- Helper to create patterns for function call syntax: func("VAR") or func('VAR')
---@param func_name string Function name (e.g., "os.getenv")
---@param filetype string|string[] Filetype(s)
---@param quote_char string Quote character: '"', "'", or "both"
---@return table[] providers Array of providers
function M.create_function_call_patterns(func_name, filetype, quote_char)
  local providers = {}
  local escaped_func = func_name:gsub("%.", "%%.")

  local quotes = quote_char == "both" and { '"', "'" } or { quote_char }

  for _, q in ipairs(quotes) do
    local complete, partial = create_pattern_pair({
      trigger = func_name .. "(" .. q,
      pattern = escaped_func .. "%(" .. q,
      var_pattern = "([%w_]+)",
      end_boundary = q .. "%)",
      filetype = filetype,
    })
    table.insert(providers, complete)
    table.insert(providers, partial)
  end

  return providers
end

--- Helper to create patterns for bracket notation: obj["VAR"] or obj['VAR']
---@param obj_name string Object name (e.g., "process.env")
---@param filetype string|string[] Filetype(s)
---@param quote_char string Quote character: '"', "'", or "both"
---@return table[] providers Array of providers
function M.create_bracket_patterns(obj_name, filetype, quote_char)
  local providers = {}
  local escaped_obj = obj_name:gsub("%.", "%%.")

  local quotes = quote_char == "both" and { '"', "'" } or { quote_char }

  for _, q in ipairs(quotes) do
    local complete, partial = create_pattern_pair({
      trigger = obj_name .. "[" .. q,
      pattern = escaped_obj .. "%[" .. q,
      var_pattern = "([%w_]+)",
      end_boundary = q .. "%]",
      filetype = filetype,
    })
    table.insert(providers, complete)
    table.insert(providers, partial)
  end

  return providers
end

--- Helper to create patterns for dot notation: obj.VAR
---@param obj_name string Object name (e.g., "process.env")
---@param filetype string|string[] Filetype(s)
---@return table[] providers Array of providers
function M.create_dot_notation_patterns(obj_name, filetype)
  local escaped_obj = obj_name:gsub("%.", "%%.")

  local complete, partial = create_pattern_pair({
    trigger = obj_name .. ".",
    pattern = escaped_obj .. "%.",
    var_pattern = "([%w_]+)",
    end_boundary = nil, -- Word boundary is implicit in [%w_]+
    filetype = filetype,
  })

  return { complete, partial }
end

-- Wrap provider functions with error boundaries
local function wrap_provider_with_error_boundaries(provider)
  if not provider or type(provider) ~= "table" then
    return provider
  end

  local wrapped = {}

  -- Copy all properties
  for k, v in pairs(provider) do
    wrapped[k] = v
  end

  -- Wrap extract_var function
  if provider.extract_var then
    wrapped.extract_var = function(...)
      return safe_provider_call(provider, "extract_var", ...)
    end
  end

  -- Wrap get_completion_trigger function
  if provider.get_completion_trigger then
    wrapped.get_completion_trigger = function(...)
      return safe_provider_call(provider, "get_completion_trigger", ...)
    end
  end

  return wrapped
end

function M.register(provider)
  -- Comprehensive provider validation
  if not provider or type(provider) ~= "table" then
    vim.notify("Provider must be a table", vim.log.levels.ERROR)
    return false
  end

  local cache_key = provider
  if _pattern_cache[cache_key] ~= nil then
    return _pattern_cache[cache_key]
  end

  -- Validate required fields
  if not provider.pattern or type(provider.pattern) ~= "string" or provider.pattern == "" then
    vim.notify("Provider must have a valid pattern string", vim.log.levels.ERROR)
    _pattern_cache[cache_key] = false
    return false
  end

  if not provider.filetype then
    vim.notify("Provider must have a filetype", vim.log.levels.ERROR)
    _pattern_cache[cache_key] = false
    return false
  end

  if not provider.extract_var or type(provider.extract_var) ~= "function" then
    vim.notify("Provider must have an extract_var function", vim.log.levels.ERROR)
    _pattern_cache[cache_key] = false
    return false
  end

  -- Validate optional fields
  if provider.get_completion_trigger and type(provider.get_completion_trigger) ~= "function" then
    vim.notify("Provider get_completion_trigger must be a function", vim.log.levels.WARN)
  end

  -- Validate pattern complexity to prevent ReDoS
  local pattern_length = #provider.pattern
  if pattern_length > 1000 then
    vim.notify("Provider pattern is too long (>1000 chars), potential ReDoS risk", vim.log.levels.ERROR)
    _pattern_cache[cache_key] = false
    return false
  end

  -- Check for dangerous pattern constructs
  if provider.pattern:find("%(.*%*.*%*.*%)") or provider.pattern:find("%(.*%+.*%+.*%)") then
    vim.notify("Provider pattern contains potentially dangerous constructs", vim.log.levels.WARN)
  end

  -- Validate and normalize filetypes
  local filetypes = type(provider.filetype) == "string" and { provider.filetype } or provider.filetype

  if type(filetypes) ~= "table" then
    vim.notify("Provider filetype must be a string or table", vim.log.levels.ERROR)
    _pattern_cache[cache_key] = false
    return false
  end

  -- Validate each filetype
  for _, ft in ipairs(filetypes) do
    if not ft or type(ft) ~= "string" or ft == "" then
      vim.notify("Invalid filetype in provider: " .. tostring(ft), vim.log.levels.ERROR)
      _pattern_cache[cache_key] = false
      return false
    end

    -- Sanitize filetype
    local sanitized_ft = ft:gsub("[^%w_%-]", "")
    if sanitized_ft ~= ft then
      vim.notify("Filetype contains invalid characters: " .. ft, vim.log.levels.WARN)
      ft = sanitized_ft
    end

    -- Wrap provider with error boundaries before registering
    local wrapped_provider = wrap_provider_with_error_boundaries(provider)

    -- Register provider for this filetype
    M.providers[ft] = M.providers[ft] or {}
    table.insert(M.providers[ft], wrapped_provider)
  end

  _pattern_cache[cache_key] = true
  check_cache_size()
  return true
end

function M.register_many(providers)
  if not providers or type(providers) ~= "table" then
    vim.notify("Providers must be a table", vim.log.levels.ERROR)
    return false
  end

  local success_count = 0
  local total_count = 0

  for _, provider in ipairs(providers) do
    total_count = total_count + 1

    local success, result = pcall(M.register, provider)
    if success and result then
      success_count = success_count + 1
    else
      vim.notify("Failed to register provider " .. total_count .. ": " .. tostring(result), vim.log.levels.ERROR)
    end
  end

  --[[ if success_count > 0 then
    vim.notify("Successfully registered " .. success_count .. "/" .. total_count .. " providers", vim.log.levels.DEBUG)
  end
]]
  return success_count == total_count
end

function M.get_providers(filetype)
  -- Validate input - empty filetype is normal for some buffers, so don't log as error
  if not filetype or type(filetype) ~= "string" or filetype == "" then
    return {}
  end

  -- Sanitize filetype
  local sanitized_ft = filetype:gsub("[^%w_%-]", "")
  if sanitized_ft ~= filetype then
    vim.notify("Filetype contains invalid characters: " .. filetype, vim.log.levels.WARN)
    filetype = sanitized_ft
  end

  -- Load providers if not already loaded
  if not M.providers[filetype] or #M.providers[filetype] == 0 then
    local success, err = pcall(M.load_providers_for_filetype, filetype)
    if not success then
      vim.notify("Failed to load providers for filetype " .. filetype .. ": " .. tostring(err), vim.log.levels.ERROR)
      return {}
    end
  end

  -- Return providers or empty table if none found
  return M.providers[filetype] or {}
end

-- Public function to safely execute provider functions
function M.safe_execute_provider(provider, func_name, ...)
  return safe_provider_call(provider, func_name, ...)
end

-- Function to test if a provider is valid and functional
function M.test_provider(provider)
  if not provider or type(provider) ~= "table" then
    return false, "Provider is not a table"
  end

  -- Test required fields
  if not provider.pattern or type(provider.pattern) ~= "string" then
    return false, "Invalid pattern"
  end

  if not provider.filetype then
    return false, "Missing filetype"
  end

  if not provider.extract_var or type(provider.extract_var) ~= "function" then
    return false, "Missing extract_var function"
  end

  -- Test extract_var function with safe inputs
  local success, result = pcall(provider.extract_var, "test_line", 5)
  if not success then
    return false, "extract_var function failed: " .. tostring(result)
  end

  -- Test get_completion_trigger if present
  if provider.get_completion_trigger then
    if type(provider.get_completion_trigger) ~= "function" then
      return false, "get_completion_trigger is not a function"
    end

    local trigger_success, trigger_result = pcall(provider.get_completion_trigger)
    if not trigger_success then
      return false, "get_completion_trigger failed: " .. tostring(trigger_result)
    end
  end

  return true, "Provider is valid"
end

return M
