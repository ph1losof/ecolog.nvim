local utils = require("ecolog.utils")
local BasePicker = require("ecolog.integrations.pickers.base")
local api = vim.api
local fn = vim.fn

---@class SnacksConfig
---@field shelter { mask_on_copy: boolean }
---@field keys { copy_value: string, copy_name: string, append_value: string, append_name: string, edit_var: string }
---@field layout snacks.picker.layout.Config|string|{}|fun(source:string):(snacks.picker.layout.Config|string)
local DEFAULT_CONFIG = {
  shelter = {
    mask_on_copy = false,
  },
  keys = {
    copy_value = "<C-y>",
    copy_name = "<C-u>",
    append_value = "<C-a>",
    append_name = "<CR>",
    edit_var = "<C-e>",
  },
  layout = {
    preset = "dropdown",
    preview = false,
  },
}

---@class SnacksPicker : BasePicker
---@field snacks function
local SnacksPicker = setmetatable({}, { __index = BasePicker })
SnacksPicker.__index = SnacksPicker

---Create a new SnacksPicker instance
---@param opts table|nil Optional configuration to override defaults
---@return SnacksPicker
function SnacksPicker:new(opts)
  local instance = BasePicker.new(self, opts)
  return instance
end

---Get the name of this picker for notifications
---@return string
function SnacksPicker:get_name()
  return "Ecolog Snacks"
end

---Get the default configuration for this picker
---@return table
function SnacksPicker:get_default_config()
  return {
    shelter = {
      mask_on_copy = false,
    },
    keys = {
      copy_value = "<C-y>",
      copy_name = "<C-u>",
      append_value = "<C-a>",
      append_name = "<CR>",
      edit_var = "<C-e>",
    },
    layout = {
      preset = "dropdown",
      preview = false,
    },
  }
end

---Create picker actions for handling different key mappings
---@return table<string, function>
function SnacksPicker:create_picker_actions()
  return {
    copy_value = function(picker)
      local item = picker:current()
      if not item then
        return
      end
      local value = self._config.shelter.mask_on_copy and self:get_masked_value(item.value, item.name, item.source)
        or item.value
      self:copy_to_clipboard(value, string.format("value of '%s'", item.name))
      picker:close()
    end,

    copy_name = function(picker)
      local item = picker:current()
      if not item then
        return
      end
      self:copy_to_clipboard(item.name, string.format("variable '%s' name", item.name))
      picker:close()
    end,

    append_value = function(picker)
      local item = picker:current()
      if not item then
        return
      end
      local value = self._config.shelter.mask_on_copy and self:get_masked_value(item.value, item.name, item.source)
        or item.value
      if self:append_at_cursor(value) then
        self:notify("Appended environment value", vim.log.levels.INFO)
        picker:close()
      end
    end,

    append_name = function(picker)
      local item = picker:current()
      if not item then
        return
      end
      if self:append_at_cursor(item.name) then
        self:notify("Appended environment name", vim.log.levels.INFO)
        picker:close()
      end
    end,

    edit_var = function(picker)
      local item = picker:current()
      if not item then
        return
      end
      if self:edit_environment_var(item.name, item.value) then
        self:notify(string.format("Editing environment variable '%s'", item.name), vim.log.levels.INFO)
        picker:close()
      end
    end,
  }
end

---Create keymap configuration for snacks picker
---@return table<string, table>
function SnacksPicker:create_keymaps()
  local function create_keymap(action)
    return { action, mode = { "i", "n" }, remap = true }
  end

  local keymaps = {}
  for action, key in pairs(self._config.keys) do
    keymaps[key] = create_keymap(action)
  end
  return keymaps
end

---Create picker items from environment variables
---@return table[], integer
function SnacksPicker:create_picker_items()
  local data = require("ecolog.integrations.pickers.data")
  local items = data.format_env_vars_for_picker(self:get_name():lower())

  local filtered_items = {}
  for _, item in ipairs(items) do
    if item.value == nil then
      item.value = ""
    end
    if item.masked_value == nil then
      item.masked_value = ""
    end
    item.text = item.name .. " " .. (item.masked_value or "")
    table.insert(filtered_items, item)
  end

  local longest_name = 0
  for _, item in ipairs(filtered_items) do
    longest_name = math.max(longest_name, #item.name)
  end

  return filtered_items, longest_name
end

---Open environment variables picker
function SnacksPicker:open()
  local has_snacks, snacks = pcall(require, "snacks.picker")
  if not has_snacks then
    vim.notify("This extension requires snacks.nvim (https://github.com/folke/snacks.nvim)", vim.log.levels.ERROR)
    return
  end

  if not self._initialized then
    self:setup({})
    self._initialized = true
  end

  self:save_current_window()

  local items, longest = self:create_picker_items()

  snacks.pick({
    title = "Environment Variables",
    items = items,
    layout = self._config.layout,
    sort = {
      fields = { "score:desc", "idx" },
    },
    format = function(item)
      local ret = {}
      ret[#ret + 1] = { ("%-" .. longest .. "s"):format(item.name), "@variable" }
      ret[#ret + 1] = { " " }
      ret[#ret + 1] = { item.masked_value or "", "@string" }
      return ret
    end,
    win = {
      input = {
        keys = self:create_keymaps(),
      },
    },
    confirm = function(picker, item)
      if not item then
        return
      end

      if self:append_at_cursor(item.name) then
        self:notify("Appended environment name", vim.log.levels.INFO)
        picker:close()
      end
    end,
    actions = self:create_picker_actions(),
  })
end

---Setup snacks integration
---@param opts? table
function SnacksPicker:setup(opts)
  BasePicker.setup(self, opts)
  self.snacks = function()
    self:open()
  end

  api.nvim_create_user_command("EcologSnacks", function()
    self:open()
  end, {
    desc = "Open environment variables picker using snacks.nvim",
  })
end

local instance = SnacksPicker:new()

local M = {
  setup = function(opts)
    instance:setup(opts)
  end,
  env_picker = function()
    instance:open()
  end,
  snacks = function()
    instance:open()
  end,
}

return M
