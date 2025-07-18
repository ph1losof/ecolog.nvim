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
local LRUCache = {}
LRUCache.__index = LRUCache

---Create a new LRU Cache
---@param capacity integer Maximum number of items to store
---@param memory_limit? number Optional memory limit in bytes
---@return LRUCache
function LRUCache.new(capacity, memory_limit)
  local self = setmetatable({}, { __index = LRUCache })
  self.capacity = capacity
  self.size = 0
  self.cache = {}
  self.memory_limit = memory_limit
  self.current_memory = 0

  self.head = { key = 0, value = 0 }
  self.tail = { key = 0, value = 0 }
  self.head.next = self.tail
  self.tail.prev = self.head

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
end

---Get current cache size
---@return integer
function LRUCache:get_size()
  return self.size
end

---Get current memory usage in bytes (if memory limit is enabled)
---@return number
function LRUCache:get_memory_usage()
  return self.current_memory
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
    vim.notify("LRU Cache corruption detected, attempting to fix: " .. table.concat(errors, ", "), vim.log.levels.WARN)
    self:clear()
    return false, table.concat(errors, ", ")
  end
  
  return true, nil
end

return {
  new = LRUCache.new,
}
