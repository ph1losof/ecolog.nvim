---@class EcologCommentParser
---Unified parser for comment line and inline comment key-value pairs
---Eliminates duplication from masking_engine.lua
local M = {}

local PATTERNS = {
  equals = "=",
  whitespace = "[%s]",
  quote = "[\"']",
  comment_start = "^%s*#",
}

local function is_whitespace(char)
  return char == " " or char == "\t" or char == "\n" or char == "\r"
end

local function is_quote(char)
  return char == '"' or char == "'"
end

---Extract a quoted or unquoted value starting from a position
---@param text string The text to parse
---@param start_pos number Starting position (after =)
---@return string? value The extracted value
---@return string? quote_char The quote character used (if any)
---@return number end_pos Position after the value
local function extract_value(text, start_pos)
  while start_pos <= #text and is_whitespace(text:sub(start_pos, start_pos)) do
    start_pos = start_pos + 1
  end

  if start_pos > #text then
    return nil, nil, start_pos
  end

  local first_char = text:sub(start_pos, start_pos)

  if is_quote(first_char) then
    local quote_char = first_char
    local end_quote_pos = text:find(quote_char, start_pos + 1, true)

    if end_quote_pos then
      local value = text:sub(start_pos + 1, end_quote_pos - 1)
      return value, quote_char, end_quote_pos
    else
      local value = text:sub(start_pos + 1)
      return value, quote_char, #text
    end
  end

  local space_pos = nil
  for i = start_pos, #text do
    if is_whitespace(text:sub(i, i)) then
      space_pos = i
      break
    end
  end

  if space_pos then
    local value = text:sub(start_pos, space_pos - 1)
    return value, nil, space_pos - 1
  else
    local value = text:sub(start_pos)
    return value, nil, #text
  end
end

---Find the start of a key by scanning backwards from equals sign
---@param text string The text to scan
---@param eq_pos number Position of equals sign
---@param search_start number Starting search position
---@return number key_start Position where key starts
local function find_key_start(text, eq_pos, search_start)
  local key_start = eq_pos
  while key_start > search_start do
    local char = text:sub(key_start - 1, key_start - 1)
    if is_whitespace(char) then
      break
    end
    key_start = key_start - 1
  end
  return key_start
end

---Parse a single key-value pair from text
---@param text string The text to parse
---@param search_pos number Starting search position
---@param line_num number Line number for result
---@param content_hash string Content hash for result
---@param is_inline boolean Whether this is an inline comment
---@return table? result Parsed key-value pair or nil
---@return number next_pos Position after this key-value pair
local function parse_key_value_pair(text, search_pos, line_num, content_hash, is_inline)
  local eq_pos = text:find("=", search_pos, true)
  if not eq_pos then
    return nil, #text + 1
  end

  local key_start = find_key_start(text, eq_pos, search_pos)
  local potential_key = text:sub(key_start, eq_pos - 1):match("^%s*(.-)%s*$")

  if not potential_key or #potential_key == 0 then
    return nil, eq_pos + 1
  end

  local value, quote_char, value_end_pos = extract_value(text, eq_pos + 1)

  if not value or #value == 0 then
    return nil, eq_pos + 1
  end

  return {
    key = potential_key,
    value = value,
    quote_char = quote_char,
    eq_pos_in_text = eq_pos,
    line_num = line_num,
    content_hash = content_hash,
    is_inline = is_inline,
  },
    value_end_pos + 1
end

---Parse comment line for key-value pairs
---Handles: # API_KEY=secret KEY2=value2
---@param line string The full line
---@param line_num number Line number (1-based)
---@param content_hash string Content hash for caching
---@return table<string, table> parsed_vars Dictionary of parsed variables
function M.parse_comment_line(line, line_num, content_hash)
  local parsed_vars = {}

  if not line:find(PATTERNS.comment_start) then
    return parsed_vars
  end

  local comment_start_pos = line:find("#", 1, true)
  if not comment_start_pos then
    return parsed_vars
  end

  local comment_text = line:sub(comment_start_pos + 1)
  local search_pos = 1

  while search_pos <= #comment_text do
    local result, next_pos = parse_key_value_pair(comment_text, search_pos, line_num, content_hash, false)

    if result then
      local eq_pos_in_line = comment_start_pos + result.eq_pos_in_text

      local unique_key = result.key .. "_line_" .. line_num .. "_pos_" .. result.eq_pos_in_text

      parsed_vars[unique_key] = {
        key = result.key,
        value = result.value,
        quote_char = result.quote_char,
        start_line = line_num,
        end_line = line_num,
        eq_pos = eq_pos_in_line,
        is_multi_line = false,
        has_newlines = false,
        content_hash = content_hash,
        is_comment = true,
        is_inline_comment = false,
      }
    end

    search_pos = next_pos
  end

  return parsed_vars
end

---Parse inline comment for key-value pairs
---Handles: VALUE=text\ #key1='value1' key2='value2'
---@param comment string The comment text (after #)
---@param line string The full line (for position calculation)
---@param line_num number Line number (1-based)
---@param content_hash string Content hash for caching
---@return table<string, table> parsed_vars Dictionary of parsed variables
function M.parse_inline_comment(comment, line, line_num, content_hash)
  local parsed_vars = {}

  if not comment or #comment == 0 then
    return parsed_vars
  end

  local comment_start_pos = line:find("#", 1, true)
  if not comment_start_pos then
    return parsed_vars
  end

  local search_pos = 1

  while search_pos <= #comment do
    local result, next_pos = parse_key_value_pair(comment, search_pos, line_num, content_hash, true)

    if result then
      local eq_pos_in_line = comment_start_pos + result.eq_pos_in_text

      local unique_key = result.key .. "_line_" .. line_num .. "_pos_" .. result.eq_pos_in_text

      parsed_vars[unique_key] = {
        key = result.key,
        value = result.value,
        quote_char = result.quote_char,
        start_line = line_num,
        end_line = line_num,
        eq_pos = eq_pos_in_line,
        is_multi_line = false,
        has_newlines = false,
        content_hash = content_hash,
        is_comment = true,
        is_inline_comment = true,
      }
    end

    search_pos = next_pos
  end

  return parsed_vars
end

return M
