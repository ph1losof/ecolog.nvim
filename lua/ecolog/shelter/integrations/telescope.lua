local M = {}

local api = vim.api
local state = require("ecolog.shelter.state")
local shelter_utils = require("ecolog.shelter.utils")
local previewer_utils = require("ecolog.shelter.previewer_utils")

local function create_masked_previewer(opts, preview_type)
  opts = opts or {}
  local previewers = require("telescope.previewers")
  local from_entry = require("telescope.from_entry")
  local conf = require("telescope.config").values

  return previewers.new_buffer_previewer({
    title = opts.title or (preview_type == "file" and "File Preview" or "Preview"),

    get_buffer_by_name = function(_, entry)
      return preview_type == "file" and from_entry.path(entry, false) or entry.filename
    end,

    define_preview = function(self, entry, status)
      if not entry then
        return
      end

      local path = preview_type == "file" and from_entry.path(entry, false) or entry.filename
      if not path or path == "" then
        return
      end

      conf.buffer_previewer_maker(path, self.state.bufnr, {
        bufname = self.state.bufname,
        callback = function(bufnr)
          if preview_type == "grep" and entry.lnum then
            vim.schedule(function()
              if api.nvim_buf_is_valid(bufnr) then
                local line_count = api.nvim_buf_line_count(bufnr)
                if entry.lnum <= line_count then
                  pcall(api.nvim_win_set_cursor, self.state.winid, { entry.lnum, entry.col or 0 })
                  api.nvim_win_call(self.state.winid, function()
                    vim.cmd("normal! zz")
                  end)
                end
              end
            end)
          end

          previewer_utils.mask_preview_buffer(bufnr, vim.fn.fnamemodify(path, ":t"), "telescope")
        end,
      })
    end,
  })
end

local function get_masked_value(value, key)
  if not value then
    return ""
  end

  return shelter_utils.determine_masked_value(value, {
    partial_mode = state.get_config().partial_mode,
    key = key,
    source = key and state.get_env_vars()[key] and state.get_env_vars()[key].source,
  })
end

function M.setup_telescope_shelter()
  local conf = require("telescope.config").values

  if not state._original_file_previewer then
    state._original_file_previewer = conf.file_previewer
  end
  if not state._original_grep_previewer then
    state._original_grep_previewer = conf.grep_previewer
  end

  if state.is_enabled("telescope_previewer") then
    conf.file_previewer = function(opts)
      return create_masked_previewer(opts, "file")
    end
    conf.grep_previewer = function(opts)
      return create_masked_previewer(opts, "grep")
    end
  else
    conf.file_previewer = state._original_file_previewer
    conf.grep_previewer = state._original_grep_previewer
  end
end

return M

