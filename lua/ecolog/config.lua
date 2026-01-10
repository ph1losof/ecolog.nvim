---@class EcologConfig
---Configuration management for ecolog.nvim
local M = {}

---@alias EcologLspBackend
---| "auto"      # Auto-detect best approach (default)
---| "native"    # Force vim.lsp.config (Neovim 0.11+)
---| "lspconfig" # Force nvim-lspconfig
---| false       # External management (hooks only)

---@class EcologFeatureConfig
---@field hover? boolean Enable hover (default: true)
---@field completion? boolean Enable completion (default: true)
---@field diagnostics? boolean Enable diagnostics (default: true)
---@field definition? boolean Enable go-to-definition (default: true)

---@class EcologStrictConfig
---@field hover? boolean Strict hover mode (default: true)
---@field completion? boolean Strict completion mode (default: true)

---@class EcologLspConfig
---@field backend? EcologLspBackend LSP setup backend (default: "auto")
---@field client? string Client name to match when backend=false (default: "ecolog")
---@field cmd? string|string[] LSP command (default: auto-detect)
---@field filetypes? string[] Filetypes to attach
---@field root_dir? string Workspace root directory (default: cwd)
---@field env_patterns? string[] File patterns for env files (used for file watching)
---@field features? EcologFeatureConfig Feature toggles (merged with ecolog.toml)
---@field strict? EcologStrictConfig Strict mode settings (merged with ecolog.toml)
---@field settings? table Additional LSP settings to send to server

---@class EcologPickerKeymaps
---@field copy_value? string Copy variable value (default: "<C-y>")
---@field copy_name? string Copy variable name (default: "<C-u>")
---@field append_value? string Append value at cursor (default: "<C-a>")
---@field append_name? string Append name at cursor (default: "<CR>")
---@field goto_source? string Go to source file (default: "<C-g>")

---@class EcologPickerConfig
---@field backend? "telescope"|"fzf"|"snacks" Force picker backend (default: auto-detect)
---@field keys? EcologPickerKeymaps Picker keymap overrides

---@class EcologStatuslineIconsConfig
---@field enabled? boolean Enable icons (default: true)
---@field env? string Environment icon (default: "")

---@class EcologStatuslineFormatConfig
---@field env_file? fun(name: string): string Format env file name
---@field vars_count? fun(count: number): string Format variable count

---@class EcologStatuslineHighlightsConfig
---@field enabled? boolean Enable highlights (default: true)
---@field env_file? string Highlight group or hex color (default: "EcologStatusFile")
---@field vars_count? string Highlight group or hex color (default: "EcologStatusCount")
---@field icons? string Highlight group or hex color (default: "EcologStatusIcons")
---@field sources? string Highlight group or hex for enabled sources (default: "EcologStatusSources")
---@field sources_disabled? string Highlight group for disabled sources (default: "EcologStatusSourcesDisabled")
---@field interpolation? string Highlight group for interpolation enabled (default: "EcologStatusInterpolation")
---@field interpolation_disabled? string Highlight group for interpolation disabled (default: "EcologStatusInterpolationDisabled")

---@class EcologStatuslineSourcesIconsConfig
---@field shell? string Icon/letter for Shell source (default: "S")
---@field file? string Icon/letter for File source (default: "F")

---@class EcologStatuslineSourcesConfig
---@field enabled? boolean Show sources section (default: true)
---@field show_disabled? boolean Show disabled sources dimmed (default: false)
---@field format? "compact"|"badges" Display format (default: "compact")
---@field icons? EcologStatuslineSourcesIconsConfig Custom icons/letters per source

---@class EcologStatuslineInterpolationConfig
---@field enabled? boolean Show interpolation indicator (default: true)
---@field show_disabled? boolean Show indicator when interpolation is disabled (default: true)
---@field icon? string Icon/letter for interpolation (default: "I")

---@class EcologStatuslineConfig
---@field hidden_mode? boolean Hide when no env file selected (default: false)
---@field icons? EcologStatuslineIconsConfig Icon configuration
---@field format? EcologStatuslineFormatConfig Custom formatters
---@field highlights? EcologStatuslineHighlightsConfig Highlight configuration
---@field sources? EcologStatuslineSourcesConfig Sources display configuration
---@field interpolation? EcologStatuslineInterpolationConfig Interpolation indicator configuration

---@class EcologUserConfig
---@field lsp? EcologLspConfig LSP configuration
---@field picker? EcologPickerConfig Picker configuration
---@field statusline? EcologStatuslineConfig Statusline configuration
---@field sort_var_fn? fun(a: EcologVariable, b: EcologVariable): boolean Custom variable sort function

---@type EcologUserConfig
local DEFAULT_CONFIG = {
  lsp = {
    backend = "auto", -- "auto" | "native" | "lspconfig" | false
    client = "ecolog", -- Client name for external mode matching
    cmd = nil, -- auto-detect binary
    filetypes = nil, -- nil = attach to all buffers; or specify list like {"javascript", "python"}
    env_patterns = { "*.env", ".env.*" }, -- Patterns for env file watching
    settings = {},
  },
  picker = {
    backend = nil, -- auto-detect
    keys = {
      copy_value = "<C-y>",
      copy_name = "<C-u>",
      append_value = "<C-a>",
      append_name = "<CR>",
      goto_source = "<C-g>",
    },
  },
  statusline = {
    hidden_mode = false,
    icons = {
      enabled = true,
      env = "",
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
      sources = "EcologStatusSources",
      sources_disabled = "EcologStatusSourcesDisabled",
      interpolation = "EcologStatusInterpolation",
      interpolation_disabled = "EcologStatusInterpolationDisabled",
    },
    sources = {
      enabled = true,
      show_disabled = false,
      format = "compact",
      icons = {
        shell = "S",
        file = "F",
      },
    },
    interpolation = {
      enabled = true,
      show_disabled = true,
      icon = "I",
    },
  },
  sort_var_fn = nil, -- No custom sorting by default (use LSP order)
}

---@type EcologUserConfig
local current_config = vim.deepcopy(DEFAULT_CONFIG)

---Setup configuration
---@param opts? EcologUserConfig
function M.setup(opts)
  current_config = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULT_CONFIG), opts or {})
end

---Get current configuration
---@return EcologUserConfig
function M.get()
  return current_config
end

---Get LSP configuration
---@return EcologLspConfig
function M.get_lsp()
  return current_config.lsp or DEFAULT_CONFIG.lsp
end

---Get picker configuration
---@return EcologPickerConfig
function M.get_picker()
  return current_config.picker or DEFAULT_CONFIG.picker
end

---Get statusline configuration
---@return EcologStatuslineConfig
function M.get_statusline()
  return current_config.statusline or DEFAULT_CONFIG.statusline
end

---Get sort_var_fn configuration
---@return fun(a: EcologVariable, b: EcologVariable): boolean|nil
function M.get_sort_var_fn()
  return current_config.sort_var_fn
end

return M
