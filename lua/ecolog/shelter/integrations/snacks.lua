local M = {}

local api = vim.api
local NotificationManager = require("ecolog.core.notification_manager")
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
  else
    previewer_utils.reset_buffer_settings(ctx.buf)
  end
end

function M.setup_snacks_shelter()
  if not state.is_enabled("snacks_previewer") then
    return
  end

  local ok, preview = pcall(require, "snacks.picker.preview")
  if not ok then
    NotificationManager.warn("snacks.picker module not found. Snacks integration will be disabled.")
    return
  end

  if not state._original_snacks_preview then
    state._original_snacks_preview = preview.file
  end

  preview.file = function(ctx)
    -- Check if this is an env file and modify preview config before calling original
    local filename = ctx.item and ctx.item.file and vim.fn.fnamemodify(ctx.item.file, ":t")
    local config = require("ecolog").get_config and require("ecolog").get_config() or {}
    
    if filename and shelter_utils.match_env_file(filename, config) then
      -- Temporarily store original config and modify it for env files
      local original_max_line_length = ctx.picker and ctx.picker.opts 
        and ctx.picker.opts.previewers 
        and ctx.picker.opts.previewers.file 
        and ctx.picker.opts.previewers.file.max_line_length
      
      -- Modify the picker context to disable truncation
      if ctx.picker then
        ctx.picker.opts = ctx.picker.opts or {}
        ctx.picker.opts.previewers = ctx.picker.opts.previewers or {}
        ctx.picker.opts.previewers.file = ctx.picker.opts.previewers.file or {}
        ctx.picker.opts.previewers.file.max_line_length = 999999
      end
      
      -- Call original preview function
      state._original_snacks_preview(ctx)
      custom_file_previewer(ctx)
      
      -- Restore original configuration
      if ctx.picker and ctx.picker.opts and ctx.picker.opts.previewers and ctx.picker.opts.previewers.file then
        if original_max_line_length ~= nil then
          ctx.picker.opts.previewers.file.max_line_length = original_max_line_length
        else
          ctx.picker.opts.previewers.file.max_line_length = nil
        end
      end
    else
      state._original_snacks_preview(ctx)
      custom_file_previewer(ctx)
    end
  end
end

return M
