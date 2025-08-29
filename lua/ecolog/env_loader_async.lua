---@class AsyncEnvLoader
local AsyncEnvLoader = {}

local types = require("ecolog.types")
local interpolation = require("ecolog.interpolation")
local utils = require("ecolog.utils")
local FileOperations = require("ecolog.core.file_operations")

-- Simplified parsing cache with automatic cleanup
local _parse_cache = {}
local _cache_timestamps = {}
local MAX_CACHE_SIZE = 1000
local CACHE_TTL = 300000 -- 5 minutes

---Parse environment files in parallel using FileOperations
---@param file_paths string[] Array of file paths to parse
---@param opts table Configuration options
---@param callback function Callback function(results, errors)
function AsyncEnvLoader.parse_env_files_parallel(file_paths, opts, callback)
  opts = opts or {}

  if not file_paths or #file_paths == 0 then
    callback({}, {})
    return
  end

  -- Use FileOperations for batch reading
  FileOperations.read_files_batch(file_paths, function(file_contents, read_errors)
    local results = {}
    local all_errors = read_errors

    -- Parse each file's content
    for file_path, content in pairs(file_contents) do
      local success, parsed_vars = pcall(AsyncEnvLoader._parse_single_file, file_path, content, opts)

      if success then
        results[file_path] = parsed_vars
      else
        all_errors[file_path] = tostring(parsed_vars)
      end
    end

    callback(results, all_errors)
  end)
end

---Parse a single environment file with intelligent caching
---@param file_path string Path to the environment file
---@param content string[] Lines of the file
---@param opts table Configuration options
---@return table<string, EnvVarInfo> parsed_vars
function AsyncEnvLoader._parse_single_file(file_path, content, opts)
  -- Check cache first using file modification time
  local mtime = FileOperations.get_mtime(file_path)
  local cache_key = file_path .. ":" .. mtime

  if _parse_cache[cache_key] and AsyncEnvLoader._is_cache_valid(cache_key) then
    return _parse_cache[cache_key]
  end

  local env_vars = {}

  -- Parse lines efficiently
  for i = 1, #content do
    local line = content[i]

    -- Skip empty lines and comments quickly
    if line ~= "" and not line:match("^%s*#") and not line:match("^%s*$") then
      local key, value, comment, quote_char = utils.extract_line_parts(line)

      if key and value then
        local type_name, transformed_value = types.detect_type(value)

        -- Use explicit nil check to handle boolean false correctly
        local final_value = value
        if transformed_value ~= nil then
          final_value = transformed_value
        end

        env_vars[key] = {
          value = final_value,
          type = type_name,
          raw_value = value,
          source = file_path,
          source_file = vim.fn.fnamemodify(file_path, ":t"),
          comment = comment,
          quote_char = quote_char,
        }
      end
    end
  end

  -- Apply interpolation if enabled
  if opts.interpolation and opts.interpolation.enabled then
    AsyncEnvLoader._apply_interpolation(env_vars, opts.interpolation)
  end

  -- Cache the result
  AsyncEnvLoader._cache_result(cache_key, env_vars)

  return env_vars
end

---Apply interpolation to environment variables
---@param env_vars table<string, EnvVarInfo> Environment variables
---@param interpolation_opts table Interpolation configuration
function AsyncEnvLoader._apply_interpolation(env_vars, interpolation_opts)
  for key, var_info in pairs(env_vars) do
    if var_info.quote_char ~= "'" then
      local interpolated_value = interpolation.interpolate(var_info.raw_value, env_vars, interpolation_opts)
      if interpolated_value ~= var_info.raw_value then
        local type_name, transformed_value = types.detect_type(interpolated_value)
        local final_value = interpolated_value
        if transformed_value ~= nil then
          final_value = transformed_value
        end
        
        env_vars[key] = {
          value = final_value,
          type = type_name,
          raw_value = var_info.raw_value,
          source = var_info.source,
          source_file = var_info.source_file,
          comment = var_info.comment,
          quote_char = var_info.quote_char,
        }
      end
    end
  end
end

---Check if cache entry is still valid
---@param cache_key string Cache key
---@return boolean valid Whether the cache entry is valid
function AsyncEnvLoader._is_cache_valid(cache_key)
  local timestamp = _cache_timestamps[cache_key]
  if not timestamp then
    return false
  end

  return (vim.loop.now() - timestamp) < CACHE_TTL
end

---Cache result with automatic cleanup
---@param cache_key string Cache key
---@param env_vars table Parsed environment variables
function AsyncEnvLoader._cache_result(cache_key, env_vars)
  -- Clean up expired entries if cache is getting large
  if vim.tbl_count(_parse_cache) >= MAX_CACHE_SIZE then
    AsyncEnvLoader._cleanup_cache()
  end

  _parse_cache[cache_key] = env_vars
  _cache_timestamps[cache_key] = vim.loop.now()
end

---Clean up expired cache entries
function AsyncEnvLoader._cleanup_cache()
  local current_time = vim.loop.now()
  local expired_keys = {}

  for key, timestamp in pairs(_cache_timestamps) do
    if (current_time - timestamp) > CACHE_TTL then
      table.insert(expired_keys, key)
    end
  end

  for _, key in ipairs(expired_keys) do
    _parse_cache[key] = nil
    _cache_timestamps[key] = nil
  end
end

---Load environment variables from multiple files with priority
---@param file_paths string[] Array of file paths in priority order
---@param opts table Configuration options
---@param callback function Callback function(env_vars, errors)
function AsyncEnvLoader.load_env_vars_with_priority(file_paths, opts, callback)
  opts = opts or {}

  if not file_paths or #file_paths == 0 then
    callback({}, {})
    return
  end

  -- Parse files in parallel
  AsyncEnvLoader.parse_env_files_parallel(file_paths, opts, function(parsed_results, errors)
    local final_env_vars = {}

    -- Merge results according to file priority (first file wins)
    for _, file_path in ipairs(file_paths) do
      local parsed_vars = parsed_results[file_path]
      if parsed_vars then
        for key, var_info in pairs(parsed_vars) do
          if not final_env_vars[key] then
            final_env_vars[key] = var_info
          end
        end
      end
    end

    callback(final_env_vars, errors)
  end)
end

---Determine if a variable should be overridden
---@param existing_var table Existing variable info
---@param new_var table New variable info
---@param opts table Configuration options
---@return boolean should_override
function AsyncEnvLoader._should_override(existing_var, new_var, opts)
  -- Workspace files override root files by default
  if opts.workspace_override ~= false then
    return true
  end

  -- Check file priority based on name
  local existing_file = existing_var.source_file
  local new_file = new_var.source_file

  -- .env files have highest priority
  if new_file == ".env" and existing_file ~= ".env" then
    return true
  end

  -- Preferred environment files have priority
  if opts.preferred_environment then
    local pref_pattern = "%." .. vim.pesc(opts.preferred_environment) .. "$"
    local new_is_preferred = new_file:match(pref_pattern) ~= nil
    local existing_is_preferred = existing_file:match(pref_pattern) ~= nil

    if new_is_preferred and not existing_is_preferred then
      return true
    end
  end

  return false
end

---Clear parse cache
function AsyncEnvLoader.clear_cache()
  _parse_cache = {}
  _cache_timestamps = {}
end

---Get cache statistics
---@return table stats
function AsyncEnvLoader.get_cache_stats()
  return {
    cache_size = vim.tbl_count(_parse_cache),
    max_cache_size = MAX_CACHE_SIZE,
    cache_ttl = CACHE_TTL,
    expired_entries = AsyncEnvLoader._count_expired_entries(),
  }
end

---Count expired cache entries
---@return number count
function AsyncEnvLoader._count_expired_entries()
  local current_time = vim.loop.now()
  local expired_count = 0

  for _, timestamp in pairs(_cache_timestamps) do
    if (current_time - timestamp) > CACHE_TTL then
      expired_count = expired_count + 1
    end
  end

  return expired_count
end

return AsyncEnvLoader

