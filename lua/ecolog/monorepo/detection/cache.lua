---@class MonorepoDetectionCache
local Cache = {}

-- Hierarchical cache structure
local _detection_cache = {} -- Provider detection results
local _workspace_cache = {} -- Workspace discovery results
local _file_cache = {} -- Environment file resolution results
local _cache_timestamps = {} -- Cache entry timestamps
local _cache_stats = { -- Cache performance stats
  hits = 0,
  misses = 0,
  evictions = 0,
}

-- Cache configuration
local CACHE_CONFIG = {
  max_entries = 1000, -- Maximum cache entries before eviction
  default_ttl = 300000, -- Default TTL in milliseconds (5 minutes)
  cleanup_interval = 60000, -- Cleanup interval in milliseconds (1 minute)
  last_cleanup = 0, -- Last cleanup timestamp
}

---Check if cache entry is valid
---@param key string Cache key
---@param ttl? number Time to live in milliseconds
---@return boolean valid Whether cache entry is valid
local function is_cache_valid(key, ttl)
  local timestamp = _cache_timestamps[key]
  if not timestamp then
    return false
  end

  ttl = ttl or CACHE_CONFIG.default_ttl
  local now = vim.loop.now()
  return (now - timestamp) < ttl
end

---Perform cache cleanup if needed
local function maybe_cleanup_cache()
  local now = vim.loop.now()
  if (now - CACHE_CONFIG.last_cleanup) < CACHE_CONFIG.cleanup_interval then
    return
  end

  CACHE_CONFIG.last_cleanup = now

  -- Count total cache entries
  local total_entries = 0
  for _ in pairs(_cache_timestamps) do
    total_entries = total_entries + 1
  end

  -- Only cleanup if we exceed max entries
  if total_entries <= CACHE_CONFIG.max_entries then
    return
  end

  -- Collect expired entries
  local expired_keys = {}
  for key, timestamp in pairs(_cache_timestamps) do
    if (now - timestamp) > CACHE_CONFIG.default_ttl then
      table.insert(expired_keys, key)
    end
  end

  -- Remove expired entries
  for _, key in ipairs(expired_keys) do
    Cache.evict(key)
    _cache_stats.evictions = _cache_stats.evictions + 1
  end

  -- If still over limit, remove oldest entries
  if total_entries - #expired_keys > CACHE_CONFIG.max_entries then
    local entries_to_remove = total_entries - #expired_keys - CACHE_CONFIG.max_entries
    local oldest_keys = {}

    for key, timestamp in pairs(_cache_timestamps) do
      table.insert(oldest_keys, { key = key, timestamp = timestamp })
    end

    table.sort(oldest_keys, function(a, b)
      return a.timestamp < b.timestamp
    end)

    for i = 1, math.min(entries_to_remove, #oldest_keys) do
      Cache.evict(oldest_keys[i].key)
      _cache_stats.evictions = _cache_stats.evictions + 1
    end
  end
end

---Store detection result in cache
---@param key string Cache key
---@param result table Detection result
---@param ttl? number Time to live in milliseconds
function Cache.set_detection(key, result, ttl)
  maybe_cleanup_cache()
  _detection_cache[key] = result
  _cache_timestamps[key] = vim.loop.now()
end

---Get detection result from cache
---@param key string Cache key
---@param ttl? number Time to live in milliseconds
---@return table? result Detection result or nil if not found/expired
function Cache.get_detection(key, ttl)
  if is_cache_valid(key, ttl) and _detection_cache[key] then
    _cache_stats.hits = _cache_stats.hits + 1
    return _detection_cache[key]
  end

  _cache_stats.misses = _cache_stats.misses + 1
  return nil
end

---Store workspace list in cache
---@param key string Cache key
---@param workspaces table[] List of workspaces
---@param ttl? number Time to live in milliseconds
function Cache.set_workspaces(key, workspaces, ttl)
  maybe_cleanup_cache()
  _workspace_cache[key] = workspaces
  _cache_timestamps[key] = vim.loop.now()
end

---Get workspace list from cache
---@param key string Cache key
---@param ttl? number Time to live in milliseconds
---@return table[]? workspaces List of workspaces or nil if not found/expired
function Cache.get_workspaces(key, ttl)
  if is_cache_valid(key, ttl) and _workspace_cache[key] then
    _cache_stats.hits = _cache_stats.hits + 1
    return _workspace_cache[key]
  end

  _cache_stats.misses = _cache_stats.misses + 1
  return nil
end

---Store environment file list in cache
---@param key string Cache key
---@param files string[] List of environment files
---@param ttl? number Time to live in milliseconds
function Cache.set_env_files(key, files, ttl)
  maybe_cleanup_cache()
  _file_cache[key] = files
  _cache_timestamps[key] = vim.loop.now()
end

---Get environment file list from cache
---@param key string Cache key
---@param ttl? number Time to live in milliseconds
---@return string[]? files List of environment files or nil if not found/expired
function Cache.get_env_files(key, ttl)
  if is_cache_valid(key, ttl) and _file_cache[key] then
    _cache_stats.hits = _cache_stats.hits + 1
    return _file_cache[key]
  end

  _cache_stats.misses = _cache_stats.misses + 1
  return nil
end

---Evict specific cache entry
---@param key string Cache key to evict
function Cache.evict(key)
  _detection_cache[key] = nil
  _workspace_cache[key] = nil
  _file_cache[key] = nil
  _cache_timestamps[key] = nil
end

---Evict all cache entries matching pattern
---@param pattern string Lua pattern to match against keys
function Cache.evict_pattern(pattern)
  local keys_to_evict = {}

  for key in pairs(_cache_timestamps) do
    if key:match(pattern) then
      table.insert(keys_to_evict, key)
    end
  end

  for _, key in ipairs(keys_to_evict) do
    Cache.evict(key)
  end
end

---Clear all cache entries
function Cache.clear_all()
  _detection_cache = {}
  _workspace_cache = {}
  _file_cache = {}
  _cache_timestamps = {}
  _cache_stats.evictions = 0
end

---Get cache statistics
---@return table stats Cache performance statistics
function Cache.get_stats()
  local total_entries = 0
  for _ in pairs(_cache_timestamps) do
    total_entries = total_entries + 1
  end

  local hit_rate = 0
  local total_requests = _cache_stats.hits + _cache_stats.misses
  if total_requests > 0 then
    hit_rate = _cache_stats.hits / total_requests
  end

  return {
    hits = _cache_stats.hits,
    misses = _cache_stats.misses,
    evictions = _cache_stats.evictions,
    total_entries = total_entries,
    hit_rate = hit_rate,
    max_entries = CACHE_CONFIG.max_entries,
  }
end

---Configure cache settings
---@param config table Cache configuration options
function Cache.configure(config)
  if config.max_entries then
    CACHE_CONFIG.max_entries = config.max_entries
  end
  if config.default_ttl then
    CACHE_CONFIG.default_ttl = config.default_ttl
  end
  if config.cleanup_interval then
    CACHE_CONFIG.cleanup_interval = config.cleanup_interval
  end
end

return Cache

