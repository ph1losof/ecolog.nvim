---@class EcologMaskingEngine
---@field private cache table LRU cache for parsed results
local M = {}


local api = vim.api
local api_buf_is_valid = api.nvim_buf_is_valid
local api_buf_clear_namespace = api.nvim_buf_clear_namespace
local api_buf_set_extmark = api.nvim_buf_set_extmark
local vim_split = vim.split
local vim_schedule = vim.schedule
local string_rep = string.rep
local table_concat = table.concat
local math_min = math.min
local math_max = math.max
local math_floor = math.floor

local lru_cache = require("ecolog.shelter.lru_cache")
local common = require("ecolog.shelter.common")
local utils = require("ecolog.utils")
local shelter_utils = require("ecolog.shelter.utils")
local comment_parser = require("ecolog.shelter.comment_parser")

local multiline_parsing
local function get_multiline_parser()
  if not multiline_parsing then
    multiline_parsing = require("ecolog.shelter.multiline_parsing")
  end
  return multiline_parsing
end

local perf_config = {
  parsed_cache_size = 200,
  extmark_cache_size = 100,
  mask_cache_size = 150,
  batch_size = 100,
  hash_sample_rate = 16,
  estimated_vars_per_lines = 4,
  estimated_extmarks_multiplier = 2,
}

local string_cache
local function intern_string(s)
  if not s then return s end
  if not string_cache then
    string_cache = setmetatable({}, {__mode = "v"})
  end
  local cached = string_cache[s]
  if cached then return cached end
  string_cache[s] = s
  return s
end


local function fast_hash(content)
  if type(content) == "table" then
    content = table_concat(content, "\n")
  end
  local len = #content
  if len == 0 then return "empty" end
  
  local hash = len
  local step = math_max(1, math_floor(len / perf_config.hash_sample_rate))
  for i = 1, len, step do
    hash = hash + content:byte(i) * i
  end
  return tostring(hash)
end


function M.configure_performance(config)
  if config then
    for key, value in pairs(config) do
      if perf_config[key] ~= nil and type(value) == type(perf_config[key]) then
        perf_config[key] = value
      end
    end
    
    
    local cache_config = {
      enable_stats = true,
      ttl_ms = config.cache_ttl_ms or 3600000,
      cleanup_interval_ms = config.cache_cleanup_interval_ms or 300000,
      auto_cleanup = config.auto_cleanup ~= false,
    }
    
    if parsed_cache then parsed_cache:configure(cache_config) end
    if extmark_cache then extmark_cache:configure(cache_config) end
    if mask_length_cache then mask_length_cache:configure(cache_config) end
  end
  return perf_config
end


local parsed_cache, extmark_cache, mask_length_cache

local function get_parsed_cache()
  if not parsed_cache then
    parsed_cache = lru_cache.new(perf_config.parsed_cache_size, {
      enable_stats = true,
      ttl_ms = 3600000, 
      auto_cleanup = true,
    })
  end
  return parsed_cache
end

local function get_extmark_cache()
  if not extmark_cache then
    extmark_cache = lru_cache.new(perf_config.extmark_cache_size, {
      enable_stats = true,
      ttl_ms = 1800000, 
      auto_cleanup = true,
    })
  end
  return extmark_cache
end

local function get_mask_cache()
  if not mask_length_cache then
    mask_length_cache = lru_cache.new(perf_config.mask_cache_size, {
      enable_stats = true,
      ttl_ms = 1800000, 
      auto_cleanup = true,
    })
  end
  return mask_length_cache
end



local BACKSLASH, EMPTY_STRING, SPACE, NEWLINE

local function get_constants()
  if not BACKSLASH then
    BACKSLASH = intern_string("\\")
    EMPTY_STRING = intern_string("")
    SPACE = intern_string(" ")
    NEWLINE = intern_string("\n")
  end
end


local PATTERNS = {
  comment = "^%s*#",
  equals = "=",
  backslash_end = "\\%s*$",
  leading_spaces = "^%s*",
  trailing_spaces = "%s*$",
  quote_chars = "[\"']",
}

---Extract inline comment from a line if in multi-line context
---@param line string The line to check
---@param was_in_multi_line boolean Whether we were in multi-line mode before this line
---@param multi_line_state table Current multi-line state
---@return string? comment The extracted comment text or nil
local function extract_inline_comment(line, was_in_multi_line, multi_line_state)
  if not (was_in_multi_line or multi_line_state.in_multi_line) then
    return nil
  end

  local hash_pos = line:find("#", 1, true)
  if not hash_pos or hash_pos == 1 then
    return nil
  end

  return line:sub(hash_pos + 1):match("^%s*(.-)%s*$")
end

---Merge parsed variables from comment parser into main table
---@param target table Target parsed_vars table
---@param source table Source parsed_vars from comment parser
local function merge_parsed_vars(target, source)
  for key, var in pairs(source) do
    target[key] = var
  end
end

---@class ParsedVariable
---@field key string The variable key
---@field value string The variable value
---@field quote_char string? The quote character used
---@field start_line number Starting line number
---@field end_line number Ending line number
---@field eq_pos number Position of equals sign
---@field is_multi_line boolean Whether this is a multi-line value
---@field has_newlines boolean Whether the value contains newlines
---@field content_hash string Hash of the content for caching
---@field is_comment boolean Whether this variable is from a comment line

---@class ExtmarkSpec
---@field line number 0-based line number
---@field col number Column position
---@field opts table Extmark options

---Parse lines into variables with caching
---@param lines string[] Array of lines to parse
---@param content_hash string Hash of the content for caching
---@return table<string, ParsedVariable> parsed_vars
function M.parse_lines_cached(lines, content_hash)
  get_constants() 

  local cached_result = get_parsed_cache():get(content_hash)
  if cached_result then
    return cached_result
  end

  
  local lines_count = #lines
  local estimated_vars = math_max(1, math_floor(lines_count / perf_config.estimated_vars_per_lines))
  
  local parsed_vars = common.new_table(0, estimated_vars)
  local line_start_positions = common.new_table(0, estimated_vars)
  local multi_line_state = {}
  local current_line_idx = 1

  while current_line_idx <= #lines do
    local line = lines[current_line_idx]

    if line == EMPTY_STRING then
      current_line_idx = current_line_idx + 1
      goto continue
    end

    local is_comment_line = line:find(PATTERNS.comment)

    if is_comment_line then
      local comment_vars = comment_parser.parse_comment_line(line, current_line_idx, content_hash)
      merge_parsed_vars(parsed_vars, comment_vars)

      current_line_idx = current_line_idx + 1
      goto continue
    end

    if not multi_line_state.in_multi_line then
      local eq_pos = line:find("=", 1, true)
      if eq_pos then
        local potential_key = line:sub(1, eq_pos - 1):match("^%s*(.-)%s*$")
        if potential_key and #potential_key > 0 then

          local unique_tracking_key = potential_key .. "_line_" .. current_line_idx
          line_start_positions[unique_tracking_key] = current_line_idx

          if not line_start_positions[potential_key] then
            line_start_positions[potential_key] = current_line_idx
          end
        end
      end
    end

    local was_in_multi_line = multi_line_state.in_multi_line

    local key, value, comment, quote_char, updated_state = utils.extract_line_parts(line, multi_line_state)
    if updated_state then
      multi_line_state = updated_state
      if updated_state.in_multi_line and updated_state.key then
        local unique_tracking_key = updated_state.key .. "_line_" .. current_line_idx
        if not line_start_positions[unique_tracking_key] then
          line_start_positions[unique_tracking_key] = current_line_idx
        end

        if not line_start_positions[updated_state.key] then
          line_start_positions[updated_state.key] = current_line_idx
        end
      end
    end

    if comment and not comment:find("\n") then
      local inline_vars = comment_parser.parse_inline_comment(comment, line, current_line_idx, content_hash)
      merge_parsed_vars(parsed_vars, inline_vars)
    end

    local inline_comment = extract_inline_comment(line, was_in_multi_line, multi_line_state)
    if inline_comment and not inline_comment:find("\n") then
      local inline_vars = comment_parser.parse_inline_comment(inline_comment, line, current_line_idx, content_hash)
      merge_parsed_vars(parsed_vars, inline_vars)
    end

    if key and value then

      local unique_tracking_key = key .. "_line_" .. current_line_idx
      local start_line = line_start_positions[unique_tracking_key] or line_start_positions[key] or current_line_idx
      local end_line = current_line_idx

      local unique_key = key .. "_line_" .. start_line
      parsed_vars[unique_key] = {
        key = key,
        value = value,
        quote_char = quote_char,
        start_line = start_line,
        end_line = end_line,
        eq_pos = lines[start_line]:find("=", 1, true) or 1,
        is_multi_line = start_line < end_line,
        has_newlines = value:find(NEWLINE) ~= nil,
        content_hash = content_hash,
        is_comment = false,
      }
      multi_line_state = {}
    end

    current_line_idx = current_line_idx + 1
    ::continue::
  end

  get_parsed_cache():put(content_hash, parsed_vars)
  return parsed_vars
end

---Optimized mask generation for mask_length scenarios
---@param var_info ParsedVariable The parsed variable information
---@param lines string[] The original lines
---@param config table Configuration for masking
---@param source_filename string Source filename for masking
---@param mask_length number The mask length to apply
---@param mask_config table Mask configuration
---@return string[] distributed_masks Array of masks for each line
function M.create_mask_length_masks(var_info, lines, config, source_filename, mask_length, mask_config)
  get_constants()
  local state = require("ecolog.shelter.state")

  local has_revealed_line = false
  for line_idx = var_info.start_line, var_info.end_line do
    if state.is_line_revealed(line_idx) then
      has_revealed_line = true
      break
    end
  end

  if has_revealed_line then
    local unmasked_result = {}
    for line_idx = var_info.start_line, var_info.end_line do
      local original_line = lines[line_idx]
      if original_line then
        if line_idx == var_info.start_line then
          local eq_pos = original_line:find("=")
          if eq_pos then
            unmasked_result[line_idx] = original_line:sub(eq_pos + 1)
          else
            unmasked_result[line_idx] = original_line
          end
        else
          unmasked_result[line_idx] = original_line
        end
      end
    end
    return unmasked_result
  end

  local cache_parts = {
    var_info.key,
    source_filename,
    tostring(mask_length),
    var_info.quote_char or "none",
    tostring(var_info.start_line),
    tostring(var_info.end_line)
  }
  local cache_key = fast_hash(table_concat(cache_parts, ":"))


  local cached_result = get_mask_cache():get(cache_key)
  if cached_result then
    return cached_result
  end

  local distributed_masks = {}

  local mask_char = mask_config.mask_char
  local quote_char = var_info.quote_char
  local first_line = lines[var_info.start_line]
  local eq_pos = first_line:find("=")

  if not eq_pos then
    return {}
  end

  local partial_config = config.partial_mode
  local is_partial = partial_config and type(partial_config) == "table" and
                    (partial_config.show_start or 0) > 0 and (partial_config.show_end or 0) > 0

  local show_start = is_partial and math.max(0, partial_config.show_start or 0) or 0
  local show_end = is_partial and math.max(0, partial_config.show_end or 0) or 0
  local min_mask = is_partial and math.max(0, partial_config.min_mask or 0) or 0

  -- For multi-line with backslash continuation, extract value from each line
  if var_info.is_multi_line and not var_info.has_newlines then
    -- Backslash continuation: extract value parts from actual file lines
    for line_idx = var_info.start_line, var_info.end_line do
      local line = lines[line_idx]
      local line_value
      local has_backslash = false

      if line_idx == var_info.start_line then
        -- First line: extract value after =
        local eq_idx = line:find("=", 1, true)
        if eq_idx then
          line_value = line:sub(eq_idx + 1)
          -- Remove leading quote if present
          if quote_char and line_value:sub(1, 1) == quote_char then
            line_value = line_value:sub(2)
          end
        end
      else
        -- Continuation lines: get the full line
        line_value = line
      end

      -- Check for backslash continuation before removing it
      if line_value and line_value:match("\\%s*$") then
        has_backslash = true
      end

      -- Remove trailing backslash and whitespace, and inline comments
      if line_value then
        line_value = line_value:gsub("%s*\\%s*$", "")  -- Remove trailing backslash
        local comment_pos = line_value:find("#")
        if comment_pos then
          line_value = line_value:sub(1, comment_pos - 1)
        end
        line_value = line_value:match("^(.-)%s*$")  -- Trim trailing whitespace

        -- Remove trailing quote on last line if present
        if line_idx == var_info.end_line and quote_char and line_value:sub(-1) == quote_char then
          line_value = line_value:sub(1, -2)
        end
      end

      local line_length = line_value and #line_value or 0
      local mask_for_line

      if is_partial and line_length > 0 then
        local is_first = line_idx == var_info.start_line
        local is_last = line_idx == var_info.end_line
        local current_show_start = is_first and show_start or 0
        local current_show_end = is_last and show_end or 0
        local available_middle = line_length - current_show_start - current_show_end

        if line_length <= (current_show_start + current_show_end) or available_middle < min_mask then
          -- Full mask for this line - exactly mask_length + padding
          mask_for_line = string_rep(mask_char, mask_length)
          if line_length > mask_length then
            mask_for_line = mask_for_line .. string_rep(SPACE, line_length - mask_length)
          end
        else
          -- Partial mask for this line - exactly mask_length + padding
          local middle_mask_len = mask_length - current_show_start - current_show_end
          local start_part = current_show_start > 0 and line_value:sub(1, current_show_start) or EMPTY_STRING
          local end_part = current_show_end > 0 and line_value:sub(-current_show_end) or EMPTY_STRING
          mask_for_line = table_concat({start_part, string_rep(mask_char, middle_mask_len), end_part})

          -- Add padding if actual value is longer than mask
          local mask_total = current_show_start + middle_mask_len + current_show_end
          if line_length > mask_total then
            mask_for_line = mask_for_line .. string_rep(SPACE, line_length - mask_total)
          end
        end
      else
        -- Full mode: exactly mask_length + padding
        mask_for_line = string_rep(mask_char, mask_length)
        if line_length > mask_length then
          mask_for_line = mask_for_line .. string_rep(SPACE, line_length - mask_length)
        end
      end

      -- Add quotes before padding
      if line_idx == var_info.start_line and quote_char then
        mask_for_line = quote_char .. mask_for_line
      end
      if line_idx == var_info.end_line and quote_char then
        -- Insert quote before padding
        local mask_without_padding = mask_for_line:match("^(.-)%s*$") or mask_for_line
        local padding_len = #mask_for_line - #mask_without_padding
        mask_for_line = mask_without_padding .. quote_char
        if padding_len > 0 then
          mask_for_line = mask_for_line .. string_rep(SPACE, padding_len)
        end
      end

      -- Add backslash continuation if it was present
      if has_backslash then
        mask_for_line = mask_for_line .. " \\"
      end

      distributed_masks[line_idx] = mask_for_line
    end
  else
    -- For values with actual newlines (quoted strings), split by newline
    local value_to_mask = var_info.value

    if quote_char then
      local val_len = #value_to_mask
      if val_len > 1 and value_to_mask:sub(1, 1) == quote_char and value_to_mask:sub(val_len, val_len) == quote_char then
        value_to_mask = value_to_mask:sub(2, val_len - 1)
      end
    end

    local value_lines = vim_split(value_to_mask, NEWLINE, { plain = true })
    local num_lines = #value_lines

    -- Apply masking per line with mask_length on each line
    for i, line_value in ipairs(value_lines) do
      local line_idx = var_info.start_line + i - 1
      local line_length = #line_value
      local mask_for_line

      if is_partial and line_length > 0 then
        local apply_start = (i == 1 or num_lines == 1)
        local apply_end = (i == num_lines or num_lines == 1)
        local current_show_start = apply_start and show_start or 0
        local current_show_end = apply_end and show_end or 0
        local available_middle = line_length - current_show_start - current_show_end

        if line_length <= (current_show_start + current_show_end) or available_middle < min_mask then
          -- Full mask for this line - exactly mask_length + padding
          mask_for_line = string_rep(mask_char, mask_length)
          if line_length > mask_length then
            mask_for_line = mask_for_line .. string_rep(SPACE, line_length - mask_length)
          end
        else
          -- Partial mask for this line - exactly mask_length + padding
          local middle_mask_len = mask_length - current_show_start - current_show_end
          local start_part = current_show_start > 0 and line_value:sub(1, current_show_start) or EMPTY_STRING
          local end_part = current_show_end > 0 and line_value:sub(-current_show_end) or EMPTY_STRING
          mask_for_line = table_concat({start_part, string_rep(mask_char, middle_mask_len), end_part})

          -- Add padding if actual value is longer than mask
          local mask_total = current_show_start + middle_mask_len + current_show_end
          if line_length > mask_total then
            mask_for_line = mask_for_line .. string_rep(SPACE, line_length - mask_total)
          end
        end
      else
        -- Full mode: exactly mask_length + padding
        mask_for_line = string_rep(mask_char, mask_length)
        if line_length > mask_length then
          mask_for_line = mask_for_line .. string_rep(SPACE, line_length - mask_length)
        end
      end

      -- Add quotes before padding
      if i == 1 and quote_char then
        mask_for_line = quote_char .. mask_for_line
      end
      if i == num_lines and quote_char then
        -- Insert quote before padding
        local mask_without_padding = mask_for_line:match("^(.-)%s*$") or mask_for_line
        local padding_len = #mask_for_line - #mask_without_padding
        mask_for_line = mask_without_padding .. quote_char
        if padding_len > 0 then
          mask_for_line = mask_for_line .. string_rep(SPACE, padding_len)
        end
      end

      distributed_masks[line_idx] = mask_for_line
    end
  end

  get_mask_cache():put(cache_key, distributed_masks)

  return distributed_masks
end

---Generate mask for multi-line value with optimized distribution
---@param var_info ParsedVariable The parsed variable information
---@param lines string[] The original lines
---@param config table Configuration for masking
---@param source_filename string Source filename for masking
---@return string[] distributed_masks Array of masks for each line
function M.generate_multiline_masks(var_info, lines, config, source_filename)
  get_constants() 
  local state = require("ecolog.shelter.state")
  local mask_length = state.get_config().mask_length
  if not mask_length then
    local global_config = require("ecolog").get_config()
    mask_length = global_config and global_config.mask_length
  end

  local has_revealed_line = false
  for line_idx = var_info.start_line, var_info.end_line do
    if state.is_line_revealed(line_idx) then
      has_revealed_line = true
      break
    end
  end

  if has_revealed_line then
    local unmasked_result = {}
    for line_idx = var_info.start_line, var_info.end_line do
      local original_line = lines[line_idx]
      if original_line then
        if line_idx == var_info.start_line then
          local eq_pos = original_line:find("=")
          if eq_pos then
            unmasked_result[line_idx] = original_line:sub(eq_pos + 1)
          else
            unmasked_result[line_idx] = original_line
          end
        else
          unmasked_result[line_idx] = original_line
        end
      end
    end
    return unmasked_result
  end

  if mask_length and (var_info.is_multi_line or var_info.has_newlines) then
    return M.create_mask_length_masks(var_info, lines, config, source_filename, mask_length, state.get_config())
  end

  local clean_value = var_info.has_newlines and var_info.value:gsub(NEWLINE, EMPTY_STRING) or var_info.value
  local entire_masked_value = shelter_utils.determine_masked_value(clean_value, {
    partial_mode = config.partial_mode,
    key = var_info.key,
    source = source_filename,
    quote_char = var_info.quote_char,
  })

  if not entire_masked_value then
    return {}
  end

  local distributed_masks = {}

  if var_info.is_multi_line and not var_info.has_newlines then
    local parser = get_multiline_parser()
    distributed_masks = parser.distribute_multiline_masks(var_info, lines, entire_masked_value)

  elseif var_info.has_newlines then

    local raw_lines = vim.split(var_info.value, NEWLINE, { plain = true })
    local content_only_mask = entire_masked_value

    if var_info.quote_char and entire_masked_value:sub(1, 1) == var_info.quote_char then
      content_only_mask = entire_masked_value:sub(2, -2)
    end

    local consumed_chars = 0
    for line_idx = var_info.start_line, var_info.end_line do
      local array_idx = line_idx - var_info.start_line + 1
      local is_first_line = line_idx == var_info.start_line
      local is_last_line = line_idx == var_info.end_line
      local raw_line = raw_lines[array_idx] or EMPTY_STRING
      local raw_length = #raw_line

      if raw_length > 0 then
        local mask_for_line = content_only_mask:sub(consumed_chars + 1, consumed_chars + raw_length)
        consumed_chars = consumed_chars + raw_length

        local display_mask = mask_for_line
        if is_first_line then
          display_mask = table_concat({var_info.quote_char or EMPTY_STRING, mask_for_line})
        elseif is_last_line then
          display_mask = table_concat({mask_for_line, var_info.quote_char or EMPTY_STRING})
        end

        distributed_masks[line_idx] = display_mask
      end
    end
  end

  return distributed_masks
end

---Create extmarks for parsed variables with batching
---@param parsed_vars table<string, ParsedVariable> Parsed variables
---@param lines string[] Original lines
---@param config table Configuration
---@param source_filename string Source filename
---@param skip_comments boolean Whether to skip comments
---@return ExtmarkSpec[] extmarks Array of extmark specifications
function M.create_extmarks_batch(parsed_vars, lines, config, source_filename, skip_comments)
  local extmarks = {}
  local extmark_cache_key = table_concat({
    source_filename,
    fast_hash(lines),
    tostring(skip_comments),
    config.mask_char or "*",
    tostring(config.mask_length or "nil"),
    config.highlight_group or "Comment"
  }, ":")

  local cached_extmarks = get_extmark_cache():get(extmark_cache_key)
  if cached_extmarks then
    return cached_extmarks
  end

  local estimated_count = 0
  for _ in pairs(parsed_vars) do
    estimated_count = estimated_count + 1
  end
  extmarks = common.new_table(estimated_count * perf_config.estimated_extmarks_multiplier, 0) 

  local base_extmark_opts = {
    virt_text_pos = "overlay",
    hl_mode = "combine",
    priority = 9999,
    strict = false,
  }

  for _, var_info in pairs(parsed_vars) do
    if skip_comments and var_info.is_comment then
      goto continue_var
    end

    if var_info.value and #var_info.value > 0 then
      if var_info.is_multi_line or var_info.has_newlines then
        local state = require("ecolog.shelter.state")
        local has_revealed_line = false
        for line_idx = var_info.start_line, var_info.end_line do
          if state.is_line_revealed(line_idx) then
            has_revealed_line = true
            break
          end
        end

        if not has_revealed_line then
          local distributed_masks = M.generate_multiline_masks(var_info, lines, config, source_filename)

          local highlight_group = config.highlight_group

          for line_idx, mask in pairs(distributed_masks) do
            local extmark_opts = {
              virt_text = { { mask, highlight_group } },
              virt_text_pos = base_extmark_opts.virt_text_pos,
              hl_mode = base_extmark_opts.hl_mode,
              priority = base_extmark_opts.priority,
              strict = base_extmark_opts.strict,
            }

            local col_pos = (line_idx == var_info.start_line) and var_info.eq_pos or 0

            table.insert(extmarks, {
              line = line_idx - 1, 
              col = col_pos,
              opts = extmark_opts,
            })
          end
        end
      else
        local buffer_utils = require("ecolog.shelter.buffer")
        local extmark_result = buffer_utils.create_extmark(var_info.value, var_info, config, source_filename, var_info.start_line)

        if extmark_result then
          if type(extmark_result[1]) == "table" and extmark_result[1][1] then
            for _, extmark in ipairs(extmark_result) do
              table.insert(extmarks, {
                line = extmark[1],
                col = extmark[2],
                opts = extmark[3],
              })
            end
          else
            table.insert(extmarks, {
              line = extmark_result[1],
              col = extmark_result[2],
              opts = extmark_result[3],
            })
          end
        end
      end
    end
    ::continue_var::
  end

  get_extmark_cache():put(extmark_cache_key, extmarks)
  return extmarks
end

---Apply extmarks to buffer with batching for performance
---@param bufnr number Buffer number
---@param extmarks ExtmarkSpec[] Array of extmark specifications
---@param namespace number Namespace for extmarks
---@param batch_size number? Batch size for processing (default: 50)
function M.apply_extmarks_batched(bufnr, extmarks, namespace, batch_size)
  batch_size = batch_size or perf_config.batch_size

  if not api_buf_is_valid(bufnr) or #extmarks == 0 then
    return
  end

  pcall(api_buf_clear_namespace, bufnr, namespace, 0, -1)

  local function apply_batch(start_idx)
    if not api_buf_is_valid(bufnr) then
      return
    end

    local end_idx = math_min(start_idx + batch_size - 1, #extmarks)
    
    local batch_success = 0
    for i = start_idx, end_idx do
      local extmark = extmarks[i]
      local success = pcall(api_buf_set_extmark, bufnr, namespace, extmark.line, extmark.col, extmark.opts)
      if success then
        batch_success = batch_success + 1
      end
    end

    if end_idx < #extmarks then
      if api_buf_is_valid(bufnr) then
        vim_schedule(function()
          apply_batch(end_idx + 1)
        end)
      end
    end
  end

  apply_batch(1)
end

---Process buffer with optimized multi-line support
---@param bufnr number Buffer number
---@param lines string[] Buffer lines
---@param config table Configuration
---@param source_filename string Source filename
---@param namespace number Namespace for extmarks
---@param skip_comments boolean Whether to skip comments
function M.process_buffer_optimized(bufnr, lines, config, source_filename, namespace, skip_comments)
  if not common.ensure_valid_buffer(bufnr) or #lines == 0 then
    return
  end

  local content_hash = fast_hash(lines)
  local parsed_vars = M.parse_lines_cached(lines, content_hash)
  local extmarks = M.create_extmarks_batch(parsed_vars, lines, config, source_filename, skip_comments)

  M.apply_extmarks_batched(bufnr, extmarks, namespace)
end

function M.clear_caches()
  if parsed_cache then parsed_cache:clear() end
  if extmark_cache then extmark_cache:clear() end
  if mask_length_cache then mask_length_cache:clear() end
end

---Clear cache entries for a specific buffer
---@param bufnr number Buffer number
---@param source_filename string Source filename
function M.clear_buffer_cache(bufnr, source_filename)
  if not bufnr or not source_filename then
    return
  end
  
  if parsed_cache then
    parsed_cache:clear()
  end
  
  if extmark_cache then
    extmark_cache:clear()
  end
  
  if mask_length_cache then
    mask_length_cache:clear()
  end
end

---Clear cache entries for specific lines in a buffer
---@param bufnr number Buffer number
---@param start_line number Start line (1-based)
---@param end_line number End line (1-based)
function M.clear_line_range_cache(bufnr, start_line, end_line)
  M.clear_caches()
end

---Get cache statistics for debugging
---@return table stats Cache statistics
function M.get_cache_stats()
  local function get_cache_info(cache, cache_name)
    if not cache then
      return { not_initialized = true, cache_name = cache_name }
    end
    return {
      stats = cache:get_stats(),
      size = cache:get_size(),
      memory_usage = cache:get_memory_usage(),
      hit_ratio = cache:get_hit_ratio(),
    }
  end
  
  return {
    parsed = get_cache_info(parsed_cache, "parsed"),
    extmark = get_cache_info(extmark_cache, "extmark"),
    mask = get_cache_info(mask_length_cache, "mask"),
  }
end

---Get cache hit ratios for performance monitoring
---@return table ratios Hit ratios for all caches
function M.get_cache_hit_ratios()
  return {
    parsed = parsed_cache and parsed_cache:get_hit_ratio() or 0,
    extmark = extmark_cache and extmark_cache:get_hit_ratio() or 0,
    mask = mask_length_cache and mask_length_cache:get_hit_ratio() or 0,
  }
end

---Shutdown all caches (stop timers and clear)
function M.shutdown_caches()
  if parsed_cache then parsed_cache:shutdown() end
  if extmark_cache then extmark_cache:shutdown() end
  if mask_length_cache then mask_length_cache:shutdown() end
end

return M

