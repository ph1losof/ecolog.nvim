---@class LRUNode
---@field key any
---@field value any
---@field prev LRUNode
---@field next LRUNode

---@class LRUCache
---@field private capacity integer
---@field private size integer
---@field private cache table<any, LRUNode>
---@field private head LRUNode
---@field private tail LRUNode
---@field private memory_limit number Memory limit in bytes (optional)
---@field private current_memory number Current memory usage in bytes
---@field private stats table Cache statistics
---@field private config table Cache configuration
---@field private created_at number Creation timestamp
---@field private cleanup_timer number? Cleanup timer handle
local LRUCache = {}

-- Compatibility layer for uv -> vim.uv migration
local uv = require("ecolog.core.compat").uv
LRUCache.__index = LRUCache

-- Add __gc metamethod to handle cleanup on garbage collection
local function cleanup_on_gc(self)
  if self.cleanup_timer then
    vim.fn.timer_stop(self.cleanup_timer)
    self.cleanup_timer = nil
  end
end

---Create a new LRU Cache
---@param capacity integer Maximum number of items to store
---@param config? table Optional configuration
---@return LRUCache
function LRUCache.new(capacity, config)
  config = config or {}
  
  local self = setmetatable({}, { 
    __index = LRUCache,
    __gc = cleanup_on_gc
  })
  self.capacity = capacity
  self.size = 0
  self.cache = {}
  self.memory_limit = config.memory_limit
  self.current_memory = 0
  self.created_at = uv.hrtime()
  
  -- Configuration with defaults
  self.config = {
    enable_stats = config.enable_stats ~= false, -- Default true
    ttl_ms = config.ttl_ms or 3600000, -- 1 hour default
    cleanup_interval_ms = config.cleanup_interval_ms or 300000, -- 5 minutes
    auto_cleanup = config.auto_cleanup ~= false, -- Default true
  }
  
  -- Statistics tracking
  self.stats = {
    hits = 0,
    misses = 0,
    evictions = 0,
    memory_bytes = 0,
  }

  self.head = { key = 0, value = 0 }
  self.tail = { key = 0, value = 0 }
  self.head.next = self.tail
  self.tail.prev = self.head

  -- Start automatic cleanup if enabled
  if self.config.auto_cleanup and self.config.cleanup_interval_ms > 0 then
    self:start_cleanup_timer()
  end

  return self
end

---Estimate memory usage of a value
---@param value any
---@param depth? number Current recursion depth (for circular reference protection)
---@return number
local function estimate_memory_usage(value, depth)
  depth = depth or 0
  
  -- Prevent infinite recursion from circular references
  if depth > 10 then
    return 0
  end
  
  local t = type(value)
  if t == "string" then
    return #value
  elseif t == "table" then
    local size = 0
    local seen = {}
    
    for k, v in pairs(value) do
      -- Prevent processing the same table multiple times
      if seen[v] then
        size = size + 4 -- Just add a small penalty for references
      else
        seen[v] = true
        size = size + estimate_memory_usage(k, depth + 1) + estimate_memory_usage(v, depth + 1)
      end
    end
    return size
  elseif t == "number" then
    return 8
  elseif t == "boolean" then
    return 1
  elseif t == "function" then
    return 100 -- Rough estimate for function overhead
  elseif t == "userdata" then
    return 50 -- Rough estimate for userdata
  end
  return 0
end

---Start automatic cleanup timer
function LRUCache:start_cleanup_timer()
  if self.cleanup_timer then
    vim.fn.timer_stop(self.cleanup_timer)
  end
  
  self.cleanup_timer = vim.fn.timer_start(self.config.cleanup_interval_ms, function()
    self:cleanup_expired()
  end, { ["repeat"] = -1 })
end

---Stop automatic cleanup timer
function LRUCache:stop_cleanup_timer()
  if self.cleanup_timer then
    vim.fn.timer_stop(self.cleanup_timer)
    self.cleanup_timer = nil
  end
end

---Check if cache is expired based on TTL
---@return boolean
function LRUCache:is_expired()
  if not self.config.ttl_ms or self.config.ttl_ms <= 0 then
    return false
  end
  
  local age_ms = (uv.hrtime() - self.created_at) / 1000000
  return age_ms > self.config.ttl_ms
end

---Cleanup expired cache entries
function LRUCache:cleanup_expired()
  if self:is_expired() then
    self:clear()
  end
end

---Add a node to the front of the list
---@param node LRUNode
function LRUCache:add_node(node)
  node.prev = self.head
  node.next = self.head.next
  self.head.next.prev = node
  self.head.next = node
end

---Remove a node from the linked list
---@param node LRUNode
function LRUCache:remove_node(node)
  if not node then
    return
  end
  local prev = node.prev
  local next = node.next
  if prev then
    prev.next = next
  end
  if next then
    next.prev = prev
  end

  node.prev = nil
  node.next = nil
end

---Move a node to the front (most recently used)
---@param node LRUNode
function LRUCache:move_to_front(node)
  self:remove_node(node)
  self:add_node(node)
end

---Remove the least recently used item
function LRUCache:remove_lru()
  if self.size == 0 then
    return
  end

  local lru_node = self.tail.prev
  if lru_node == self.head or not lru_node then
    return
  end

  -- Calculate memory usage before removing to avoid errors
  local memory_to_remove = 0
  if self.memory_limit and lru_node.value then
    local success, mem_usage = pcall(estimate_memory_usage, lru_node.value)
    if success then
      memory_to_remove = mem_usage
    end
  end

  self:remove_node(lru_node)
  
  -- Safely remove from cache
  if lru_node.key then
    self.cache[lru_node.key] = nil
  end
  
  self.size = math.max(0, self.size - 1)

  if self.memory_limit then
    self.current_memory = math.max(0, self.current_memory - memory_to_remove)
  end
  
  -- Update statistics
  if self.config.enable_stats then
    self.stats.evictions = self.stats.evictions + 1
  end

  -- Clear node references to prevent memory leaks
  lru_node.key = nil
  lru_node.value = nil
  lru_node.prev = nil
  lru_node.next = nil
end

---Put a value in the cache
---@param key any
---@param value any
function LRUCache:put(key, value)
  -- Validate inputs
  if key == nil then
    return
  end
  
  local node = self.cache[key]

  -- Calculate memory usage safely
  local value_memory = 0
  if self.memory_limit then
    local success, mem_usage = pcall(estimate_memory_usage, value)
    if success then
      value_memory = mem_usage
    end
  end

  if node then
    -- Update existing node
    local old_memory = 0
    if self.memory_limit and node.value then
      local success, mem_usage = pcall(estimate_memory_usage, node.value)
      if success then
        old_memory = mem_usage
      end
    end
    
    if self.memory_limit then
      self.current_memory = self.current_memory - old_memory + value_memory
    end
    
    -- Update statistics
    if self.config.enable_stats then
      self.stats.memory_bytes = self.stats.memory_bytes - old_memory + value_memory
    end
    
    node.value = value
    self:move_to_front(node)
  else
    -- Create new node
    node = { key = key, value = value }
    self.cache[key] = node
    self:add_node(node)
    self.size = self.size + 1
    
    if self.memory_limit then
      self.current_memory = self.current_memory + value_memory
    end
    
    -- Update statistics
    if self.config.enable_stats then
      self.stats.memory_bytes = self.stats.memory_bytes + value_memory
    end

    -- Evict items if necessary
    local eviction_count = 0
    local max_evictions = self.capacity -- Prevent infinite loops
    
    while ((self.size > self.capacity) or (self.memory_limit and self.current_memory > self.memory_limit)) 
          and eviction_count < max_evictions do
      self:remove_lru()
      eviction_count = eviction_count + 1
    end
    
    if eviction_count >= max_evictions then
      -- Emergency cleanup if we hit the limit
      self:clear()
    end
  end
end

---Get a value from the cache
---@param key any
---@return any|nil
function LRUCache:get(key)
  local node = self.cache[key]
  
  -- Update statistics
  if self.config.enable_stats then
    if node then
      self.stats.hits = self.stats.hits + 1
    else
      self.stats.misses = self.stats.misses + 1
    end
  end
  
  if not node then
    return nil
  end
  
  self:move_to_front(node)
  return node.value
end

---Remove a key from the cache
---@param key any
function LRUCache:remove(key)
  if key == nil then
    return
  end
  
  local node = self.cache[key]
  if node then
    -- Calculate memory usage before removing
    local memory_to_remove = 0
    if self.memory_limit and node.value then
      local success, mem_usage = pcall(estimate_memory_usage, node.value)
      if success then
        memory_to_remove = mem_usage
      end
    end
    
    self:remove_node(node)
    self.cache[key] = nil
    self.size = math.max(0, self.size - 1)

    if self.memory_limit then
      self.current_memory = math.max(0, self.current_memory - memory_to_remove)
    end

    -- Clear node references to prevent memory leaks
    node.key = nil
    node.value = nil
    node.prev = nil
    node.next = nil
  end
end

function LRUCache:clear()
  -- Stop cleanup timer first
  self:stop_cleanup_timer()
  
  local current = self.head.next
  while current ~= self.tail do
    local next = current.next
    current.prev = nil
    current.next = nil
    current.key = nil
    current.value = nil
    current = next
  end

  self.cache = {}
  self.size = 0
  self.current_memory = 0
  self.head.next = self.tail
  self.tail.prev = self.head
  
  -- Reset statistics
  if self.config.enable_stats then
    self.stats.memory_bytes = 0
  end
end

---Get current cache size
---@return integer
function LRUCache:get_size()
  return self.size
end

---Alias for get_size for backward compatibility
---@return integer
function LRUCache:size()
  return self.size
end

---Get current memory usage in bytes (if memory limit is enabled)
---@return number
function LRUCache:get_memory_usage()
  return self.current_memory
end

---Get cache statistics
---@return table stats Current cache statistics
function LRUCache:get_stats()
  if not self.config.enable_stats then
    return { stats_disabled = true }
  end
  
  return vim.tbl_deep_extend("force", {}, self.stats)
end

---Get cache hit ratio
---@return number ratio Hit ratio between 0 and 1
function LRUCache:get_hit_ratio()
  if not self.config.enable_stats then
    return 0
  end
  
  local total_requests = self.stats.hits + self.stats.misses
  return total_requests > 0 and (self.stats.hits / total_requests) or 0
end

---Reset cache statistics
function LRUCache:reset_stats()
  if self.config.enable_stats then
    self.stats.hits = 0
    self.stats.misses = 0
    self.stats.evictions = 0
  end
end

---Get cache configuration
---@return table config Current cache configuration
function LRUCache:get_config()
  return vim.tbl_deep_extend("force", {}, self.config)
end

---Update cache configuration
---@param new_config table New configuration options
function LRUCache:configure(new_config)
  local old_auto_cleanup = self.config.auto_cleanup
  self.config = vim.tbl_deep_extend("force", self.config, new_config or {})
  
  -- Handle cleanup timer changes
  if old_auto_cleanup and not self.config.auto_cleanup then
    self:stop_cleanup_timer()
  elseif not old_auto_cleanup and self.config.auto_cleanup then
    self:start_cleanup_timer()
  elseif self.config.auto_cleanup and self.cleanup_timer then
    -- Restart timer with new interval
    self:start_cleanup_timer()
  end
end

---Shutdown cache (stop timers and clear)
function LRUCache:shutdown()
  self:stop_cleanup_timer()
  self:clear()
end

---Get all keys in the cache
---@return table
function LRUCache:keys()
  local keys = {}
  local node = self.head.next
  local count = 0
  
  while node ~= self.tail and count < self.capacity * 2 do -- Prevent infinite loops
    if node.key then
      table.insert(keys, node.key)
    end
    node = node.next
    count = count + 1
  end
  
  return keys
end

---Health check to detect and fix cache corruption
---@return boolean is_healthy
---@return string|nil error_message
function LRUCache:health_check()
  local errors = {}
  
  -- Check if head and tail are properly connected
  if self.head.next == nil or self.tail.prev == nil then
    table.insert(errors, "Head or tail connections are broken")
  end
  
  -- Count nodes in linked list
  local linked_count = 0
  local node = self.head.next
  local visited = {}
  
  while node ~= self.tail and linked_count < self.capacity * 2 do
    if visited[node] then
      table.insert(errors, "Circular reference detected in linked list")
      break
    end
    visited[node] = true
    linked_count = linked_count + 1
    node = node.next
  end
  
  -- Check if linked list count matches cache size
  if linked_count ~= self.size then
    table.insert(errors, string.format("Linked list count (%d) doesn't match cache size (%d)", linked_count, self.size))
  end
  
  -- Check if cache table count matches size
  local cache_count = 0
  for _ in pairs(self.cache) do
    cache_count = cache_count + 1
  end
  
  if cache_count ~= self.size then
    table.insert(errors, string.format("Cache table count (%d) doesn't match cache size (%d)", cache_count, self.size))
  end
  
  -- If we found errors, try to fix them
  if #errors > 0 then
    local NotificationManager = require("ecolog.core.notification_manager")
    NotificationManager.warn("LRU Cache corruption detected, attempting to fix: " .. table.concat(errors, ", "))
    self:clear()
    return false, table.concat(errors, ", ")
  end
  
  return true, nil
end

return {
  new = LRUCache.new,
}
