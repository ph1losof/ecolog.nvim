local M = {}

local FEATURES =
  { "cmp", "peek", "files", "telescope", "fzf", "telescope_previewer", "fzf_previewer", "snacks_previewer", "snacks" }
local DEFAULT_PARTIAL_MODE = {
  show_start = 3,
  show_end = 3,
  min_mask = 3,
}

-- State cache with weak keys to avoid memory leaks
local _state_cache = setmetatable({}, {
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
}

-- Optimized state getters with caching
function M.get_state()
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

-- Optimized state setters with cache invalidation
function M.set_feature_state(feature, enabled)
  state.features.enabled[feature] = enabled
  _state_cache["feature_enabled_" .. feature] = enabled
end

function M.set_initial_feature_state(feature, enabled)
  state.features.initial[feature] = enabled
end

function M.set_config(config)
  state.config = config
  -- Invalidate relevant caches
  for k in pairs(_state_cache) do
    if k:match("^config_") then
      _state_cache[k] = nil
    end
  end
end

-- Buffer state management with optimized caching
local _buffer_cache = setmetatable({}, {
  __mode = "k", -- Weak keys
})

function M.update_buffer_state(key, value)
  state.buffer[key] = value
  _buffer_cache[key] = nil
end

function M.get_buffer_state()
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

return M

