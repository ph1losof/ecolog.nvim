---@class EcologPickerCommon
---Common utilities shared across picker implementations
local M = {}

local notify = require("ecolog.notification_manager")
local hooks = require("ecolog.hooks")
local api = vim.api
local fn = vim.fn

---@type number|nil
local original_winid = nil

---@class EcologDisplayEntry
---@field name string Variable name
---@field value string|nil Variable value (may be masked)
---@field source string|nil Source file path
---@field raw EcologVariable Original unmasked variable data

---@class EcologVariablesData
---@field entries EcologDisplayEntry[] Transformed entries
---@field longest_name number Longest variable name length for alignment

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

---Build display entries from variables list
---Transforms variables through hooks and calculates alignment
---@param vars EcologVariable[] Raw variables from LSP
---@return EcologVariablesData
function M.build_entries(vars)
  local entries = {}
  local longest_name = 0

  for _, var in ipairs(vars) do
    longest_name = math.max(longest_name, #var.name)
  end

  for _, var in ipairs(vars) do
    -- Transform through hooks for display (may mask values)
    local display = hooks.fire_filter("on_picker_entry", {
      name = var.name,
      value = var.value,
      source = var.source,
    })

    table.insert(entries, {
      name = display.name,
      value = display.value,
      source = display.source,
      raw = var, -- Keep original for actions that need unmasked value
    })
  end

  return {
    entries = entries,
    longest_name = longest_name,
  }
end

---Get unmasked variable value through peek hook
---@param var EcologVariable Variable to peek
---@return EcologVariable var with unmasked value
function M.get_unmasked(var)
  return hooks.fire_filter("on_variable_peek", var) or var
end

---Copy variable value to clipboard (unmasked)
---@param var EcologVariable Variable to copy value from
function M.copy_value(var)
  local unmasked = M.get_unmasked(var)
  M.copy_to_clipboard(unmasked.value, "value of '" .. var.name .. "'")
end

---Copy variable name to clipboard
---@param var EcologVariable Variable to copy name from
function M.copy_name(var)
  M.copy_to_clipboard(var.name, "variable '" .. var.name .. "' name")
end

---Append variable value at cursor (unmasked)
---@param var EcologVariable Variable to append value from
---@return boolean success
function M.append_value(var)
  local unmasked = M.get_unmasked(var)
  local success = M.append_at_cursor(unmasked.value)
  if success then
    notify.info("Appended value")
  end
  return success
end

---Append variable name at cursor
---@param var EcologVariable Variable to append name from
---@return boolean success
function M.append_name(var)
  local success = M.append_at_cursor(var.name)
  if success then
    notify.info("Appended " .. var.name)
  end
  return success
end

---Go to variable source file
---@param var EcologVariable Variable to navigate to
function M.goto_var_source(var)
  M.goto_source(var.source)
end

return M
