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

local function is_highlight_group(str)
  return type(str) == "string" and not is_hex_color(str)
end

local function get_hl_color(hl_name)
  if is_hex_color(hl_name) then
    return hl_name
  end
  
  local success, hl = pcall(vim.api.nvim_get_hl, 0, { name = hl_name, link = false })
  if not success or not hl or not hl.fg then
    local linked_success, linked_hl = pcall(vim.api.nvim_get_hl, 0, { name = hl_name, link = true })
    if linked_success and linked_hl and linked_hl.link then
      return get_hl_color(linked_hl.link)
    end
    return nil
  end
  
  local fg = hl.fg
  if type(fg) == "number" then
    return string.format("#%06x", fg)
  end
  
  return nil
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

  if is_highlight_group(config.highlights.env_file) and not is_hex_color(config.highlights.env_file) then
    vim.api.nvim_set_hl(0, "EcologStatusFile", { link = config.highlights.env_file })
  end

  if is_highlight_group(config.highlights.vars_count) and not is_hex_color(config.highlights.vars_count) then
    vim.api.nvim_set_hl(0, "EcologStatusCount", { link = config.highlights.vars_count })
  end

  local icon_hl = config.highlights.icons

  if type(icon_hl) == "table" then
    if is_highlight_group(icon_hl.env) and not is_hex_color(icon_hl.env) then
      vim.api.nvim_set_hl(0, "EcologStatusIconsEnv", { link = icon_hl.env })
    elseif is_hex_color(icon_hl.env) then
      vim.api.nvim_set_hl(0, "EcologStatusIconsEnvHex", { fg = icon_hl.env })
    end

    if is_highlight_group(icon_hl.shelter) and not is_hex_color(icon_hl.shelter) then
      vim.api.nvim_set_hl(0, "EcologStatusIconsShelter", { link = icon_hl.shelter })
    elseif is_hex_color(icon_hl.shelter) then
      vim.api.nvim_set_hl(0, "EcologStatusIconsShelterHex", { fg = icon_hl.shelter })
    end
  else
    if is_highlight_group(icon_hl) and not is_hex_color(icon_hl) then
      vim.api.nvim_set_hl(0, "EcologStatusIconsEnv", { link = icon_hl })
      vim.api.nvim_set_hl(0, "EcologStatusIconsShelter", { link = icon_hl })
    elseif is_hex_color(icon_hl) then
      vim.api.nvim_set_hl(0, "EcologStatusIconsEnvHex", { fg = icon_hl })
      vim.api.nvim_set_hl(0, "EcologStatusIconsShelterHex", { fg = icon_hl })
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
  local is_shelter = status_cache.shelter_active
  
  if hl_spec == config.highlights.env_file then
    hl_group = is_hex_color(hl_spec) and "EcologStatusFileHex" or "EcologStatusFile"
  elseif hl_spec == config.highlights.vars_count then
    hl_group = is_hex_color(hl_spec) and "EcologStatusCountHex" or "EcologStatusCount"
  elseif type(config.highlights.icons) == "table" then
    if hl_spec == config.highlights.icons.env then
      hl_group = is_hex_color(hl_spec) and "EcologStatusIconsEnvHex" or "EcologStatusIconsEnv"
    elseif hl_spec == config.highlights.icons.shelter then
      hl_group = is_hex_color(hl_spec) and "EcologStatusIconsShelterHex" or "EcologStatusIconsShelter"
    else
      hl_group = is_hex_color(hl_spec) and 
                 (is_shelter and "EcologStatusIconsShelterHex" or "EcologStatusIconsEnvHex") or
                 (is_shelter and "EcologStatusIconsShelter" or "EcologStatusIconsEnv")
    end
  elseif hl_spec == config.highlights.icons then
    hl_group = is_hex_color(hl_spec) and 
               (is_shelter and "EcologStatusIconsShelterHex" or "EcologStatusIconsEnvHex") or
               (is_shelter and "EcologStatusIconsShelter" or "EcologStatusIconsEnv")
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
  local lualine_require = require("lualine_require")
  local Component = lualine_require.require("lualine.component")
  local highlight = require("lualine.highlight")
  
  local EcologComponent = Component:extend()
  
  EcologComponent.condition = function()
    if _ecolog then
      return true
    end
    return package.loaded["ecolog"] ~= nil
  end
  
  function EcologComponent:init(options)
    EcologComponent.super.init(self, options)
    
    self.highlights = {}
    self.highlight_module = highlight
    
    if config.highlights.enabled then
      local env_file_color = get_hl_color(config.highlights.env_file)
      local vars_count_color = get_hl_color(config.highlights.vars_count)
      
      if env_file_color then
        self.highlights.env_file = highlight.create_component_highlight_group(
          {fg = env_file_color},
          'eco_file',
          self.options
        )
      end
      
      if vars_count_color then
        self.highlights.vars_count = highlight.create_component_highlight_group(
          {fg = vars_count_color},
          'eco_count',
          self.options
        )
      end
      
      if type(config.highlights.icons) == "table" then
        local env_icon_color = get_hl_color(config.highlights.icons.env)
        local shelter_icon_color = get_hl_color(config.highlights.icons.shelter)
        
        if env_icon_color then
          self.highlights.env_icon = highlight.create_component_highlight_group(
            {fg = env_icon_color},
            'eco_env',
            self.options
          )
        end
        
        if shelter_icon_color then
          self.highlights.shelter_icon = highlight.create_component_highlight_group(
            {fg = shelter_icon_color},
            'eco_shelter',
            self.options
          )
        end
      else
        local icon_color = get_hl_color(config.highlights.icons)
        if icon_color then
          self.highlights.env_icon = highlight.create_component_highlight_group(
            {fg = icon_color},
            'eco_env',
            self.options
          )
          
          self.highlights.shelter_icon = highlight.create_component_highlight_group(
            {fg = icon_color},
            'eco_shelter',
            self.options
          )
        end
      end
      
      self.highlights.default = highlight.create_component_highlight_group(
        {},
        'eco_default',
        self.options
      )
    end
  end
  
  function EcologComponent:update_status()
    local status = get_cached_status()
    if config.hidden_mode and not status.has_env_file then
      return ""
    end
    
    local parts = {}
    
    if config.icons.enabled then
      local icon = status.shelter_active and config.icons.shelter or config.icons.env
      
      if config.highlights.enabled then
        local hl_group = status.shelter_active and self.highlights.shelter_icon or self.highlights.env_icon
        
        if hl_group then
          table.insert(parts, self.highlight_module.component_format_highlight(hl_group) .. icon)
        else
          table.insert(parts, icon)
        end
      else
        table.insert(parts, icon)
      end
    end
    
    local file_name = config.format.env_file(status.file)
    local vars_count_str = config.format.vars_count(status.vars_count)
    local vars_count = vars_count_str:match("^(%d+)") or "0"
    
    local default_hl = self.highlights.default or self.highlight_module.create_component_highlight_group(
      {},
      'eco_def',
      self.options
    )
    
    if config.highlights.enabled then
      local result
      local default_hl_str = self.highlight_module.component_format_highlight(default_hl)
      
      local file_part = file_name
      local count_part = vars_count
      
      if self.highlights.env_file then
        local file_hl = self.highlight_module.component_format_highlight(self.highlights.env_file)
        file_part = file_hl .. file_name .. default_hl_str
      end
      
      if self.highlights.vars_count then
        local count_hl = self.highlight_module.component_format_highlight(self.highlights.vars_count)
        count_part = count_hl .. vars_count .. default_hl_str
      end
      
      result = string.format("%s (%s)", file_part, count_part)
      table.insert(parts, result)
    else
      table.insert(parts, string.format("%s (%s)", file_name, vars_count))
    end
    
    return table.concat(parts, " ")
  end
  
  return EcologComponent
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

function M.lualine_config()
  return {
    component = M.lualine(),
    condition = function()
      if _ecolog then
        return true
      end
      return package.loaded["ecolog"] ~= nil
    end,
    icon = "",
  }
end

return M
