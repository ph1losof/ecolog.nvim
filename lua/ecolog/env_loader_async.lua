---@class AsyncEnvLoader
local AsyncEnvLoader = {}

local types = require("ecolog.types")
local interpolation = require("ecolog.interpolation")
local utils = require("ecolog.utils")

-- Performance optimized parsing cache
local _parse_cache = {}
local _parse_cache_size = 0
local MAX_PARSE_CACHE_SIZE = 10000

---Parse environment file content in parallel
---@param file_content table Map of file_path to content lines
---@param opts table Configuration options
---@param callback function Callback function(results, errors)
function AsyncEnvLoader.parse_env_files_parallel(file_content, opts, callback)
  opts = opts or {}
  
  local results = {}
  local errors = {}
  local completed = 0
  local total = 0
  
  -- Count total files
  for _ in pairs(file_content) do
    total = total + 1
  end
  
  if total == 0 then
    callback({}, {})
    return
  end
  
  -- Parse each file concurrently
  for file_path, content in pairs(file_content) do
    vim.defer_fn(function()
      local success, parsed_vars = pcall(AsyncEnvLoader._parse_single_file, file_path, content, opts)
      
      if success then
        results[file_path] = parsed_vars
      else
        errors[file_path] = tostring(parsed_vars)
      end
      
      completed = completed + 1
      
      if completed == total then
        vim.schedule(function()
          callback(results, errors)
        end)
      end
    end, 0)
  end
end

---Parse a single environment file with optimized caching
---@param file_path string Path to the environment file
---@param content string[] Lines of the file
---@param opts table Configuration options
---@return table<string, EnvVarInfo> parsed_vars
function AsyncEnvLoader._parse_single_file(file_path, content, opts)
  local env_vars = {}
  local file_hash = AsyncEnvLoader._hash_content(content)
  
  -- Check cache first
  local cache_key = file_path .. ":" .. file_hash
  if _parse_cache[cache_key] then
    return _parse_cache[cache_key]
  end
  
  -- Parse lines efficiently
  for i = 1, #content do
    local line = content[i]
    
    -- Skip empty lines and comments quickly
    if line ~= "" and not line:match("^%s*#") then
      local key, value, comment, quote_char = utils.extract_line_parts(line)
      
      if key and value then
        local type_name, transformed_value = types.detect_type(value)
        
        env_vars[key] = {
          value = transformed_value or value,
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
    for key, var_info in pairs(env_vars) do
      if var_info.quote_char ~= "'" then
        local interpolated_value = interpolation.interpolate(var_info.raw_value, env_vars, opts.interpolation)
        if interpolated_value ~= var_info.raw_value then
          local type_name, transformed_value = types.detect_type(interpolated_value)
          env_vars[key] = {
            value = transformed_value or interpolated_value,
            type = type_name,
            raw_value = var_info.raw_value,
            source = var_info.source,
            comment = var_info.comment,
            quote_char = var_info.quote_char,
          }
        end
      end
    end
  end
  
  -- Cache the result with size limit
  AsyncEnvLoader._cache_parsed_result(cache_key, env_vars)
  
  return env_vars
end

---Hash content for caching
---@param content string[] Lines of content
---@return string hash
function AsyncEnvLoader._hash_content(content)
  local hash_str = table.concat(content, "\n")
  return tostring(hash_str:len()) .. ":" .. hash_str:sub(1, 50)
end

---Cache parsed result with size management
---@param cache_key string Cache key
---@param env_vars table Parsed environment variables
function AsyncEnvLoader._cache_parsed_result(cache_key, env_vars)
  -- Simple LRU-style cache management
  if _parse_cache_size >= MAX_PARSE_CACHE_SIZE then
    -- Clear half the cache
    local keys_to_remove = {}
    local count = 0
    local threshold = MAX_PARSE_CACHE_SIZE / 2
    
    for key in pairs(_parse_cache) do
      if count >= threshold then
        break
      end
      table.insert(keys_to_remove, key)
      count = count + 1
    end
    
    for _, key in ipairs(keys_to_remove) do
      _parse_cache[key] = nil
    end
    
    _parse_cache_size = _parse_cache_size - #keys_to_remove
  end
  
  _parse_cache[cache_key] = env_vars
  _parse_cache_size = _parse_cache_size + 1
end

---Optimized monorepo environment loading
---@param workspace_files table Map of workspace_path to env_files
---@param opts table Configuration options
---@param callback function Callback function(env_vars, errors)
function AsyncEnvLoader.load_monorepo_env_vars(workspace_files, opts, callback)
  opts = opts or {}
  
  -- Collect all unique files
  local all_files = {}
  local file_to_workspaces = {}
  
  for workspace_path, files in pairs(workspace_files) do
    for _, file_path in ipairs(files) do
      if not all_files[file_path] then
        all_files[file_path] = true
        file_to_workspaces[file_path] = {}
      end
      table.insert(file_to_workspaces[file_path], workspace_path)
    end
  end
  
  -- Convert to array
  local file_paths = {}
  for file_path in pairs(all_files) do
    table.insert(file_paths, file_path)
  end
  
  -- Load files in parallel
  local BulkResolver = require("ecolog.monorepo.workspace.bulk_resolver")
  BulkResolver.parallel_load_env_files(file_paths, function(file_contents, load_errors)
    -- Parse all files in parallel
    AsyncEnvLoader.parse_env_files_parallel(file_contents, opts, function(parsed_results, parse_errors)
      -- Merge results according to workspace resolution strategy
      local final_env_vars = {}
      local all_errors = {}
      
      -- Combine errors
      for file_path, error_msg in pairs(load_errors) do
        all_errors[file_path] = "Load error: " .. error_msg
      end
      
      for file_path, error_msg in pairs(parse_errors) do
        all_errors[file_path] = "Parse error: " .. error_msg
      end
      
      -- Merge parsed results by workspace priority
      for workspace_path, files in pairs(workspace_files) do
        for _, file_path in ipairs(files) do
          local parsed_vars = parsed_results[file_path]
          if parsed_vars then
            -- Apply workspace-specific merging strategy
            for key, var_info in pairs(parsed_vars) do
              if not final_env_vars[key] or AsyncEnvLoader._should_override(final_env_vars[key], var_info, opts) then
                final_env_vars[key] = var_info
              end
            end
          end
        end
      end
      
      callback(final_env_vars, all_errors)
    end)
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

---Stream-based environment variable loading for real-time updates
---@param file_paths string[] Array of file paths
---@param opts table Configuration options
---@param on_update function Called for each processed file
---@param on_complete function Called when all files are processed
function AsyncEnvLoader.stream_load_env_vars(file_paths, opts, on_update, on_complete)
  local total_processed = 0
  local total_files = #file_paths
  local accumulated_vars = {}
  
  if total_files == 0 then
    on_complete({})
    return
  end
  
  -- Process files in streaming fashion
  for i, file_path in ipairs(file_paths) do
    vim.defer_fn(function()
      local success, content = pcall(vim.fn.readfile, file_path)
      
      if success then
        local parsed_vars = AsyncEnvLoader._parse_single_file(file_path, content, opts)
        
        -- Merge with accumulated vars
        for key, var_info in pairs(parsed_vars) do
          accumulated_vars[key] = var_info
        end
        
        -- Notify about update
        on_update(file_path, parsed_vars, accumulated_vars)
      end
      
      total_processed = total_processed + 1
      
      if total_processed == total_files then
        vim.schedule(function()
          on_complete(accumulated_vars)
        end)
      end
    end, 0)
  end
end

---Clear parse cache
function AsyncEnvLoader.clear_cache()
  _parse_cache = {}
  _parse_cache_size = 0
end

---Get cache statistics
---@return table stats
function AsyncEnvLoader.get_cache_stats()
  return {
    cache_size = _parse_cache_size,
    max_cache_size = MAX_PARSE_CACHE_SIZE,
    cache_hit_ratio = _parse_cache_size > 0 and "N/A" or 0,
  }
end

return AsyncEnvLoader