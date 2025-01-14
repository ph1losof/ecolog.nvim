local M = {}
local utils = require("ecolog.utils")
local shelter = utils.get_module("ecolog.shelter")
local fn = vim.fn

local config = {
  hidden_mode = false,
}

local status_cache = {
  last_update = 0,
  data = nil,
  env_vars_count = 0,
  shelter_active = false,
}

local _ecolog = nil
local function get_ecolog()
  if not _ecolog then
    _ecolog = require("ecolog")
  end
  return _ecolog
end

local function get_cached_status()
  local current_time = vim.loop.now()
  if status_cache.data and (current_time - status_cache.last_update) < 1000 then
    return status_cache.data
  end

  local ecolog = get_ecolog()
  local env_vars = ecolog.get_env_vars()
  local current_file = ecolog.get_state().selected_env_file

  status_cache.env_vars_count = vim.tbl_count(env_vars)
  status_cache.shelter_active = shelter.is_enabled("files")

  local status = {
    file = current_file and fn.fnamemodify(current_file, ":t") or "No env file",
    vars_count = status_cache.env_vars_count,
    shelter_active = status_cache.shelter_active,
    has_env_file = current_file ~= nil,
  }

  status_cache.data = status
  status_cache.last_update = current_time
  return status
end

local ECOLOG_ICON = "🌲"
local SHELTER_ICON = "🛡️"

function M.get_statusline()
  local status = get_cached_status()

  if config.hidden_mode and not status.has_env_file then
    return ""
  end

  local parts = {
    ECOLOG_ICON,
    status.file,
    string.format("%d vars", status.vars_count),
  }

  if status.shelter_active then
    table.insert(parts, SHELTER_ICON)
  end

  return table.concat(parts, " ")
end

function M.lualine()
  return {
    function()
      local status = get_cached_status()

      if config.hidden_mode and not status.has_env_file then
        return ""
      end

      return string.format(
        "%s %s (%d)%s",
        ECOLOG_ICON,
        status.file,
        status.vars_count,
        status.shelter_active and " " .. SHELTER_ICON or ""
      )
    end,
    cond = function()
      if _ecolog then
        return true
      end
      return package.loaded["ecolog"] ~= nil
    end,
  }
end

function M.invalidate_cache()
  status_cache.data = nil
  status_cache.env_files = nil
  status_cache.last_update = 0
  status_cache.last_file_check = 0
  status_cache.env_vars_count = 0
  status_cache.shelter_active = false
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
end

return M

