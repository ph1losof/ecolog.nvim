local M = {}
local utils = require("ecolog.utils")
local shelter = utils.get_module("ecolog.shelter")
local fn = vim.fn

local config = {
  hidden_mode = false,
  icons = {
    enabled = true,
    env = "🌲",
    shelter = "🛡️",
  },
  format = {
    env_file = function(name)
      return name
    end,
    vars_count = function(count)
      return string.format("%d vars", count)
    end,
  },
  highlights = {
    enabled = true,
    env_file = "EcologStatusFile",
    vars_count = "EcologStatusCount",
    icons = "EcologStatusIcons",
  },
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

local function is_hex_color(str)
  return type(str) == "string" and str:match("^#%x%x%x%x%x%x$")
end

local function get_icon_highlight(is_shelter)
  local icon_hl = config.highlights.icons

  if type(icon_hl) == "table" then
    return is_shelter and icon_hl.shelter or icon_hl.env
  end

  return icon_hl
end

local function setup_highlights()
  if not config.highlights.enabled then
    return
  end

  if not is_hex_color(config.highlights.env_file) then
    vim.api.nvim_set_hl(0, "EcologStatusFile", { link = "Directory" })
  end

  if not is_hex_color(config.highlights.vars_count) then
    vim.api.nvim_set_hl(0, "EcologStatusCount", { link = "Number" })
  end

  local icon_hl = config.highlights.icons

  if type(icon_hl) == "table" then
    if not is_hex_color(icon_hl.env) then
      vim.api.nvim_set_hl(0, "EcologStatusIconsEnv", { link = icon_hl.env or "Special" })
    else
      vim.api.nvim_set_hl(0, "EcologStatusIconsEnvHex", { fg = icon_hl.env })
    end

    if not is_hex_color(icon_hl.shelter) then
      vim.api.nvim_set_hl(0, "EcologStatusIconsShelter", { link = icon_hl.shelter or "WarningMsg" })
    else
      vim.api.nvim_set_hl(0, "EcologStatusIconsShelterHex", { fg = icon_hl.shelter })
    end
  else
    if not is_hex_color(icon_hl) then
      vim.api.nvim_set_hl(0, "EcologStatusIcons", { link = "Special" })
    else
      vim.api.nvim_set_hl(0, "EcologStatusIconsHex", { fg = icon_hl })
    end
  end

  if is_hex_color(config.highlights.env_file) then
    vim.api.nvim_set_hl(0, "EcologStatusFileHex", { fg = config.highlights.env_file })
  end

  if is_hex_color(config.highlights.vars_count) then
    vim.api.nvim_set_hl(0, "EcologStatusCountHex", { fg = config.highlights.vars_count })
  end
end

local function format_with_hl(text, hl_spec)
  if not config.highlights.enabled then
    return text
  end

  local hl_group = hl_spec
  
  if hl_spec == config.highlights.env_file then
    hl_group = is_hex_color(hl_spec) and "EcologStatusFileHex" or "EcologStatusFile"
  elseif hl_spec == config.highlights.vars_count then
    hl_group = is_hex_color(hl_spec) and "EcologStatusCountHex" or "EcologStatusCount"
  elseif type(config.highlights.icons) == "table" then
    if hl_spec == config.highlights.icons.env then
      hl_group = is_hex_color(hl_spec) and "EcologStatusIconsEnvHex" or "EcologStatusIconsEnv"
    elseif hl_spec == config.highlights.icons.shelter then
      hl_group = is_hex_color(hl_spec) and "EcologStatusIconsShelterHex" or "EcologStatusIconsShelter"
    end
  elseif hl_spec == config.highlights.icons then
    hl_group = is_hex_color(hl_spec) and "EcologStatusIconsHex" or "EcologStatusIcons"
  end

  return string.format("%%#%s#%s%%*", hl_group, text)
end

function M.get_statusline()
  local status = get_cached_status()
  if config.hidden_mode and not status.has_env_file then
    return ""
  end

  local parts = {}
  if config.icons.enabled then
    local icon = status.shelter_active and config.icons.shelter or config.icons.env
    local icon_hl = get_icon_highlight(status.shelter_active)
    table.insert(parts, format_with_hl(icon, icon_hl))
  end

  table.insert(parts, format_with_hl(config.format.env_file(status.file), config.highlights.env_file))
  table.insert(parts, format_with_hl(config.format.vars_count(status.vars_count), config.highlights.vars_count))

  return table.concat(parts, " ")
end

function M.lualine()
  return {
    function()
      local status = get_cached_status()
      if config.hidden_mode and not status.has_env_file then
        return ""
      end

      local parts = {}
      if config.icons.enabled then
        local icon = status.shelter_active and config.icons.shelter or config.icons.env
        local icon_hl = get_icon_highlight(status.shelter_active)
        table.insert(parts, format_with_hl(icon, icon_hl))
      end

      local file_name = config.format.env_file(status.file)
      local vars_count = config.format.vars_count(status.vars_count):match("^(%d+)")
      
      table.insert(
        parts,
        string.format(
          "%s (%s)",
          format_with_hl(file_name, config.highlights.env_file),
          format_with_hl(vars_count, config.highlights.vars_count)
        )
      )

      return table.concat(parts, " ")
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
  setup_highlights()
end

return M
