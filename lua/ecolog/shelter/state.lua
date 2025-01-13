local M = {}

local FEATURES = { "cmp", "peek", "files", "telescope", "fzf", "telescope_previewer", "fzf_previewer" }
local DEFAULT_PARTIAL_MODE = {
  show_start = 3,
  show_end = 3,
  min_mask = 3,
}

local state = {
  config = {
    partial_mode = false,
    mask_char = "*",
    patterns = {},
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
  return state.features.enabled[feature] or false
end

function M.get_config()
  return state.config
end

function M.set_feature_state(feature, enabled)
  state.features.enabled[feature] = enabled
end

function M.set_initial_feature_state(feature, enabled)
  state.features.initial[feature] = enabled
end

function M.set_config(config)
  state.config = config
end

function M.update_buffer_state(key, value)
  state.buffer[key] = value
end

function M.get_buffer_state()
  return state.buffer
end

function M.reset_revealed_lines()
  state.buffer.revealed_lines = {}
end

function M.set_revealed_line(line_num, revealed)
  state.buffer.revealed_lines[line_num] = revealed
end

function M.is_line_revealed(line_num)
  return state.buffer.revealed_lines[line_num]
end

return M 