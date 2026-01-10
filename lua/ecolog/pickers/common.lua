---@class EcologPickerCommon
---Common utilities shared across picker implementations
local M = {}

local notify = require("ecolog.notification_manager")
local api = vim.api
local fn = vim.fn

---@type number|nil
local original_winid = nil

---Save current window for later use
---Call this before opening a picker
function M.save_current_window()
  original_winid = api.nvim_get_current_win()
end

---Validate if original window is still valid
---@return boolean
function M.validate_window()
  return original_winid and api.nvim_win_is_valid(original_winid)
end

---Get the saved window ID
---@return number|nil
function M.get_original_window()
  return original_winid
end

---Append text at cursor position in original window
---@param text string
---@return boolean success
function M.append_at_cursor(text)
  if not M.validate_window() then
    notify.error("Original window no longer valid")
    return false
  end

  api.nvim_set_current_win(original_winid)
  local cursor = api.nvim_win_get_cursor(original_winid)
  local line = api.nvim_get_current_line()
  local new_line = line:sub(1, cursor[2]) .. text .. line:sub(cursor[2] + 1)
  api.nvim_set_current_line(new_line)
  api.nvim_win_set_cursor(original_winid, { cursor[1], cursor[2] + #text })
  return true
end

---Copy text to clipboard (both + and " registers)
---@param text string
---@param what string Description of what was copied (e.g., "value of 'FOO'")
function M.copy_to_clipboard(text, what)
  fn.setreg("+", text)
  fn.setreg('"', text)
  notify.info("Copied " .. what)
end

---Go to source file
---@param source string Source path (can be relative or absolute)
function M.goto_source(source)
  if not source or source == "" or source == "System Environment" then
    notify.info("No file source for this variable")
    return
  end

  -- Handle relative paths
  local path = source
  if not vim.startswith(source, "/") then
    local client = require("ecolog.lsp").get_client()
    if client and client.config and client.config.root_dir then
      path = client.config.root_dir .. "/" .. source
    end
  end

  if fn.filereadable(path) == 1 then
    vim.cmd("edit " .. fn.fnameescape(path))
    notify.info("Opened " .. source)
  else
    notify.warn("Cannot find file: " .. source)
  end
end

return M
