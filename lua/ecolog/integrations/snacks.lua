local utils = require("ecolog.utils")
local shelter = utils.get_module("ecolog.shelter")
local api = vim.api
local fn = vim.fn

---@class SnacksConfig
---@field shelter { mask_on_copy: boolean }
---@field keys { copy_value: string, copy_name: string, append_value: string, append_name: string }
local DEFAULT_CONFIG = {
  shelter = {
    mask_on_copy = false,
  },
  keys = {
    copy_value = "<C-y>",
    copy_name = "<C-u>",
    append_value = "<C-a>",
    append_name = "<CR>",
  },
}

---@class Snacks
---@field _initialized boolean
---@field config SnacksConfig
---@field snacks function
local M = {
  _initialized = false,
  config = DEFAULT_CONFIG,
}

-- Store window ID in module scope
local original_winid = nil

---Notify user with Ecolog Snacks prefix
---@param msg string
---@param level number
local function notify_with_title(msg, level)
  vim.notify(string.format("Ecolog Snacks: %s", msg), level)
end

---Validate if the original window is still valid
---@return boolean
local function validate_window()
  if not api.nvim_win_is_valid(original_winid) then
    notify_with_title("Original window no longer valid", vim.log.levels.ERROR)
    return false
  end
  return true
end

---Append text at cursor position
---@param text string
---@return boolean success
local function append_at_cursor(text)
  if not validate_window() then
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

---Copy text to clipboard with notification
---@param text string
---@param description string
local function copy_to_clipboard(text, description)
  fn.setreg("+", text)
  notify_with_title(string.format("Copied %s to clipboard", description), vim.log.levels.INFO)
end

---Create picker actions for handling different key mappings
---@return table<string, function>
local function create_picker_actions()
  return {
    copy_value = function(picker)
      local item = picker:current()
      if not item then return end
      local value = M.config.shelter.mask_on_copy and shelter.mask_value(item.data.value, "snacks") or item.data.value
      copy_to_clipboard(value, string.format("value of '%s'", item.data.name))
      picker:close()
    end,
    copy_name = function(picker)
      local item = picker:current()
      if not item then return end
      copy_to_clipboard(item.data.name, string.format("variable '%s' name", item.data.name))
      picker:close()
    end,
    append_value = function(picker)
      local item = picker:current()
      if not item then return end
      local value = M.config.shelter.mask_on_copy and shelter.mask_value(item.data.value, "snacks") or item.data.value
      if append_at_cursor(value) then
        notify_with_title("Appended environment value", vim.log.levels.INFO)
        picker:close()
      end
    end,
    append_name = function(picker)
      local item = picker:current()
      if not item then return end
      if append_at_cursor(item.name) then
        notify_with_title("Appended environment name", vim.log.levels.INFO)
        picker:close()
      end
    end,
  }
end

---Create keymap configuration for snacks picker
---@param config SnacksConfig
---@return table<string, table>
local function create_keymaps(config)
  local function create_keymap(action)
    return { action, mode = { "i", "n" }, remap = true }
  end

  local keymaps = {}
  for action, key in pairs(config.keys) do
    keymaps[key] = create_keymap(action)
  end
  return keymaps
end

---Format item for display in picker
---@param item table
---@return table
local function format_picker_item(item)
  return {
    text = item.label,
    hl = {
      { "@variable", 0, #item.name },
      { "@operator", #item.name + 1, #item.name + 3 },
      { "@string", #item.name + 3, -1 },
    },
  }
end

---Create picker items from environment variables
---@return table[]
local function create_picker_items()
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
  return items
end

---Open environment variables picker
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

  snacks.pick({
    title = "Environment Variables",
    items = create_picker_items(),
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
        keys = create_keymaps(M.config),
      },
      list = {
        border = "single",
        height = 0.8,
        width = 1.0,
      },
    },
    format_item = format_picker_item,
    confirm = function(picker, item)
      if not item then return end
      if append_at_cursor(item.name) then
        notify_with_title("Appended environment name", vim.log.levels.INFO)
        picker:close()
      end
    end,
    actions = create_picker_actions(),
  })
end

---Setup snacks integration
---@param opts? table
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", DEFAULT_CONFIG, opts or {})
  M.snacks = M.env_picker

  api.nvim_create_user_command("EcologSnacks", function()
    M.env_picker()
  end, {
    desc = "Open environment variables picker using snacks.nvim",
  })
end

return M
