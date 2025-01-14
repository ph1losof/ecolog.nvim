local M = {}
local utils = require("ecolog.utils")
local shelter = utils.get_module("ecolog.shelter")
local fn = vim.fn

-- Default configuration
local config = {
    hidden_mode = false,
}

-- Cache for performance
local status_cache = {
  last_update = 0,
  data = nil,
}

local function get_cached_status()
  local current_time = vim.loop.now()
  -- Update cache every 2 seconds
  if status_cache.data and (current_time - status_cache.last_update) < 1000 then
    return status_cache.data
  end

  local ecolog = require("ecolog")
  local env_vars = ecolog.get_env_vars()
  local current_file = ecolog.get_state().selected_env_file
  
  local status = {
    file = current_file and fn.fnamemodify(current_file, ":t") or "No env file",
    vars_count = vim.tbl_count(env_vars),
    shelter_active = shelter.is_enabled("files"),
    has_env_file = current_file ~= nil,
  }

  status_cache.data = status
  status_cache.last_update = current_time
  return status
end

function M.get_statusline()
  local status = get_cached_status()
  
  -- Return empty string if hidden_mode is enabled and no env file is selected
  if config.hidden_mode and not status.has_env_file then
    return ""
  end
  
  local parts = {
    "🌲", -- ecolog icon
    status.file,
    string.format("%d vars", status.vars_count),
  }
  
  if status.shelter_active then
    table.insert(parts, "🛡️") -- shelter mode indicator
  end
  
  return table.concat(parts, " ")
end

-- Lualine component
function M.lualine()
  return {
    function()
      local status = get_cached_status()
      
      -- Return empty string if hidden_mode is enabled and no env file is selected
      if config.hidden_mode and not status.has_env_file then
        return ""
      end
      
      return string.format(
        "🌲 %s (%d)%s",
        status.file,
        status.vars_count,
        status.shelter_active and " 🛡️" or ""
      )
    end,
    cond = function()
      return package.loaded["ecolog"] ~= nil
    end,
  }
end

function M.invalidate_cache()
  status_cache.data = nil
  status_cache.env_files = nil
  status_cache.last_update = 0
  status_cache.last_file_check = 0
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
end

return M 