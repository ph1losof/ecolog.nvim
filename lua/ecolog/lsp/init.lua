---@class EcologLsp
---LSP client management for ecolog.nvim
---Orchestrates between native vim.lsp.config and nvim-lspconfig
local M = {}

local config = require("ecolog.config")
local state = require("ecolog.state")
local hooks = require("ecolog.hooks")
local notify = require("ecolog.notification_manager")

---@alias EcologLspBackend "auto"|"native"|"lspconfig"|false
---@alias EcologResolvedBackend "native"|"lspconfig"|"external"

---Resolve backend from config to actual implementation
---@param backend EcologLspBackend
---@return EcologResolvedBackend
---@return string|nil error_message
local function resolve_backend(backend)
  -- External management
  if backend == false then
    return "external", nil
  end

  -- Force native
  if backend == "native" then
    if vim.fn.has("nvim-0.11") ~= 1 then
      return "native", "backend = 'native' requires Neovim 0.11+. Current version: " .. vim.version().major .. "." .. vim.version().minor
    end
    return "native", nil
  end

  -- Force lspconfig
  if backend == "lspconfig" then
    local lspconfig_mod = require("ecolog.lsp.lspconfig")
    if not lspconfig_mod.is_available() then
      return "lspconfig", "backend = 'lspconfig' requires nvim-lspconfig. Install it or use backend = 'native'."
    end
    return "lspconfig", nil
  end

  -- Auto-detect: prefer native on 0.11+, fall back to lspconfig
  if vim.fn.has("nvim-0.11") == 1 then
    return "native", nil
  end

  local lspconfig_mod = require("ecolog.lsp.lspconfig")
  if lspconfig_mod.is_available() then
    return "lspconfig", nil
  end

  return "external", "No LSP backend available. Requires Neovim 0.11+ or nvim-lspconfig."
end

---Setup hooks for external LSP management
---When backend = false, user manages LSP externally
---We just hook into LspAttach to track the client
---@param lsp_cfg EcologLspConfig
local function setup_external_hooks(lsp_cfg)
  local client_name = lsp_cfg.client or "ecolog"

  vim.api.nvim_create_autocmd("LspAttach", {
    group = vim.api.nvim_create_augroup("ecolog-lsp-external", { clear = true }),
    callback = function(event)
      local client = vim.lsp.get_client_by_id(event.data.client_id)
      if not client then
        return
      end

      -- Match by exact name or common ecolog patterns
      local is_ecolog = client.name == client_name
        or client.name == "ecolog"
        or client.name == "ecolog_lsp"
        or client.name == "ecolog-lsp"

      if is_ecolog then
        state.set_client_id(client.id)
        hooks.fire("on_lsp_attach", { client = client, bufnr = event.buf })
      end
    end,
  })
end

---@type EcologResolvedBackend|nil
local current_backend = nil

---Setup LSP client
---Automatically chooses between native vim.lsp.config and nvim-lspconfig
function M.setup()
  local lsp_cfg = config.get_lsp()

  local backend, err = resolve_backend(lsp_cfg.backend)

  if err then
    notify.error(err)
    return
  end

  current_backend = backend

  if backend == "external" then
    setup_external_hooks(lsp_cfg)
    return
  end

  if backend == "lspconfig" then
    local lspconfig_mod = require("ecolog.lsp.lspconfig")
    lspconfig_mod.setup(lsp_cfg)
    return
  end

  -- Default: native mode
  local native = require("ecolog.lsp.native")
  native.setup(lsp_cfg)
end

---Get the active ecolog LSP client
---@return vim.lsp.Client|nil
function M.get_client()
  local client_id = state.get_client_id()
  if client_id then
    local client = vim.lsp.get_client_by_id(client_id)
    if client then
      return client
    end
  end

  -- Fallback: search by name
  local lsp_cfg = config.get_lsp()
  local search_names = { lsp_cfg.client or "ecolog", "ecolog", "ecolog_lsp", "ecolog-lsp" }

  for _, name in ipairs(search_names) do
    local clients = vim.lsp.get_clients({ name = name })
    if #clients > 0 then
      state.set_client_id(clients[1].id)
      return clients[1]
    end
  end

  return nil
end

---Execute an LSP command
---@param command string Command name
---@param args? any[] Command arguments
---@param callback? fun(err: any, result: any) Callback for async execution
---@return any|nil result Synchronous result (if no callback)
function M.execute_command(command, args, callback)
  local client = M.get_client()
  if not client then
    notify.warn("LSP not running")
    if callback then
      callback({ message = "LSP not running" }, nil)
    end
    return nil
  end

  local params = {
    command = command,
    arguments = args or {},
  }

  if callback then
    client:request("workspace/executeCommand", params, function(err, result)
      callback(err, result)
    end)
  else
    local result = client:request_sync("workspace/executeCommand", params, 5000)
    if result and result.err then
      return nil
    end
    return result and result.result
  end
end

---Restart the LSP client
function M.restart()
  local client = M.get_client()
  if client then
    vim.lsp.stop_client(client.id)
    state.set_client_id(nil)
  end

  vim.defer_fn(function()
    if current_backend == "native" then
      vim.lsp.enable("ecolog")
    elseif current_backend == "lspconfig" then
      -- Trigger buffer re-read to restart via lspconfig filetype autocmds
      vim.cmd("edit")
    end
    -- External mode: user handles restart
  end, 500)
end

---Check if LSP is running
---@return boolean
function M.is_running()
  return M.get_client() ~= nil
end

---Get current LSP backend
---@return EcologResolvedBackend|nil
function M.get_backend()
  return current_backend
end

---Manually register ecolog with lspconfig
---For advanced users who want to manage setup themselves
---@param user_config? EcologLspConfig
---@return boolean success
function M.register_lspconfig(user_config)
  local lspconfig_mod = require("ecolog.lsp.lspconfig")
  return lspconfig_mod.register(user_config)
end

---Get binary detection module
---@return EcologBinary
function M.get_binary()
  return require("ecolog.lsp.binary")
end

---Get server config module
---@return EcologServerConfig
function M.get_server_config()
  return require("ecolog.lsp.server_config")
end

return M
