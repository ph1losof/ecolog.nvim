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
---@return number
local function estimate_memory_usage(value)
  local t = type(value)
  if t == "string" then
    return #value
  elseif t == "table" then
    local size = 0
    for k, v in pairs(value) do
      size = size + estimate_memory_usage(k) + estimate_memory_usage(v)
    end
    return size
  elseif t == "number" then
    return 8
  elseif t == "boolean" then
    return 1
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
  if lru_node == self.head then
    return
  end

  self:remove_node(lru_node)
  self.cache[lru_node.key] = nil
  self.size = self.size - 1

  if self.memory_limit then
    self.current_memory = self.current_memory - estimate_memory_usage(lru_node.value)
  end

  lru_node.key = nil
  lru_node.value = nil
end

---Put a value in the cache
---@param key any
---@param value any
function LRUCache:put(key, value)
  local node = self.cache[key]

  local value_memory = self.memory_limit and estimate_memory_usage(value) or 0

  if node then
    if self.memory_limit then
      self.current_memory = self.current_memory - estimate_memory_usage(node.value) + value_memory
    end
    node.value = value
    self:move_to_front(node)
  else
    node = { key = key, value = value }
    self.cache[key] = node
    self:add_node(node)
    self.size = self.size + 1
    if self.memory_limit then
      self.current_memory = self.current_memory + value_memory
    end

    while (self.size > self.capacity) or (self.memory_limit and self.current_memory > self.memory_limit) do
      self:remove_lru()
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
  local node = self.cache[key]
  if node then
    if self.memory_limit then
      self.current_memory = self.current_memory - estimate_memory_usage(node.value)
    end
    self:remove_node(node)
    self.cache[key] = nil
    self.size = self.size - 1

    node.key = nil
    node.value = nil
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
  while node ~= self.tail do
    table.insert(keys, node.key)
    node = node.next
  end
  return keys
end

return {
  new = LRUCache.new,
}
