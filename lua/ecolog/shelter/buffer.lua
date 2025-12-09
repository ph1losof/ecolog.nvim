---@class EcologShelterBuffer
---@field NAMESPACE number Namespace ID for buffer highlights and virtual text
local M = {}
local NotificationManager = require("ecolog.core.notification_manager")

-- Compatibility layer for uv -> vim.uv migration
local uv = require("ecolog.core.compat").uv

---@class KeyValueResult
---@field key string The key part of the key-value pair
---@field value string The value part of the key-value pair
---@field quote_char string? The quote character used (if any)
---@field eq_pos number Position of the equals sign
---@field next_pos number Position after the value

---@class ProcessedItem
---@field key string The key part of the key-value pair
---@field value string The value part of the key-value pair
---@field quote_char string? The quote character used (if any)
---@field eq_pos number Position of the equals sign
---@field is_comment boolean Whether this item was found in a comment

---@class ExtmarkData
---@field line_num number The line number
---@field eq_pos number Position of the equals sign
---@field extmarks table[] Array of extmark data

local api = vim.api
local string_find = string.find
local string_sub = string.sub
local string_match = string.match
local table_insert = table.insert
local fn = vim.fn
local pcall = pcall

-- Lazy-loaded modules using centralized lazy loader
local lazy = require("ecolog.core.lazy_loader")
local get_state = lazy.getter("ecolog.shelter.state")
local get_shelter_utils = lazy.getter("ecolog.shelter.utils")
local get_main_utils = lazy.getter("ecolog.utils")

local NAMESPACE = api.nvim_create_namespace("ecolog_shelter")
local CLEANUP_INTERVAL = 300000
local BUFFER_TIMEOUT = 3600000
local KEY_PATTERN = "^%s*(.-)%s*$"
local VALUE_PATTERN = "^%s*(.-)%s*$"
local BATCH_SIZE = 100

local active_buffers = setmetatable({}, { __mode = "k" })
local string_buffer = table.new and table.new(1000, 0) or {}

local PADDING_CACHE = setmetatable({}, {
  __index = function(t, n)
    if n <= 0 or n > 1000 then
      return string.rep(" ", math.max(0, math.min(n, 1000)))
    end
    local pad = string.rep(" ", n)
    t[n] = pad
    return pad
  end,
})

M.NAMESPACE = NAMESPACE

---@param text string
---@param start_pos number?
---@param multi_line_state table? Multi-line parsing state
---@return KeyValueResult?
---@return table? multi_line_state Updated multi-line state
M.find_next_key_value = function(text, start_pos, multi_line_state)
  vim.validate({ text = { text, "string" } })
  vim.validate({ start_pos = { start_pos, "number" } }, true)

  start_pos = start_pos or 1
  if start_pos > #text then
    return nil, multi_line_state
  end

  local eq_pos = string_find(text, "=", start_pos)
  if not eq_pos then
    return nil, multi_line_state
  end

  local key_start = eq_pos
  while key_start > start_pos do
    local char = text:sub(key_start - 1, key_start - 1)
    if char:match("[%s#]") then
      break
    end
    key_start = key_start - 1
  end

  local key = string_match(string_sub(text, key_start, eq_pos - 1), KEY_PATTERN)
  if not key or #key == 0 then
    return M.find_next_key_value(text, eq_pos + 1, multi_line_state)
  end

  local value_part = text:sub(eq_pos + 1)

  local pos = eq_pos + 1
  local quote_char = text:sub(pos, pos)
  local in_quotes = quote_char == '"' or quote_char == "'"

  local value
  if in_quotes then
    pos = pos + 1
    local value_end = nil
    while pos <= #text do
      if text:sub(pos, pos) == quote_char and text:sub(pos - 1, pos - 1) ~= "\\" then
        value_end = pos
        break
      end
      pos = pos + 1
    end

    if value_end then
      value = text:sub(eq_pos + 2, value_end - 1)
      pos = value_end + 1
    else
      return M.find_next_key_value(text, eq_pos + 1, multi_line_state)
    end
  else
    while pos <= #text do
      local char = text:sub(pos, pos)
      if char:match("[%s#]") then
        break
      end
      pos = pos + 1
    end
    value = string_match(text:sub(eq_pos + 1, pos - 1), VALUE_PATTERN)
  end

  if not value or #value == 0 then
    return M.find_next_key_value(text, eq_pos + 1, multi_line_state)
  end

  return {
    key = key,
    value = value,
    quote_char = in_quotes and quote_char or nil,
    eq_pos = eq_pos,
    next_pos = pos,
  },
    multi_line_state
end

local function cleanup_invalid_buffers()
  local current_time = uv.now()
  for bufnr, timestamp in pairs(active_buffers) do
    if not api.nvim_buf_is_valid(bufnr) or (current_time - timestamp) > BUFFER_TIMEOUT then
      pcall(api.nvim_buf_clear_namespace, bufnr, NAMESPACE, 0, -1)
      active_buffers[bufnr] = nil
    end
  end
end

---@param bufnr number
---@return boolean
local function is_buffer_valid(bufnr)
  return type(bufnr) == "number" and api.nvim_buf_is_valid(bufnr)
end

---@param ... string
---@return string
local function fast_concat(...)
  local n = select("#", ...)
  for i = 1, n do
    local value = select(i, ...)
    string_buffer[i] = value ~= nil and tostring(value) or ""
  end
  local result = table.concat(string_buffer, "", 1, n)
  for i = 1, n do
    string_buffer[i] = nil
  end
  return result
end

function M.unshelter_buffer()
  local bufnr = api.nvim_get_current_buf()
  if not is_buffer_valid(bufnr) then
    NotificationManager.warn("Invalid buffer")
    return
  end

  local winid = api.nvim_get_current_win()
  api.nvim_win_set_option(winid, "conceallevel", 0)
  api.nvim_win_set_option(winid, "concealcursor", "")

  api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)
  local s = get_state()
  s.reset_revealed_lines()
  active_buffers[bufnr] = nil

  if s.get_buffer_state().disable_cmp then
    vim.b.completion = true
    local s_utils = get_shelter_utils()
    if s_utils.has_cmp() then
      require("cmp").setup.buffer({ enabled = true })
    end
  end
end

---@param bufnr number
---@param winid number
local function setup_buffer_options(bufnr, winid)
  vim.opt_local.wrap = false

  api.nvim_win_set_option(winid, "conceallevel", 2)
  api.nvim_win_set_option(winid, "concealcursor", "nvic")
  active_buffers[bufnr] = uv.now()

  if uv.now() % CLEANUP_INTERVAL == 0 then
    cleanup_invalid_buffers()
  end

  local s = get_state()
  if s.get_buffer_state().disable_cmp then
    vim.b.completion = false
    local s_utils = get_shelter_utils()
    if s_utils.has_cmp() then
      require("cmp").setup.buffer({ enabled = false })
    end
  end
end

---Truncate masked value with partial mode support
---@param masked_value string The masked value to truncate
---@param mask_length number The target mask length
---@param partial_mode table? Partial mode configuration
---@return string truncated The truncated value
local function truncate_with_partial_mode(masked_value, mask_length, partial_mode)
  if not partial_mode or type(partial_mode) ~= "table" then
    return masked_value:sub(1, mask_length)
  end

  local show_end = partial_mode.show_end or 0
  if show_end > 0 and mask_length > show_end then
    local end_chars = masked_value:sub(-show_end)
    local start_part = masked_value:sub(1, mask_length - show_end)
    return start_part .. end_chars
  end

  return masked_value:sub(1, mask_length)
end

---Apply display logic: truncation, quotes, and padding
---@param masked_value string The base masked value
---@param raw_value string The original raw value
---@param quote_char string? Quote character to use
---@param mask_length number? Mask length to apply
---@param config table Configuration with partial_mode
---@return string display_text The final display text
local function apply_mask_display_logic(masked_value, raw_value, quote_char, mask_length, config)
  local display_text = masked_value

  if mask_length and #masked_value > mask_length then
    display_text = truncate_with_partial_mode(masked_value, mask_length, config.partial_mode)
  end

  if quote_char then
    display_text = quote_char .. display_text .. quote_char
  end

  local padding_needed = math.max(0, #raw_value - #display_text)
  if padding_needed > 0 then
    display_text = display_text .. PADDING_CACHE[padding_needed]
  end

  return display_text
end

---Build extmark specification
---@param line_num number Line number (1-based)
---@param col_pos number Column position
---@param display_text string Text to display
---@param config table Configuration
---@param item ProcessedItem Item information
---@return table extmark The extmark specification
local function build_extmark(line_num, col_pos, display_text, config, item)
  return {
    line_num - 1, -- 0-based
    col_pos,
    {
      virt_text = { { display_text, config.highlight_group } },
      virt_text_pos = "overlay",
      hl_mode = "combine",
      priority = item.is_comment and 10000 or 9999,
      strict = false,
    },
  }
end

---@param value string
---@param item ProcessedItem
---@param config table
---@param bufname string
---@param line_num number
---@return table|table[]? extmark(s) Single extmark or array of extmarks for multi-line values
function M.create_extmark(value, item, config, bufname, line_num)
  local raw_value = item.quote_char and (item.quote_char .. value .. item.quote_char) or value

  local is_multi_line = value:find("\n") ~= nil
  if is_multi_line then
    local s = get_state()
    local is_revealed = s.is_line_revealed(line_num)
    local masked_value
    if is_revealed then
      masked_value = raw_value
    else
      local s_utils = get_shelter_utils()
      masked_value = s_utils.determine_masked_value(value, {
        partial_mode = config.partial_mode,
        key = item.key,
        source = bufname,
        quote_char = item.quote_char,
      })
    end
    return M.create_multi_line_extmarks(raw_value, masked_value, item, config, line_num)
  end

  local s = get_state()
  local is_revealed = s.is_line_revealed(line_num)
  if is_revealed then
    return build_extmark(line_num, item.eq_pos, raw_value, { highlight_group = "String" }, item)
  end

  local s_utils = get_shelter_utils()
  local masked_value = s_utils.determine_masked_value(value, {
    partial_mode = config.partial_mode,
    key = item.key,
    source = bufname,
    quote_char = nil,
  })

  if not masked_value or #masked_value == 0 then
    return nil
  end

  local display_text = apply_mask_display_logic(masked_value, raw_value, item.quote_char, config.mask_length, config)

  return build_extmark(line_num, item.eq_pos, display_text, config, item)
end

---Batch check revealed lines for performance
---@param start_line number Starting line number
---@param end_line number Ending line number
---@return table<number, boolean> revealed_map Map of line numbers to revelation status
local function get_revealed_lines_map(start_line, end_line)
  local s = get_state()
  local revealed = {}
  for i = start_line, end_line do
    revealed[i] = s.is_line_revealed(i)
  end
  return revealed
end

---Create extmarks for multi-line values
---@param raw_value string The original raw value
---@param masked_value string The masked value
---@param item ProcessedItem The processed item
---@param config table Configuration
---@param start_line_num number The starting line number
---@return table[] extmarks Array of extmarks for each line
function M.create_multi_line_extmarks(raw_value, masked_value, item, config, start_line_num)
  local raw_lines = vim.split(raw_value, "\n", { plain = true })
  local masked_lines = vim.split(masked_value, "\n", { plain = true })
  local extmarks = {}

  local num_lines = #masked_lines
  local revealed_map = get_revealed_lines_map(start_line_num, start_line_num + num_lines - 1)

  for i, masked_line in ipairs(masked_lines) do
    local line_num = start_line_num + i - 1
    local is_revealed = revealed_map[line_num]
    local display_value = is_revealed and (raw_lines[i] or "") or masked_line

    local extmark_opts = {
      virt_text = {
        {
          display_value,
          (is_revealed or display_value == (raw_lines[i] or "")) and "String" or config.highlight_group,
        },
      },
      virt_text_pos = "overlay",
      hl_mode = "combine",
      priority = item.is_comment and 10000 or 9999,
      strict = false,
    }

    local col_pos = i == 1 and item.eq_pos or 0

    table.insert(extmarks, {
      line_num - 1,
      col_pos,
      extmark_opts,
    })
  end

  return extmarks
end

function M.shelter_buffer()
  local config = require("ecolog").get_config and require("ecolog").get_config() or {}
  local bufname = fn.bufname()

  local s_utils = get_shelter_utils()
  if not s_utils.match_env_file(bufname, config) then
    return
  end

  local bufnr = api.nvim_get_current_buf()
  if not is_buffer_valid(bufnr) then
    NotificationManager.warn("Invalid buffer")
    return
  end

  local winid = api.nvim_get_current_win()
  setup_buffer_options(bufnr, winid)

  local s = get_state()
  local masking_config = {
    partial_mode = s.get_config().partial_mode,
    highlight_group = s.get_config().highlight_group,
    mask_length = s.get_config().mask_length,
  }
  local skip_comments = s.get_config().skip_comments

  local ok, all_lines = pcall(api.nvim_buf_get_lines, bufnr, 0, -1, false)
  if not ok then
    NotificationManager.error("Failed to get buffer lines")
    return
  end

  local masking_engine = require("ecolog.shelter.masking_engine")
  masking_engine.process_buffer_optimized(bufnr, all_lines, masking_config, bufname, NAMESPACE, skip_comments)
end

---@param config table
---@return table
local function setup_buffer_state(config)
  local shelter_config = type(config.shelter) == "table"
      and type(config.shelter.modules) == "table"
      and type(config.shelter.modules.files) == "table"
      and config.shelter.modules.files
    or {}

  local buffer_state = {
    disable_cmp = type(shelter_config) == "table" and shelter_config.disable_cmp ~= false or false,
    revealed_lines = {},
  }
  local s = get_state()
  s.set_buffer_state(buffer_state)
  return buffer_state
end

---@param config table
---@param group number
local function setup_buffer_autocmds(config, group)
  local m_utils = get_main_utils()
  local watch_patterns = m_utils.get_watch_patterns(config)

  if config._monorepo_root then
    local monorepo_patterns = {}
    local base_patterns = config.env_file_patterns or { ".env", ".envrc", ".env.*" }

    for _, pattern in ipairs(base_patterns) do
      table.insert(monorepo_patterns, config._monorepo_root .. "/" .. pattern)
      table.insert(monorepo_patterns, config._monorepo_root .. "/**/" .. pattern)
    end

    for _, pattern in ipairs(monorepo_patterns) do
      table.insert(watch_patterns, pattern)
    end
  end

  if #watch_patterns == 0 then
    watch_patterns = { ".env*" }
  end

  api.nvim_create_autocmd("BufReadCmd", {
    pattern = watch_patterns,
    group = group,
    callback = function(ev)
      local s_utils = get_shelter_utils()
      if not s_utils.match_env_file(ev.file, config) then
        return
      end

      local bufnr = ev.buf
      local ok, err = pcall(function()
        vim.cmd("keepalt edit " .. fn.fnameescape(ev.file))

        local ft = vim.filetype.match({ filename = ev.file })
        if ft then
          vim.bo[bufnr].filetype = ft
        else
          vim.bo[bufnr].filetype = "sh"
        end

        vim.bo[bufnr].modified = false
      end)

      if not ok then
        NotificationManager.error("Failed to set buffer contents: " .. tostring(err))
        return true
      end

      local s = get_state()
      if s.is_enabled("files") then
        local revealed_lines = s.get_buffer_state().revealed_lines
        if not next(revealed_lines) then
          M.shelter_buffer()
        end
      end

      return true
    end,
  })

  api.nvim_create_autocmd({ "BufWritePost", "BufEnter", "TextChanged", "TextChangedI", "TextChangedP" }, {
    pattern = watch_patterns,
    group = group,
    callback = function(ev)
      local s_utils = get_shelter_utils()
      if s_utils.match_env_file(ev.file, config) then
        local s = get_state()
        if s.is_enabled("files") then
          -- Clear masking engine caches on text changes to ensure fresh parsing
          local masking_engine = require("ecolog.shelter.masking_engine")
          masking_engine.clear_buffer_cache(ev.buf, ev.file)
          vim.cmd('noautocmd lua require("ecolog.shelter.buffer").shelter_buffer()')
        else
          M.unshelter_buffer()
        end
      end
    end,
  })

  api.nvim_create_autocmd("BufLeave", {
    pattern = watch_patterns,
    group = group,
    callback = function(ev)
      local s_utils = get_shelter_utils()
      local s = get_state()
      if s_utils.match_env_file(ev.file, config) and s.get_config().shelter_on_leave then
        s.set_feature_state("files", true)

        if s.get_state().features.initial.telescope_previewer then
          s.set_feature_state("telescope_previewer", true)
          require("ecolog.shelter.integrations.telescope").setup_telescope_shelter()
        end

        if s.get_state().features.initial.fzf_previewer then
          s.set_feature_state("fzf_previewer", true)
          require("ecolog.shelter.integrations.fzf").setup_fzf_shelter()
        end

        if s.get_state().features.initial.snacks_previewer then
          s.set_feature_state("snacks_previewer", true)
          require("ecolog.shelter.integrations.snacks").setup_snacks_shelter()
        end

        M.shelter_buffer()
      end
    end,
  })
end

---@param config table
---@return table
local function setup_paste_override(config)
  local original_paste = vim.paste
  vim.paste = (function()
    return function(lines, phase)
      local bufnr = api.nvim_get_current_buf()
      local filename = fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":t")

      local s_utils = get_shelter_utils()
      local s = get_state()
      if not s_utils.match_env_file(filename, config) or not s.is_enabled("files") then
        return original_paste(lines, phase)
      end

      if type(lines) == "string" then
        lines = vim.split(lines, "\n", { plain = true })
      end

      if not lines or #lines == 0 then
        return true
      end

      local cursor = api.nvim_win_get_cursor(0)
      local row, col = cursor[1], cursor[2]
      local current_line = api.nvim_get_current_line()
      local pre = current_line:sub(1, col)
      local post = current_line:sub(col + 1)

      local new_lines = {}
      if #lines == 1 then
        new_lines[1] = fast_concat(pre or "", lines[1] or "", post or "")
      else
        new_lines[1] = fast_concat(pre or "", lines[1] or "")
        for i = 2, #lines - 1 do
          new_lines[i] = lines[i] or ""
        end
        if #lines > 1 then
          new_lines[#lines] = fast_concat(lines[#lines] or "", post or "")
        end
      end

      pcall(api.nvim_buf_set_lines, bufnr, row - 1, row, false, new_lines)

      local new_row = row + #new_lines - 1
      local new_col = #new_lines == 1 and col + (lines[1] and #lines[1] or 0) or (lines[#lines] and #lines[#lines] or 0)
      pcall(api.nvim_win_set_cursor, 0, { new_row, new_col })

      return true
    end
  end)()
end

function M.setup_file_shelter()
  local group = api.nvim_create_augroup("ecolog_shelter", { clear = true })
  local config = require("ecolog").get_config and require("ecolog").get_config() or {}

  setup_buffer_state(config)
  setup_buffer_autocmds(config, group)
  setup_paste_override(config)
end

function M.refresh_shelter_for_monorepo()
  pcall(api.nvim_del_augroup_by_name, "ecolog_shelter")

  M.setup_file_shelter()

  local current_file = fn.bufname()
  local config = require("ecolog").get_config and require("ecolog").get_config() or {}
  local s_utils = get_shelter_utils()
  local s = get_state()
  if current_file and s_utils.match_env_file(current_file, config) and s.is_enabled("files") then
    vim.schedule(function()
      M.shelter_buffer()
    end)
  end
end

return M
