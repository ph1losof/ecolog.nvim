local M = {}

local state = require("ecolog.shelter.state")
local previewer_utils = require("ecolog.shelter.previewer_utils")
local shelter_utils = require("ecolog.shelter.utils")

---@param ctx snacks.picker.preview.ctx
local function custom_file_previewer(ctx)
  if not ctx.item.file then
    return
  end

  local filename = vim.fn.fnamemodify(ctx.item.file, ":t")
  local config = require("ecolog").get_config and require("ecolog").get_config() or {}
  if shelter_utils.match_env_file(filename, config) then
    previewer_utils.mask_preview_buffer(ctx.buf, filename, "snacks")
  end
end

function M.setup_snacks_shelter()
  if not state.is_enabled("snacks_previewer") then
    return
  end

  local ok, preview = pcall(require, "snacks.picker.preview")
  if not ok then
    vim.notify("snacks.picker module not found. Snacks integration will be disabled.", vim.log.levels.WARN)
    return
  end

  if not state._original_snacks_preview then
    state._original_snacks_preview = preview.file
  end

  preview.file = function(ctx)
    state._original_snacks_preview(ctx)
    custom_file_previewer(ctx)
  end
end

return M
