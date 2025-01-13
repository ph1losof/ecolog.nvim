local M = {}

local api = vim.api
local string_find = string.find
local string_sub = string.sub
local string_match = string.match

local state = require("ecolog.shelter.state")
local utils = require("ecolog.utils")
local shelter_utils = require("ecolog.shelter.utils")

local namespace = api.nvim_create_namespace("ecolog_shelter")

local extmarks = {}
local function clear_extmarks()
  for i = 1, #extmarks do
    extmarks[i] = nil
  end
end

local function mask_preview_buffer(bufnr, filename)
  if not bufnr or not api.nvim_buf_is_valid(bufnr) then
    return
  end

  local config = require("ecolog").get_config and require("ecolog").get_config() or {}
  local is_env_file = shelter_utils.match_env_file(filename, config)

  if not (is_env_file and state.is_enabled("telescope_previewer")) then
    return
  end

  pcall(api.nvim_buf_set_var, bufnr, "ecolog_masked", true)

  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  clear_extmarks()

  local chunk_size = 100
  for i = 1, #lines, chunk_size do
    local end_idx = math.min(i + chunk_size - 1, #lines)

    vim.schedule(function()
      for j = i, end_idx do
        local line = lines[j]
        local key, value, eq_pos = utils.parse_env_line(line)
        
        if key and value then
          local quote_char, actual_value = utils.extract_quoted_value(value)
          
          if actual_value then
            local masked_value = shelter_utils.determine_masked_value(actual_value, {
              partial_mode = state.get_config().partial_mode,
              key = key,
            })

            if masked_value and #masked_value > 0 then
              if quote_char then
                masked_value = quote_char .. masked_value .. quote_char
              end

              table.insert(extmarks, {
                j - 1,
                eq_pos,
                {
                  virt_text = { { masked_value, state.get_config().highlight_group } },
                  virt_text_pos = "overlay",
                  hl_mode = "combine",
                },
              })
            end
          end
        end
      end

      if #extmarks > 0 then
        for _, mark in ipairs(extmarks) do
          api.nvim_buf_set_extmark(bufnr, namespace, mark[1], mark[2], mark[3])
        end
        clear_extmarks()
      end
    end)
  end
end

function M.setup_telescope_shelter()
  local previewers = require("telescope.previewers")
  local from_entry = require("telescope.from_entry")
  local conf = require("telescope.config").values

  -- Create a masked file previewer
  local masked_file_previewer = function(opts)
    opts = opts or {}

    return previewers.new_buffer_previewer({
      title = opts.title or "File Preview",

      get_buffer_by_name = function(_, entry)
        return from_entry.path(entry, false)
      end,

      define_preview = function(self, entry, status)
        local p = from_entry.path(entry, false)
        if not p or p == "" then
          return
        end

        conf.buffer_previewer_maker(p, self.state.bufnr, {
          bufname = self.state.bufname,
          callback = function(bufnr)
            local filename = vim.fn.fnamemodify(p, ":t")
            mask_preview_buffer(bufnr, filename)
          end,
        })
      end,
    })
  end

  -- Create a masked grep previewer
  local masked_grep_previewer = function(opts)
    opts = opts or {}
    
    return previewers.new_buffer_previewer({
      title = opts.title or "Preview",
      
      get_buffer_by_name = function(_, entry)
        return entry.filename
      end,

      define_preview = function(self, entry, status)
        if not entry then
          return
        end

        local filename = entry.filename
        if not filename then
          return
        end

        conf.buffer_previewer_maker(filename, self.state.bufnr, {
          bufname = self.state.bufname,
          callback = function(bufnr)
            -- Apply masking first
            mask_preview_buffer(bufnr, vim.fn.fnamemodify(filename, ":t"))

            -- Set cursor position after ensuring buffer has content
            vim.schedule(function()
              if entry.lnum and api.nvim_buf_is_valid(bufnr) then
                local line_count = api.nvim_buf_line_count(bufnr)
                if entry.lnum <= line_count then
                  -- Use the preview window instead of current window
                  pcall(api.nvim_win_set_cursor, self.state.winid, { entry.lnum, entry.col or 0 })
                  -- Center the view in the preview window
                  api.nvim_win_call(self.state.winid, function()
                    vim.cmd("normal! zz")
                  end)
                end
              end
            end)
          end,
        })
      end,
    })
  end

  if not state._original_file_previewer then
    state._original_file_previewer = conf.file_previewer
  end

  if not state._original_grep_previewer then
    state._original_grep_previewer = conf.grep_previewer
  end

  if state.is_enabled("telescope_previewer") then
    conf.file_previewer = masked_file_previewer
    conf.grep_previewer = masked_grep_previewer
  else
    conf.file_previewer = state._original_file_previewer
    conf.grep_previewer = state._original_grep_previewer
  end
end

return M 