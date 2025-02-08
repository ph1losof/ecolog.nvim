local M = {}

local config = require("ecolog.shelter.state").get_config
local string_sub = string.sub
local string_rep = string.rep

---@param pattern string
---@return string
local function convert_to_lua_pattern(pattern)
  local escaped = pattern:gsub("[%.%[%]%(%)%+%-%^%$%%]", "%%%1")
  return escaped:gsub("%*", ".*")
end

---@param key string|nil
---@param source string|nil
---@return "none"|"partial"|"full"
function M.determine_masking_mode(key, source)
  local conf = config()

  if key and conf.patterns then
    for pattern, mode in pairs(conf.patterns) do
      local lua_pattern = convert_to_lua_pattern(pattern)
      if key:match("^" .. lua_pattern .. "$") then
        return mode
      end
    end
  end

  if source and conf.sources then
    for pattern, mode in pairs(conf.sources) do
      local lua_pattern = convert_to_lua_pattern(pattern)
      local source_to_match = source
      -- TODO: This has to be refactored not to match the hardcoded source pattern for vault/asm
      if source ~= "vault" and source ~= "asm" then
        source_to_match = vim.fn.fnamemodify(source, ":t")
      end
      if source_to_match:match("^" .. lua_pattern .. "$") then
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

  -- Extract quotes if present
  local first_char = value:sub(1, 1)
  local last_char = value:sub(-1)
  local has_quotes = (first_char == '"' or first_char == "'") and first_char == last_char
  local inner_value = has_quotes and value:sub(2, -2) or value

  if mode == "full" or not config().partial_mode then
    local masked = string_rep(config().mask_char, #inner_value)
    return has_quotes and (first_char .. masked .. first_char) or masked
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

  if #inner_value <= (show_start + show_end) or #inner_value < (show_start + show_end + min_mask) then
    local masked = string_rep(config().mask_char, #inner_value)
    return has_quotes and (first_char .. masked .. first_char) or masked
  end

  local mask_length = math.max(min_mask, #inner_value - show_start - show_end)
  local masked = string_sub(inner_value, 1, show_start)
    .. string_rep(config().mask_char, mask_length)
    .. string_sub(inner_value, -show_end)

  return has_quotes and (first_char .. masked .. first_char) or masked
end

---@param value string
---@return string, string|nil
function M.extract_value(value_part)
  if not value_part then
    return "", nil
  end

  local value = vim.trim(value_part)

  -- Only treat it as quoted if it starts AND ends with the same quote character
  local first_char = value:sub(1, 1)
  local last_char = value:sub(-1)

  if (first_char == '"' or first_char == "'") and first_char == last_char then
    return value:sub(2, -2), first_char
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
