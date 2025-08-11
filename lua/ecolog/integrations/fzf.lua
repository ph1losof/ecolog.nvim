local utils = require("ecolog.utils")
local BasePicker = require("ecolog.integrations.pickers.base")
local api = vim.api

---@class FzfPicker : BasePicker
---@field fzf function
local FzfPicker = setmetatable({}, { __index = BasePicker })
FzfPicker.__index = FzfPicker

---Create a new FzfPicker instance
---@param opts table|nil Optional configuration to override defaults
---@return FzfPicker
function FzfPicker:new(opts)
  local instance = BasePicker.new(self, opts)
  return instance
end

---Get the name of this picker for notifications
---@return string
function FzfPicker:get_name()
  return "Ecolog FZF"
end

---Get the default configuration for this picker
---@return table
function FzfPicker:get_default_config()
  return {
    shelter = {
      mask_on_copy = false,
    },
    mappings = {
      copy_value = "ctrl-y",
      copy_name = "ctrl-n",
      append_value = "ctrl-a",
      append_name = "enter",
      edit_var = "ctrl-e",
    },
    custom_actions = {},
  }
end

---Wrap action function with error handling
---@param name string Name of the action for error reporting
---@param _fn function Function to wrap
---@return function
function FzfPicker:safe_action(name, _fn)
  local self_ref = self
  return function(selected)
    local ok, err = pcall(_fn, selected)
    if not ok then
      self_ref:notify(string.format("Failed to %s: %s", name, err), vim.log.levels.ERROR)
    end
  end
end

---Handle buffer action with cursor position update
---@param selected table Selected item from fzf
---@param action_fn function Function to process the variable name
---@return boolean?
function FzfPicker:handle_buffer_action(selected, action_fn)
  local var_name = utils.extract_var_name(selected[1])
  if not var_name then
    return false
  end

  local result = action_fn(var_name)
  if not result then
    return false
  end

  return self:append_at_cursor(result)
end

---Create copy value action
---@return function
function FzfPicker:create_copy_value_action()
  local env_vars = require("ecolog").get_env_vars()
  return self:safe_action("copy_value", function(selected)
    local var_name = utils.extract_var_name(selected[1])
    local selection = env_vars[var_name]
    if not selection then
      return
    end

    local value = self._config.shelter.mask_on_copy
        and self:get_masked_value(selection.value, var_name, selection.source)
      or selection.value
    self:copy_to_clipboard(value, string.format("value of '%s'", var_name))
  end)
end

---Create copy name action
---@return function
function FzfPicker:create_copy_name_action()
  return self:safe_action("copy_name", function(selected)
    local var_name = utils.extract_var_name(selected[1])
    if not var_name then
      return
    end
    self:copy_to_clipboard(var_name, string.format("variable '%s' name", var_name))
  end)
end

---Create append name action
---@return function
function FzfPicker:create_append_name_action()
  local self_ref = self
  return function(selected)
    if self_ref:handle_buffer_action(selected, function(var_name)
      return var_name
    end) then
      self_ref:notify("Appended environment name", vim.log.levels.INFO)
    end
  end
end

---Create append value action
---@return function
function FzfPicker:create_append_value_action()
  local env_vars = require("ecolog").get_env_vars()
  local self_ref = self
  return function(selected)
    if
      self_ref:handle_buffer_action(selected, function(var_name)
        local selection = env_vars[var_name]
        if not selection then
          return nil
        end
        return self_ref._config.shelter.mask_on_copy
            and self_ref:get_masked_value(selection.value, var_name, selection.source)
          or selection.value
      end)
    then
      self_ref:notify("Appended environment value", vim.log.levels.INFO)
    end
  end
end

---Create edit variable action
---@return function
function FzfPicker:create_edit_var_action()
  local env_vars = require("ecolog").get_env_vars()
  return self:safe_action("edit_variable", function(selected)
    local var_name = utils.extract_var_name(selected[1])
    if not var_name then
      return
    end

    local selection = env_vars[var_name]
    if not selection then
      return
    end

    self:edit_environment_var(var_name, selection.value)
  end)
end

---Create custom action wrapper
---@param name string The name of the action
---@return function
function FzfPicker:create_custom_action(name)
  local env_vars = require("ecolog").get_env_vars()
  local self_ref = self

  return self:safe_action(name, function(selected)
    local var_name = utils.extract_var_name(selected[1])
    if not var_name then
      return
    end

    local selection = env_vars[var_name]
    if not selection then
      return
    end

    local item = {
      name = var_name,
      value = selection.value,
      masked_value = self_ref:get_masked_value(selection.value, var_name, selection.source),
      source = selection.source,
      type = selection.type,
    }

    local result = self_ref:run_custom_action(name, item)

    local action = self_ref._custom_actions[name]
    if result and action and action.opts and action.opts.notify ~= false then
      self_ref:notify(action.opts.message or string.format("Custom action '%s' executed", name), vim.log.levels.INFO)
    end

    return result
  end)
end

---Create fzf actions mapping
---@return table<string, function>
function FzfPicker:create_actions()
  local actions = {
    [self._config.mappings.copy_value] = self:create_copy_value_action(),
    [self._config.mappings.copy_name] = self:create_copy_name_action(),
    [self._config.mappings.append_name] = self:create_append_name_action(),
    [self._config.mappings.append_value] = self:create_append_value_action(),
    [self._config.mappings.edit_var] = self:create_edit_var_action(),
  }

  local custom_actions = self:get_custom_actions()
  for name, action in pairs(custom_actions) do
    if type(action.key) == "string" then
      actions[action.key] = self:create_custom_action(name)
    elseif type(action.key) == "table" then
      for _, key in ipairs(action.key) do
        actions[key] = self:create_custom_action(name)
      end
    end
  end

  return actions
end

---Format environment variables for display
---@return string[]
function FzfPicker:format_env_vars()
  local data = require("ecolog.integrations.pickers.data")
  local items = data.format_env_vars_for_picker(self:get_name():lower())

  local results = {}
  for _, item in ipairs(items) do
    -- Add ANSI color codes for highlighting
    -- White for variable name, green for value
    local longest = item.longest_name or 20
    local colored_display =
      string.format("\027[37m%-" .. longest .. "s\027[0m \027[32m%s\027[0m", item.name, item.masked_value or "")
    table.insert(results, colored_display)
  end

  return results
end

---Open environment variables picker using fzf
function FzfPicker:open()
  local has_fzf, fzf = pcall(require, "fzf-lua")
  if not has_fzf then
    vim.notify("This extension requires fzf-lua (https://github.com/ibhagwan/fzf-lua)", vim.log.levels.ERROR)
    return
  end

  if not self._initialized then
    self:setup({})
    self._initialized = true
  end

  self:save_current_window()
  local results = self:format_env_vars()

  if #results == 0 then
    self:notify("No results", vim.log.levels.WARN)
    return
  end

  local current_file = require("ecolog").get_state().selected_env_file
  local file = current_file and vim.fn.fnamemodify(current_file, ":t")

  fzf.fzf_exec(results, {
    winopts = {
      title = "Environment Variables",
    },
    prompt = (file or "") .. "> ",
    actions = self:create_actions(),
    fzf_opts = {
      ["--ansi"] = "",
    },
  })
end

---Setup fzf integration
---@param opts? table
function FzfPicker:setup(opts)
  BasePicker.setup(self, opts)
  self.fzf = function()
    self:open()
  end

  api.nvim_create_user_command("EcologFzf", function()
    self:open()
  end, {
    desc = "Open environment variables picker using fzf-lua",
  })
end

---Add a custom action to the fzf picker
---@param name string The name of the action
---@param key string|table The key or keys to map to this action
---@param callback function The callback function to run
---@param opts table|nil Additional options for the action
function FzfPicker:add_action(name, key, callback, opts)
  self:add_custom_action(name, key, callback, opts)
end

local instance = FzfPicker:new()

local M = {
  setup = function(opts)
    instance:setup(opts)
  end,
  env_picker = function()
    instance:open()
  end,
  fzf = function()
    instance:open()
  end,
  actions = function()
    return instance:create_actions()
  end,
  add_action = function(name, key, callback, opts)
    instance:add_action(name, key, callback, opts)
  end,
}

return M
