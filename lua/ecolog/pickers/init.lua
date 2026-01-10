---@class EcologPickers
---Picker abstraction layer
local M = {}

local config = require("ecolog.config")
local notify = require("ecolog.notification_manager")

---Detect available picker backend
---@return "telescope"|"fzf"|"snacks"|nil
function M.detect_backend()
  local cfg = config.get_picker()

  -- Respect user preference
  if cfg.backend then
    return cfg.backend
  end

  -- Auto-detect
  local has_telescope = pcall(require, "telescope")
  if has_telescope then
    return "telescope"
  end

  local has_fzf = pcall(require, "fzf-lua")
  if has_fzf then
    return "fzf"
  end

  local has_snacks = pcall(require, "snacks.picker")
  if has_snacks then
    return "snacks"
  end

  return nil
end

---Open variable picker
---@param opts? { on_select?: fun(var: EcologVariable) }
function M.pick_variables(opts)
  opts = opts or {}
  local backend = M.detect_backend()

  if not backend then
    notify.error("No picker backend available (telescope, fzf-lua, or snacks)")
    return
  end

  local picker = require("ecolog.pickers." .. backend)
  picker.pick_variables(opts)
end

---Open file picker
---@param opts? { on_select?: fun(files: string[]), multi?: boolean }
function M.pick_files(opts)
  opts = opts or {}
  local backend = M.detect_backend()

  if not backend then
    notify.error("No picker backend available")
    return
  end

  local picker = require("ecolog.pickers." .. backend)
  picker.pick_files(opts)
end

---Open picker for active files (used by :Ecolog open when multiple active files)
---@param files string[] List of active files to choose from
function M.pick_active_files(files)
  local backend = M.detect_backend()

  if not backend then
    notify.error("No picker backend available")
    return
  end

  local picker = require("ecolog.pickers." .. backend)
  if picker.pick_active_files then
    picker.pick_active_files(files)
  else
    -- Fallback: just open the first one
    if files[1] then
      vim.cmd.edit(files[1])
    end
  end
end

---Open source picker (toggle Shell/File/Remote sources)
---@param opts? { on_select?: fun(sources: string[]) }
function M.pick_sources(opts)
  opts = opts or {}
  local backend = M.detect_backend()

  if not backend then
    notify.error("No picker backend available")
    return
  end

  local picker = require("ecolog.pickers." .. backend)
  if picker.pick_sources then
    picker.pick_sources(opts)
  else
    notify.warn("Source picker not implemented for " .. backend)
  end
end

return M
