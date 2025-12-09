---@class EcologMaskingCore
---Core masking utilities shared across the shelter module
local M = {}

local string_rep = string.rep
local string_sub = string.sub
local table_concat = table.concat
local math_min = math.min
local math_max = math.max

-- Constants (will be initialized lazily)
local SPACE, EMPTY_STRING

---Initialize constants
local function ensure_constants()
  if not SPACE then
    SPACE = " "
    EMPTY_STRING = ""
  end
end

---Generate mask for a single line with exact length
---@param line_value string The line value to mask
---@param line_length number Length of the line
---@param mask_length number The mask length to apply
---@param mask_char string The mask character
---@param is_partial boolean Whether partial mode is active
---@param show_start number Characters to show at start
---@param show_end number Characters to show at end
---@param min_mask number Minimum mask characters required
---@return string mask The generated mask
function M.generate_line_mask(line_value, line_length, mask_length, mask_char, is_partial, show_start, show_end, min_mask)
  ensure_constants()

  -- Step 1: Create base mask of exactly mask_length
  local base_mask = string_rep(mask_char, mask_length)

  -- Step 2: Apply partial mode to the fixed-length mask
  local final_mask
  if is_partial and line_length > 0 then
    -- Check if mask_length can accommodate show_start + min_mask + show_end
    local available_in_mask = mask_length - show_start - show_end

    if mask_length <= (show_start + show_end) or available_in_mask < min_mask then
      -- mask_length doesn't have enough room for partial mode: use full mask
      final_mask = base_mask
    else
      -- Apply partial mode: replace start/end of mask with actual characters
      local start_len = math_min(show_start, line_length)
      local start_part = start_len > 0 and string_sub(line_value, 1, start_len) or EMPTY_STRING

      local end_part = EMPTY_STRING
      if show_end > 0 and line_length > show_end then
        end_part = string_sub(line_value, -show_end)
      end

      -- Calculate how many mask chars we need in the middle
      local middle_mask_len = mask_length - #start_part - #end_part
      middle_mask_len = math_max(0, middle_mask_len)

      final_mask = table_concat({start_part, string_rep(mask_char, middle_mask_len), end_part})
    end
  else
    final_mask = base_mask
  end

  -- Step 3: Add padding if actual value is longer than our mask
  if line_length > #final_mask then
    final_mask = final_mask .. string_rep(SPACE, line_length - #final_mask)
  end

  return final_mask
end

---Apply partial masking to a single-line value
---Handles both fixed mask_length and dynamic length cases
---@param value string The value to mask
---@param mask_char string The character to use for masking
---@param show_start number Characters to show at start
---@param show_end number Characters to show at end
---@param min_mask number Minimum mask characters required
---@param mask_length number? Optional fixed mask length
---@return string masked_value The masked value
function M.apply_partial_masking(value, mask_char, show_start, show_end, min_mask, mask_length)
  ensure_constants()

  local value_len = #value
  show_start = math.max(0, show_start or 0)
  show_end = math.max(0, show_end or 0)
  min_mask = math.max(0, min_mask or 0)

  if mask_length then
    -- Fixed mask_length mode: mask has exact length regardless of value length
    local base_mask = string_rep(mask_char, mask_length)
    local available_in_mask = mask_length - show_start - show_end

    if mask_length <= (show_start + show_end) or available_in_mask < min_mask then
      return base_mask
    end

    local start_part = show_start > 0 and string_sub(value, 1, math_min(show_start, value_len)) or EMPTY_STRING
    local end_part = show_end > 0 and value_len > show_end and string_sub(value, -show_end) or EMPTY_STRING
    local middle_mask_len = math_max(0, mask_length - #start_part - #end_part)

    return start_part .. string_rep(mask_char, middle_mask_len) .. end_part
  else
    -- Dynamic length mode: mask length matches value length
    local available_middle = value_len - show_start - show_end

    if value_len <= (show_start + show_end) or available_middle < min_mask then
      return string_rep(mask_char, value_len)
    end

    local end_part = show_end > 0 and string_sub(value, -show_end) or EMPTY_STRING
    return string_sub(value, 1, show_start) .. string_rep(mask_char, available_middle) .. end_part
  end
end

---Add quotes around mask, placing closing quote before padding
---@param mask string The mask to wrap
---@param quote_char string The quote character
---@param is_first boolean Whether this is the first line
---@param is_last boolean Whether this is the last line
---@return string quoted_mask The mask with quotes
function M.add_quotes_to_mask(mask, quote_char, is_first, is_last)
  ensure_constants()

  if is_first then
    mask = quote_char .. mask
  end

  if is_last then
    -- Insert quote before padding
    local mask_without_padding = mask:match("^(.-)%s*$") or mask
    local padding_len = #mask - #mask_without_padding
    mask = mask_without_padding .. quote_char
    if padding_len > 0 then
      mask = mask .. string_rep(SPACE, padding_len)
    end
  end

  return mask
end

---Extract and clean line value for backslash continuation
---@param line string The raw line
---@param line_idx number Line index
---@param start_line number First line index
---@param end_line number Last line index
---@param quote_char string? Quote character if present
---@return string? line_value The cleaned value
---@return boolean has_backslash Whether line has continuation
function M.extract_continuation_line_value(line, line_idx, start_line, end_line, quote_char)
  local line_value

  if line_idx == start_line then
    -- First line: extract value after =
    local eq_idx = line:find("=", 1, true)
    if eq_idx then
      line_value = line:sub(eq_idx + 1)
      -- Remove leading quote if present
      if quote_char and #line_value > 0 and line_value:sub(1, 1) == quote_char then
        line_value = line_value:sub(2)
      end
    end
  else
    -- Continuation lines: get the full line
    line_value = line
  end

  if not line_value then
    return nil, false
  end

  -- Check for backslash continuation
  local has_backslash = line_value:match("\\%s*$") ~= nil

  -- Remove trailing backslash, comments, and whitespace
  line_value = line_value:gsub("%s*\\%s*$", "")
  local comment_pos = line_value:find("#")
  if comment_pos then
    line_value = line_value:sub(1, comment_pos - 1)
  end
  line_value = line_value:match("^(.-)%s*$")

  -- Remove trailing quote on last line
  if line_idx == end_line and quote_char and #line_value > 0 and line_value:sub(-1) == quote_char then
    line_value = line_value:sub(1, -2)
  end

  return line_value, has_backslash
end

return M
