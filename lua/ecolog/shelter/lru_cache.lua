local M = {}

---@class LRUNode
---@field key any
---@field value any
---@field prev LRUNode|nil
---@field next LRUNode|nil

---@class LRUCache
---@field private capacity integer
---@field private size integer
---@field private cache table<any, LRUNode>
---@field private head LRUNode
---@field private tail LRUNode
local LRUCache = {}
LRUCache.__index = LRUCache

---Create a new LRU cache with the specified capacity
---@param capacity integer
---@return LRUCache
function M.new(capacity)
  local self = setmetatable({}, LRUCache)
  self.capacity = capacity
  self.size = 0
  self.cache = {}
  -- Initialize dummy head and tail nodes
  self.head = { key = 0, value = 0, prev = nil, next = nil }
  self.tail = { key = 0, value = 0, prev = nil, next = nil }
  self.head.next = self.tail
  self.tail.prev = self.head
  return self
end

---Add a node after the head
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
  local prev = node.prev
  local next = node.next
  prev.next = next
  next.prev = prev
end

---Move a node to the front (most recently used)
---@param node LRUNode
function LRUCache:move_to_front(node)
  self:remove_node(node)
  self:add_node(node)
end

---Get a value from the cache
---@param key any
---@return any|nil
function LRUCache:get(key)
  local node = self.cache[key]
  if not node then
    return nil
  end
  -- Move to front (most recently used)
  self:move_to_front(node)
  return node.value
end

---Put a key-value pair into the cache
---@param key any
---@param value any
function LRUCache:put(key, value)
  local node = self.cache[key]
  if node then
    -- Update existing node
    node.value = value
    self:move_to_front(node)
  else
    -- Create new node
    node = { key = key, value = value }
    self.cache[key] = node
    self:add_node(node)
    self.size = self.size + 1
    
    -- Remove least recently used if over capacity
    if self.size > self.capacity then
      -- Remove from cache
      local lru = self.tail.prev
      self.cache[lru.key] = nil
      self:remove_node(lru)
      self.size = self.size - 1
    end
  end
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

---Clear the cache
function LRUCache:clear()
  self.size = 0
  self.cache = {}
  self.head.next = self.tail
  self.tail.prev = self.head
end

return M 