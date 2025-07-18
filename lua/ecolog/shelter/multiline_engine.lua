---@class EcologMultilineEngine
---@field private cache table LRU cache for parsed results
---@field private string_pool table String pool for repeated patterns
local M = {}

local api = vim.api
local lru_cache = require("ecolog.shelter.lru_cache")
local utils = require("ecolog.utils")
local shelter_utils = require("ecolog.shelter.utils")

-- Cache for parsed multi-line values
local parsed_cache = lru_cache.new(200)
local extmark_cache = lru_cache.new(100)

-- String pool for common patterns
local string_pool = {
  asterisk = "*",
  backslash = "\\",
  empty = "",
  space = " ",
  newline = "\n",
}

-- Pre-compiled patterns for better performance
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
  -- Check cache first
  local cached_result = parsed_cache:get(content_hash)
  if cached_result then
    return cached_result
  end

  local parsed_vars = {}
  local line_start_positions = {}
  local multi_line_state = {}
  local current_line_idx = 1
  
  -- Pre-allocate tables to avoid runtime allocation
  -- Note: Using regular tables since table.new might not be available
  
  while current_line_idx <= #lines do
    local line = lines[current_line_idx]
    
    -- Skip empty lines and comments efficiently
    if line == string_pool.empty or line:find(PATTERNS.comment) then
      current_line_idx = current_line_idx + 1
      goto continue
    end

    -- Track variable start positions before multi-line parsing
    if not multi_line_state.in_multi_line then
      local eq_pos = line:find(PATTERNS.equals)
      if eq_pos then
        local potential_key = line:sub(1, eq_pos - 1):match("^%s*(.-)%s*$")
        if potential_key and #potential_key > 0 then
          line_start_positions[potential_key] = current_line_idx
        end
      end
    end

    -- Parse line with optimized state management
    local key, value, comment, quote_char, updated_state = utils.extract_line_parts(line, multi_line_state)
    
    -- Update state efficiently
    if updated_state then
      multi_line_state = updated_state
      if updated_state.in_multi_line and updated_state.key and not line_start_positions[updated_state.key] then
        line_start_positions[updated_state.key] = current_line_idx
      end
    end
    
    -- Process completed variables
    if key and value then
      local start_line = line_start_positions[key] or current_line_idx
      local end_line = current_line_idx
      
      parsed_vars[key] = {
        key = key,
        value = value,
        quote_char = quote_char,
        start_line = start_line,
        end_line = end_line,
        eq_pos = lines[start_line]:find(PATTERNS.equals) or 1,
        is_multi_line = start_line < end_line,
        has_newlines = value:find(string_pool.newline) ~= nil,
        content_hash = content_hash,
      }
      
      -- Reset state after processing
      multi_line_state = {}
    end
    
    current_line_idx = current_line_idx + 1
    ::continue::
  end
  
  -- Cache the result
  parsed_cache:put(content_hash, parsed_vars)
  return parsed_vars
end

---Generate mask for multi-line value with optimized distribution
---@param var_info ParsedVariable The parsed variable information
---@param lines string[] The original lines
---@param config table Configuration for masking
---@param source_filename string Source filename for masking
---@return string[] distributed_masks Array of masks for each line
function M.generate_multiline_masks(var_info, lines, config, source_filename)
  local clean_value = var_info.has_newlines and var_info.value:gsub(string_pool.newline, string_pool.empty) or var_info.value
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
    -- Backslash continuation - optimized processing
    local consumed_chars = 0
    for line_idx = var_info.start_line, var_info.end_line do
      local buffer_line = lines[line_idx]
      local is_first_line = line_idx == var_info.start_line
      local is_last_line = line_idx == var_info.end_line
      
      -- Extract content efficiently
      local parsed_content_part
      if is_first_line then
        local eq_pos = buffer_line:find(PATTERNS.equals)
        if eq_pos then
          parsed_content_part = buffer_line:sub(eq_pos + 1):gsub(PATTERNS.backslash_end, string_pool.empty)
        else
          parsed_content_part = string_pool.empty
        end
      elseif is_last_line then
        parsed_content_part = buffer_line
      else
        parsed_content_part = buffer_line:gsub(PATTERNS.backslash_end, string_pool.empty)
      end
      
      local parsed_length = #parsed_content_part
      if parsed_length > 0 then
        local mask_for_parsed = entire_masked_value:sub(consumed_chars + 1, consumed_chars + parsed_length)
        consumed_chars = consumed_chars + parsed_length
        
        -- Add backslash if present
        local has_backslash = buffer_line:match(PATTERNS.backslash_end)
        local final_mask = mask_for_parsed .. (has_backslash and string_pool.backslash or string_pool.empty)
        
        distributed_masks[line_idx] = final_mask
      end
    end
    
  elseif var_info.has_newlines then
    -- Quoted multi-line - optimized processing
    local raw_lines = vim.split(var_info.value, string_pool.newline, { plain = true })
    local content_only_mask = entire_masked_value
    
    -- Remove quotes from mask if present
    if var_info.quote_char and entire_masked_value:sub(1, 1) == var_info.quote_char then
      content_only_mask = entire_masked_value:sub(2, -2)
    end
    
    local consumed_chars = 0
    for line_idx = var_info.start_line, var_info.end_line do
      local array_idx = line_idx - var_info.start_line + 1
      local is_first_line = line_idx == var_info.start_line
      local is_last_line = line_idx == var_info.end_line
      local raw_line = raw_lines[array_idx] or string_pool.empty
      local raw_length = #raw_line
      
      if raw_length > 0 then
        local mask_for_line = content_only_mask:sub(consumed_chars + 1, consumed_chars + raw_length)
        consumed_chars = consumed_chars + raw_length
        
        -- Add quotes appropriately
        local display_mask = mask_for_line
        if is_first_line then
          display_mask = (var_info.quote_char or string_pool.empty) .. mask_for_line
        elseif is_last_line then
          display_mask = mask_for_line .. (var_info.quote_char or string_pool.empty)
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
  local extmark_cache_key = source_filename .. ":" .. vim.fn.sha256(table.concat(lines, string_pool.newline))
  
  -- Check cache first
  local cached_extmarks = extmark_cache:get(extmark_cache_key)
  if cached_extmarks then
    return cached_extmarks
  end
  
  -- Pre-allocate extmarks table
  local estimated_count = 0
  for _ in pairs(parsed_vars) do
    estimated_count = estimated_count + 1
  end
  extmarks = {} -- Use regular table since table.new might not be available
  
  for _, var_info in pairs(parsed_vars) do
    if skip_comments and var_info.is_comment then
      goto continue_var
    end

    if var_info.value and #var_info.value > 0 then
      if var_info.is_multi_line or var_info.has_newlines then
        -- Multi-line value - use optimized mask generation
        local distributed_masks = M.generate_multiline_masks(var_info, lines, config, source_filename)
        
        for line_idx, mask in pairs(distributed_masks) do
          local is_first_line = line_idx == var_info.start_line
          local col_pos = is_first_line and var_info.eq_pos or 0
          
          local extmark_opts = {
            virt_text = { { mask, config.highlight_group } },
            virt_text_pos = "overlay",
            hl_mode = "combine",
            priority = 9999,
            strict = false,
          }
          
          table.insert(extmarks, {
            line = line_idx - 1, -- 0-based
            col = col_pos,
            opts = extmark_opts,
          })
        end
      else
        -- Single line value - use existing optimized logic
        local buffer_utils = require("ecolog.shelter.buffer")
        local extmark_result = buffer_utils.create_extmark(var_info.value, var_info, config, source_filename, var_info.start_line)
        
        if extmark_result then
          if type(extmark_result[1]) == "table" and extmark_result[1][1] then
            -- Array of extmarks
            for _, extmark in ipairs(extmark_result) do
              table.insert(extmarks, {
                line = extmark[1],
                col = extmark[2],
                opts = extmark[3],
              })
            end
          else
            -- Single extmark
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
  
  -- Cache the result
  extmark_cache:put(extmark_cache_key, extmarks)
  return extmarks
end

---Apply extmarks to buffer with batching for performance
---@param bufnr number Buffer number
---@param extmarks ExtmarkSpec[] Array of extmark specifications
---@param namespace number Namespace for extmarks
---@param batch_size number? Batch size for processing (default: 50)
function M.apply_extmarks_batched(bufnr, extmarks, namespace, batch_size)
  batch_size = batch_size or 50
  
  if not api.nvim_buf_is_valid(bufnr) or #extmarks == 0 then
    return
  end
  
  -- Clear existing extmarks
  pcall(api.nvim_buf_clear_namespace, bufnr, namespace, 0, -1)
  
  -- Apply extmarks in batches to avoid blocking
  local function apply_batch(start_idx)
    if not api.nvim_buf_is_valid(bufnr) then
      return
    end
    
    local end_idx = math.min(start_idx + batch_size - 1, #extmarks)
    for i = start_idx, end_idx do
      local extmark = extmarks[i]
      pcall(api.nvim_buf_set_extmark, bufnr, namespace, extmark.line, extmark.col, extmark.opts)
    end
    
    -- Schedule next batch if needed
    if end_idx < #extmarks then
      vim.schedule(function()
        apply_batch(end_idx + 1)
      end)
    end
  end
  
  -- Start processing
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
  if not api.nvim_buf_is_valid(bufnr) or #lines == 0 then
    return
  end
  
  -- Generate content hash for caching
  local content_hash = vim.fn.sha256(table.concat(lines, string_pool.newline))
  
  -- Parse lines with caching
  local parsed_vars = M.parse_lines_cached(lines, content_hash)
  
  -- Create extmarks with batching
  local extmarks = M.create_extmarks_batch(parsed_vars, lines, config, source_filename, skip_comments)
  
  -- Apply extmarks with batching
  M.apply_extmarks_batched(bufnr, extmarks, namespace)
end

---Clear caches to free memory
function M.clear_caches()
  parsed_cache:clear()
  extmark_cache:clear()
end

---Get cache statistics for debugging
---@return table stats Cache statistics
function M.get_cache_stats()
  local parsed_size = type(parsed_cache.size) == "function" and parsed_cache:size() or "unknown"
  local extmark_size = type(extmark_cache.size) == "function" and extmark_cache:size() or "unknown"
  
  return {
    parsed_cache_size = parsed_size,
    extmark_cache_size = extmark_size,
    parsed_cache_hits = parsed_cache.hits or 0,
    parsed_cache_misses = parsed_cache.misses or 0,
    extmark_cache_hits = extmark_cache.hits or 0,
    extmark_cache_misses = extmark_cache.misses or 0,
  }
end

return M