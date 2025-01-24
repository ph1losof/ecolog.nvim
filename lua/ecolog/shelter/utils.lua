local M = {}

local config = require("ecolog.shelter.state").get_config
local string_sub = string.sub
local string_rep = string.rep

---@param key string|nil
---@param source string|nil
---@return "none"|"partial"|"full"
function M.determine_masking_mode(key, source)
  local conf = config()

  if key and conf.patterns then
    for pattern, mode in pairs(conf.patterns) do
      local lua_pattern = pattern:gsub("%*", ".*"):gsub("%%", "%%%%")
      if key:match("^" .. lua_pattern .. "$") then
        return mode
      end
    end
  end

  if source and conf.sources then
    for pattern, mode in pairs(conf.sources) do
      local lua_pattern = pattern:gsub("%*", ".*"):gsub("%%", "%%%%")
      if source:match("^" .. lua_pattern .. "$") then
        return mode
      end
    end
  end

  return conf.default_mode or "partial"
end

---@param value string
---@param settings table
function M.determine_masked_value(value, settings)
  if not value then
    return ""
  end

  local mode = M.determine_masking_mode(settings.key, settings.source)
  if mode == "none" then
    return value
  end

  if mode == "full" or not config().partial_mode then
    return string_rep(config().mask_char, #value)
  end

  local partial_mode = config().partial_mode
  if type(partial_mode) ~= "table" then
    partial_mode = {
      show_start = 3,
      show_end = 3,
      min_mask = 3,
    }
  end

  local show_start = math.max(0, settings.show_start or partial_mode.show_start or 0)
  local show_end = math.max(0, settings.show_end or partial_mode.show_end or 0)
  local min_mask = math.max(1, settings.min_mask or partial_mode.min_mask or 1)

  if #value <= (show_start + show_end) or #value < (show_start + show_end + min_mask) then
    return string_rep(config().mask_char, #value)
  end

  local mask_length = math.max(min_mask, #value - show_start - show_end)

  return string_sub(value, 1, show_start) .. string_rep(config().mask_char, mask_length) .. string_sub(value, -show_end)
end

---@param value string
---@return string, string|nil
function M.extract_value(value_part)
  if not value_part then
    return "", nil
  end

  local value = vim.trim(value_part)
  local quote_char = value:match("^([\"'])")

  if quote_char then
    local actual_value = value:match("^" .. quote_char .. "(.-)" .. quote_char)
    if actual_value then
      return actual_value, quote_char
    end
  end

  return value, nil
end

function M.match_env_file(filename, config)
  if not filename then
    return false
  end

  local patterns = config.env_file_patterns or { "%.env.*" }
  for _, pattern in ipairs(patterns) do
    if filename:match(pattern) then
      return true
    end
  end

  return false
end

function M.has_cmp()
  return vim.fn.exists(":CmpStatus") > 0
end

return M
