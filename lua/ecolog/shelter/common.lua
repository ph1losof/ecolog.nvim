---@class EcologShelterCommon
---Common utilities to reduce code duplication across shelter modules
local M = {}
local NotificationManager = require("ecolog.core.notification_manager")

local api = vim.api

local state, shelter_utils

local function get_state()
  if not state then
    state = require("ecolog.shelter.state")
  end
  return state
end

local function get_shelter_utils()
  if not shelter_utils then
    shelter_utils = require("ecolog.shelter.utils")
  end
  return shelter_utils
end

-- Cache API references for performance
local api_buf_is_valid = api.nvim_buf_is_valid
local api_buf_get_lines = api.nvim_buf_get_lines
local api_list_wins = api.nvim_list_wins
local api_win_get_buf = api.nvim_win_get_buf
local api_win_set_option = api.nvim_win_set_option

---Ensure buffer is valid with optional error message
---@param bufnr number Buffer number to validate
---@param error_message string? Optional error message to display
---@return boolean valid True if buffer is valid
function M.ensure_valid_buffer(bufnr, error_message)
  if not api_buf_is_valid(bufnr) then
    if error_message then
      NotificationManager.warn(error_message)
    end
    return false
  end
  return true
end

---Get ecolog config with proper fallback
---@return table config Ecolog configuration or empty table
function M.get_ecolog_config()
  local ok, ecolog = pcall(require, "ecolog")
  if not ok then
    return {}
  end
  return ecolog.get_config and ecolog.get_config() or {}
end

---Check if a file should be processed by shelter based on environment file matching
---@param filename string Filename to check
---@param feature_name string Feature name to validate (e.g., "files", "telescope_previewer")
---@return boolean should_process True if file should be processed
function M.should_process_env_file(filename, feature_name)
  if not filename or not feature_name then
    return false
  end

  local config = M.get_ecolog_config()
  local s_utils = get_shelter_utils()
  local is_env_file = s_utils.match_env_file(filename, config)
  local s = get_state()
  return is_env_file and s.is_enabled(feature_name)
end

---Get buffer content hash for caching purposes
---@param bufnr number Buffer number
---@return string? hash SHA256 hash of buffer content or nil if invalid
function M.get_buffer_content_hash(bufnr)
  if not M.ensure_valid_buffer(bufnr) then
    return nil
  end

  local lines = api_buf_get_lines(bufnr, 0, -1, false)
  return vim.fn.sha256(table.concat(lines, "\n"))
end

---Setup concealment options for all windows displaying the buffer
---@param bufnr number Buffer number
---@param conceallevel number? Conceal level (default: 2)
---@param concealcursor string? Conceal cursor modes (default: "nvic")
---@return boolean success True if at least one window was configured
function M.setup_concealment_options(bufnr, conceallevel, concealcursor)
  if not M.ensure_valid_buffer(bufnr) then
    return false
  end

  conceallevel = conceallevel or 2
  concealcursor = concealcursor or "nvic"

  local configured_count = 0

  for _, winid in ipairs(api_list_wins()) do
    if api_win_get_buf(winid) == bufnr then
      local ok1 = pcall(api_win_set_option, winid, "conceallevel", conceallevel)
      local ok2 = pcall(api_win_set_option, winid, "concealcursor", concealcursor)
      if ok1 and ok2 then
        configured_count = configured_count + 1
      end
    end
  end

  return configured_count > 0
end

---Safely call a function with pcall and return result or default value
---@param func function Function to call
---@param default any Default value to return on error
---@param ... any Arguments to pass to function
---@return any result Function result or default value
function M.safe_call(func, default, ...)
  local ok, result = pcall(func, ...)
  if ok then
    return result
  end
  return default
end

---Get buffer filename safely
---@param bufnr number Buffer number
---@return string? filename Buffer filename or nil if invalid
function M.get_buffer_filename(bufnr)
  if not M.ensure_valid_buffer(bufnr) then
    return nil
  end

  local filename = api.nvim_buf_get_name(bufnr)
  return filename ~= "" and filename or nil
end

---Check if buffer has specific option set
---@param bufnr number Buffer number
---@param option string Buffer option name
---@param expected any Expected value
---@return boolean matches True if option matches expected value
function M.buffer_option_matches(bufnr, option, expected)
  if not M.ensure_valid_buffer(bufnr) then
    return false
  end

  return M.safe_call(api.nvim_buf_get_option, nil, bufnr, option) == expected
end

---Batch update buffer options with error handling
---@param bufnr number Buffer number
---@param options table<string, any> Table of option name -> value pairs
---@return table<string, boolean> results Table of option -> success mapping
function M.set_buffer_options(bufnr, options)
  local results = {}

  if not M.ensure_valid_buffer(bufnr) then
    for option, _ in pairs(options) do
      results[option] = false
    end
    return results
  end

  for option, value in pairs(options) do
    results[option] = pcall(api.nvim_buf_set_option, bufnr, option, value)
  end

  return results
end

---Create standardized autocmd group name
---@param feature string Feature name
---@param bufnr number? Buffer number (optional)
---@param suffix string? Additional suffix (optional)
---@return string group_name Standardized autocmd group name
function M.create_autocmd_group_name(feature, bufnr, suffix)
  local parts = { "Ecolog", "Shelter", feature }

  if bufnr then
    table.insert(parts, tostring(bufnr))
  end

  if suffix then
    table.insert(parts, suffix)
  end

  return table.concat(parts, "_")
end

---Check if current environment supports a feature
---@param feature_name string Feature to check
---@return boolean supported True if feature is supported
function M.is_feature_supported(feature_name)
  -- Add any environment-specific feature checks here
  if feature_name == "telescope_previewer" then
    return pcall(require, "telescope")
  elseif feature_name == "fzf_previewer" then
    return vim.fn.executable("fzf") == 1
  elseif feature_name == "snacks_previewer" then
    return pcall(require, "snacks")
  end

  return true -- Default to supported
end

---Performance helper: pre-allocate table if table.new is available
---@param array_size number Array part size
---@param hash_size number Hash part size
---@return table table Pre-allocated table
function M.new_table(array_size, hash_size)
  if table.new then
    return table.new(array_size or 0, hash_size or 0)
  end
  return {}
end

return M

