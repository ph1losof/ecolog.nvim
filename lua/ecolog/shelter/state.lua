local M = {}

local FEATURES =
  { "cmp", "peek", "files", "telescope", "fzf", "telescope_previewer", "fzf_previewer", "snacks_previewer", "snacks" }
local DEFAULT_PARTIAL_MODE = {
  show_start = 3,
  show_end = 3,
  min_mask = 3,
}

local MEMORY_CHECK_INTERVAL = 300000
local MEMORY_THRESHOLD = 50 * 1024 * 1024
local last_memory_check = 0

local _state_cache = setmetatable({}, {
  __mode = "k",
})

local _buffer_cache = setmetatable({}, {
  __mode = "k",
})

local state = {
  config = {
    partial_mode = false,
    mask_char = "*",
    patterns = {},
    sources = {},
    default_mode = "full",
    shelter_on_leave = false,
    highlight_group = "Comment",
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

function M.get_state()
  check_memory_usage()
  return state
end

function M.get_features()
  return FEATURES
end

function M.get_default_partial_mode()
  return DEFAULT_PARTIAL_MODE
end

function M.is_enabled(feature)
  local cache_key = "feature_enabled_" .. feature
  if _state_cache[cache_key] ~= nil then
    return _state_cache[cache_key]
  end
  local enabled = state.features.enabled[feature] or false
  _state_cache[cache_key] = enabled
  return enabled
end

function M.get_config()
  return state.config
end

function M.set_feature_state(feature, enabled)
  state.features.enabled[feature] = enabled
  _state_cache["feature_enabled_" .. feature] = enabled
end

function M.set_initial_feature_state(feature, enabled)
  state.features.initial[feature] = enabled
end

function M.set_config(config)
  state.config = config

  for k in pairs(_state_cache) do
    if k:match("^config_") then
      _state_cache[k] = nil
    end
  end
end

function M.update_buffer_state(key, value)
  state.buffer[key] = value
  _buffer_cache[key] = nil
end

function M.get_buffer_state()
  check_memory_usage()
  return state.buffer
end

function M.reset_revealed_lines()
  state.buffer.revealed_lines = {}
  _buffer_cache.revealed_lines = nil
end

function M.set_revealed_line(line_num, revealed)
  state.buffer.revealed_lines[line_num] = revealed
  if _buffer_cache.revealed_lines then
    _buffer_cache.revealed_lines[line_num] = revealed
  end
end

function M.is_line_revealed(line_num)
  if not _buffer_cache.revealed_lines then
    _buffer_cache.revealed_lines = vim.deepcopy(state.buffer.revealed_lines)
  end
  return _buffer_cache.revealed_lines[line_num]
end

function M.get_memory_stats()
  check_memory_usage()
  return state.memory.stats
end

return M
