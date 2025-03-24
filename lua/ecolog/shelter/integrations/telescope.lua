local M = {}

local api = vim.api
local state = require("ecolog.shelter.state")
local previewer_utils = require("ecolog.shelter.previewer_utils")
local shelter_utils = require("ecolog.shelter.utils")

function M.create_masked_previewer(opts, preview_type)
  if not state.is_enabled("telescope_previewer") then
    local original_previewer = preview_type == "file" and state._original_file_previewer
      or state._original_grep_previewer
    if not original_previewer then
      return nil
    end
    return original_previewer(opts)
  end

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

          local filename = vim.fn.fnamemodify(path, ":t")
          local config = require("ecolog").get_config and require("ecolog").get_config() or {}
          if shelter_utils.match_env_file(filename, config) then
            previewer_utils.mask_preview_buffer(bufnr, filename, "telescope")
          else
            previewer_utils.reset_buffer_settings(bufnr)
          end
        end,
      })
    end,
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
      return M.create_masked_previewer(opts, "file")
    end
    conf.grep_previewer = function(opts)
      return M.create_masked_previewer(opts, "grep")
    end
  else
    conf.file_previewer = state._original_file_previewer
    conf.grep_previewer = state._original_grep_previewer
  end
end

return M
