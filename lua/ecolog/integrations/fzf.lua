local utils = require("ecolog.utils")
local shelter = utils.get_module("ecolog.shelter")
local api = vim.api
local fn = vim.fn

---@class FzfConfig
---@field shelter { mask_on_copy: boolean }
---@field mappings { copy_value: string, copy_name: string, append_value: string, append_name: string }
local DEFAULT_CONFIG = {
  shelter = {
    mask_on_copy = false,
  },
  mappings = {
    copy_value = "ctrl-y",
    copy_name = "ctrl-n",
    append_value = "ctrl-a",
    append_name = "enter",
  },
}

---@class FzfIntegration
---@field _initialized boolean
---@field config FzfConfig
---@field fzf function
local M = {
  _initialized = false,
  config = DEFAULT_CONFIG,
}

---Notify user with Ecolog FZF prefix
---@param msg string
---@param level number
local function notify_with_title(msg, level)
  vim.notify(string.format("Ecolog FZF: %s", msg), level)
end

---Wrap action function with error handling
---@param name string Name of the action for error reporting
---@param _fn function Function to wrap
---@return function
local function safe_action(name, _fn)
  return function(selected)
    local ok, err = pcall(_fn, selected)
    if not ok then
      notify_with_title(string.format("Failed to %s: %s", name, err), vim.log.levels.ERROR)
    end
  end
end

---Handle buffer action with cursor position update
---@param selected table Selected item from fzf
---@param action_fn function Function to process the variable name
---@return boolean?
local function handle_buffer_action(selected, action_fn)
  local var_name = utils.extract_var_name(selected[1])
  if not var_name then
    return false
  end

  local result = action_fn(var_name)
  if not result then
    return false
  end

  local cursor = api.nvim_win_get_cursor(0)
  local line = api.nvim_get_current_line()
  local new_line = line:sub(1, cursor[2]) .. result .. line:sub(cursor[2] + 1)
  api.nvim_set_current_line(new_line)
  api.nvim_win_set_cursor(0, { cursor[1], cursor[2] + #result })
  return true
end

---Create copy value action
---@param env_vars table Environment variables
---@param config FzfConfig
---@return function
local function create_copy_value_action(env_vars, config)
  return safe_action("copy_value", function(selected)
    local var_name = utils.extract_var_name(selected[1])
    local selection = env_vars[var_name]
    if not selection then
      return
    end

    local value = config.shelter.mask_on_copy and shelter.mask_value(selection.value, "fzf", nil, selection.source)
      or selection.value
    fn.setreg("+", value)
    notify_with_title(string.format("Copied value of '%s' to clipboard", var_name), vim.log.levels.INFO)
  end)
end

---Create copy name action
---@return function
local function create_copy_name_action()
  return safe_action("copy_name", function(selected)
    local var_name = utils.extract_var_name(selected[1])
    if not var_name then
      return
    end
    fn.setreg("+", var_name)
    notify_with_title(string.format("Copied variable '%s' name to clipboard", var_name), vim.log.levels.INFO)
  end)
end

---Create append name action
---@return function
local function create_append_name_action()
  return function(selected)
    if handle_buffer_action(selected, function(var_name)
      return var_name
    end) then
      notify_with_title("Appended environment name", vim.log.levels.INFO)
    end
  end
end

---Create append value action
---@param env_vars table Environment variables
---@param config FzfConfig
---@return function
local function create_append_value_action(env_vars, config)
  return function(selected)
    if
      handle_buffer_action(selected, function(var_name)
        local selection = env_vars[var_name]
        if not selection then
          return nil
        end
        return config.shelter.mask_on_copy and shelter.mask_value(selection.value, "fzf", nil, selection.source)
          or selection.value
      end)
    then
      notify_with_title("Appended environment value", vim.log.levels.INFO)
    end
  end
end

---Create fzf actions mapping
---@return table<string, function>
function M.actions()
  local ecolog = require("ecolog")
  local env_vars = ecolog.get_env_vars()

  return {
    [M.config.mappings.copy_value] = create_copy_value_action(env_vars, M.config),
    [M.config.mappings.copy_name] = create_copy_name_action(),
    [M.config.mappings.append_name] = create_append_name_action(),
    [M.config.mappings.append_value] = create_append_value_action(env_vars, M.config),
  }
end

---Format environment variables for display
---@param env_vars table Environment variables
---@return string[]
local function format_env_vars(env_vars)
  local results = {}
  for name, var in pairs(env_vars) do
    local display_value = shelter.mask_value(var.value, "fzf", nil, var.source)
    table.insert(results, string.format("%-30s = %s", name, display_value))
  end
  return results
end

---Open environment variables picker using fzf
function M.env_picker()
  local has_fzf, fzf = pcall(require, "fzf-lua")
  if not has_fzf then
    vim.notify("This extension requires fzf-lua (https://github.com/ibhagwan/fzf-lua)", vim.log.levels.ERROR)
    return
  end

  if not M._initialized then
    M.setup({})
    M._initialized = true
  end

  local ecolog = require("ecolog")
  local env_vars = ecolog.get_env_vars()
  local results = format_env_vars(env_vars)

  fzf.fzf_exec(results, {
    prompt = "Environment Variables> ",
    actions = M.actions(),
  })
end

---Setup fzf integration
---@param opts? table
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", DEFAULT_CONFIG, opts or {})
  M.fzf = M.env_picker

  api.nvim_create_user_command("EcologFzf", function()
    M.env_picker()
  end, {
    desc = "Open environment variables picker using fzf-lua",
  })
end

return M
