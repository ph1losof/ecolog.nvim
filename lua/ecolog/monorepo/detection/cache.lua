---@class MonorepoDetectionCache
local Cache = {}

-- Compatibility layer for uv -> vim.uv migration
local uv = require("ecolog.core.compat").uv

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
  local now = uv.now()
  return (now - timestamp) < ttl
end

-- Sorted list of cache entries by timestamp for efficient cleanup
local _cache_entries_sorted = {}
local _needs_resort = false

---Perform cache cleanup if needed
local function maybe_cleanup_cache()
  local now = uv.now()
  if (now - CACHE_CONFIG.last_cleanup) < CACHE_CONFIG.cleanup_interval then
    return
  end

  CACHE_CONFIG.last_cleanup = now

  -- Count total cache entries
  local total_entries = #_cache_entries_sorted
  
  -- Only cleanup if we exceed max entries
  if total_entries <= CACHE_CONFIG.max_entries then
    return
  end

  -- Resort if needed
  if _needs_resort then
    table.sort(_cache_entries_sorted, function(a, b)
      return a.timestamp < b.timestamp
    end)
    _needs_resort = false
  end

  -- Remove expired and oldest entries in one pass
  local entries_to_remove = math.max(0, total_entries - CACHE_CONFIG.max_entries)
  local removed_count = 0
  
  for i = 1, #_cache_entries_sorted do
    local entry = _cache_entries_sorted[i]
    local expired = (now - entry.timestamp) > CACHE_CONFIG.default_ttl
    
    if expired or removed_count < entries_to_remove then
      Cache.evict(entry.key)
      _cache_stats.evictions = _cache_stats.evictions + 1
      removed_count = removed_count + 1
      _cache_entries_sorted[i] = nil
    end
  end
  
  -- Compact the sorted list
  local compacted = {}
  for _, entry in ipairs(_cache_entries_sorted) do
    if entry then
      table.insert(compacted, entry)
    end
  end
  _cache_entries_sorted = compacted
end

---Store detection result in cache
---@param key string Cache key
---@param result table Detection result
---@param ttl? number Time to live in milliseconds
function Cache.set_detection(key, result, ttl)
  maybe_cleanup_cache()
  local now = uv.now()
  
  -- If key already exists, update timestamp in sorted list
  local existing_idx = nil
  for i, entry in ipairs(_cache_entries_sorted) do
    if entry.key == key then
      existing_idx = i
      break
    end
  end
  
  if existing_idx then
    _cache_entries_sorted[existing_idx].timestamp = now
    _needs_resort = true
  else
    table.insert(_cache_entries_sorted, { key = key, timestamp = now })
  end
  
  _detection_cache[key] = result
  _cache_timestamps[key] = now
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
  local now = uv.now()
  
  -- If key already exists, update timestamp in sorted list
  local existing_idx = nil
  for i, entry in ipairs(_cache_entries_sorted) do
    if entry.key == key then
      existing_idx = i
      break
    end
  end
  
  if existing_idx then
    _cache_entries_sorted[existing_idx].timestamp = now
    _needs_resort = true
  else
    table.insert(_cache_entries_sorted, { key = key, timestamp = now })
  end
  
  _workspace_cache[key] = workspaces
  _cache_timestamps[key] = now
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
  local now = uv.now()
  
  -- If key already exists, update timestamp in sorted list
  local existing_idx = nil
  for i, entry in ipairs(_cache_entries_sorted) do
    if entry.key == key then
      existing_idx = i
      break
    end
  end
  
  if existing_idx then
    _cache_entries_sorted[existing_idx].timestamp = now
    _needs_resort = true
  else
    table.insert(_cache_entries_sorted, { key = key, timestamp = now })
  end
  
  _file_cache[key] = files
  _cache_timestamps[key] = now
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
  
  -- Remove from sorted list
  for i, entry in ipairs(_cache_entries_sorted) do
    if entry.key == key then
      table.remove(_cache_entries_sorted, i)
      break
    end
  end
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
  _cache_entries_sorted = {}
  _needs_resort = false
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

