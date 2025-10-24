---@class BulkEnvironmentResolver
local BulkResolver = {}

-- Compatibility layer for uv -> vim.uv migration
local uv = vim.uv or uv

local Cache = require("ecolog.monorepo.detection.cache")

-- Performance optimized bulk pattern matching
local _bulk_pattern_cache = {}
local _bulk_pattern_cache_time = 0

---Bulk resolve environment files for multiple workspaces/paths
---@param paths table[] Array of {path, workspace_info} pairs
---@param patterns string[] Environment file patterns
---@param provider MonorepoBaseProvider Provider instance
---@param opts table? Additional options
---@return table files Map of path to environment files
function BulkResolver.bulk_resolve_env_files(paths, patterns, provider, opts)
  opts = opts or {}
  
  if not paths or #paths == 0 then
    return {}
  end
  
  -- Generate bulk cache key
  local cache_key = BulkResolver._generate_bulk_cache_key(paths, patterns, provider, opts)
  local cached_result = Cache.get_env_files(cache_key)
  if cached_result then
    return cached_result
  end
  
  -- Batch all glob operations for maximum efficiency
  local all_patterns = {}
  local path_to_workspace = {}
  
  for _, path_info in ipairs(paths) do
    local path = path_info.path or path_info
    local workspace = path_info.workspace_info
    path_to_workspace[path] = workspace
    
    for _, pattern in ipairs(patterns) do
      table.insert(all_patterns, path .. "/" .. pattern)
    end
  end
  
  -- Process patterns in batches to avoid vim.fn.glob syntax issues
  local found_files = {}
  for _, pattern in ipairs(all_patterns) do
    local found = vim.fn.glob(pattern, false, true)
    if type(found) == "string" then
      found = { found }
    end
    if found and #found > 0 then
      vim.list_extend(found_files, found)
    end
  end
  
  -- Organize results by path
  local results = {}
  for _, file_path in ipairs(found_files) do
    local dir = vim.fn.fnamemodify(file_path, ":h")
    if not results[dir] then
      results[dir] = {}
    end
    table.insert(results[dir], file_path)
  end
  
  -- Apply workspace-specific resolution strategies
  for path, files in pairs(results) do
    local workspace = path_to_workspace[path]
    if workspace and provider then
      local env_resolution = {
        strategy = "workspace_first",
        inheritance = true,
        override_order = { "workspace", "root" }
      }
      
      if type(provider.get_env_resolution) == "function" then
        env_resolution = provider:get_env_resolution()
      end
      
      results[path] = BulkResolver._apply_resolution_strategy(files, env_resolution, workspace, opts)
    end
  end
  
  -- Cache the bulk result
  local cache_duration = 300000 -- Default 5 minutes
  if provider and type(provider.get_cache_duration) == "function" then
    cache_duration = provider:get_cache_duration()
  end
  Cache.set_env_files(cache_key, results, cache_duration)
  
  return results
end

---Apply resolution strategy to files
---@param files string[] Files to process
---@param env_resolution table Environment resolution config
---@param workspace table? Workspace information
---@param opts table Options
---@return string[] processed_files
function BulkResolver._apply_resolution_strategy(files, env_resolution, workspace, opts)
  if not env_resolution then
    return files
  end
  
  -- Sort files according to strategy
  local sorted_files = vim.deepcopy(files)
  
  -- Apply preferred environment sorting
  if opts.preferred_environment then
    local pref_pattern = "%." .. vim.pesc(opts.preferred_environment) .. "$"
    table.sort(sorted_files, function(a, b)
      local a_is_preferred = a:match(pref_pattern) ~= nil
      local b_is_preferred = b:match(pref_pattern) ~= nil
      if a_is_preferred ~= b_is_preferred then
        return a_is_preferred
      end
      return a < b
    end)
  end
  
  return sorted_files
end

---Generate cache key for bulk resolution
---@param paths table[] Array of paths
---@param patterns string[] Patterns
---@param provider MonorepoBaseProvider Provider
---@param opts table Options
---@return string cache_key
function BulkResolver._generate_bulk_cache_key(paths, patterns, provider, opts)
  local path_strs = {}
  for _, path_info in ipairs(paths) do
    local path = path_info.path or path_info
    table.insert(path_strs, path)
  end
  
  local key_parts = {
    "bulk_env_files",
    provider.name,
    table.concat(path_strs, ","),
    table.concat(patterns, ","),
    opts.preferred_environment or "no_pref",
  }
  
  return table.concat(key_parts, ":")
end

---Optimized batch file existence check
---@param file_paths string[] Array of file paths to check
---@return table exists Map of path to boolean
function BulkResolver.batch_file_exists(file_paths)
  local now = uv.now()
  if (now - _bulk_pattern_cache_time) > 5000 then -- Clear cache every 5 seconds
    _bulk_pattern_cache = {}
    _bulk_pattern_cache_time = now
  end
  
  local results = {}
  local uncached_paths = {}
  
  -- Check cache first
  for _, path in ipairs(file_paths) do
    if _bulk_pattern_cache[path] ~= nil then
      results[path] = _bulk_pattern_cache[path]
    else
      table.insert(uncached_paths, path)
    end
  end
  
  -- Check uncached paths individually but efficiently
  if #uncached_paths > 0 then
    local existing_files = {}
    for _, path in ipairs(uncached_paths) do
      if vim.fn.filereadable(path) == 1 then
        table.insert(existing_files, path)
      end
    end
    
    -- Mark all as non-existent first
    for _, path in ipairs(uncached_paths) do
      results[path] = false
      _bulk_pattern_cache[path] = false
    end
    
    -- Mark existing files as found
    for _, existing_file in ipairs(existing_files) do
      results[existing_file] = true
      _bulk_pattern_cache[existing_file] = true
    end
  end
  
  return results
end

---Parallel environment file loading
---@param file_paths string[] Array of file paths
---@param callback function Callback function(results, errors)
function BulkResolver.parallel_load_env_files(file_paths, callback)
  local results = {}
  local errors = {}
  local completed = 0
  local total = #file_paths
  
  if total == 0 then
    callback({}, {})
    return
  end
  
  -- Load files concurrently
  for i, file_path in ipairs(file_paths) do
    vim.defer_fn(function()
      local success, content = pcall(vim.fn.readfile, file_path)
      
      if success then
        results[file_path] = content
      else
        errors[file_path] = tostring(content)
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

---Stream-based environment file processing
---@param file_paths string[] Array of file paths
---@param processor function Function to process each file
---@param callback function Final callback when all files processed
function BulkResolver.stream_process_env_files(file_paths, processor, callback)
  local processed_count = 0
  local total = #file_paths
  
  if total == 0 then
    callback()
    return
  end
  
  -- Process files in streaming fashion
  for i, file_path in ipairs(file_paths) do
    vim.defer_fn(function()
      local success, content = pcall(vim.fn.readfile, file_path)
      
      if success then
        processor(file_path, content)
      end
      
      processed_count = processed_count + 1
      
      if processed_count == total then
        vim.schedule(callback)
      end
    end, 0)
  end
end

return BulkResolver
