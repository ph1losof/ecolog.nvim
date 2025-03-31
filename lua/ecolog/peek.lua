local api = vim.api
local notify = vim.notify
local shelter = require("ecolog.shelter")
local utils = require("ecolog.utils")

local M = {}

local PATTERNS = {
  label_width = 10,
}

local peek = {
  bufnr = nil,
  winid = nil,
  cancel = nil,
}

function peek:clean()
  if self.cancel then
    self.cancel()
    self.cancel = nil
  end
  self.bufnr = nil
  self.winid = nil
end

local function create_peek_content(var_name, var_info, types)
  local type_name, value = types.detect_type(var_info.value)

  local display_type = type_name or var_info.type
  local display_value = shelter.mask_value(value or var_info.value, "peek", var_name, var_info.source)
  local source = var_info.source

  local lines = {}
  local highlights = {}

  lines[1] = "Name    : " .. var_name
  lines[2] = "Type    : " .. display_type
  lines[3] = "Source  : " .. source
  lines[4] = "Value   : " .. display_value

  highlights[1] = { "EcologVariable", 0, PATTERNS.label_width, PATTERNS.label_width + #var_name }
  highlights[2] = { "EcologType", 1, PATTERNS.label_width, PATTERNS.label_width + #display_type }
  highlights[3] = { "EcologSource", 2, PATTERNS.label_width, PATTERNS.label_width + #source }
  highlights[4] = {
    shelter.is_enabled("peek") and shelter.get_config().highlight_group or "EcologValue",
    3,
    PATTERNS.label_width,
    PATTERNS.label_width + #display_value,
  }

  if var_info.comment then
    local comment_value = var_info.comment
    if shelter.is_enabled("peek") and not shelter.get_config().skip_comments then
      local utils = require("ecolog.shelter.utils")
      comment_value = utils.mask_comment(comment_value, var_info.source, shelter, "peek")
    end
    lines[5] = "Comment : " .. comment_value
    highlights[5] = { "Comment", 4, PATTERNS.label_width, -1 }
  end

  return {
    lines = lines,
    highlights = highlights,
  }
end

local function setup_peek_autocommands(curbuf)
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

function M.peek_env_var(available_providers, var_name)
  local filetype = vim.bo.filetype
  local types = require("ecolog.types")

  if #available_providers == 0 then
    notify("EcologPeek is not available for " .. filetype .. " files", vim.log.levels.WARN)
    return
  end

  if peek.winid and api.nvim_win_is_valid(peek.winid) then
    api.nvim_set_current_win(peek.winid)
    api.nvim_win_set_cursor(peek.winid, { 1, 0 })
    return
  end

  local has_ecolog, ecolog = pcall(require, "ecolog")
  if not has_ecolog then
    notify("Ecolog not found", vim.log.levels.ERROR)
    return
  end

  if not var_name or var_name == "" then
    var_name = utils.get_var_word_under_cursor(available_providers)
    if not var_name then
      notify("No environment variable found under cursor", vim.log.levels.WARN)
      return
    end
  end

  local env_vars = ecolog.get_env_vars()
  local var_info = env_vars[var_name]
  if not var_info then
    notify(string.format("Environment variable '%s' not found", var_name), vim.log.levels.WARN)
    return
  end

  local content = create_peek_content(var_name, var_info, types)
  local curbuf = api.nvim_get_current_buf()

  peek.bufnr = api.nvim_create_buf(false, true)

  api.nvim_buf_set_option(peek.bufnr, "modifiable", true)
  api.nvim_buf_set_lines(peek.bufnr, 0, -1, false, content.lines)
  api.nvim_buf_set_option(peek.bufnr, "modifiable", false)
  api.nvim_buf_set_option(peek.bufnr, "bufhidden", "wipe")
  api.nvim_buf_set_option(peek.bufnr, "buftype", "nofile")
  api.nvim_buf_set_option(peek.bufnr, "filetype", "ecolog")

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

  api.nvim_win_set_option(peek.winid, "conceallevel", 2)
  api.nvim_win_set_option(peek.winid, "concealcursor", "niv")
  api.nvim_win_set_option(peek.winid, "cursorline", true)
  api.nvim_win_set_option(peek.winid, "winhl", "Normal:EcologNormal,FloatBorder:EcologBorder")

  for _, hl in ipairs(content.highlights) do
    api.nvim_buf_add_highlight(peek.bufnr, -1, hl[1], hl[2], hl[3], hl[4])
  end

  setup_peek_autocommands(curbuf)

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
