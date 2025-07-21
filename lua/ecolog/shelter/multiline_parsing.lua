local M = {}

local PATTERNS = {
  backslash_comment = "^(.-)\\%s*#(.*)$",
  backslash_only = "^(.-)\\%s*$",
  backslash_with_comment = "\\%s*#",
  backslash_part = "\\(.*)$",
  leading_spaces = "^(%s*)",
  content_trim = "^%s*(.*)$",
  content_trim_both = "^%s*(.-)%s*$",
  trailing_spaces = "(%s*)$",
  comment_start = "#",
}

-- Extract content and comment parts from a line with backslash continuation
---@param line string The line to parse
---@param start_pos number? Start position (for first line after equals)
---@return string content The content before backslash
---@return string suffix Everything from backslash onward (backslash + comment)
local function parse_backslash_line(line, start_pos)
  local search_text = start_pos and line:sub(start_pos) or line

  if search_text:match(PATTERNS.backslash_with_comment) then
    local before = search_text:match("^(.-)\\")
    local after = search_text:match(PATTERNS.backslash_part)
    return before or "", "\\" .. (after or "")
  end

  local before = search_text:match(PATTERNS.backslash_only)
  if before then
    return before, "\\"
  end

  return search_text, ""
end

-- Parse comment from last line (no backslash)
---@param line string The line to parse
---@return string content The content before comment
---@return string comment_part The comment part including spacing
local function parse_last_line_comment(line)
  local comment_pos = line:find(PATTERNS.comment_start)
  if comment_pos and comment_pos > 1 and line:sub(comment_pos - 1, comment_pos - 1):match("%s") then
    local content_with_space = line:sub(1, comment_pos - 1)
    local content = content_with_space:match(PATTERNS.content_trim_both) or ""
    local space_before = content_with_space:match(PATTERNS.trailing_spaces) or ""
    return content, space_before .. line:sub(comment_pos)
  end
  return line:match(PATTERNS.content_trim_both) or line, ""
end

-- Process a single line for multiline masking
---@param buffer_line string The line to process
---@param line_idx number The line index
---@param var_info table Variable information
---@param is_first boolean Whether this is the first line
---@param is_last boolean Whether this is the last line
---@return string content_part The content to mask
---@return string preserve_part The part to preserve (backslash/comment)
function M.process_line_for_mask(buffer_line, line_idx, var_info, is_first, is_last)
  if is_first then
    local eq_pos = buffer_line:find("=")
    if eq_pos then
      return parse_backslash_line(buffer_line, eq_pos + 1)
    end
    return "", ""
  elseif is_last then
    return parse_last_line_comment(buffer_line)
  else
    local content, suffix = parse_backslash_line(buffer_line)
    local actual_content = content:match(PATTERNS.content_trim) or ""
    return actual_content, suffix
  end
end

-- Build final mask for a line
---@param mask_content string The masked content
---@param preserve_part string The part to preserve
---@param original_line string The original line
---@param is_first boolean Whether this is the first line
---@return string final_mask The complete masked line
function M.build_final_mask(mask_content, preserve_part, original_line, is_first)
  if is_first then
    return mask_content .. preserve_part
  else
    local leading_spaces = original_line:match(PATTERNS.leading_spaces) or ""
    return leading_spaces .. mask_content .. preserve_part
  end
end

-- Optimized mask distribution for multiline values
---@param var_info table Variable information
---@param lines string[] Buffer lines
---@param entire_masked_value string The complete masked value
---@return table<number, string> distributed_masks Masks by line number
function M.distribute_multiline_masks(var_info, lines, entire_masked_value)
  local distributed_masks = {}
  local consumed_chars = 0

  for line_idx = var_info.start_line, var_info.end_line do
    local buffer_line = lines[line_idx]
    if buffer_line then
      local is_first = line_idx == var_info.start_line
      local is_last = line_idx == var_info.end_line

      local content_part, preserve_part = M.process_line_for_mask(buffer_line, line_idx, var_info, is_first, is_last)

      local content_length = #content_part
      local mask_for_content = ""

      if content_length > 0 then
        mask_for_content = entire_masked_value:sub(consumed_chars + 1, consumed_chars + content_length)
        consumed_chars = consumed_chars + content_length
      end

      distributed_masks[line_idx] = M.build_final_mask(mask_for_content, preserve_part, buffer_line, is_first)
    end
  end

  return distributed_masks
end

-- Distribute masks for mask_length scenarios
---@param var_info table Variable information
---@param lines string[] Buffer lines
---@param final_mask string The final mask to distribute
---@param eq_pos number Position of equals sign on first line
---@return table<number, string> distributed_masks Masks by line number
function M.distribute_mask_length_masks(var_info, lines, final_mask, eq_pos)
  local distributed_masks = {}

  local first_line = lines[var_info.start_line]
  if first_line and eq_pos then
    local original_value_part = first_line:sub(eq_pos + 1)
    local content, suffix = parse_backslash_line(original_value_part)

    local content_len = #content
    local mask_len = #final_mask

    if mask_len > content_len then
      distributed_masks[var_info.start_line] = final_mask:sub(1, content_len) .. suffix
    elseif mask_len < content_len then
      distributed_masks[var_info.start_line] = final_mask .. string.rep(" ", content_len - mask_len) .. suffix
    else
      distributed_masks[var_info.start_line] = final_mask .. suffix
    end
  end

  for line_idx = var_info.start_line + 1, var_info.end_line do
    local line = lines[line_idx]
    if line then
      local is_last = line_idx == var_info.end_line
      local content, suffix

      if is_last then
        content, suffix = parse_last_line_comment(line)
      else
        local before_backslash = line:match("^(.-)\\")
        if before_backslash then
          suffix = line:match("(\\%s*#?.*)$") or ""
          content = before_backslash
        else
          content = line
          suffix = ""
        end
      end

      distributed_masks[line_idx] = string.rep(" ", #content) .. suffix
    end
  end

  return distributed_masks
end

return M

