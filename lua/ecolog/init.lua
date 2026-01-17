---@class Ecolog
---ecolog.nvim - Neovim plugin for environment variable tooling
---Wraps ecolog-lsp to provide IDE features for env vars
local M = {}

local config = require("ecolog.config")
local state = require("ecolog.state")
local notify = require("ecolog.notification_manager")

---@type boolean
local is_setup = false

---Setup ecolog.nvim
---@param opts? EcologUserConfig
function M.setup(opts)
  if is_setup then
    return
  end

  -- Check minimum Neovim version
  -- 0.11+ for native vim.lsp.config support
  -- 0.10+ works with nvim-lspconfig backend
  if vim.fn.has("nvim-0.10") ~= 1 then
    notify.error("ecolog.nvim requires Neovim 0.10+ (0.11+ recommended)")
    return
  end

  -- Configure
  config.setup(opts)

  -- Initialize state from config defaults (e.g., sources.defaults)
  local lsp_cfg = config.get_lsp()
  if lsp_cfg.sources and lsp_cfg.sources.defaults then
    state.init_from_config(lsp_cfg.sources.defaults)
  end

  -- Setup statusline with highlights
  local statusline = require("ecolog.statusline")
  statusline.setup(config.get_statusline())

  -- Setup LSP (auto-detects best backend)
  local lsp = require("ecolog.lsp")
  lsp.setup()

  -- Register user commands
  local commands = require("ecolog.commands")
  commands._register_commands()

  -- Setup autocmds for env file changes
  local lsp_config = config.get_lsp()
  local augroup = vim.api.nvim_create_augroup("EcologEnvFileWatch", { clear = true })

  -- Refresh statusline when env files are written or deleted
  vim.api.nvim_create_autocmd({ "BufWritePost", "BufDelete" }, {
    group = augroup,
    pattern = lsp_config.env_patterns,
    callback = function()
      vim.schedule(function()
        local lsp_commands = require("ecolog.lsp.commands")
        lsp_commands.refresh_state()
      end)
    end,
    desc = "Ecolog: Refresh statusline on env file changes",
  })

  -- Cleanup vim.env on exit (optional, vars are cleared on exit anyway)
  if config.get_vim_env() then
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = augroup,
      callback = function()
        local vim_env = require("ecolog.vim_env")
        vim_env.clear()
      end,
      desc = "Ecolog: Clear vim.env on exit",
    })

    -- Initial vim.env sync after LSP is ready
    vim.defer_fn(function()
      local lsp_commands = require("ecolog.lsp.commands")
      lsp_commands.list_variables(nil, function() end)
    end, 500)
  end

  -- Mark as initialized
  state.set_initialized(true)
  is_setup = true
end

---Check if ecolog is setup
---@return boolean
function M.is_setup()
  return is_setup
end

---Get configuration
---@return EcologUserConfig
function M.get_config()
  return config.get()
end

---Get hooks module (for external integrations like shelter.nvim)
---@return EcologHooks
function M.hooks()
  return require("ecolog.hooks")
end

---Get statusline module
---@return EcologStatusline
function M.statusline()
  return require("ecolog.statusline")
end

---Get lualine component
---@param opts? EcologStatuslineOpts
---@return table Lualine component configuration
function M.lualine(opts)
  return require("ecolog.statusline.lualine").create(opts)
end

---Get LSP module
---@return EcologLsp
function M.lsp()
  return require("ecolog.lsp")
end

---Get pickers module
---@return EcologPickers
function M.pickers()
  return require("ecolog.pickers")
end

-- Convenience functions that delegate to commands
-- Note: For hover (K), go-to-definition (gd), references (gr), and rename (:LspRename),
-- use Neovim's native LSP keybindings - no plugin wrapper needed.

---Select active env file via picker
function M.select()
  require("ecolog.commands").files_cmd("select")
end

---Copy variable name or value at cursor
---@param what "name"|"value"
function M.copy(what)
  require("ecolog.commands").copy(what)
end

---Refresh LSP (reload env files)
function M.refresh()
  require("ecolog.commands").refresh()
end

---Open variable picker
function M.list()
  require("ecolog.commands").list()
end

---Open file picker
function M.files()
  require("ecolog.commands").files_cmd("select")
end

---Generate .env.example file
---@param opts? { output?: string }
function M.generate_example(opts)
  require("ecolog.commands").generate_example(opts)
end

---Show ecolog info
function M.info()
  require("ecolog.commands").info()
end

---Get a variable by name
---@param name string Variable name
---@param callback fun(var: EcologVariable|nil)
function M.get(name, callback)
  require("ecolog.lsp.commands").get_variable(name, callback)
end

---List all variables
---@param file_path? string Optional file path for package scoping
---@param callback fun(vars: EcologVariable[])
function M.all(file_path, callback)
  -- Handle backwards compatibility: if first arg is a function, it's the callback
  if type(file_path) == "function" then
    callback = file_path
    file_path = nil
  end
  require("ecolog.lsp.commands").list_variables(file_path, callback)
end

return M
