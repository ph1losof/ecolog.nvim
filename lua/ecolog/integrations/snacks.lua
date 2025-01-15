local utils = require("ecolog.utils")
local shelter = utils.get_module("ecolog.shelter")
local api = vim.api
local fn = vim.fn

local config = {
  shelter = {
    mask_on_copy = false,
  },
}

local M = {}
M._initialized = false

local function notify_with_title(msg, level)
  vim.notify(string.format("Ecolog Snacks: %s", msg), level)
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
  local var_name = utils.extract_var_name(selected)
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

function M.env_picker()
  local has_snacks, snacks = pcall(require, "snacks.picker")
  if not has_snacks then
    vim.notify("This extension requires snacks.nvim (https://github.com/folke/snacks.nvim)", vim.log.levels.ERROR)
    return
  end

  if not M._initialized then
    M.setup({})
    M._initialized = true
  end

  local ecolog = require("ecolog")
  local env_vars = ecolog.get_env_vars()
  local items = {}

  for name, var in pairs(env_vars) do
    local display_value = shelter.mask_value(var.value, "snacks")
    table.insert(items, {
      id = name,
      text = name,
      label = string.format("%-30s = %s", name, display_value),
      name = name,
      value = var.value,
      data = {
        name = name,
        value = var.value,
        display_value = display_value,
      },
    })
  end

  snacks.pick({
    title = "Environment Variables",
    items = items,
    layout = {
      preset = "vscode",
      config = {
        preview = false,
      },
    },
    format_item = function(item)
      return {
        text = item.label,
        hl = {
          { "@variable", 0, #item.name },
          { "@operator", #item.name + 1, #item.name + 3 },
          { "@string", #item.name + 3, -1 },
        },
      }
    end,
    on_select = function(item)
      handle_buffer_action(item.data.name, function(var_name)
        return var_name
      end)
      notify_with_title("Appended environment name", vim.log.levels.INFO)
    end,
    keys = {
      ["<C-y>"] = function(item)
        local value = config.shelter.mask_on_copy and shelter.mask_value(item.data.value, "snacks") or item.data.value
        fn.setreg("+", value)
        notify_with_title(string.format("Copied value of '%s' to clipboard", item.data.name), vim.log.levels.INFO)
      end,
      ["<C-n>"] = function(item)
        fn.setreg("+", item.data.name)
        notify_with_title(string.format("Copied variable '%s' name to clipboard", item.data.name), vim.log.levels.INFO)
      end,
      ["<C-a>"] = function(item)
        handle_buffer_action(item.data.name, function(var_name)
          local value = config.shelter.mask_on_copy and shelter.mask_value(item.data.value, "snacks") or item.data.value
          return value
        end)
        notify_with_title("Appended environment value", vim.log.levels.INFO)
      end,
    },
  })
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
  M.snacks = M.env_picker

  api.nvim_create_user_command("EcologSnacks", function()
    M.env_picker()
  end, {
    desc = "Open environment variables picker using snacks.nvim",
  })
end

return M

