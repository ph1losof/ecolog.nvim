local M = {}

local string_match = string.match
local string_sub = string.sub
local string_rep = string.rep

local state = require("ecolog.shelter.state")

function M.match_env_file(filename, config)
  if not filename then
    return false
  end

  if filename:match("^%.env$") or filename:match("^%.env%.[^.]+$") then
    return true
  end

  if config and config.env_file_pattern then
    local patterns = type(config.env_file_pattern) == "string" and { config.env_file_pattern }
      or config.env_file_pattern

    for _, pattern in ipairs(patterns) do
      if filename:match(pattern) then
        return true
      end
    end
  end

  return false
end

function M.matches_shelter_pattern(key)
  local config = state.get_config()
  if not key or not config.patterns or vim.tbl_isempty(config.patterns) then
    return nil
  end

  for pattern, mode in pairs(config.patterns) do
    local lua_pattern = pattern:gsub("%*", ".*"):gsub("%%", "%%%%")
    if key:match("^" .. lua_pattern .. "$") then
      return mode
    end
  end

  return nil
end

function M.determine_masked_value(value, opts)
  if not value or value == "" then
    return ""
  end

  opts = opts or {}
  local key = opts.key
  local config = state.get_config()
  local pattern_mode = key and M.matches_shelter_pattern(key)

  if pattern_mode then
    if pattern_mode == "none" then
      return value
    elseif pattern_mode == "full" then
      return string_rep(config.mask_char, #value)
    end
  else
    if config.default_mode == "none" then
      return value
    elseif config.default_mode == "full" then
      return string_rep(config.mask_char, #value)
    end
  end

  local settings = type(config.partial_mode) == "table" and config.partial_mode or state.get_default_partial_mode()

  local show_start = math.max(0, settings.show_start or 0)
  local show_end = math.max(0, settings.show_end or 0)
  local min_mask = math.max(1, settings.min_mask or 1)

  if #value <= (show_start + show_end) or #value < (show_start + show_end + min_mask) then
    return string_rep(config.mask_char, #value)
  end

  local mask_length = math.max(min_mask, #value - show_start - show_end)

  return string_sub(value, 1, show_start)
    .. string_rep(config.mask_char, mask_length)
    .. string_sub(value, -show_end)
end

function M.has_cmp()
  return vim.fn.exists(":CmpStatus") > 0
end

return M 