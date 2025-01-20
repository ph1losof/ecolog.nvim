local api = vim.api
local fn = vim.fn
local notify = vim.notify
local win = require("ecolog.win")
local shelter = require("ecolog.shelter")
local utils = require("ecolog.utils")

local M = {}

-- Cached patterns
local PATTERNS = {
  label_width = 10, -- 8 chars for label + 2 chars for ":"
}

-- Peek state
local peek = {
  bufnr = nil,
  winid = nil,
  cancel = nil,
}

-- Clean up peek window resources
function peek:clean()
  if self.cancel then
    self.cancel()
    self.cancel = nil
  end
  self.bufnr = nil
  self.winid = nil
end

-- Extract variable using providers
local function extract_variable(line, word_end, available_providers, var_name)
  -- Try each provider with the full word
  for _, provider in ipairs(available_providers) do
    local extracted = provider.extract_var(line, word_end)
    if extracted then
      return extracted
    end
  end

  -- If var_name provided, use that
  if var_name and #var_name > 0 then
    return var_name
  end

  return nil
end

-- Create peek window content with optimized string handling
local function create_peek_content(var_name, var_info, types)
  -- Re-detect type to ensure accuracy
  local type_name, value = types.detect_type(var_info.value)

  -- Use the re-detected type and value, or fall back to stored ones
  local display_type = type_name or var_info.type
  local display_value = shelter.mask_value(value or var_info.value, "peek", var_name, var_info.source)
  local source = var_info.source

  -- Pre-allocate table for better performance
  local content_size = var_info.comment and 5 or 4
  local lines = {}
  local highlights = {}

  -- Build content with minimal string operations
  lines[1] = "Name    : " .. var_name
  lines[2] = "Type    : " .. display_type
  lines[3] = "Source  : " .. source
  lines[4] = "Value   : " .. display_value

  -- Add highlights with pre-calculated positions
  highlights[1] = { "EcologVariable", 0, PATTERNS.label_width, PATTERNS.label_width + #var_name }
  highlights[2] = { "EcologType", 1, PATTERNS.label_width, PATTERNS.label_width + #display_type }
  highlights[3] = { "EcologSource", 2, PATTERNS.label_width, PATTERNS.label_width + #source }
  highlights[4] = {
    shelter.is_enabled("peek") and shelter.get_config().highlight_group or "EcologValue",
    3,
    PATTERNS.label_width,
    PATTERNS.label_width + #display_value,
  }

  -- Add comment if exists
  if var_info.comment then
    lines[5] = "Comment : " .. var_info.comment
    highlights[5] = { "Comment", 4, PATTERNS.label_width, -1 }
  end

  return {
    lines = lines,
    highlights = highlights,
  }
end

-- Set up peek window autocommands
local function setup_peek_autocommands(curbuf)
  -- Auto-close window on cursor move in main buffer
  api.nvim_create_autocmd({ "CursorMoved", "InsertEnter", "BufDelete", "BufWinLeave" }, {
    buffer = curbuf,
    callback = function(opt)
      if peek.winid and api.nvim_win_is_valid(peek.winid) and api.nvim_get_current_win() ~= peek.winid then
        api.nvim_win_close(peek.winid, true)
        peek:clean()
      end
      api.nvim_del_autocmd(opt.id)
    end,
    once = true,
  })

  -- Clean up on buffer wipeout
  api.nvim_create_autocmd("BufWipeout", {
    buffer = peek.bufnr,
    callback = function()
      peek:clean()
    end,
  })
end

---@class PeekContent
---@field lines string[] Lines of content to display
---@field highlights table[] Highlight definitions

-- Optimized peek window creation
function M.peek_env_var(available_providers, var_name)
  local filetype = vim.bo.filetype
  local types = require("ecolog.types")

  if #available_providers == 0 then
    notify("EcologPeek is not available for " .. filetype .. " files", vim.log.levels.WARN)
    return
  end

  -- Check if window exists and is valid
  if peek.winid and api.nvim_win_is_valid(peek.winid) then
    api.nvim_set_current_win(peek.winid)
    api.nvim_win_set_cursor(peek.winid, { 1, 0 })
    return
  end

  -- Get ecolog instance
  local has_ecolog, ecolog = pcall(require, "ecolog")
  if not has_ecolog then
    notify("Ecolog not found", vim.log.levels.ERROR)
    return
  end

  -- If no var_name provided, try to get it from under cursor
  if not var_name or var_name == "" then
    var_name = utils.get_var_word_under_cursor(available_providers)
    if not var_name then
      notify("No environment variable found under cursor", vim.log.levels.WARN)
      return
    end
  end

  -- Get the environment variable from ecolog
  local env_vars = ecolog.get_env_vars()
  local var_info = env_vars[var_name]
  if not var_info then
    notify(string.format("Environment variable '%s' not found", var_name), vim.log.levels.WARN)
    return
  end

  -- Create content with optimized functions
  local content = create_peek_content(var_name, var_info, types)
  local curbuf = api.nvim_get_current_buf()

  -- Create peek window with batched operations
  peek.bufnr = api.nvim_create_buf(false, true)

  -- Set all buffer options at once
  api.nvim_buf_set_option(peek.bufnr, "modifiable", true)
  api.nvim_buf_set_lines(peek.bufnr, 0, -1, false, content.lines)
  api.nvim_buf_set_option(peek.bufnr, "modifiable", false)
  api.nvim_buf_set_option(peek.bufnr, "bufhidden", "wipe")
  api.nvim_buf_set_option(peek.bufnr, "buftype", "nofile")
  api.nvim_buf_set_option(peek.bufnr, "filetype", "ecolog")

  -- Create window with all options
  peek.winid = api.nvim_open_win(peek.bufnr, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = 52,
    height = #content.lines,
    style = "minimal",
    border = "rounded",
    focusable = true,
  })

  -- Set window options in batch
  api.nvim_win_set_option(peek.winid, "conceallevel", 2)
  api.nvim_win_set_option(peek.winid, "concealcursor", "niv")
  api.nvim_win_set_option(peek.winid, "cursorline", true)
  api.nvim_win_set_option(peek.winid, "winhl", "Normal:EcologNormal,FloatBorder:EcologBorder")

  -- Apply highlights in batch
  for _, hl in ipairs(content.highlights) do
    api.nvim_buf_add_highlight(peek.bufnr, -1, hl[1], hl[2], hl[3], hl[4])
  end

  -- Set up autocommands and mappings
  setup_peek_autocommands(curbuf)

  -- Set buffer mappings efficiently
  local close_fn = function()
    if peek.winid and api.nvim_win_is_valid(peek.winid) then
      api.nvim_win_close(peek.winid, true)
      peek:clean()
    end
  end

  api.nvim_buf_set_keymap(peek.bufnr, "n", "q", "", {
    callback = close_fn,
    noremap = true,
    silent = true,
  })
end

return M
