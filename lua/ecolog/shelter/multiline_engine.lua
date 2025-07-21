---@class EcologMultilineEngine
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


local perf_config = {
  parsed_cache_size = 200,
  extmark_cache_size = 100,
  mask_cache_size = 150,
  batch_size = 50,
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


    if line == EMPTY_STRING or line:find(PATTERNS.comment) then
      current_line_idx = current_line_idx + 1
      goto continue
    end


    if not multi_line_state.in_multi_line then
      local eq_pos = line:find(PATTERNS.equals)
      if eq_pos then
        local potential_key = line:sub(1, eq_pos - 1):match("^%s*(.-)%s*$")
        if potential_key and #potential_key > 0 then
          -- Create unique key for tracking duplicates
          local unique_tracking_key = potential_key .. "_line_" .. current_line_idx
          line_start_positions[unique_tracking_key] = current_line_idx
          -- Also store without line number for backward compatibility
          if not line_start_positions[potential_key] then
            line_start_positions[potential_key] = current_line_idx
          end
        end
      end
    end

    local key, value, comment, quote_char, updated_state = utils.extract_line_parts(line, multi_line_state)
    if updated_state then
      multi_line_state = updated_state
      if updated_state.in_multi_line and updated_state.key then
        local unique_tracking_key = updated_state.key .. "_line_" .. current_line_idx
        if not line_start_positions[unique_tracking_key] then
          line_start_positions[unique_tracking_key] = current_line_idx
        end
        -- Also store without line number for backward compatibility
        if not line_start_positions[updated_state.key] then
          line_start_positions[updated_state.key] = current_line_idx
        end
      end
    end

    if key and value then
      -- Look up the correct start line for this occurrence
      local unique_tracking_key = key .. "_line_" .. current_line_idx
      local start_line = line_start_positions[unique_tracking_key] or line_start_positions[key] or current_line_idx
      local end_line = current_line_idx
      -- Use a unique identifier that includes the start line to handle duplicates
      local unique_key = key .. "_line_" .. start_line
      parsed_vars[unique_key] = {
        key = key,
        value = value,
        quote_char = quote_char,
        start_line = start_line,
        end_line = end_line,
        eq_pos = lines[start_line]:find(PATTERNS.equals) or 1,
        is_multi_line = start_line < end_line,
        has_newlines = value:find(NEWLINE) ~= nil,
        content_hash = content_hash,
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
  get_constants() -- Initialize constants
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

  -- Use fast hash for cache key instead of expensive string formatting
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

  local value_to_mask = var_info.value

  if quote_char then
    local val_len = #value_to_mask
    if val_len > 1 and value_to_mask:sub(1, 1) == quote_char and value_to_mask:sub(val_len, val_len) == quote_char then
      value_to_mask = value_to_mask:sub(2, val_len - 1)
    end
  end

  -- Optimized string splitting using vim.split
  local single_line_parts = vim_split(value_to_mask, NEWLINE, { plain = true })
  local single_line_value = table_concat(single_line_parts, EMPTY_STRING)
  local actual_length = #single_line_value

  local partial_config = config.partial_mode
  local is_partial = partial_config and type(partial_config) == "table" and
                    (partial_config.show_start or 0) > 0 and (partial_config.show_end or 0) > 0
  local final_mask

  if is_partial and actual_length > 0 then

    local show_start = math.max(0, partial_config.show_start or 0)
    local show_end = math.max(0, partial_config.show_end or 0)
    local min_mask = math.max(1, partial_config.min_mask or 1)

    if actual_length <= (show_start + show_end) or actual_length < (show_start + show_end + min_mask) then

      final_mask = string.rep(mask_char, math.min(mask_length, actual_length))
    else

      local start_part = single_line_value:sub(1, show_start)
      local end_part = single_line_value:sub(-show_end)
      local middle_mask_len = math.max(min_mask, math.min(mask_length - show_start - show_end, actual_length - show_start - show_end))

      -- Use table.concat for better performance
      final_mask = table_concat({start_part, string_rep(mask_char, middle_mask_len), end_part})
    end


    if mask_length > actual_length then
      final_mask = table_concat({final_mask, string_rep(mask_char, mask_length - actual_length)})
    end
  else

    local effective_length = math_min(mask_length, actual_length)
    final_mask = string_rep(mask_char, effective_length)

    if mask_length > actual_length then
      final_mask = table_concat({final_mask, string_rep(mask_char, mask_length - actual_length)})
    end
  end

  if quote_char then
    final_mask = table_concat({quote_char, final_mask, quote_char})
  end

  -- Process first line - need to handle comments separately
  local original_value_part = first_line:sub(eq_pos + 1)
  
  -- Check if there's a backslash and/or comment
  local value_without_backslash_comment = original_value_part
  local backslash_comment_part = ""
  
  if original_value_part:match("\\%s*#") then
    -- Has backslash and comment
    value_without_backslash_comment = original_value_part:match("^(.-)\\") or original_value_part
    backslash_comment_part = original_value_part:match("(\\%s*#.*)$") or ""
  elseif original_value_part:match("\\%s*$") then
    -- Has only backslash
    value_without_backslash_comment = original_value_part:match("^(.-)\\") or original_value_part
    backslash_comment_part = "\\"
  end
  
  local original_value_len = #value_without_backslash_comment
  local masked_len = #final_mask

  if masked_len > original_value_len then
    distributed_masks[var_info.start_line] = final_mask:sub(1, original_value_len) .. backslash_comment_part
  elseif masked_len < original_value_len then
    distributed_masks[var_info.start_line] = table_concat({final_mask, string_rep(SPACE, original_value_len - masked_len)}) .. backslash_comment_part
  else
    distributed_masks[var_info.start_line] = final_mask .. backslash_comment_part
  end

  -- Process continuation lines
  for line_idx = var_info.start_line + 1, var_info.end_line do
    local original_line = lines[line_idx]
    if original_line then
      -- Check for comments on continuation lines
      local line_without_comment = original_line
      local line_comment = ""
      
      -- Handle comments after backslash continuation
      local has_backslash_comment = original_line:match("^(.-)\\%s*#(.*)$")
      if has_backslash_comment then
        line_without_comment = original_line:match("^(.-)\\") or original_line
        line_comment = original_line:match("(\\%s*#.*)$") or ""
      elseif line_idx == var_info.end_line then
        -- Handle comments on the last line (no backslash)
        local comment_pos = original_line:find("#")
        if comment_pos and comment_pos > 1 and original_line:sub(comment_pos - 1, comment_pos - 1):match("%s") then
          line_without_comment = original_line:sub(1, comment_pos - 1)
          line_comment = original_line:sub(comment_pos)
        else
          -- No comment on last line
          line_without_comment = original_line
          line_comment = ""
        end
      end
      
      distributed_masks[line_idx] = string_rep(SPACE, #line_without_comment) .. line_comment
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
  get_constants() -- Initialize constants
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

    local consumed_chars = 0
    for line_idx = var_info.start_line, var_info.end_line do
      local buffer_line = lines[line_idx]
      local is_first_line = line_idx == var_info.start_line
      local is_last_line = line_idx == var_info.end_line

      local parsed_content_part
      local comment_part = ""
      
      if is_first_line then
        local eq_pos = buffer_line:find(PATTERNS.equals)
        if eq_pos then
          local value_part = buffer_line:sub(eq_pos + 1)
          -- Check for comment after backslash
          if value_part:match("\\%s*#") then
            -- Has backslash and comment
            local before_backslash = value_part:match("^(.-)\\")
            local after_backslash = value_part:match("\\(.*)$")
            parsed_content_part = before_backslash or ""
            comment_part = "\\" .. (after_backslash or "")
          elseif value_part:match("\\%s*$") then
            -- Has only backslash, no comment
            local before_backslash = value_part:match("^(.-)\\%s*$")
            parsed_content_part = before_backslash or ""
            comment_part = "\\"
          else
            -- No backslash
            parsed_content_part = value_part
            comment_part = ""
          end
        else
          parsed_content_part = EMPTY_STRING
        end
      elseif is_last_line then
        -- Check for comment on last line
        local comment_pos = buffer_line:find("#")
        if comment_pos and comment_pos > 1 and buffer_line:sub(comment_pos - 1, comment_pos - 1):match("%s") then
          -- Extract content without trimming to preserve spacing
          local content_with_space = buffer_line:sub(1, comment_pos - 1)
          parsed_content_part = content_with_space:match("^%s*(.-)%s*$") or ""
          -- Get the exact spacing before the comment
          local space_before_comment = content_with_space:match("(%s*)$") or ""
          comment_part = space_before_comment .. buffer_line:sub(comment_pos)
        else
          parsed_content_part = buffer_line:match("^%s*(.-)%s*$") or buffer_line
        end
      else
        -- Middle lines: preserve exact structure
        if buffer_line:match("\\%s*#") then
          -- Line has backslash and comment
          local before_backslash = buffer_line:match("^(.-)\\")
          local after_backslash = buffer_line:match("\\(.*)$")
          
          -- Get the actual content to mask (trim leading spaces only)
          parsed_content_part = before_backslash:match("^%s*(.*)$") or ""
          
          -- Preserve everything after the content (backslash + spaces + comment)
          comment_part = "\\" .. (after_backslash or "")
        else
          -- Line has only backslash, no comment
          local before_backslash = buffer_line:match("^(.-)\\%s*$")
          if before_backslash then
            parsed_content_part = before_backslash:match("^%s*(.-)%s*$") or ""
            comment_part = "\\"
          else
            -- No backslash (shouldn't happen in middle lines)
            parsed_content_part = buffer_line:match("^%s*(.-)%s*$") or ""
            comment_part = ""
          end
        end
      end

      local parsed_length = #parsed_content_part
      if parsed_length > 0 or comment_part ~= "" then
        local mask_for_parsed = ""
        if parsed_length > 0 then
          mask_for_parsed = entire_masked_value:sub(consumed_chars + 1, consumed_chars + parsed_length)
          consumed_chars = consumed_chars + parsed_length
        end

        local has_backslash = buffer_line:match(PATTERNS.backslash_end) or buffer_line:match("\\%s*#")
        
        -- Build the final mask preserving original spacing
        local final_mask
        if is_first_line then
          -- First line: mask + comment_part (which includes backslash if present)
          final_mask = mask_for_parsed .. comment_part
        else
          -- Continuation lines: preserve leading spaces
          local original_spacing = buffer_line:match("^(%s*)") or ""
          
          -- The mask should cover exactly the content length
          if parsed_length > 0 then
            -- Apply mask only to the content portion, preserve everything else
            final_mask = original_spacing .. mask_for_parsed .. comment_part
          else
            -- If no content to mask (only comment/backslash), preserve original
            final_mask = buffer_line
          end
        end

        distributed_masks[line_idx] = final_mask
      end
    end

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
  local extmark_cache_key = table_concat({source_filename, fast_hash(lines)}, ":")

  local cached_extmarks = get_extmark_cache():get(extmark_cache_key)
  if cached_extmarks then
    return cached_extmarks
  end

  -- Pre-allocate extmarks table based on estimated count
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

            -- For mask_length scenarios, position extmark after the equals sign on first line, 
            -- at column 0 for subsequent lines
            local col_pos = (line_idx == var_info.start_line) and var_info.eq_pos or 0

            table.insert(extmarks, {
              line = line_idx - 1, -- 0-based
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
    for i = start_idx, end_idx do
      local extmark = extmarks[i]
      pcall(api_buf_set_extmark, bufnr, namespace, extmark.line, extmark.col, extmark.opts)
    end

    if end_idx < #extmarks then
      vim_schedule(function()
        apply_batch(end_idx + 1)
      end)
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
  
  -- Clear cache entries that match this buffer
  if parsed_cache then
    -- Clear all entries for this buffer by iterating through cache
    -- Since we can't iterate through LRU cache directly, we'll clear all
    -- This is safer to ensure no stale entries remain
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
  -- Clear all caches when lines change to ensure consistency
  -- This is a conservative approach but ensures correctness
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

