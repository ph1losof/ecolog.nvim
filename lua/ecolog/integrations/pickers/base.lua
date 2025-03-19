local utils = require("ecolog.utils")
local shelter = utils.get_module("ecolog.shelter")
local api = vim.api
local fn = vim.fn

---@class BasePicker
---@field _initialized boolean
---@field _config table
---@field _original_winid number|nil
local BasePicker = {}
BasePicker.__index = BasePicker

---Create a new picker instance
---@param opts table|nil Optional configuration to override defaults
---@return BasePicker
function BasePicker:new(opts)
  local instance = setmetatable({}, self)
  instance._initialized = false
  instance._config = vim.tbl_deep_extend("force", instance:get_default_config(), opts or {})
  return instance
end

---Get the default configuration for this picker
---@return table
function BasePicker:get_default_config()
  return {
    shelter = {
      mask_on_copy = false,
    },
    keys = {
      copy_value = "",
      copy_name = "",
      append_value = "",
      append_name = "",
      edit_var = "",
    },
  }
end

---Store current window id for later use
function BasePicker:save_current_window()
  self._original_winid = api.nvim_get_current_win()
end

---Validate if the original window is still valid
---@return boolean
function BasePicker:validate_window()
  if not self._original_winid or not api.nvim_win_is_valid(self._original_winid) then
    self:notify("Original window no longer valid", vim.log.levels.ERROR)
    return false
  end
  return true
end

---Notify user with prefix specific to the picker implementation
---@param msg string
---@param level number
function BasePicker:notify(msg, level)
  vim.notify(string.format("%s: %s", self:get_name(), msg), level)
end

---Get the name of this picker for notifications
---@return string
function BasePicker:get_name()
  return "Ecolog Picker" -- Subclasses should override this
end

---Append text at cursor position
---@param text string
---@return boolean success
function BasePicker:append_at_cursor(text)
  if not self:validate_window() then
    return false
  end

  api.nvim_set_current_win(self._original_winid)
  local cursor = api.nvim_win_get_cursor(self._original_winid)
  local line = api.nvim_get_current_line()
  local new_line = line:sub(1, cursor[2]) .. text .. line:sub(cursor[2] + 1)
  api.nvim_set_current_line(new_line)
  api.nvim_win_set_cursor(self._original_winid, { cursor[1], cursor[2] + #text })
  return true
end

---Copy text to clipboard with notification
---@param text string
---@param description string
function BasePicker:copy_to_clipboard(text, description)
  fn.setreg("+", text)
  self:notify(string.format("Copied %s to clipboard", description), vim.log.levels.INFO)
end

---Prompt for a new value and update the environment variable
---@param var_name string The environment variable name
---@param current_value string The current value of the variable
---@return boolean success
function BasePicker:edit_environment_var(var_name, current_value)
  if not self:validate_window() then
    return false
  end

  vim.ui.input({ prompt = string.format("New value for %s (current: %s): ", var_name, current_value) }, function(input)
    if input then
      vim.cmd(string.format("EcologEnvSet %s %s", var_name, input))
      self:notify(string.format("Updated environment variable '%s'", var_name), vim.log.levels.INFO)
    end
  end)

  return true
end

---Get masked version of a variable value based on config
---@param value string Original value
---@param var_name string|nil Variable name for context
---@param source string|nil Source of the variable
---@return string masked_value
function BasePicker:get_masked_value(value, var_name, source)
  if not value then
    return ""
  end
  return shelter.mask_value(value, self:get_name():lower(), var_name, source)
end

---Setup the picker with configuration
---@param opts table|nil
function BasePicker:setup(opts)
  self._config = vim.tbl_deep_extend("force", self:get_default_config(), opts or {})
  self._initialized = true
end

function BasePicker:open()
  error("BasePicker:open() must be implemented by subclasses")
end

return BasePicker

