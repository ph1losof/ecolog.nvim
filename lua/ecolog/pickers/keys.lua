---@class EcologPickerKeys
---Unified keymap handling for all picker backends
local M = {}

local config = require("ecolog.config")

---@class PickerKeyConfig
---@field copy_value string
---@field copy_name string
---@field append_value string
---@field append_name string
---@field goto_source string

---Get the configured picker keymaps
---@return PickerKeyConfig
function M.get()
  local picker_cfg = config.get_picker()
  local keys = picker_cfg.keys or {}

  return {
    copy_value = keys.copy_value or "<C-y>",
    copy_name = keys.copy_name or "<C-u>",
    append_value = keys.append_value or "<C-a>",
    append_name = keys.append_name or "<CR>",
    goto_source = keys.goto_source or "<C-g>",
  }
end

---Convert a Neovim keymap string to fzf format
---Example: "<C-y>" -> "ctrl-y", "<M-a>" -> "alt-a", "<CR>" -> "enter"
---@param key string Neovim-style keymap
---@return string fzf-style keymap
function M.to_fzf(key)
  if not key or key == "" then
    return ""
  end

  local lower = key:lower()

  -- Handle special keys
  if lower == "<cr>" or lower == "<enter>" then
    return "enter"
  elseif lower == "<tab>" then
    return "tab"
  elseif lower == "<s-tab>" then
    return "shift-tab"
  elseif lower == "<esc>" then
    return "esc"
  elseif lower == "<bs>" or lower == "<backspace>" then
    return "backspace"
  elseif lower == "<space>" then
    return "space"
  end

  -- Handle Ctrl combinations: <C-x> -> ctrl-x
  local ctrl_match = key:match("^<[cC]%-(%a)>$")
  if ctrl_match then
    return "ctrl-" .. ctrl_match:lower()
  end

  -- Handle Alt/Meta combinations: <M-x> or <A-x> -> alt-x
  local alt_match = key:match("^<[mMaA]%-(%a)>$")
  if alt_match then
    return "alt-" .. alt_match:lower()
  end

  -- Handle Shift combinations: <S-x> -> shift-x
  local shift_match = key:match("^<[sS]%-(%a)>$")
  if shift_match then
    return "shift-" .. shift_match:lower()
  end

  -- Single character or unknown format - return as-is
  return (key:lower():gsub("[<>]", ""))
end

---Get fzf-formatted keymaps
---@return table<string, string> Map of action name to fzf key
function M.get_fzf()
  local keys = M.get()
  return {
    copy_value = M.to_fzf(keys.copy_value),
    copy_name = M.to_fzf(keys.copy_name),
    append_value = M.to_fzf(keys.append_value),
    append_name = M.to_fzf(keys.append_name),
    goto_source = M.to_fzf(keys.goto_source),
  }
end

---Get snacks-formatted keymaps (same as Neovim format)
---@return PickerKeyConfig
function M.get_snacks()
  return M.get()
end

---Get telescope-formatted keymaps (same as Neovim format)
---@return PickerKeyConfig
function M.get_telescope()
  return M.get()
end

return M
