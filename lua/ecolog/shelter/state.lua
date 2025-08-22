local M = {}

local FEATURES = {
  "cmp",
  "peek",
  "files",
  "telescope",
  "fzf",
  "telescope_previewer",
  "fzf_previewer",
  "snacks_previewer",
  "snacks",
}

local DEFAULT_PARTIAL_MODE = {
  show_start = 3,
  show_end = 3,
  min_mask = 3,
}

local MEMORY_CHECK_INTERVAL = 300000
local MEMORY_THRESHOLD = 50 * 1024 * 1024

-- State initialization
---@class StateConfig
---@field partial_mode boolean|table
---@field mask_char string
---@field patterns table
---@field sources table
---@field default_mode string
---@field shelter_on_leave boolean
---@field highlight_group string
---@field mask_length number|nil
---@field skip_comments boolean

---@class BufferState
---@field revealed_lines table<number, boolean>
---@field disable_cmp boolean

---@class State
---@field config StateConfig
---@field features table
---@field buffer BufferState
---@field telescope table
---@field memory table

---@type State
local state = {
  config = {
    partial_mode = false,
    mask_char = "*",
    patterns = {},
    sources = {},
    default_mode = "full",
    shelter_on_leave = false,
    highlight_group = "Comment",
    mask_length = nil,
    skip_comments = false,
  },
  features = {
    enabled = {},
    initial = {},
  },
  buffer = {
    revealed_lines = {},
    disable_cmp = true,
  },
  telescope = {
    last_selection = nil,
  },
  memory = {
    last_gc = vim.loop.now(),
    stats = {},
  },
}

local _state_cache = setmetatable({}, { __mode = "k" })
local _buffer_cache = setmetatable({}, { __mode = "k" })
local last_memory_check = 0

---@return table
local function get_memory_usage()
  local stats = {}
  stats.lua_used = collectgarbage("count") * 1024

  stats.buffer_cache = 0
  for _, cache in pairs(_buffer_cache) do
    if type(cache) == "table" then
      stats.buffer_cache = stats.buffer_cache + vim.fn.strlen(vim.inspect(cache))
    end
  end

  stats.state_cache = 0
  for _, cache in pairs(_state_cache) do
    if type(cache) == "table" then
      stats.state_cache = stats.state_cache + vim.fn.strlen(vim.inspect(cache))
    end
  end

  return stats
end

local function check_memory_usage()
  local current_time = vim.loop.now()
  if current_time - last_memory_check < MEMORY_CHECK_INTERVAL then
    return
  end

  last_memory_check = current_time
  local stats = get_memory_usage()
  state.memory.stats = stats

  if stats.lua_used > MEMORY_THRESHOLD then
    M.force_garbage_collection()
  end
end

function M.force_garbage_collection()
  _state_cache = setmetatable({}, { __mode = "k" })
  _buffer_cache = setmetatable({}, { __mode = "k" })
  state.buffer.revealed_lines = {}
  collectgarbage("collect")
  state.memory.last_gc = vim.loop.now()
  vim.notify("Memory cleanup performed", vim.log.levels.INFO)
end

---@return State
function M.get_state()
  check_memory_usage()
  return state
end

---@return string[]
function M.get_features()
  return FEATURES
end

---@return table
function M.get_default_partial_mode()
  return vim.deepcopy(DEFAULT_PARTIAL_MODE)
end

---@param feature string
---@return boolean
function M.is_enabled(feature)
  vim.validate({ feature = { feature, "string" } })

  local cache_key = "feature_enabled_" .. feature
  if _state_cache[cache_key] ~= nil then
    return _state_cache[cache_key]
  end
  local enabled = state.features.enabled[feature] or false
  _state_cache[cache_key] = enabled
  return enabled
end

---@return StateConfig
function M.get_config()
  return state.config
end

---@param feature string
---@param enabled boolean
function M.set_feature_state(feature, enabled)
  vim.validate({ feature = { feature, "string" } })
  vim.validate({ enabled = { enabled, "boolean" } })

  state.features.enabled[feature] = enabled
  _state_cache["feature_enabled_" .. feature] = enabled

  if feature == "files" and enabled then
    M.reset_revealed_lines()
    vim.schedule(function()
      local multiline_engine = require("ecolog.shelter.multiline_engine")
      multiline_engine.clear_caches()

      local buffer = require("ecolog.shelter.buffer")
      if buffer and buffer.shelter_buffer then
        buffer.shelter_buffer()
      end
    end)
  end
end

---@param feature string
---@param enabled boolean
function M.set_initial_feature_state(feature, enabled)
  vim.validate({ feature = { feature, "string" } })
  vim.validate({ enabled = { enabled, "boolean" } })

  state.features.initial[feature] = enabled
end

---@param config StateConfig
function M.set_config(config)
  vim.validate({ config = { config, "table" } })

  state.config = config
  for k in pairs(_state_cache) do
    if k:match("^config_") then
      _state_cache[k] = nil
    end
  end
end

---@param key string
---@param value any
function M.update_buffer_state(key, value)
  vim.validate({ key = { key, "string" } })

  state.buffer[key] = value
  if _buffer_cache[key] then
    _buffer_cache[key] = value
  end
end

---@param new_state BufferState
function M.set_buffer_state(new_state)
  vim.validate({ new_state = { new_state, "table" } })

  for key, value in pairs(new_state) do
    M.update_buffer_state(key, value)
  end
end

---@return BufferState
function M.get_buffer_state()
  check_memory_usage()
  return state.buffer
end

function M.reset_revealed_lines()
  state.buffer.revealed_lines = {}
  _buffer_cache.revealed_lines = nil
end

---@param line_num number
---@param revealed boolean
function M.set_revealed_line(line_num, revealed)
  vim.validate({ line_num = { line_num, "number" } })
  vim.validate({ revealed = { revealed, "boolean" } })

  state.buffer.revealed_lines[line_num] = revealed
  if _buffer_cache.revealed_lines then
    _buffer_cache.revealed_lines[line_num] = revealed
  end
end

---@param line_num number
---@return boolean
function M.is_line_revealed(line_num)
  vim.validate({ line_num = { line_num, "number" } })

  if not _buffer_cache.revealed_lines then
    _buffer_cache.revealed_lines = vim.deepcopy(state.buffer.revealed_lines)
  end
  return _buffer_cache.revealed_lines[line_num] or false
end

---@return table
function M.get_memory_stats()
  check_memory_usage()
  return state.memory.stats
end

return M
