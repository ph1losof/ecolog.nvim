local M = {}

local api = vim.api
local state = require("ecolog.shelter.state")
local shelter_utils = require("ecolog.shelter.utils")
local buffer_utils = require("ecolog.shelter.buffer")
local LRUCache = require("ecolog.shelter.lru_cache")

local namespace = api.nvim_create_namespace("ecolog_shelter")
local processed_buffers = LRUCache.new(100)

---Process a chunk of lines and create extmarks for them
---@param bufnr number Buffer number
---@param lines string[] Lines to process
---@param start_idx number Start index
---@param end_idx number End index
---@param content_hash string Content hash
---@param filename string Filename
---@param on_complete? function Optional callback when processing is complete
local function process_buffer_chunk(bufnr, lines, start_idx, end_idx, content_hash, filename, on_complete)
  if not api.nvim_buf_is_valid(bufnr) then
    return
  end

  end_idx = math.min(end_idx, #lines)
  local chunk_extmarks = {}
  local config = state.get_config()
  local skip_comments = state.get_buffer_state().skip_comments

  for i = start_idx, end_idx do
    local line = lines[i]
    local processed_items = buffer_utils.process_line(line)

    for _, item in ipairs(processed_items) do
      if not (skip_comments and item.is_comment) then
        local extmark = buffer_utils.create_extmark(item.value, item, config, filename, i)
        if extmark then
          table.insert(chunk_extmarks, extmark)
        end
      end
    end
  end

  if #chunk_extmarks > 0 then
    vim.schedule(function()
      for _, mark in ipairs(chunk_extmarks) do
        pcall(api.nvim_buf_set_extmark, bufnr, namespace, mark[1], mark[2], mark[3])
      end
    end)
  end

  if end_idx < #lines then
    vim.schedule(function()
      process_buffer_chunk(bufnr, lines, end_idx + 1, end_idx + 50, content_hash, filename, on_complete)
    end)
  else
    if on_complete then
      on_complete(content_hash)
    else
      processed_buffers:put(bufnr, content_hash)
    end
  end
end

---Check if a buffer needs processing based on its content hash
---@param bufnr number Buffer number
---@param content_hash string Content hash
---@param cache table? Optional cache table to use instead of global cache
---@return boolean needs_processing
function M.needs_processing(bufnr, content_hash, cache)
  local cache_to_use = cache or processed_buffers
  local cached = cache_to_use:get(bufnr)

  if type(cached) == "table" then
    return not cached.hash or cached.hash ~= content_hash
  end

  return not cached or cached ~= content_hash
end

---Reset buffer settings to user's preferences for non-env files
---@param bufnr number Buffer number
---@param force boolean? Force reset even if buffer wasn't modified
function M.reset_buffer_settings(bufnr, force)
  if not api.nvim_buf_is_valid(bufnr) then
    return
  end

  local has_env_settings = false
  local ok, val = pcall(api.nvim_buf_get_var, bufnr, "ecolog_env_settings")
  if ok and val then
    has_env_settings = true
  end

  if not has_env_settings and not force then
    return
  end

  pcall(api.nvim_buf_set_option, bufnr, "wrap", vim.o.wrap)
  pcall(api.nvim_buf_set_option, bufnr, "conceallevel", vim.o.conceallevel)
  pcall(api.nvim_win_set_option, bufnr, "concealcursor", vim.o.concealcursor)

  for _, winid in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(winid) == bufnr then
      pcall(api.nvim_win_set_option, winid, "wrap", vim.o.wrap)
      pcall(api.nvim_win_set_option, winid, "conceallevel", vim.o.conceallevel)
      pcall(api.nvim_win_set_option, winid, "concealcursor", vim.o.concealcursor)
      break
    end
  end

  pcall(api.nvim_buf_set_var, bufnr, "ecolog_env_settings", false)
end

---@param bufnr number
---@param filename string? Optional filename to check if it's an env file
function M.setup_preview_buffer(bufnr, filename)
  if not filename then
    return
  end

  local config = require("ecolog").get_config and require("ecolog").get_config() or {}
  local is_env_file = shelter_utils.match_env_file(filename, config)

  if is_env_file then
    pcall(api.nvim_buf_set_option, bufnr, "conceallevel", 2)
    pcall(api.nvim_buf_set_option, bufnr, "wrap", false)

    for _, winid in ipairs(api.nvim_list_wins()) do
      if api.nvim_win_get_buf(winid) == bufnr then
        pcall(api.nvim_win_set_option, winid, "conceallevel", 2)
        pcall(api.nvim_win_set_option, winid, "concealcursor", "nvic")
        break
      end
    end

    pcall(api.nvim_buf_set_var, bufnr, "ecolog_env_settings", true)
  else
    M.reset_buffer_settings(bufnr)
  end
end

---Process a buffer and apply masking
---@param bufnr number Buffer number
---@param source_filename string? Source filename
---@param cache table? Optional cache table to use instead of global cache
---@param on_complete? function Optional callback when processing is complete
function M.process_buffer(bufnr, source_filename, cache, on_complete)
  if not bufnr or not api.nvim_buf_is_valid(bufnr) then
    return
  end

  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local content_hash = vim.fn.sha256(table.concat(lines, "\n"))
  local filename = source_filename or vim.fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":t")

  pcall(api.nvim_buf_clear_namespace, bufnr, namespace, 0, -1)
  pcall(api.nvim_buf_set_var, bufnr, "ecolog_masked", true)

  M.setup_preview_buffer(bufnr, filename)
  process_buffer_chunk(bufnr, lines, 1, 50, content_hash, filename, on_complete)
end

---@param bufnr number
---@param filename string
---@param integration_name string
function M.mask_preview_buffer(bufnr, filename, integration_name)
  if not bufnr or not api.nvim_buf_is_valid(bufnr) then
    return
  end

  local config = require("ecolog").get_config and require("ecolog").get_config() or {}
  local is_env_file = shelter_utils.match_env_file(filename, config)

  if not (is_env_file and state.is_enabled(integration_name .. "_previewer")) then
    return
  end

  M.process_buffer(bufnr, filename)
end

return M
