---@class EcologLualine
---Lualine component class for ecolog
local M = {}

local statusline = require("ecolog.statusline")
local state = require("ecolog.state")

-- Cached component class (created once on first use)
local EcologComponent = nil

---Create the lualine component class
---@return table EcologComponent class
local function create_component_class()
  if EcologComponent then
    return EcologComponent
  end

  local lualine_require = require("lualine_require")
  local Component = lualine_require.require("lualine.component")
  local highlight = require("lualine.highlight")

  EcologComponent = Component:extend()

  -- Condition for showing component
  EcologComponent.condition = function()
    return statusline.is_running()
  end

  function EcologComponent:init(options)
    EcologComponent.super.init(self, options)
    self.highlights = {}
    self.highlight_module = highlight
    self._highlights_initialized = false

    statusline.invalidate_cache()

    local config = statusline._get_config()
    if config.highlights.enabled then
      self:setup_lualine_highlights()
    end
  end

  function EcologComponent:setup_lualine_highlights()
    local config = statusline._get_config()
    local hl = statusline._get_hl()

    -- File name highlight
    local env_file_color = hl.get_color(config.highlights.env_file)
    if env_file_color then
      self.highlights.env_file = self.highlight_module.create_component_highlight_group(
        { fg = env_file_color },
        "eco_file",
        self.options
      )
    end

    -- Variables count highlight
    local vars_count_color = hl.get_color(config.highlights.vars_count)
    if vars_count_color then
      self.highlights.vars_count = self.highlight_module.create_component_highlight_group(
        { fg = vars_count_color },
        "eco_count",
        self.options
      )
    end

    -- Icon highlight
    local icon_color = hl.get_color(config.highlights.icons)
    if icon_color then
      self.highlights.icon = self.highlight_module.create_component_highlight_group(
        { fg = icon_color },
        "eco_icon",
        self.options
      )
    end

    -- Sources highlight
    if config.highlights.sources then
      local sources_color = hl.get_color(config.highlights.sources)
      if sources_color then
        self.highlights.sources = self.highlight_module.create_component_highlight_group(
          { fg = sources_color },
          "eco_sources",
          self.options
        )
      end
    end

    -- Sources disabled highlight
    if config.highlights.sources_disabled then
      local sources_disabled_color = hl.get_color(config.highlights.sources_disabled)
      if sources_disabled_color then
        self.highlights.sources_disabled = self.highlight_module.create_component_highlight_group(
          { fg = sources_disabled_color },
          "eco_sources_disabled",
          self.options
        )
      end
    end

    -- Interpolation highlight
    if config.highlights.interpolation then
      local interpolation_color = hl.get_color(config.highlights.interpolation)
      if interpolation_color then
        self.highlights.interpolation = self.highlight_module.create_component_highlight_group(
          { fg = interpolation_color },
          "eco_interpolation",
          self.options
        )
      end
    end

    -- Interpolation disabled highlight
    if config.highlights.interpolation_disabled then
      local interpolation_disabled_color = hl.get_color(config.highlights.interpolation_disabled)
      if interpolation_disabled_color then
        self.highlights.interpolation_disabled = self.highlight_module.create_component_highlight_group(
          { fg = interpolation_disabled_color },
          "eco_interpolation_disabled",
          self.options
        )
      end
    end

    -- Default highlight (for resetting)
    self.highlights.default = self.highlight_module.create_component_highlight_group(
      {},
      "eco_default",
      self.options
    )

    self._highlights_initialized = true
  end

  function EcologComponent:update_status()
    local config = statusline._get_config()
    local status = statusline._get_cached_status()

    -- Hidden mode: return empty if no env variables from any source
    if config.hidden_mode and status.vars_count == 0 then
      return ""
    end

    -- Lazy init highlights if needed
    if not self._highlights_initialized and config.highlights.enabled then
      self:setup_lualine_highlights()
    end

    local parts = {}

    -- Icon
    if config.icons.enabled and config.icons.env and config.icons.env ~= "" then
      self:add_icon_to_parts(parts, config)
    end

    -- Sources
    if config.sources and config.sources.enabled then
      self:add_sources_to_parts(parts, status.sources, config)
    end

    -- Interpolation
    if config.interpolation and config.interpolation.enabled then
      self:add_interpolation_to_parts(parts, config)
    end

    -- Formatted status text (file name and count)
    local formatted_status = self:format_status_text(status, config)
    if formatted_status ~= "" then
      table.insert(parts, formatted_status)
    end

    return table.concat(parts, " ")
  end

  function EcologComponent:add_icon_to_parts(parts, config)
    local icon = config.icons.env

    if config.highlights.enabled and self.highlights.icon then
      local icon_hl = self.highlight_module.component_format_highlight(self.highlights.icon)
      local default_hl = self.highlight_module.component_format_highlight(self.highlights.default)
      table.insert(parts, icon_hl .. icon .. default_hl)
    else
      table.insert(parts, icon)
    end
  end

  function EcologComponent:add_sources_to_parts(parts, sources, config)
    if not sources then
      return
    end

    local icons = config.sources.icons or { shell = "S", file = "F" }
    local source_str = ""
    local default_hl = self.highlights.default
        and self.highlight_module.component_format_highlight(self.highlights.default)
      or ""

    for _, key in ipairs({ "shell", "file" }) do
      local icon = icons[key]
      local enabled = sources[key]

      if enabled then
        if config.highlights.enabled and self.highlights.sources then
          local hl_str = self.highlight_module.component_format_highlight(self.highlights.sources)
          source_str = source_str .. hl_str .. icon
        else
          source_str = source_str .. icon
        end
      elseif config.sources.show_disabled then
        if config.highlights.enabled and self.highlights.sources_disabled then
          local hl_str = self.highlight_module.component_format_highlight(self.highlights.sources_disabled)
          source_str = source_str .. hl_str .. icon
        else
          source_str = source_str .. icon
        end
      end
    end

    if source_str ~= "" then
      -- Handle badge format
      if config.sources.format == "badges" then
        local badge_str = ""
        for _, key in ipairs({ "shell", "file" }) do
          local icon = icons[key]
          local enabled = sources[key]

          if enabled then
            if config.highlights.enabled and self.highlights.sources then
              local hl_str = self.highlight_module.component_format_highlight(self.highlights.sources)
              badge_str = badge_str .. hl_str .. "[" .. icon .. "]"
            else
              badge_str = badge_str .. "[" .. icon .. "]"
            end
          elseif config.sources.show_disabled then
            if config.highlights.enabled and self.highlights.sources_disabled then
              local hl_str = self.highlight_module.component_format_highlight(self.highlights.sources_disabled)
              badge_str = badge_str .. hl_str .. "[" .. icon .. "]"
            else
              badge_str = badge_str .. "[" .. icon .. "]"
            end
          end
        end
        table.insert(parts, badge_str .. default_hl)
      else
        -- Compact format
        table.insert(parts, source_str .. default_hl)
      end
    end
  end

  function EcologComponent:add_interpolation_to_parts(parts, config)
    if not config.interpolation or not config.interpolation.enabled then
      return
    end

    local icon = config.interpolation.icon or "I"
    local is_enabled = state.get_interpolation_enabled()
    local default_hl = self.highlights.default
        and self.highlight_module.component_format_highlight(self.highlights.default)
      or ""

    if is_enabled then
      if config.highlights.enabled and self.highlights.interpolation then
        local hl_str = self.highlight_module.component_format_highlight(self.highlights.interpolation)
        table.insert(parts, hl_str .. icon .. default_hl)
      else
        table.insert(parts, icon)
      end
    elseif config.interpolation.show_disabled then
      if config.highlights.enabled and self.highlights.interpolation_disabled then
        local hl_str = self.highlight_module.component_format_highlight(self.highlights.interpolation_disabled)
        table.insert(parts, hl_str .. icon .. default_hl)
      else
        table.insert(parts, icon)
      end
    end
  end

  function EcologComponent:format_status_text(status, config)
    -- Handle case where we have vars but no file (shell-only)
    if not status.file then
      if status.vars_count > 0 then
        local vars_count_str = config.format.vars_count(status.vars_count)
        if config.highlights.enabled and self.highlights.vars_count then
          local count_hl = self.highlight_module.component_format_highlight(self.highlights.vars_count)
          local default_hl_str = self.highlights.default
              and self.highlight_module.component_format_highlight(self.highlights.default) or ""
          return "(" .. count_hl .. vars_count_str .. default_hl_str .. ")"
        end
        return "(" .. vars_count_str .. ")"
      end
      return ""
    end

    local file_name = config.format.env_file(status.file)
    local vars_count_str = config.format.vars_count(status.vars_count)

    -- No highlights
    if not config.highlights.enabled then
      if status.vars_count > 0 then
        return string.format("%s (%s)", file_name, vars_count_str)
      end
      return file_name
    end

    local default_hl = self.highlights.default
    local default_hl_str = default_hl and self.highlight_module.component_format_highlight(default_hl) or ""

    local file_part = file_name
    local count_part = vars_count_str

    -- Apply file highlight
    if self.highlights.env_file then
      local file_hl = self.highlight_module.component_format_highlight(self.highlights.env_file)
      file_part = file_hl .. file_name .. default_hl_str
    end

    -- Apply count highlight
    if self.highlights.vars_count and status.vars_count > 0 then
      local count_hl = self.highlight_module.component_format_highlight(self.highlights.vars_count)
      count_part = count_hl .. vars_count_str .. default_hl_str
    end

    if status.vars_count > 0 then
      return string.format("%s (%s)", file_part, count_part)
    end
    return file_part
  end

  return EcologComponent
end

---Get the lualine component class
---@return table EcologComponent class for lualine
function M.component()
  return create_component_class()
end

-- =============================================================================
-- Backward compatible API
-- =============================================================================

---@class EcologLualineOpts : EcologStatuslineOpts
---@field color? table|string Lualine color configuration

---Create lualine component (backward compatible)
---Returns component class for lualine configuration
---@param opts? EcologLualineOpts
---@return table Lualine component configuration
function M.create(opts)
  opts = opts or {}

  -- If highlights are enabled, use the component class
  local config = statusline._get_config()
  if config.highlights.enabled then
    return M.component()
  end

  -- Fallback to simple function-based component for non-highlight usage
  return {
    function()
      return statusline.get(opts)
    end,
    cond = function()
      return statusline.is_running()
    end,
    icon = nil,
    color = opts.color or { fg = "#89b4fa" },
  }
end

---Create a simple lualine component showing just the active file
---@param opts? { icon?: string, color?: table|string }
---@return table
function M.file(opts)
  opts = opts or {}
  local config = statusline._get_config()

  -- Use component class if highlights enabled
  if config.highlights.enabled then
    -- Create a specialized file-only component
    local FileComponent = create_component_class():extend()

    function FileComponent:update_status()
      local cfg = statusline._get_config()
      local status = statusline._get_cached_status()

      if cfg.hidden_mode and not status.has_env_file then
        return ""
      end

      if not status.file then
        return ""
      end

      local file_name = cfg.format.env_file(status.file)

      if cfg.highlights.enabled and self.highlights.env_file then
        local file_hl = self.highlight_module.component_format_highlight(self.highlights.env_file)
        local default_hl = self.highlight_module.component_format_highlight(self.highlights.default)
        return file_hl .. file_name .. default_hl
      end

      return file_name
    end

    return FileComponent
  end

  -- Fallback to simple function
  return {
    function()
      local file = statusline.get_active_file()
      if file then
        return (opts.icon or "") .. " " .. file
      end
      return ""
    end,
    cond = function()
      return statusline.is_running() and statusline.get_active_file() ~= nil
    end,
    color = opts.color or { fg = "#89b4fa" },
  }
end

---Create a simple lualine component showing variable count
---@param opts? { icon?: string, color?: table|string }
---@return table
function M.count(opts)
  opts = opts or {}
  local config = statusline._get_config()

  -- Use component class if highlights enabled
  if config.highlights.enabled then
    -- Create a specialized count-only component
    local CountComponent = create_component_class():extend()

    function CountComponent:update_status()
      local cfg = statusline._get_config()
      local status = statusline._get_cached_status()

      if status.vars_count == 0 then
        return ""
      end

      local count_str = cfg.format.vars_count(status.vars_count)

      if cfg.highlights.enabled and self.highlights.vars_count then
        local count_hl = self.highlight_module.component_format_highlight(self.highlights.vars_count)
        local default_hl = self.highlight_module.component_format_highlight(self.highlights.default)
        return count_hl .. count_str .. default_hl
      end

      return count_str
    end

    return CountComponent
  end

  -- Fallback to simple function
  return {
    function()
      local count = statusline.get_var_count()
      if count > 0 then
        return (opts.icon or "") .. " " .. tostring(count)
      end
      return ""
    end,
    cond = function()
      return statusline.is_running() and statusline.get_var_count() > 0
    end,
    color = opts.color or { fg = "#a6e3a1" },
  }
end

-- Export as callable for direct use in lualine config
-- Usage: require("ecolog.statusline.lualine")({ icon = "", show_file = true })
setmetatable(M, {
  __call = function(_, opts)
    return M.create(opts)
  end,
})

return M
