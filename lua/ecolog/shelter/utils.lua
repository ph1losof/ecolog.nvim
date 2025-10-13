local M = {}

-- Lazy-loaded modules and caches
local config, utils, lru_cache, masking_core, mode_cache, value_cache

local string_sub = string.sub
local string_rep = string.rep

local function get_config()
  if not config then
    config = require("ecolog.shelter.state").get_config
  end
  return config
end

local function get_utils()
  if not utils then
    utils = require("ecolog.utils")
  end
  return utils
end

local function get_lru_cache()
  if not lru_cache then
    lru_cache = require("ecolog.shelter.lru_cache")
  end
  return lru_cache
end

local function get_masking_core()
  if not masking_core then
    masking_core = require("ecolog.shelter.masking_core")
  end
  return masking_core
end

local function get_mode_cache()
  if not mode_cache then
    local lru = get_lru_cache()
    mode_cache = lru.new(1000)
  end
  return mode_cache
end

local function get_value_cache()
  if not value_cache then
    local lru = get_lru_cache()
    value_cache = lru.new(1000)
  end
  return value_cache
end

function M.clear_caches()
  local lru = get_lru_cache()
  mode_cache = lru.new(1000)
  value_cache = lru.new(1000)
end

local function table_to_key(tbl)
  if not tbl or type(tbl) ~= "table" then
    return ""
  end
  local parts = {}
  for k, v in pairs(tbl) do
    parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
  end
  table.sort(parts)
  return table.concat(parts, ",")
end

---@param key string|nil
---@param source string|nil
---@param patterns table|nil
---@param sources table|nil
---@param default_mode string|nil
---@return "none"|"partial"|"full"
function M.determine_masking_mode(key, source, patterns, sources, default_mode)
  local cache_key = string.format(
    "%s:%s:%s:%s:%s",
    key or "",
    source or "",
    table_to_key(patterns),
    table_to_key(sources),
    default_mode or ""
  )

  local m_cache = get_mode_cache()
  local cached = m_cache:get(cache_key)
  if cached then
    return cached
  end

  local conf = get_config()()
  patterns = patterns or conf.patterns
  sources = sources or conf.sources
  default_mode = default_mode or conf.default_mode

  local result
  if key and patterns then
    local matches = {}
    local util = get_utils()
    for pattern, mode in pairs(patterns) do
      local lua_pattern = util.convert_to_lua_pattern(pattern)
      if key:match("^" .. lua_pattern .. "$") then
        local wildcard_count = select(2, pattern:gsub("[*]", ""))
        local specificity = (#pattern * 100) - (wildcard_count * 50)
        table.insert(matches, { pattern = pattern, mode = mode, specificity = specificity })
      end
    end

    if #matches > 0 then
      table.sort(matches, function(a, b)
        return a.specificity > b.specificity
      end)
      result = matches[1].mode
    end
  end

  if not result and source and sources then
    local source_to_match = source
    if source ~= "vault" and source ~= "asm" then
      source_to_match = vim.fn.fnamemodify(source, ":t")
    end
    local util = get_utils()
    for pattern, mode in pairs(sources) do
      local lua_pattern = util.convert_to_lua_pattern(pattern)
      if source_to_match:match("^" .. lua_pattern .. "$") then
        result = mode
        break
      end
    end
  end

  result = result or default_mode or "partial"
  local m_cache = get_mode_cache()
  m_cache:put(cache_key, result)
  return result
end

---Generate a cache key for masked values
---@param value string
---@param settings table
---@return string
local function get_value_cache_key(value, settings)
  return string.format(
    "%s:%s:%s:%s:%s:%s:%s",
    value,
    settings.key or "",
    settings.source or "",
    table_to_key(settings.patterns),
    table_to_key(settings.sources),
    settings.default_mode or "",
    table_to_key(settings.partial_mode)
  )
end

---@param value string
---@param settings table
function M.determine_masked_value(value, settings)
  if not value then
    return ""
  end

  local cache_key = get_value_cache_key(value, settings)
  local v_cache = get_value_cache()
  local cached = v_cache:get(cache_key)
  if cached then
    if settings.quote_char then
      return settings.quote_char .. cached .. settings.quote_char
    end
    return cached
  end

  local conf = get_config()()
  local mode =
    M.determine_masking_mode(settings.key, settings.source, settings.patterns, settings.sources, settings.default_mode)

  if mode == "none" then
    v_cache:put(cache_key, value)
    if settings.quote_char then
      return settings.quote_char .. value .. settings.quote_char
    end
    return value
  end

  local mask_length = conf.mask_length
  if not mask_length then
    local global_config = require("ecolog").get_config()
    mask_length = global_config and global_config.mask_length
  end

  -- Handle multi-line values
  local is_multi_line = value:find("\n") ~= nil
  if is_multi_line then
    return M.mask_multi_line_value(value, settings, conf, mode, mask_length)
  end

  -- Only default mask_length for full mode
  if mode == "full" or not conf.partial_mode then
    mask_length = mask_length or #value
    local result
    if not mask_length then
      result = string_rep(conf.mask_char, #value)
    else
      result = string_rep(conf.mask_char, mask_length)
    end
    local v_cache = get_value_cache()
    v_cache:put(cache_key, result)
    if settings.quote_char then
      return settings.quote_char .. result .. settings.quote_char
    end
    return result
  end

  local partial_mode = type(conf.partial_mode) == "table" and conf.partial_mode
    or {
      show_start = 3,
      show_end = 3,
      min_mask = 3,
    }

  local show_start = math.max(0, settings.show_start or partial_mode.show_start or 0)
  local show_end = math.max(0, settings.show_end or partial_mode.show_end or 0)
  local min_mask = math.max(0, settings.min_mask or partial_mode.min_mask or 0)

  if mask_length then
    local base_mask = string_rep(conf.mask_char, mask_length)

    local available_in_mask = mask_length - show_start - show_end

    local v_cache = get_value_cache()
    if mask_length <= (show_start + show_end) or available_in_mask < min_mask then
      local result = base_mask
      v_cache:put(cache_key, result)
      if settings.quote_char then
        return settings.quote_char .. result .. settings.quote_char
      end
      return result
    end

    local start_part = show_start > 0 and string_sub(value, 1, math.min(show_start, #value)) or ""
    local end_part = show_end > 0 and #value > show_end and string_sub(value, -show_end) or ""
    local middle_mask_len = mask_length - #start_part - #end_part
    if middle_mask_len < 0 then
      middle_mask_len = 0
    end
    local result = start_part .. string_rep(conf.mask_char, middle_mask_len) .. end_part
    v_cache:put(cache_key, result)
    if settings.quote_char then
      return settings.quote_char .. result .. settings.quote_char
    end
    return result
  end

  local available_middle = #value - show_start - show_end

  local v_cache = get_value_cache()
  if #value <= (show_start + show_end) or available_middle < min_mask then
    local result = string_rep(conf.mask_char, #value)
    v_cache:put(cache_key, result)
    if settings.quote_char then
      return settings.quote_char .. result .. settings.quote_char
    end
    return result
  end

  local end_part = show_end > 0 and string_sub(value, -show_end) or ""
  local result = string_sub(value, 1, show_start) .. string_rep(conf.mask_char, available_middle) .. end_part

  v_cache:put(cache_key, result)
  if settings.quote_char then
    return settings.quote_char .. result .. settings.quote_char
  end
  return result
end

---Mask multi-line values while preserving newlines
---@param value string The multi-line value
---@param settings table Masking settings
---@param conf table Shelter configuration
---@param mode string Masking mode
---@param mask_length number? Optional mask length
---@return string masked_value The masked multi-line value
function M.mask_multi_line_value(value, settings, conf, mode, mask_length)
  local lines = vim.split(value, "\n", { plain = true })
  local masked_lines = {}

  -- When mask_length is specified, apply it per line with exact length
  if mask_length then
    local partial_mode_cfg = type(conf.partial_mode) == "table" and conf.partial_mode
      or {
        show_start = 3,
        show_end = 3,
        min_mask = 3,
      }

    local show_start = math.max(0, settings.show_start or partial_mode_cfg.show_start or 0)
    local show_end = math.max(0, settings.show_end or partial_mode_cfg.show_end or 0)
    local min_mask = math.max(0, settings.min_mask or partial_mode_cfg.min_mask or 0)
    local is_partial = mode == "partial" and conf.partial_mode

    local num_lines = #lines
    local core = get_masking_core()

    for i, line in ipairs(lines) do
      local line_length = #line
      local apply_start = (i == 1 or num_lines == 1)
      local apply_end = (i == num_lines or num_lines == 1)
      local current_show_start = apply_start and show_start or 0
      local current_show_end = apply_end and show_end or 0

      local mask_for_line = core.generate_line_mask(
        line,
        line_length,
        mask_length,
        conf.mask_char,
        is_partial,
        current_show_start,
        current_show_end,
        min_mask
      )

      masked_lines[i] = mask_for_line
    end
  else
    -- Original behavior when mask_length is not specified
    if mode == "full" or not conf.partial_mode then
      -- Full masking - mask each line completely
      for i, line in ipairs(lines) do
        local line_mask_length = mask_length or #line
        if line_mask_length > 0 then
          masked_lines[i] = string_rep(conf.mask_char, line_mask_length)
        else
          masked_lines[i] = ""
        end
      end
    else
      -- Partial masking - handle first and last lines specially
      local partial_mode = type(conf.partial_mode) == "table" and conf.partial_mode
        or {
          show_start = 3,
          show_end = 3,
          min_mask = 3,
        }

      local show_start = math.max(0, settings.show_start or partial_mode.show_start or 0)
      local show_end = math.max(0, settings.show_end or partial_mode.show_end or 0)
      local min_mask = math.max(0, settings.min_mask or partial_mode.min_mask or 0)

      for i, line in ipairs(lines) do
        if i == 1 and #lines > 1 then
          -- First line - show start, mask end
          local available_middle = #line - show_start
          if #line <= show_start or available_middle < min_mask then
            masked_lines[i] = string_rep(conf.mask_char, #line)
          else
            masked_lines[i] = string_sub(line, 1, show_start) .. string_rep(conf.mask_char, available_middle)
          end
        elseif i == #lines and #lines > 1 then
          -- Last line - mask start, show end
          local available_middle = #line - show_end
          if #line <= show_end or available_middle < min_mask then
            masked_lines[i] = string_rep(conf.mask_char, #line)
          else
            masked_lines[i] = string_rep(conf.mask_char, available_middle) .. string_sub(line, -show_end)
          end
        else
          -- Middle lines or single line - apply standard partial masking
          local available_middle = #line - show_start - show_end
          if #line <= (show_start + show_end) or available_middle < min_mask then
            masked_lines[i] = string_rep(conf.mask_char, #line)
          else
            masked_lines[i] = string_sub(line, 1, show_start)
              .. string_rep(conf.mask_char, available_middle)
              .. string_sub(line, -show_end)
          end
        end
      end
    end
  end

  local result = table.concat(masked_lines, "\n")
  local v_cache = get_value_cache()
  v_cache:put(get_value_cache_key(value, settings), result)

  if settings.quote_char then
    return settings.quote_char .. result .. settings.quote_char
  end
  return result
end

---@param value_part string
---@return string, string|nil, string|nil value, quote_char, rest
function M.extract_value(value_part)
  if not value_part then
    return "", nil, nil
  end

  local value = vim.trim(value_part)

  local first_char = value:sub(1, 1)
  local last_char = value:sub(-1)

  if (first_char == '"' or first_char == "'") and first_char == last_char then
    local pos = 2
    while pos <= #value do
      if value:sub(pos, pos) == first_char and value:sub(pos - 1, pos - 1) ~= "\\" then
        local quoted_value = value:sub(2, pos - 1)
        local rest = pos < #value and value:sub(pos + 1) or nil
        return quoted_value, first_char, rest
      end
      pos = pos + 1
    end
    return value:sub(2, -2), first_char, nil
  end

  local space_pos = value:find("%s")
  local comment_pos = value:find("#")
  local end_pos = space_pos or comment_pos or #value + 1
  local rest = end_pos <= #value and value:sub(end_pos) or nil

  return value:sub(1, end_pos - 1), nil, rest
end

---@param filename string
---@param config table
---@return boolean
function M.match_env_file(filename, config)
  local util = get_utils()
  return util.match_env_file(filename, config)
end

function M.has_cmp()
  return vim.fn.exists(":CmpStatus") > 0
end

---Mask key-value pairs in a comment string
---@param comment_value string The comment text containing key-value pairs
---@param source string The source of the comment (e.g., file path)
---@param shelter table The shelter module reference
---@param feature string The feature name to check for enabling/masking
---@return string The comment text with masked values
function M.mask_comment(comment_value, source, shelter, feature)
  if not comment_value or shelter.get_config().skip_comments then
    return comment_value
  end

  local buffer = require("ecolog.shelter.buffer")
  local pos = 1
  local result = comment_value
  local multi_line_state = {}

  while true do
    local kv, updated_state = buffer.find_next_key_value(result, pos, multi_line_state)
    if not kv then
      break
    end

    local masked = shelter.mask_value(kv.value, feature, kv.key, source)

    if kv.quote_char then
      masked = kv.quote_char .. masked .. kv.quote_char
    end

    result = result:sub(1, kv.eq_pos) .. masked .. result:sub(kv.next_pos)

    pos = kv.eq_pos + #masked + 1
    multi_line_state = updated_state or multi_line_state
  end

  return result
end

return M
