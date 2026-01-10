---@class EcologStatusline
---Generic statusline component with highlight and caching support
local M = {}

local state = require("ecolog.state")

-- Compatibility layer for uv
local uv = vim.uv or vim.loop

-- Module-level config (set by setup or from config module)
local config = nil

-- Cache
local status_cache = {
  last_update = 0,
  data = nil,
}

-- Highlight utilities
local hl = {}

---Check if string is a hex color (#RRGGBB)
---@param str any
---@return boolean
function hl.is_hex_color(str)
  return type(str) == "string" and str:match("^#%x%x%x%x%x%x$") ~= nil
end

---Check if string is a highlight group name (not a hex color)
---@param str any
---@return boolean
function hl.is_highlight_group(str)
  return type(str) == "string" and not hl.is_hex_color(str)
end

---Recursively resolve linked highlight groups to get foreground color
---@param hl_name string Highlight group name or hex color
---@param visited? table Visited groups to detect circular references
---@return string|nil Hex color or nil if not found
function hl.get_color(hl_name, visited)
  visited = visited or {}

  -- Avoid circular references
  if visited[hl_name] then
    return nil
  end

  -- Direct hex color
  if hl.is_hex_color(hl_name) then
    return hl_name
  end

  visited[hl_name] = true

  -- Try to get highlight directly
  local success, highlight = pcall(vim.api.nvim_get_hl, 0, { name = hl_name, link = false })
  if not success or not highlight or not highlight.fg then
    -- Try to follow linked highlight
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

---Setup a single highlight group
---@param spec string Highlight group name or hex color
---@param base_name string Base name for the highlight group
---@param hex_name string Name for hex variant
local function setup_single_highlight(spec, base_name, hex_name)
  if hl.is_highlight_group(spec) and not hl.is_hex_color(spec) then
    vim.api.nvim_set_hl(0, base_name, { link = spec })
  elseif hl.is_hex_color(spec) then
    vim.api.nvim_set_hl(0, hex_name, { fg = spec })
  end
end

---Setup all highlight groups based on config
function hl.setup_highlights()
  local cfg = M._get_config()
  if not cfg.highlights.enabled then
    return
  end

  -- File name highlight
  setup_single_highlight(cfg.highlights.env_file, "EcologStatusFile", "EcologStatusFileHex")

  -- Variables count highlight
  setup_single_highlight(cfg.highlights.vars_count, "EcologStatusCount", "EcologStatusCountHex")

  -- Icon highlight
  setup_single_highlight(cfg.highlights.icons, "EcologStatusIcons", "EcologStatusIconsHex")

  -- Sources highlight
  if cfg.highlights.sources then
    setup_single_highlight(cfg.highlights.sources, "EcologStatusSources", "EcologStatusSourcesHex")
  end

  -- Sources disabled highlight
  if cfg.highlights.sources_disabled then
    setup_single_highlight(cfg.highlights.sources_disabled, "EcologStatusSourcesDisabled", "EcologStatusSourcesDisabledHex")
  end

  -- Interpolation highlight
  if cfg.highlights.interpolation then
    setup_single_highlight(cfg.highlights.interpolation, "EcologStatusInterpolation", "EcologStatusInterpolationHex")
  end

  -- Interpolation disabled highlight
  if cfg.highlights.interpolation_disabled then
    setup_single_highlight(cfg.highlights.interpolation_disabled, "EcologStatusInterpolationDisabled", "EcologStatusInterpolationDisabledHex")
  end
end

---Resolve config spec to actual highlight group name
---@param hl_spec string The highlight specification from config
---@return string The actual highlight group name to use
function hl.resolve_highlight_group(hl_spec)
  local cfg = M._get_config()
  if hl_spec == cfg.highlights.env_file then
    return hl.is_hex_color(hl_spec) and "EcologStatusFileHex" or "EcologStatusFile"
  elseif hl_spec == cfg.highlights.vars_count then
    return hl.is_hex_color(hl_spec) and "EcologStatusCountHex" or "EcologStatusCount"
  elseif hl_spec == cfg.highlights.icons then
    return hl.is_hex_color(hl_spec) and "EcologStatusIconsHex" or "EcologStatusIcons"
  elseif hl_spec == cfg.highlights.sources then
    return hl.is_hex_color(hl_spec) and "EcologStatusSourcesHex" or "EcologStatusSources"
  elseif hl_spec == cfg.highlights.sources_disabled then
    return hl.is_hex_color(hl_spec) and "EcologStatusSourcesDisabledHex" or "EcologStatusSourcesDisabled"
  elseif hl_spec == cfg.highlights.interpolation then
    return hl.is_hex_color(hl_spec) and "EcologStatusInterpolationHex" or "EcologStatusInterpolation"
  elseif hl_spec == cfg.highlights.interpolation_disabled then
    return hl.is_hex_color(hl_spec) and "EcologStatusInterpolationDisabledHex" or "EcologStatusInterpolationDisabled"
  end
  return hl_spec
end

---Format text with highlight for generic statusline
---@param text string Text to format
---@param hl_spec string Highlight specification
---@return string Formatted text with highlight codes
function hl.format_with_hl(text, hl_spec)
  local cfg = M._get_config()
  if not cfg.highlights.enabled then
    return text
  end
  local hl_group = hl.resolve_highlight_group(hl_spec)
  return string.format("%%#%s#%s%%*", hl_group, text)
end

---Format sources display string
---@param sources EcologEnabledSources The enabled sources
---@return string Formatted sources string
local function format_sources(sources)
  local cfg = M._get_config()
  if not cfg.sources or not cfg.sources.enabled then
    return ""
  end

  local icons = cfg.sources.icons or { shell = "S", file = "F" }
  local parts = {}
  local source_order = { "shell", "file" }

  for _, key in ipairs(source_order) do
    local icon = icons[key]
    local enabled = sources[key]

    if enabled then
      if cfg.highlights.enabled and cfg.highlights.sources then
        table.insert(parts, hl.format_with_hl(icon, cfg.highlights.sources))
      else
        table.insert(parts, icon)
      end
    elseif cfg.sources.show_disabled then
      if cfg.highlights.enabled and cfg.highlights.sources_disabled then
        table.insert(parts, hl.format_with_hl(icon, cfg.highlights.sources_disabled))
      else
        table.insert(parts, icon)
      end
    end
  end

  if cfg.sources.format == "badges" then
    -- Wrap each part in brackets for badge format
    local badge_parts = {}
    for _, part in ipairs(parts) do
      -- Extract just the letter from highlighted text for badge format
      local letter = part:match("%%#.-#(.)%%*") or part
      if cfg.highlights.enabled then
        -- Re-apply highlight around the bracketed letter
        local hl_match = part:match("(%%#.-#)")
        if hl_match then
          table.insert(badge_parts, hl_match .. "[" .. letter .. "]%*")
        else
          table.insert(badge_parts, "[" .. letter .. "]")
        end
      else
        table.insert(badge_parts, "[" .. part .. "]")
      end
    end
    return table.concat(badge_parts, "")
  end

  -- Compact format - just concatenate the letters
  return table.concat(parts, "")
end

---Format interpolation display string
---@return string Formatted interpolation string
local function format_interpolation()
  local cfg = M._get_config()
  if not cfg.interpolation or not cfg.interpolation.enabled then
    return ""
  end

  local icon = cfg.interpolation.icon or "I"
  local is_enabled = state.get_interpolation_enabled()

  if is_enabled then
    if cfg.highlights.enabled and cfg.highlights.interpolation then
      return hl.format_with_hl(icon, cfg.highlights.interpolation)
    else
      return icon
    end
  elseif cfg.interpolation.show_disabled then
    if cfg.highlights.enabled and cfg.highlights.interpolation_disabled then
      return hl.format_with_hl(icon, cfg.highlights.interpolation_disabled)
    else
      return icon
    end
  end

  return ""
end

---Get cached status data
---@return table Status data with file, files, vars_count, has_env_file, sources
local function get_cached_status()
  local now = uv.now()
  if status_cache.data and (now - status_cache.last_update) < 1000 then
    return status_cache.data
  end

  local lsp = require("ecolog.lsp")
  local client = lsp.get_client()

  if not client then
    local status = {
      file = nil,
      files = {},
      vars_count = 0,
      has_env_file = false,
      sources = state.get_enabled_sources(),
    }
    status_cache.data = status
    status_cache.last_update = now
    return status
  end

  local active_files = state.get_active_files()
  local filename = nil
  if #active_files > 0 then
    filename = vim.fn.fnamemodify(active_files[1], ":t")
    if #active_files > 1 then
      filename = filename .. " +" .. (#active_files - 1)
    end
  end

  local status = {
    file = filename,
    files = active_files,
    vars_count = state.get_var_count(),
    has_env_file = #active_files > 0,
    sources = state.get_enabled_sources(),
  }

  status_cache.data = status
  status_cache.last_update = now
  return status
end

---Setup statusline module with configuration
---@param opts? EcologStatuslineConfig
function M.setup(opts)
  -- Get defaults from config module, then merge with opts
  local cfg_module = require("ecolog.config")
  local defaults = cfg_module.get_statusline()
  config = vim.tbl_deep_extend("force", defaults, opts or {})

  -- Setup highlight groups
  hl.setup_highlights()

  -- Invalidate cache
  M.invalidate_cache()

  -- ColorScheme autocmd to refresh highlights on theme change
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("EcologStatuslineHighlights", { clear = true }),
    callback = function()
      hl.setup_highlights()
    end,
  })
end

---Invalidate the status cache
function M.invalidate_cache()
  status_cache = {
    data = nil,
    last_update = 0,
  }
end

---Get statusline string with highlights (for generic statusline)
---@return string
function M.get_statusline()
  local cfg = M._get_config()
  local status = get_cached_status()

  -- Hidden mode: return empty if no env variables from any source
  if cfg.hidden_mode and status.vars_count == 0 then
    return ""
  end

  local parts = {}

  -- Icon
  if cfg.icons.enabled and cfg.icons.env and cfg.icons.env ~= "" then
    local icon = cfg.icons.env
    if cfg.highlights.enabled then
      icon = hl.format_with_hl(icon, cfg.highlights.icons)
    end
    table.insert(parts, icon)
  end

  -- Sources
  if cfg.sources and cfg.sources.enabled then
    local sources_str = format_sources(status.sources)
    if sources_str ~= "" then
      table.insert(parts, sources_str)
    end
  end

  -- Interpolation
  if cfg.interpolation and cfg.interpolation.enabled then
    local interp_str = format_interpolation()
    if interp_str ~= "" then
      table.insert(parts, interp_str)
    end
  end

  -- File name
  if status.file then
    local file_text = cfg.format.env_file(status.file)
    if cfg.highlights.enabled then
      file_text = hl.format_with_hl(file_text, cfg.highlights.env_file)
    end
    table.insert(parts, file_text)
  end

  -- Variable count
  if status.vars_count > 0 then
    local count_text = "(" .. cfg.format.vars_count(status.vars_count) .. ")"
    if cfg.highlights.enabled then
      count_text = hl.format_with_hl(count_text, cfg.highlights.vars_count)
    end
    table.insert(parts, count_text)
  end

  return table.concat(parts, " ")
end

-- =============================================================================
-- Backward compatible API
-- =============================================================================

---@class EcologStatuslineOpts
---@field icon? string Icon to show (default: "")
---@field no_lsp_text? string Text when LSP not running (default: "")
---@field separator? string Separator between icon and text (default: " ")
---@field show_file? boolean Show active env file (default: true)
---@field show_count? boolean Show variable count (default: false)

---Get statusline component string (backward compatible)
---@param opts? EcologStatuslineOpts
---@return string
function M.get(opts)
  opts = vim.tbl_extend("force", {
    icon = "",
    no_lsp_text = "",
    separator = " ",
    show_file = true,
    show_count = false,
  }, opts or {})

  local lsp = require("ecolog.lsp")
  local client = lsp.get_client()
  if not client then
    return opts.no_lsp_text
  end

  local parts = { opts.icon }

  if opts.show_file then
    local active_files = state.get_active_files()
    if #active_files > 0 then
      local filename = vim.fn.fnamemodify(active_files[1], ":t")
      if #active_files > 1 then
        table.insert(parts, filename .. " +" .. (#active_files - 1))
      else
        table.insert(parts, filename)
      end
    end
  end

  if opts.show_count then
    local count = state.get_var_count()
    if count > 0 then
      table.insert(parts, string.format("(%d)", count))
    end
  end

  return table.concat(parts, opts.separator)
end

---Check if ecolog LSP is running
---@return boolean
function M.is_running()
  local lsp = require("ecolog.lsp")
  return lsp.is_running()
end

---Get active env file name (just filename, not path)
---Returns first file if multiple are selected, with "+N" suffix
---@return string|nil
function M.get_active_file()
  local active_files = state.get_active_files()
  if #active_files == 0 then
    return nil
  end
  local filename = vim.fn.fnamemodify(active_files[1], ":t")
  if #active_files > 1 then
    return filename .. " +" .. (#active_files - 1)
  end
  return filename
end

---Get active env file full path (first file if multiple)
---@return string|nil
function M.get_active_file_path()
  return state.get_active_file()
end

---Get all active env files
---@return string[]
function M.get_active_files()
  return state.get_active_files()
end

---Get all active env file names (just filenames, not paths)
---@return string[]
function M.get_active_file_names()
  local files = state.get_active_files()
  local names = {}
  for _, file in ipairs(files) do
    table.insert(names, vim.fn.fnamemodify(file, ":t"))
  end
  return names
end

---Get variable count
---@return number
function M.get_var_count()
  return state.get_var_count()
end

-- =============================================================================
-- Internal exports for lualine module
-- =============================================================================

---Get current config (internal use)
---@return EcologStatuslineConfig
function M._get_config()
  if config then
    return config
  end
  -- Fallback to config module defaults
  local cfg_module = require("ecolog.config")
  return cfg_module.get_statusline()
end

---Get highlight utilities (internal use)
---@return table
function M._get_hl()
  return hl
end

---Get cached status (internal use)
---@return table
function M._get_cached_status()
  return get_cached_status()
end

return M
