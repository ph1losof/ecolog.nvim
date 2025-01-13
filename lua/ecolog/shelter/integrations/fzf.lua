local M = {}

local api = vim.api
local string_find = string.find
local string_sub = string.sub
local string_match = string.match

local state = require("ecolog.shelter.state")
local utils = require("ecolog.utils")
local shelter_utils = require("ecolog.shelter.utils")

local namespace = api.nvim_create_namespace("ecolog_shelter")

local processed_buffers = {}

function M.setup_fzf_shelter()
  if not state.is_enabled("fzf_previewer") then
    return
  end

  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    return
  end

  local builtin = require("fzf-lua.previewer.builtin")
  local buffer_or_file = builtin.buffer_or_file

  local orig_preview_buf_post = buffer_or_file.preview_buf_post

  buffer_or_file.preview_buf_post = function(self, entry, min_winopts)
    if orig_preview_buf_post then
      orig_preview_buf_post(self, entry, min_winopts)
    end

    local bufnr = self.preview_bufnr
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end

    local filename = entry and (entry.path or entry.filename or entry.name)
    if not filename then
      return
    end
    filename = vim.fn.fnamemodify(filename, ":t")

    local config = require("ecolog").get_config and require("ecolog").get_config() or {}
    local is_env_file = shelter_utils.match_env_file(filename, config)

    if not (is_env_file and state.is_enabled("fzf_previewer")) then
      return
    end

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local content_hash = vim.fn.sha256(table.concat(lines, "\n"))

    if processed_buffers[bufnr] and processed_buffers[bufnr].hash == content_hash then
      return
    end

    local all_extmarks = {}

    for i, line in ipairs(lines) do
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

            table.insert(all_extmarks, {
              i - 1,
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

    if #all_extmarks > 0 then
      vim.schedule(function()
        for _, mark in ipairs(all_extmarks) do
          pcall(vim.api.nvim_buf_set_extmark, bufnr, namespace, mark[1], mark[2], mark[3])
        end
      end)
    end

    processed_buffers[bufnr] = {
      hash = content_hash,
      timestamp = vim.loop.now(),
    }

    if vim.tbl_count(processed_buffers) > 100 then
      local current_time = vim.loop.now()
      for buf, info in pairs(processed_buffers) do
        if current_time - info.timestamp > 300000 then
          processed_buffers[buf] = nil
        end
      end
    end
  end
end

return M 