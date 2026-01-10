---@class EcologNativeLsp
---Native vim.lsp.config implementation for Neovim 0.11+
local M = {}

local server_config = require("ecolog.lsp.server_config")
local state = require("ecolog.state")
local hooks = require("ecolog.hooks")

---@type boolean
local is_configured = false

---Check if a buffer should have LSP attached
---@param bufnr number
---@return boolean
local function should_attach(bufnr)
  local buftype = vim.bo[bufnr].buftype
  -- Skip special buffers
  if buftype ~= "" then
    return false
  end
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  -- Skip unnamed buffers
  if bufname == "" then
    return false
  end
  return true
end

---Setup the LSP using native vim.lsp.config (Neovim 0.11+)
---@param lsp_config EcologLspConfig
function M.setup(lsp_config)
  if is_configured then
    return
  end

  local config = server_config.build(lsp_config)

  -- Track if we've sent setRoot (only need to do it once per server instance)
  local root_sent = false

  -- Build on_attach handler
  local function on_attach(client, bufnr)
    state.set_client_id(client.id)
    hooks.fire("on_lsp_attach", { client = client, bufnr = bufnr })

    -- Send workspace root to LSP if we detected one and haven't sent it yet
    if not root_sent and config.settings.workspace and config.settings.workspace.root then
      root_sent = true
      local lsp_commands = require("ecolog.lsp.commands")
      lsp_commands.set_root(config.settings.workspace.root)
    end

    -- Query LSP state to populate statusline
    vim.schedule(function()
      local lsp_commands = require("ecolog.lsp.commands")
      local current_file = vim.api.nvim_buf_get_name(bufnr)

      lsp_commands.list_files(current_file, function(files)
        if files and #files > 0 and #state.get_active_files() == 0 then
          state.set_active_files(files)
        end
      end)

      lsp_commands.list_variables(current_file, function(vars)
        if vars and #vars > 0 then
          state.set_var_count(#vars)
        end
      end)

      lsp_commands.list_sources(function(sources)
        if sources and #sources > 0 then
          local enabled = { shell = false, file = false }
          for _, src in ipairs(sources) do
            local key = src.name:lower()
            if enabled[key] ~= nil then
              enabled[key] = src.enabled
            end
          end
          state.set_enabled_sources(enabled)
        end
      end)
    end)
  end

  -- LSP start configuration
  local lsp_start_config = {
    name = "ecolog",
    cmd = config.cmd,
    root_dir = config.settings.workspace and config.settings.workspace.root or vim.fn.getcwd(),
    settings = config.settings,
    capabilities = vim.lsp.protocol.make_client_capabilities(),
    on_attach = on_attach,
  }

  -- Create autocmd to attach LSP to all buffers
  local augroup = vim.api.nvim_create_augroup("ecolog-lsp-native", { clear = true })

  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group = augroup,
    callback = function(event)
      if not should_attach(event.buf) then
        return
      end
      -- Start or attach the LSP to this buffer
      vim.lsp.start(lsp_start_config, { bufnr = event.buf })
    end,
  })

  -- Also attach to current buffer if it exists and is valid
  local current_buf = vim.api.nvim_get_current_buf()
  if should_attach(current_buf) then
    vim.lsp.start(lsp_start_config, { bufnr = current_buf })
  end

  is_configured = true
end

---Check if native setup is configured
---@return boolean
function M.is_configured()
  return is_configured
end

---Reset configured state (for testing)
function M.reset()
  is_configured = false
end

---Check if native vim.lsp.config is available
---@return boolean
function M.is_available()
  return vim.fn.has("nvim-0.11") == 1
end

return M
