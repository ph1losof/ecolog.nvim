---@class EcologHealth
---Health check for ecolog.nvim
local M = {}

local health = vim.health

---Run health checks
function M.check()
  health.start("ecolog.nvim")

  M._check_neovim_version()
  M._check_binary()
  M._check_lsp_backend()
  M._check_lsp_status()
  M._check_dependencies()
  M._check_configuration()
end

---Check Neovim version
function M._check_neovim_version()
  local version = vim.version()
  local version_str = string.format("%d.%d.%d", version.major, version.minor, version.patch)

  if vim.fn.has("nvim-0.11") == 1 then
    health.ok("Neovim " .. version_str .. " (native vim.lsp.config available)")
  elseif vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim " .. version_str .. " (requires nvim-lspconfig for LSP)")
  else
    health.error(
      "Neovim " .. version_str .. " is too old",
      { "ecolog.nvim requires Neovim 0.10+ (0.11+ recommended for native LSP support)" }
    )
  end
end

---Check binary availability
function M._check_binary()
  local binary = require("ecolog.lsp.binary")
  local search_info = binary.get_search_info()

  local found = false
  local found_at = nil

  for _, info in ipairs(search_info) do
    if info.available then
      found = true
      found_at = info
      break
    end
  end

  if found then
    health.ok(string.format("ecolog-lsp found: %s (%s)", found_at.path, found_at.name))
  else
    local locations = {}
    for _, info in ipairs(search_info) do
      table.insert(locations, string.format("  - %s: %s", info.name, info.path))
    end

    health.error("ecolog-lsp binary not found", {
      "Install via one of:",
      "  - Mason: :MasonInstall ecolog-lsp",
      "  - Cargo: cargo install ecolog-lsp",
      "  - Manual: place ecolog-lsp in PATH",
      "",
      "Searched locations:",
      ---@diagnostic disable-next-line: deprecated
      unpack(locations),
    })
  end
end

---Check LSP backend resolution
function M._check_lsp_backend()
  local config = require("ecolog.config")
  local lsp_cfg = config.get_lsp()
  local backend = lsp_cfg.backend

  health.info(string.format("Configured backend: %s", tostring(backend)))

  -- Check what backend would be resolved
  local lsp = require("ecolog.lsp")
  local resolved = lsp.get_backend()

  if resolved then
    health.info(string.format("Resolved backend: %s", resolved))
  else
    -- Try to determine what would resolve
    if backend == false then
      health.info("Backend: external (user manages LSP)")
    elseif backend == "native" then
      if vim.fn.has("nvim-0.11") == 1 then
        health.ok("Backend 'native' available (Neovim 0.11+)")
      else
        health.error("Backend 'native' requires Neovim 0.11+")
      end
    elseif backend == "lspconfig" then
      local lspconfig_available = pcall(require, "lspconfig")
      if lspconfig_available then
        health.ok("Backend 'lspconfig' available")
      else
        health.error("Backend 'lspconfig' requires nvim-lspconfig")
      end
    else
      -- Auto mode
      if vim.fn.has("nvim-0.11") == 1 then
        health.ok("Auto-detect: will use 'native' (Neovim 0.11+)")
      elseif pcall(require, "lspconfig") then
        health.ok("Auto-detect: will use 'lspconfig'")
      else
        health.error("Auto-detect: no backend available", {
          "Install nvim-lspconfig or upgrade to Neovim 0.11+",
        })
      end
    end
  end
end

---Check LSP status
function M._check_lsp_status()
  local state = require("ecolog.state")

  if not state.is_initialized() then
    health.warn("ecolog.nvim not yet initialized", {
      "Call require('ecolog').setup() in your config",
    })
    return
  end

  local lsp = require("ecolog.lsp")

  if lsp.is_running() then
    local client = lsp.get_client()
    if client then
      health.ok(string.format("LSP running (id: %d, name: %s)", client.id, client.name))

      if client.config and client.config.root_dir then
        health.info(string.format("Root directory: %s", client.config.root_dir))
      end
    end
  else
    local backend = lsp.get_backend()
    if backend == "external" then
      health.warn("LSP not running (external mode)", {
        "ecolog.nvim is configured for external LSP management",
        "Ensure your external LSP setup is working",
      })
    else
      health.warn("LSP not running", {
        "Open a supported filetype to start the LSP",
        "Supported: javascript, typescript, python, rust, go, lua, etc.",
      })
    end
  end
end

---Check optional dependencies
function M._check_dependencies()
  -- Check lspconfig (optional)
  local has_lspconfig = pcall(require, "lspconfig")
  if has_lspconfig then
    health.ok("nvim-lspconfig: installed")
  else
    health.info("nvim-lspconfig: not installed (optional, needed for backend = 'lspconfig')")
  end

  -- Check pickers
  local has_telescope = pcall(require, "telescope")
  local has_fzf = pcall(require, "fzf-lua")
  local has_snacks = pcall(require, "snacks")

  if has_telescope then
    health.ok("telescope.nvim: installed")
  end
  if has_fzf then
    health.ok("fzf-lua: installed")
  end
  if has_snacks then
    health.ok("snacks.nvim: installed")
  end

  if not has_telescope and not has_fzf and not has_snacks then
    health.warn("No picker backend found", {
      "Install telescope.nvim, fzf-lua, or snacks.nvim for picker support",
      "Commands like :Ecolog list will not work without a picker",
    })
  end
end

---Check configuration validity
function M._check_configuration()
  local state = require("ecolog.state")

  if not state.is_initialized() then
    return
  end

  local config = require("ecolog.config")
  local lsp_cfg = config.get_lsp()

  -- Check for common configuration issues
  if lsp_cfg.backend == false and not lsp_cfg.client then
    health.warn("backend = false but no client name specified", {
      "Set lsp.client to match your external LSP client name",
      "Example: lsp = { backend = false, client = 'ecolog_lsp' }",
    })
  end

  if lsp_cfg.cmd then
    local cmd = type(lsp_cfg.cmd) == "table" and lsp_cfg.cmd[1] or lsp_cfg.cmd
    if vim.fn.executable(cmd) ~= 1 then
      health.error(string.format("Configured cmd not executable: %s", cmd), {
        "Check lsp.cmd configuration",
        "Ensure the path is correct and the binary exists",
      })
    else
      health.ok(string.format("Custom cmd executable: %s", cmd))
    end
  end

  -- Check filetypes
  if lsp_cfg.filetypes and #lsp_cfg.filetypes > 0 then
    health.info(string.format("Configured filetypes: %s", table.concat(lsp_cfg.filetypes, ", ")))
  end
end

return M
