local M = {}

local api = vim.api

local state = require("ecolog.shelter.state")
local utils = require("ecolog.utils")
local shelter_utils = require("ecolog.shelter.utils")
local lru_cache = require("ecolog.shelter.lru_cache")

local namespace = api.nvim_create_namespace("ecolog_shelter")

-- Initialize LRU cache with capacity of 100 buffers
local processed_buffers = lru_cache.new(100)

local function get_masked_value(value, key, filename)
  if not value then
    return ""
  end

  local quote_char = value:match("^([\"'])")
  local actual_value = quote_char and value:match("^" .. quote_char .. "(.-)" .. quote_char) or value

  if not actual_value then
    return value
  end

  local masked = shelter_utils.determine_masked_value(actual_value, {
    partial_mode = state.get_config().partial_mode,
    key = key,
    source = filename,
  })

  if quote_char then
    return quote_char .. masked .. quote_char
  end
  return masked
end

local function process_buffer_chunk(bufnr, lines, start_idx, end_idx, content_hash, filename)
  local chunk_extmarks = {}

  for i = start_idx, math.min(end_idx, #lines) do
    local line = lines[i]
    local key, value, eq_pos = utils.parse_env_line(line)

    if key and value then
      local masked_value = get_masked_value(value, key, filename)
      local quote_char = value:match("^([\"'])")
      local actual_value = quote_char and value:match("^" .. quote_char .. "(.-)" .. quote_char) or value

      if masked_value and #masked_value > 0 then
        table.insert(chunk_extmarks, {
          i - 1,
          eq_pos,
          {
            virt_text = { { masked_value, masked_value == value and "String" or state.get_config().highlight_group } },
            virt_text_pos = "overlay",
            hl_mode = "combine",
          },
        })
      end
    end
  end

  if #chunk_extmarks > 0 then
    vim.schedule(function()
      for _, mark in ipairs(chunk_extmarks) do
        pcall(vim.api.nvim_buf_set_extmark, bufnr, namespace, mark[1], mark[2], mark[3])
      end
    end)
  end

  -- Process next chunk if needed
  if end_idx < #lines then
    vim.schedule(function()
      process_buffer_chunk(bufnr, lines, end_idx + 1, end_idx + 50, content_hash, filename)
    end)
  else
    processed_buffers:put(bufnr, {
      hash = content_hash,
      timestamp = vim.loop.now(),
    })
  end
end

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
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
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

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local content_hash = vim.fn.sha256(table.concat(lines, "\n"))

    local cached = processed_buffers:get(bufnr)
    if cached and cached.hash == content_hash then
      return
    end

    -- Start processing in chunks of 50 lines
    process_buffer_chunk(bufnr, lines, 1, 50, content_hash, filename)
  end
end

return M

