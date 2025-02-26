local utils = require("ecolog.utils")
local shelter = utils.get_module("ecolog.shelter")
local api = vim.api
local fn = vim.fn

---@class SnacksConfig
---@field shelter { mask_on_copy: boolean }
---@field keys { copy_value: string, copy_name: string, append_value: string, append_name: string }
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
  },
  layout = {
    preset = "dropdown",
    preview = false,
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
      local value = M.config.shelter.mask_on_copy and shelter.mask_value(item.value, "snacks", nil, item.source) or item.value
      copy_to_clipboard(value, string.format("value of '%s'", item.name))
      picker:close()
    end,
    copy_name = function(picker)
      local item = picker:current()
      if not item then return end
      copy_to_clipboard(item.name, string.format("variable '%s' name", item.name))
      picker:close()
    end,
    append_value = function(picker)
      local item = picker:current()
      if not item then return end
      local value = M.config.shelter.mask_on_copy and shelter.mask_value(item.value, "snacks", nil, item.source) or item.value
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


---Create picker items from environment variables
---@return table[]
---@return integer
local function create_picker_items()
  local ecolog = require("ecolog")
  local env_vars = ecolog.get_env_vars()
  
  local items = {}
  local longest_name = 0
  
  local var_names = {}
  for name in pairs(env_vars) do
    table.insert(var_names, name)
  end
  
  local config = ecolog.get_config()
  if config.sort_var_fn and type(config.sort_var_fn) == "function" then
    table.sort(var_names, config.sort_var_fn)
  end
  
  -- Create items in our explicitly sorted order
  for idx, name in ipairs(var_names) do
    local var = env_vars[name]
    local display_value = shelter.mask_value(var.value, "snacks", name, var.source)
    table.insert(items, {
      name = name,
      text = name,
      value = var.value,
      display_value = display_value,
      source = var.source,
      original_idx = idx,
    })
    longest_name = math.max(longest_name, #name)
  end
  
  return items, longest_name
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

  local items, longuest = create_picker_items()

  snacks.pick({
    title = "Environment Variables",
    items = items,
    layout = M.config.layout,
    sort = { 
      fields = { "score:desc", "original_idx" }
    },
    format = function(item)
      local ret = {}
      ret[#ret + 1] = { ("%-" .. longuest .. "s"):format(item.name), "@variable" }
      ret[#ret + 1] = { " " }
      ret[#ret + 1] = { item.display_value or "", "@string" }
      return ret
    end,
    win = {
      input = {
        keys = create_keymaps(M.config),
      },
    },
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
