local M = {}

local config = require("ecolog.shelter.state").get_config
local utils = require("ecolog.utils")
local string_sub = string.sub
local string_rep = string.rep
local lru_cache = require("ecolog.shelter.lru_cache")

local mode_cache = lru_cache.new(1000)
local value_cache = lru_cache.new(1000)

---@param key string|nil
---@param source string|nil
---@param patterns table|nil
---@param sources table|nil
---@param default_mode string|nil
---@return "none"|"partial"|"full"
function M.determine_masking_mode(key, source, patterns, sources, default_mode)
  local cache_key = string.format("%s:%s:%s:%s:%s", 
    key or "", 
    source or "", 
    vim.inspect(patterns or {}),
    vim.inspect(sources or {}),
    default_mode or ""
  )
  
  local cached = mode_cache:get(cache_key)
  if cached then
    return cached
  end

  local conf = config()
  patterns = patterns or conf.patterns
  sources = sources or conf.sources
  default_mode = default_mode or conf.default_mode

  local result
  if key and patterns then
    for pattern, mode in pairs(patterns) do
      local lua_pattern = utils.convert_to_lua_pattern(pattern)
      if key:match("^" .. lua_pattern .. "$") then
        result = mode
        break
      end
    end
  end

  if not result and source and sources then
    local source_to_match = source
    if source ~= "vault" and source ~= "asm" then
      source_to_match = vim.fn.fnamemodify(source, ":t")
    end
    for pattern, mode in pairs(sources) do
      local lua_pattern = utils.convert_to_lua_pattern(pattern)
      if source_to_match:match("^" .. lua_pattern .. "$") then
        result = mode
        break
      end
    end
  end

  result = result or default_mode or "partial"
  mode_cache:put(cache_key, result)
  return result
end

---Generate a cache key for masked values
---@param value string
---@param settings table
---@return string
local function get_value_cache_key(value, settings)
  return string.format("%s:%s:%s:%s:%s:%s:%s",
    value,
    settings.key or "",
    settings.source or "",
    vim.inspect(settings.patterns or {}),
    vim.inspect(settings.sources or {}),
    settings.default_mode or "",
    vim.inspect(settings.partial_mode or {})
  )
end

---@param value string
---@param settings table
function M.determine_masked_value(value, settings)
  if not value then
    return ""
  end

  local cache_key = get_value_cache_key(value, settings)
  local cached = value_cache:get(cache_key)
  if cached then
    if settings.quote_char then
      return settings.quote_char .. cached .. settings.quote_char
    end
    return cached
  end

  local conf = config()
  local mode = M.determine_masking_mode(
    settings.key,
    settings.source,
    settings.patterns,
    settings.sources,
    settings.default_mode
  )

  if mode == "none" then
    value_cache:put(cache_key, value)
    if settings.quote_char then
      return settings.quote_char .. value .. settings.quote_char
    end
    return value
  end

  local mask_length = conf.mask_length
  if mask_length and mask_length > 0 then
    local masked = string_rep(conf.mask_char, mask_length)
    if mode == "partial" and conf.partial_mode then
      local partial_mode = type(conf.partial_mode) == "table" and conf.partial_mode or {
        show_start = 3,
        show_end = 3,
        min_mask = 3,
      }
      local show_start = math.max(0, settings.show_start or partial_mode.show_start or 0)
      local show_end = math.max(0, settings.show_end or partial_mode.show_end or 0)

      if #value <= (show_start + show_end) then
        local result = string_rep(conf.mask_char, #value)
        value_cache:put(cache_key, result)
        if settings.quote_char then
          return settings.quote_char .. result .. settings.quote_char
        end
        return result
      end

      local total_length = show_start + mask_length + show_end
      local full_value_length = settings.quote_char and (#value + 2) or #value

      if #value <= mask_length then
        local result = string_rep(conf.mask_char, #value)
        value_cache:put(cache_key, result)
        if settings.quote_char then
          return settings.quote_char .. result .. settings.quote_char
        end
        return result
      end

      local result = string_sub(value, 1, show_start) .. masked .. string_sub(value, -show_end)
      if total_length < full_value_length and not settings.no_padding then
        result = result .. string_rep(" ", full_value_length - total_length)
      end
      value_cache:put(cache_key, result)
      if settings.quote_char then
        return settings.quote_char .. result .. settings.quote_char
      end
      return result
    end

    local result = string_rep(conf.mask_char, #value)
    value_cache:put(cache_key, result)
    if settings.quote_char then
      return settings.quote_char .. result .. settings.quote_char
    end
    return result
  end

  if mode == "full" or not conf.partial_mode then
    local result = string_rep(conf.mask_char, #value)
    value_cache:put(cache_key, result)
    if settings.quote_char then
      return settings.quote_char .. result .. settings.quote_char
    end
    return result
  end

  local partial_mode = type(conf.partial_mode) == "table" and conf.partial_mode or {
    show_start = 3,
    show_end = 3,
    min_mask = 3,
  }

  local show_start = math.max(0, settings.show_start or partial_mode.show_start or 0)
  local show_end = math.max(0, settings.show_end or partial_mode.show_end or 0)
  local min_mask = math.max(1, settings.min_mask or partial_mode.min_mask or 1)

  if #value <= (show_start + show_end) or #value < (show_start + show_end + min_mask) then
    local result = string_rep(conf.mask_char, #value)
    value_cache:put(cache_key, result)
    if settings.quote_char then
      return settings.quote_char .. result .. settings.quote_char
    end
    return result
  end

  local mask_len = math.max(min_mask, #value - show_start - show_end)
  local result = string_sub(value, 1, show_start)
    .. string_rep(conf.mask_char, mask_len)
    .. string_sub(value, -show_end)

  value_cache:put(cache_key, result)
  if settings.quote_char then
    return settings.quote_char .. result .. settings.quote_char
  end
  return result
end

---@param value string
---@return string, string|nil
function M.extract_value(value_part)
  if not value_part then
    return "", nil
  end

  local value = vim.trim(value_part)

  local first_char = value:sub(1, 1)
  local last_char = value:sub(-1)

  if (first_char == '"' or first_char == "'") and first_char == last_char then
    return value:sub(2, -2), first_char
  end

  return value, nil
end

---@param filename string
---@param config table
---@return boolean
function M.match_env_file(filename, config)
  return utils.match_env_file(filename, config)
end

function M.has_cmp()
  return vim.fn.exists(":CmpStatus") > 0
end

return M
