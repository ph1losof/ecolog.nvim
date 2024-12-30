local has_fzf, fzf = pcall(require, "fzf-lua")
if not has_fzf then
  error("This extension requires fzf-lua (https://github.com/ibhagwan/fzf-lua)")
end

local utils = require("ecolog.utils")
local shelter = utils.get_module("ecolog.shelter")
local api = vim.api
local fn = vim.fn

local config = {
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

local M = {}

local function notify_with_title(msg, level)
  vim.notify(string.format("Ecolog FZF: %s", msg), level)
end

local function safe_action(name, _fn)
  return function(selected)
    local ok, err = pcall(_fn, selected)
    if not ok then
      notify_with_title(string.format("Failed to %s: %s", name, err), vim.log.levels.ERROR)
    end
  end
end

local function handle_buffer_action(selected, action_fn)
  local var_name = utils.extract_var_name(selected[1])
  if not var_name then
    return
  end

  local result = action_fn(var_name)
  if not result then
    return
  end

  local cursor = api.nvim_win_get_cursor(0)
  local line = api.nvim_get_current_line()
  local new_line = line:sub(1, cursor[2]) .. result .. line:sub(cursor[2] + 1)
  api.nvim_set_current_line(new_line)
  api.nvim_win_set_cursor(0, { cursor[1], cursor[2] + #result })
end

function M.actions()
  local ecolog = require("ecolog")
  local env_vars = ecolog.get_env_vars()

  return {
    [config.mappings.copy_value] = safe_action("copy_value", function(selected)
      local var_name = utils.extract_var_name(selected[1])
      local selection = env_vars[var_name]
      if not selection then
        return
      end

      local value = config.shelter.mask_on_copy and shelter.mask_value(selection.value, "fzf") or selection.value
      fn.setreg("+", value)
      notify_with_title(string.format("Copied value of '%s' to clipboard", var_name), vim.log.levels.INFO)
    end),

    [config.mappings.copy_name] = safe_action("copy_name", function(selected)
      local var_name = utils.extract_var_name(selected[1])
      if not var_name then
        return
      end
      fn.setreg("+", var_name)
      notify_with_title(string.format("Copied variable '%s' name to clipboard", var_name), vim.log.levels.INFO)
    end),

    [config.mappings.append_name] = function(selected)
      handle_buffer_action(selected, function(var_name)
        return var_name
      end)
      notify_with_title("Appended environment name", vim.log.levels.INFO)
    end,

    [config.mappings.append_value] = function(selected)
      handle_buffer_action(selected, function(var_name)
        local selection = env_vars[var_name]
        if not selection then
          return nil
        end
        return config.shelter.mask_on_copy and shelter.mask_value(selection.value, "fzf") or selection.value
      end)
      notify_with_title("Appended environment value", vim.log.levels.INFO)
    end,
  }
end

function M.env_picker()
  local ecolog = require("ecolog")
  local env_vars = ecolog.get_env_vars()
  local results = {}

  for name, var in pairs(env_vars) do
    local display_value = shelter.mask_value(var.value, "fzf")
    table.insert(results, string.format("%-30s = %s", name, display_value))
  end

  fzf.fzf_exec(results, {
    prompt = "Environment Variables> ",
    actions = M.actions(),
  })
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
  M.fzf = M.env_picker
end

return M
