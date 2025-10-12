local M = {}

local api = vim.api
local state = require("ecolog.shelter.state")
local shelter_utils = require("ecolog.shelter.utils")
local buffer_utils = require("ecolog.shelter.buffer")
local LRUCache = require("ecolog.shelter.lru_cache")

local namespace = api.nvim_create_namespace("ecolog_shelter")
local processed_buffers = LRUCache.new(100)

---Process buffer with optimized masking engine
---@param bufnr number Buffer number
---@param lines string[] Lines to process
---@param content_hash string Content hash
---@param filename string Filename
---@param on_complete? function Optional callback when processing is complete
local function process_buffer_with_masking(bufnr, lines, content_hash, filename, on_complete)
  if not api.nvim_buf_is_valid(bufnr) then
    return
  end

  local state_config = state.get_config()
  local skip_comments = state_config.skip_comments or false

  -- Build config with all necessary masking parameters
  local config = {
    partial_mode = state_config.partial_mode,
    highlight_group = state_config.highlight_group,
    mask_length = state_config.mask_length,
    mask_char = state_config.mask_char,
  }

  -- Use the optimized masking engine
  local masking_engine = require("ecolog.shelter.masking_engine")
  masking_engine.process_buffer_optimized(bufnr, lines, config, filename, namespace, skip_comments)

  -- Complete processing
  if on_complete then
    on_complete(content_hash)
  else
    processed_buffers:put(bufnr, content_hash)
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
---@param from_setup boolean? Whether this is called from setup_preview_buffer
function M.reset_buffer_settings(bufnr, force, from_setup)
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

  local original_settings = {}
  ok, val = pcall(api.nvim_buf_get_var, bufnr, "ecolog_original_settings")
  if ok and val then
    original_settings = val
  end

  local wrap_setting = original_settings.wrap
  if from_setup then
    local config = require("ecolog").get_config and require("ecolog").get_config() or {}
    wrap_setting = config.default_wrap ~= nil and config.default_wrap or vim.o.wrap
  else
    wrap_setting = wrap_setting or vim.o.wrap
  end

  local conceallevel_setting = original_settings.conceallevel or vim.o.conceallevel
  local concealcursor_setting = original_settings.concealcursor or vim.o.concealcursor

  for _, winid in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(winid) == bufnr then
      pcall(api.nvim_win_set_option, winid, "wrap", wrap_setting)
      pcall(api.nvim_win_set_option, winid, "conceallevel", conceallevel_setting)
      pcall(api.nvim_win_set_option, winid, "concealcursor", concealcursor_setting)
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
    local original_settings = {}

    for _, winid in ipairs(api.nvim_list_wins()) do
      if api.nvim_win_get_buf(winid) == bufnr then
        original_settings.wrap = vim.wo[winid].wrap
        original_settings.conceallevel = vim.wo[winid].conceallevel
        original_settings.concealcursor = vim.wo[winid].concealcursor
        break
      end
    end

    pcall(api.nvim_buf_set_var, bufnr, "ecolog_original_settings", original_settings)

    for _, winid in ipairs(api.nvim_list_wins()) do
      if api.nvim_win_get_buf(winid) == bufnr then
        pcall(api.nvim_win_set_option, winid, "wrap", false)
        pcall(api.nvim_win_set_option, winid, "conceallevel", 2)
        pcall(api.nvim_win_set_option, winid, "concealcursor", "nvic")
        break
      end
    end

    pcall(api.nvim_buf_set_var, bufnr, "ecolog_env_settings", true)
  else
    M.reset_buffer_settings(bufnr, nil, true)
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
  process_buffer_with_masking(bufnr, lines, content_hash, filename, on_complete)
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
