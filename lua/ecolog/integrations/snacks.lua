local utils = require("ecolog.utils")
local shelter = utils.get_module("ecolog.shelter")
local api = vim.api
local fn = vim.fn

local config = {
  shelter = {
    mask_on_copy = false,
  },
  keys = {
    copy_value = "<C-y>",
    copy_name = "<C-n>",
    append_value = "<C-a>",
    append_name = "<CR>",
  },
}

local M = {}
M._initialized = false
local original_winid = nil

local function notify_with_title(msg, level)
  vim.notify(string.format("Ecolog Snacks: %s", msg), level)
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

  original_winid = api.nvim_get_current_win()

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
      buf = 0,
      pos = { 1, 1 },
      data = {
        name = name,
        value = var.value,
        display_value = display_value,
      },
    })
  end

  local function create_keymap(action)
    return { action, mode = { "i", "n" }, remap = true }
  end

  local keymaps = {}
  for action, key in pairs(config.keys) do
    keymaps[key] = create_keymap(action)
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
    win = {
      input = {
        border = "single",
        height = 1,
        width = 1.0,
        row = -2,
        keys = keymaps,
      },
      list = {
        border = "single",
        height = 0.8,
        width = 1.0,
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
    confirm = function(picker, item)
      if not item then
        return
      end
      if not api.nvim_win_is_valid(original_winid) then
        notify_with_title("Original window no longer valid", vim.log.levels.ERROR)
        return
      end
      api.nvim_set_current_win(original_winid)
      local cursor = api.nvim_win_get_cursor(original_winid)
      local line = api.nvim_get_current_line()
      local new_line = line:sub(1, cursor[2]) .. item.name .. line:sub(cursor[2] + 1)
      api.nvim_set_current_line(new_line)
      api.nvim_win_set_cursor(original_winid, { cursor[1], cursor[2] + #item.name })
      notify_with_title("Appended environment name", vim.log.levels.INFO)
      picker:close()
    end,
    actions = {
      copy_value = function(picker)
        local item = picker:current()
        if not item then
          return
        end
        local value = config.shelter.mask_on_copy and shelter.mask_value(item.data.value, "snacks") or item.data.value
        fn.setreg("+", value)
        notify_with_title(string.format("Copied value of '%s' to clipboard", item.data.name), vim.log.levels.INFO)
        picker:close()
      end,
      copy_name = function(picker)
        local item = picker:current()
        if not item then
          return
        end
        fn.setreg("+", item.data.name)
        notify_with_title(string.format("Copied variable '%s' name to clipboard", item.data.name), vim.log.levels.INFO)
        picker:close()
      end,
      append_value = function(picker)
        local item = picker:current()
        if not item then
          return
        end
        if not api.nvim_win_is_valid(original_winid) then
          notify_with_title("Original window no longer valid", vim.log.levels.ERROR)
          return
        end
        api.nvim_set_current_win(original_winid)
        local cursor = api.nvim_win_get_cursor(original_winid)
        local line = api.nvim_get_current_line()
        local value = config.shelter.mask_on_copy and shelter.mask_value(item.data.value, "snacks") or item.data.value
        local new_line = line:sub(1, cursor[2]) .. value .. line:sub(cursor[2] + 1)
        api.nvim_set_current_line(new_line)
        api.nvim_win_set_cursor(original_winid, { cursor[1], cursor[2] + #value })
        notify_with_title("Appended environment value", vim.log.levels.INFO)
        picker:close()
      end,
      append_name = function(picker)
        local item = picker:current()
        if not item then
          return
        end
        if not api.nvim_win_is_valid(original_winid) then
          notify_with_title("Original window no longer valid", vim.log.levels.ERROR)
          return
        end
        api.nvim_set_current_win(original_winid)
        local cursor = api.nvim_win_get_cursor(original_winid)
        local line = api.nvim_get_current_line()
        local new_line = line:sub(1, cursor[2]) .. item.name .. line:sub(cursor[2] + 1)
        api.nvim_set_current_line(new_line)
        api.nvim_win_set_cursor(original_winid, { cursor[1], cursor[2] + #item.name })
        notify_with_title("Appended environment name", vim.log.levels.INFO)
        picker:close()
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
