---@class EcologServerConfig
---Server configuration for ecolog-lsp
---This is the single source of truth for all LSP setup methods
local M = {}

local binary = require("ecolog.lsp.binary")

---Default filetypes ecolog-lsp supports (used for lspconfig registration)
---Note: The LSP attaches to all buffers via autocmds, not just these filetypes
---@type string[]
M.DEFAULT_FILETYPES = {
  "javascript",
  "javascriptreact",
  "typescript",
  "typescriptreact",
  "python",
  "rust",
  "go",
  "lua",
  "dotenv",
  "sh",
  "conf",
}

---@class EcologServerConfigResult
---@field cmd string[] Command to start the LSP
---@field filetypes string[] Filetypes to attach
---@field init_options table LSP initialization options
---@field settings table LSP settings
---@field single_file_support boolean Support single files without workspace
---@field name string Server name
---@field docs {description: string} Documentation

---Build the complete server configuration
---@param user_config? EcologLspConfig User-provided LSP config
---@return EcologServerConfigResult
function M.build(user_config)
  user_config = user_config or {}

  local cmd = user_config.cmd
  if not cmd then
    local bin_path = binary.find()
    cmd = { bin_path }
  elseif type(cmd) == "string" then
    cmd = { cmd }
  end

  -- Workspace root: user-configured root_dir > cwd (no automatic searching)
  local workspace_root = user_config.root_dir or vim.fn.getcwd()

  -- Build settings to send to LSP
  -- These are merged with ecolog.toml (ecolog.toml takes precedence)
  local base_settings = {
    workspace = {
      root = workspace_root,
    },
  }

  -- Add feature config if provided
  if user_config.features then
    base_settings.features = user_config.features
  end

  -- Add strict config if provided
  if user_config.strict then
    base_settings.strict = user_config.strict
  end

  -- Add sources config if provided
  if user_config.sources then
    base_settings.sources = user_config.sources
  end

  -- Merge with any additional user settings
  local settings = vim.tbl_deep_extend("force", base_settings, user_config.settings or {})

  -- Build init_options (sent as initializationOptions to LSP)
  -- The LSP reads configuration from initializationOptions, so we merge
  -- base_settings into init_options to ensure features, strict, sources, etc. are sent
  local init_options = vim.tbl_deep_extend("force", base_settings, user_config.init_options or {})

  return {
    cmd = cmd,
    filetypes = user_config.filetypes or M.DEFAULT_FILETYPES,
    init_options = init_options,
    settings = settings,
    single_file_support = true,
    name = "ecolog",
    docs = {
      description = [[
ecolog-lsp: Language server for environment variables.

Provides completion, hover, go-to-definition, references, rename,
and diagnostics for env var references across JavaScript, TypeScript,
Python, Rust, and Go.

https://github.com/ecolog/ecolog-lsp
]],
    },
  }
end

---Get default filetypes
---@return string[]
function M.get_filetypes()
  return vim.deepcopy(M.DEFAULT_FILETYPES)
end

return M
