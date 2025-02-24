local M = {}

local api = vim.api

local state = require("ecolog.shelter.state")
local utils = require("ecolog.utils")
local shelter_utils = require("ecolog.shelter.utils")
local previewer_utils = require("ecolog.shelter.previewer_utils")
local lru_cache = require("ecolog.shelter.lru_cache")

local processed_buffers = lru_cache.new(100)

function M.setup_fzf_shelter()
  if not state.is_enabled("fzf_previewer") then
    return
  end

  local ok = pcall(require, "fzf-lua")
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
    if not bufnr or not api.nvim_buf_is_valid(bufnr) then
      return
    end

    local filename = entry.path or entry.filename or entry.name
    if not filename then
      return
    end

    local config = require("ecolog").get_config and require("ecolog").get_config() or {}
    local is_env_file = shelter_utils.match_env_file(filename, config)

    if not (is_env_file and state.is_enabled("fzf_previewer")) then
      return
    end

    previewer_utils.setup_preview_buffer(bufnr)

    local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local content_hash = vim.fn.sha256(table.concat(lines, "\n"))

    if not previewer_utils.needs_processing(bufnr, content_hash, processed_buffers) then
      return
    end

    previewer_utils.process_buffer(bufnr, filename, processed_buffers, function(hash)
      processed_buffers:put(bufnr, {
        hash = hash,
        timestamp = vim.loop.now(),
      })
    end)
  end
end

return M
