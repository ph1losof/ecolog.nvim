local M = {}

-- Compatibility layer for uv -> vim.uv migration
local uv = vim.uv or uv
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
      return string.format("%d", count)
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
  local current_time = uv.now()
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

local hl = {}

function hl.is_hex_color(str)
  return type(str) == "string" and str:match("^#%x%x%x%x%x%x$")
end

function hl.is_highlight_group(str)
  return type(str) == "string" and not hl.is_hex_color(str)
end

function hl.get_color(hl_name, visited)
  visited = visited or {}

  if visited[hl_name] then
    return nil
  end

  if hl.is_hex_color(hl_name) then
    return hl_name
  end

  visited[hl_name] = true

  local success, highlight = pcall(vim.api.nvim_get_hl, 0, { name = hl_name, link = false })
  if not success or not highlight or not highlight.fg then
    local linked_success, linked_hl = pcall(vim.api.nvim_get_hl, 0, { name = hl_name, link = true })
    if linked_success and linked_hl and linked_hl.link then
      return hl.get_color(linked_hl.link, visited)
    end
    return nil
  end

  local fg = highlight.fg
  if type(fg) == "number" then
    return string.format("#%06x", fg)
  end

  return nil
end

function hl.get_icon_highlight(is_shelter)
  local icon_hl = config.highlights.icons
  if type(icon_hl) == "table" then
    return is_shelter and icon_hl.shelter or icon_hl.env
  end
  return icon_hl
end

function hl.setup_highlights()
  if not config.highlights.enabled then
    return
  end

  if hl.is_highlight_group(config.highlights.env_file) and not hl.is_hex_color(config.highlights.env_file) then
    vim.api.nvim_set_hl(0, "EcologStatusFile", { link = config.highlights.env_file })
  elseif hl.is_hex_color(config.highlights.env_file) then
    vim.api.nvim_set_hl(0, "EcologStatusFileHex", { fg = config.highlights.env_file })
  end

  if hl.is_highlight_group(config.highlights.vars_count) and not hl.is_hex_color(config.highlights.vars_count) then
    vim.api.nvim_set_hl(0, "EcologStatusCount", { link = config.highlights.vars_count })
  elseif hl.is_hex_color(config.highlights.vars_count) then
    vim.api.nvim_set_hl(0, "EcologStatusCountHex", { fg = config.highlights.vars_count })
  end

  local icon_hl = config.highlights.icons
  hl.setup_icon_highlights(icon_hl)
end

function hl.setup_icon_highlights(icon_hl)
  if type(icon_hl) == "table" then
    hl.setup_single_icon_highlight(icon_hl.env, "EcologStatusIconsEnv", "EcologStatusIconsEnvHex")
    hl.setup_single_icon_highlight(icon_hl.shelter, "EcologStatusIconsShelter", "EcologStatusIconsShelterHex")
  else
    hl.setup_single_icon_highlight(icon_hl, "EcologStatusIconsEnv", "EcologStatusIconsEnvHex")
    hl.setup_single_icon_highlight(icon_hl, "EcologStatusIconsShelter", "EcologStatusIconsShelterHex")
  end
end

function hl.setup_single_icon_highlight(highlight_spec, link_group, hex_group)
  if hl.is_highlight_group(highlight_spec) and not hl.is_hex_color(highlight_spec) then
    vim.api.nvim_set_hl(0, link_group, { link = highlight_spec })
  elseif hl.is_hex_color(highlight_spec) then
    vim.api.nvim_set_hl(0, hex_group, { fg = highlight_spec })
  end
end

function hl.format_with_hl(text, hl_spec)
  if not config.highlights.enabled then
    return text
  end

  local hl_group = hl.resolve_highlight_group(hl_spec, status_cache.shelter_active)
  return string.format("%%#%s#%s%%*", hl_group, text)
end

function hl.resolve_highlight_group(hl_spec, is_shelter)
  if hl_spec == config.highlights.env_file then
    return hl.is_hex_color(hl_spec) and "EcologStatusFileHex" or "EcologStatusFile"
  elseif hl_spec == config.highlights.vars_count then
    return hl.is_hex_color(hl_spec) and "EcologStatusCountHex" or "EcologStatusCount"
  elseif type(config.highlights.icons) == "table" then
    if hl_spec == config.highlights.icons.env then
      return hl.is_hex_color(hl_spec) and "EcologStatusIconsEnvHex" or "EcologStatusIconsEnv"
    elseif hl_spec == config.highlights.icons.shelter then
      return hl.is_hex_color(hl_spec) and "EcologStatusIconsShelterHex" or "EcologStatusIconsShelter"
    else
      local base = is_shelter and "EcologStatusIconsShelter" or "EcologStatusIconsEnv"
      return hl.is_hex_color(hl_spec) and base .. "Hex" or base
    end
  elseif hl_spec == config.highlights.icons then
    local base = is_shelter and "EcologStatusIconsShelter" or "EcologStatusIconsEnv"
    return hl.is_hex_color(hl_spec) and base .. "Hex" or base
  end

  return hl_spec
end

function M.get_statusline()
  local status = get_cached_status()
  if config.hidden_mode and not status.has_env_file then
    return ""
  end

  local parts = {}

  if config.icons.enabled then
    local icon = status.shelter_active and config.icons.shelter or config.icons.env
    local icon_hl = hl.get_icon_highlight(status.shelter_active)
    table.insert(parts, hl.format_with_hl(icon, icon_hl))
  end

  table.insert(parts, hl.format_with_hl(config.format.env_file(status.file), config.highlights.env_file))

  local vars_count_str = config.format.vars_count(status.vars_count)
  table.insert(parts, hl.format_with_hl(vars_count_str, config.highlights.vars_count))

  return table.concat(parts, " ")
end

function M.lualine()
  local lualine_require = require("lualine_require")
  local Component = lualine_require.require("lualine.component")
  local highlight = require("lualine.highlight")

  local EcologComponent = Component:extend()

  EcologComponent.condition = function()
    return _ecolog or package.loaded["ecolog"] ~= nil
  end

  function EcologComponent:init(options)
    EcologComponent.super.init(self, options)
    self.highlights = {}
    self.highlight_module = highlight

    M.invalidate_cache()

    if config.highlights.enabled then
      self:setup_lualine_highlights()
    end
  end

  function EcologComponent:setup_lualine_highlights()
    local env_file_color = hl.get_color(config.highlights.env_file)
    if env_file_color then
      self.highlights.env_file =
        self.highlight_module.create_component_highlight_group({ fg = env_file_color }, "eco_file", self.options)
    end

    local vars_count_color = hl.get_color(config.highlights.vars_count)
    if vars_count_color then
      self.highlights.vars_count =
        self.highlight_module.create_component_highlight_group({ fg = vars_count_color }, "eco_count", self.options)
    end

    self:setup_lualine_icon_highlights()

    self.highlights.default = self.highlight_module.create_component_highlight_group({}, "eco_default", self.options)
  end

  function EcologComponent:setup_lualine_icon_highlights()
    if type(config.highlights.icons) == "table" then
      local env_icon_color = hl.get_color(config.highlights.icons.env)
      local shelter_icon_color = hl.get_color(config.highlights.icons.shelter)

      if env_icon_color then
        self.highlights.env_icon =
          self.highlight_module.create_component_highlight_group({ fg = env_icon_color }, "eco_env", self.options)
      end

      if shelter_icon_color then
        self.highlights.shelter_icon = self.highlight_module.create_component_highlight_group(
          { fg = shelter_icon_color },
          "eco_shelter",
          self.options
        )
      end
    else
      local icon_color = hl.get_color(config.highlights.icons)
      if icon_color then
        self.highlights.env_icon =
          self.highlight_module.create_component_highlight_group({ fg = icon_color }, "eco_env", self.options)

        self.highlights.shelter_icon =
          self.highlight_module.create_component_highlight_group({ fg = icon_color }, "eco_shelter", self.options)
      end
    end
  end

  function EcologComponent:update_status()
    local status = get_cached_status()
    if config.hidden_mode and not status.has_env_file then
      return ""
    end

    if not self._highlights_initialized and config.highlights.enabled then
      self:setup_lualine_highlights()
      self._highlights_initialized = true
    end

    local parts = {}

    if config.icons.enabled then
      self:add_icon_to_parts(parts, status.shelter_active)
    end

    local formatted_status = self:format_status_text(status)
    table.insert(parts, formatted_status)

    return table.concat(parts, " ")
  end

  function EcologComponent:add_icon_to_parts(parts, is_shelter)
    local icon = is_shelter and config.icons.shelter or config.icons.env

    if config.highlights.enabled then
      local hl_group = is_shelter and self.highlights.shelter_icon or self.highlights.env_icon

      if hl_group then
        table.insert(parts, self.highlight_module.component_format_highlight(hl_group) .. icon)
      else
        table.insert(parts, icon)
      end
    else
      table.insert(parts, icon)
    end
  end

  function EcologComponent:format_status_text(status)
    local file_name = config.format.env_file(status.file)
    local vars_count_str = config.format.vars_count(status.vars_count)
    local vars_count = vars_count_str

    if not config.highlights.enabled then
      return string.format("%s (%s)", file_name, vars_count)
    end

    local default_hl = self.highlights.default
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

    return string.format("%s (%s)", file_part, count_part)
  end

  return EcologComponent
end

function M.invalidate_cache()
  status_cache = {
    data = nil,
    last_update = 0,
    env_vars_count = 0,
    shelter_active = false,
  }
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})

  hl.setup_highlights()

  M.invalidate_cache()

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("EcologStatuslineHighlights", { clear = true }),
    callback = function()
      hl.setup_highlights()
    end,
  })
end

function M.lualine_config()
  return {
    component = M.lualine(),
    condition = function()
      return _ecolog or package.loaded["ecolog"] ~= nil
    end,
    icon = "",
  }
end

return M
