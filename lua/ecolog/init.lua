local M = {}

local api = vim.api
local fn = vim.fn
local notify = vim.notify
local schedule = vim.schedule
local tbl_extend = vim.tbl_deep_extend

---@class EcologConfig
---@field path string Path to search for .env files
---@field shelter ShelterConfig Shelter mode configuration
---@field integrations IntegrationsConfig Integration settings
---@field types boolean|table Enable all types or specific type configuration
---@field custom_types table Custom type definitions
---@field preferred_environment string Preferred environment name
---@field load_shell LoadShellConfig Shell variables loading configuration
---@field env_file_pattern string|string[] Custom pattern(s) for matching env files
---@field sort_fn? function Custom function for sorting env files
---@field provider_patterns table|boolean Controls how environment variables are extracted from code
---@field vim_env boolean Enable vim.env integration

---@class IntegrationsConfig
---@field lsp boolean Enable LSP integration
---@field lspsaga boolean Enable LSPSaga integration
---@field nvim_cmp boolean|table Enable nvim-cmp integration
---@field blink_cmp boolean|table Enable blink-cmp integration
---@field fzf boolean|table Enable fzf integration
---@field statusline boolean|table Enable statusline integration
---@field snacks boolean|table Enable snacks integration
---@field secret_managers? table Secret manager configurations
---@field secret_managers.aws? boolean|LoadAwsSecretsConfig AWS Secrets Manager configuration
---@field secret_managers.vault? boolean|LoadVaultSecretsConfig HashiCorp Vault configuration

local DEFAULT_CONFIG = {
  path = vim.fn.getcwd(),
  shelter = {
    configuration = {
      partial_mode = false,
      mask_char = "*",
    },
    modules = {
      cmp = false,
      peek = false,
      files = false,
      telescope = false,
      telescope_previewer = false,
      fzf = false,
      fzf_previewer = false,
      snacks = false,
      snacks_previewer = false,
    },
  },
  integrations = {
    lsp = false,
    lspsaga = false,
    nvim_cmp = true,
    blink_cmp = false,
    fzf = false,
    statusline = false,
    snacks = false,
    secret_managers = {
      aws = false,
      vault = false,
    },
  },
  vim_env = false,
  types = true,
  custom_types = {},
  preferred_environment = "",
  provider_patterns = {
    extract = true,
    cmp = true,
  },
  load_shell = {
    enabled = false,
    override = false,
    filter = nil,
    transform = nil,
  },
  env_file_pattern = nil,
  sort_fn = nil,
}

---@class EcologState
---@field env_vars table<string, EnvVarInfo>
---@field cached_env_files string[]?
---@field last_opts EcologConfig?
---@field file_cache_opts table?
---@field current_watcher_group number?
---@field selected_env_file string?
---@field _env_module table?
---@field _file_watchers number[]
---@field _env_line_cache table
---@field _secret_managers table<string, any>
---@field initialized boolean

-- Initialize state with weak cache for line parsing
local state = {
  env_vars = {},
  cached_env_files = nil,
  last_opts = nil,
  file_cache_opts = nil,
  current_watcher_group = nil,
  selected_env_file = nil,
  _env_module = nil,
  _file_watchers = {},
  _env_line_cache = setmetatable({}, { __mode = "k" }),
  _secret_managers = {},
  initialized = false,
}

-- Module loading with circular dependency protection
local _loaded_modules = {}
local _loading = {}
local _setup_done = false
local _lazy_setup_tasks = {}

local function require_module(name)
  if _loaded_modules[name] then
    return _loaded_modules[name]
  end

  if _loading[name] then
    error("Circular dependency detected: " .. name)
  end

  _loading[name] = true
  local module = require(name)
  _loading[name] = nil
  _loaded_modules[name] = module
  return module
end

-- Core module loading
local utils = require_module("ecolog.utils")
local providers = utils.get_module("ecolog.providers")
local select = utils.get_module("ecolog.select")
local peek = utils.get_module("ecolog.peek")
local shelter = utils.get_module("ecolog.shelter")
local types = utils.get_module("ecolog.types")
local env_loader = require_module("ecolog.env_loader")
local file_watcher = require_module("ecolog.file_watcher")

-- Lazy load vim.env integration
local function get_env_module()
  if not state._env_module then
    state._env_module = require("ecolog.env")
    state._env_module.setup()
  end
  return state._env_module
end

-- Lazy load secret manager
local function get_secret_manager(name)
  if not state._secret_managers[name] then
    state._secret_managers[name] = require("ecolog.integrations.secret_managers." .. name)
  end
  return state._secret_managers[name]
end

-- Environment variable management
function M.refresh_env_vars(opts)
  state.cached_env_files = nil
  state.file_cache_opts = nil
  -- Use either last_opts or DEFAULT_CONFIG as the base
  local base_opts = state.last_opts or DEFAULT_CONFIG
  -- Always use full config
  opts = vim.tbl_deep_extend("force", base_opts, opts or {})
  env_loader.load_environment(opts, state, true)

  -- Invalidate statusline cache only if integration is enabled
  if opts.integrations.statusline then
    local statusline = require("ecolog.integrations.statusline")
    statusline.invalidate_cache()
  end

  -- Refresh secrets if configured
  if opts.integrations.secret_managers then
    -- Refresh AWS secrets if configured
    if opts.integrations.secret_managers.aws then
      local aws = get_secret_manager("aws")
      aws.load_aws_secrets(opts.integrations.secret_managers.aws)
    end

    -- Refresh Vault secrets if configured
    if opts.integrations.secret_managers.vault then
      local vault = get_secret_manager("vault")
      vault.load_vault_secrets(opts.integrations.secret_managers.vault)
    end
  end
end

function M.get_env_vars()
  -- Check if selected file exists
  if state.selected_env_file and vim.fn.filereadable(state.selected_env_file) == 0 then
    state.selected_env_file = nil
    state.env_vars = {}
    state._env_line_cache = {}
    env_loader.load_environment(state.last_opts or DEFAULT_CONFIG, state, true)
  end

  if next(state.env_vars) == nil then
    env_loader.load_environment(state.last_opts or DEFAULT_CONFIG, state)
  end
  return state.env_vars
end

-- File selection and environment handling
local function handle_env_file_change()
  state.cached_env_files = nil
  M.refresh_env_vars(state.last_opts)
  if state._env_module then
    state._env_module.update_env_vars()
  end
end

local function handle_env_file_selection(file, config)
  if file then
    state.selected_env_file = file
    config.preferred_environment = fn.fnamemodify(file, ":t"):gsub("^%.env%.", "")
    file_watcher.setup_watcher(config, state, M.refresh_env_vars)
    state.cached_env_files = nil
    M.refresh_env_vars(config)
    if state._env_module then
      state._env_module.update_env_vars()
    end
    notify(string.format("Selected environment file: %s", fn.fnamemodify(file, ":t")), vim.log.levels.INFO)
  end
end

-- Integration setup
local function setup_integrations(config)
  if config.integrations.lsp then
    local lsp = require_module("ecolog.integrations.lsp")
    lsp.setup()
  end

  if config.integrations.lspsaga then
    local lspsaga = require_module("ecolog.integrations.lspsaga")
    lspsaga.setup()
  end

  if config.integrations.nvim_cmp then
    local nvim_cmp = require("ecolog.integrations.cmp.nvim_cmp")
    nvim_cmp.setup(config.integrations.nvim_cmp, state.env_vars, providers, shelter, types, state.selected_env_file)
  end

  if config.integrations.blink_cmp then
    local blink_cmp = require("ecolog.integrations.cmp.blink_cmp")
    blink_cmp.setup(config.integrations.blink_cmp, state.env_vars, providers, shelter, types, state.selected_env_file)
  end

  if config.integrations.fzf then
    local fzf = require("ecolog.integrations.fzf")
    fzf.setup(type(config.integrations.fzf) == "table" and config.integrations.fzf or {})
  end

  if config.integrations.statusline then
    local statusline = require("ecolog.integrations.statusline")
    statusline.setup(type(config.integrations.statusline) == "table" and config.integrations.statusline or {})
  end

  if config.integrations.snacks then
    local snacks = require("ecolog.integrations.snacks")
    snacks.setup(type(config.integrations.snacks) == "table" and config.integrations.snacks or {})
  end
end

-- Command creation
local function create_commands(config)
  local commands = {
    EcologPeek = {
      callback = function(args)
        local filetype = vim.bo.filetype
        local available_providers = providers.get_providers(filetype)
        peek.peek_env_var(available_providers, args.args)
      end,
      nargs = "?",
      desc = "Peek environment variable value",
    },
    EcologSelect = {
      callback = function()
        select.select_env_file({
          path = config.path,
          active_file = state.selected_env_file,
          env_file_pattern = config.env_file_pattern,
          sort_fn = config.sort_fn,
          preferred_environment = config.preferred_environment,
        }, function(file)
          handle_env_file_selection(file, config)
        end)
      end,
      desc = "Select environment file to use",
    },
    EcologGenerateExample = {
      callback = function()
        if not state.selected_env_file then
          notify("No environment file selected. Use :EcologSelect to select one.", vim.log.levels.ERROR)
          return
        end
        utils.generate_example_file(state.selected_env_file)
      end,
      desc = "Generate .env.example file from selected .env file",
    },
    EcologShelterToggle = {
      callback = function(args)
        local arg = args.args:lower()
        if arg == "" then
          shelter.toggle_all()
          return
        end
        local parts = vim.split(arg, " ")
        local command = parts[1]
        local feature = parts[2]
        if command ~= "enable" and command ~= "disable" then
          notify("Invalid command. Use 'enable' or 'disable'", vim.log.levels.ERROR)
          return
        end
        shelter.set_state(command, feature)
      end,
      nargs = "?",
      desc = "Toggle all shelter modes or enable/disable specific features",
      complete = function(arglead, cmdline)
        local args = vim.split(cmdline, "%s+")
        if #args == 2 then
          return vim.tbl_filter(function(item)
            return item:find(arglead, 1, true)
          end, { "enable", "disable" })
        elseif #args == 3 then
          return vim.tbl_filter(function(item)
            return item:find(arglead, 1, true)
          end, { "cmp", "peek", "files" })
        end
        return { "enable", "disable" }
      end,
    },
    EcologRefresh = {
      callback = function()
        M.refresh_env_vars(config)
      end,
      desc = "Refresh environment variables cache",
    },
    EcologGoto = {
      callback = function()
        if state.selected_env_file then
          vim.cmd("edit " .. fn.fnameescape(state.selected_env_file))
        else
          notify("No environment file selected", vim.log.levels.WARN)
        end
      end,
      desc = "Go to selected environment file",
    },
    EcologGotoVar = {
      callback = function(args)
        local filetype = vim.bo.filetype
        local available_providers = providers.get_providers(filetype)
        local var_name = args.args

        if var_name == "" then
          var_name = utils.get_var_word_under_cursor(available_providers)
        end

        if not var_name or #var_name == 0 then
          notify("No environment variable specified or found at cursor", vim.log.levels.WARN)
          return
        end

        env_loader.load_environment(config, state)

        local var = state.env_vars[var_name]
        if not var then
          notify(string.format("Environment variable '%s' not found", var_name), vim.log.levels.WARN)
          return
        end

        vim.cmd("edit " .. fn.fnameescape(var.source))

        local lines = api.nvim_buf_get_lines(0, 0, -1, false)
        for i, line in ipairs(lines) do
          if line:match("^" .. vim.pesc(var_name) .. "=") then
            api.nvim_win_set_cursor(0, { i, 0 })
            vim.cmd("normal! zz")
            break
          end
        end
      end,
      nargs = "?",
      desc = "Go to environment variable definition in file",
    },
    EcologFzf = {
      callback = function()
        local has_fzf, fzf = pcall(require, "ecolog.integrations.fzf")
        if not has_fzf or not config.integrations.fzf then
          notify(
            "FZF integration is not enabled. Enable it in your setup with integrations.fzf = true",
            vim.log.levels.ERROR
          )
          return
        end
        if not fzf._initialized then
          fzf.setup(type(config.integrations.fzf) == "table" and config.integrations.fzf or {})

          fzf._initialized = true
        end
        fzf.env_picker()
      end,
      desc = "Open FZF environment variable picker",
    },
    EcologCopy = {
      callback = function(args)
        local filetype = vim.bo.filetype
        local var_name = args.args

        if var_name == "" then
          if config.provider_patterns.extract then
            local available_providers = providers.get_providers(filetype)
            var_name = utils.get_var_word_under_cursor(available_providers)
          else
            local word = vim.fn.expand("<cword>")
            if word and #word > 0 then
              var_name = word
            end
          end
        end

        if not var_name or #var_name == 0 then
          notify("No environment variable specified or found at cursor", vim.log.levels.WARN)
          return
        end

        env_loader.load_environment(config, state)

        local var = state.env_vars[var_name]
        if not var then
          notify(string.format("Environment variable '%s' not found", var_name), vim.log.levels.WARN)
          return
        end

        local value = var.raw_value
        vim.fn.setreg("+", value)
        vim.fn.setreg('"', value)
        notify(string.format("Copied raw value of '%s' to clipboard", var_name), vim.log.levels.INFO)
      end,
      nargs = "?",
      desc = "Copy environment variable value to clipboard",
    },
    EcologAWSSelect = {
      callback = function()
        if not config.integrations.secret_managers or not config.integrations.secret_managers.aws then
          notify("AWS Secrets Manager is not configured", vim.log.levels.ERROR)
          return
        end
        local aws = get_secret_manager("aws")
        aws.select()
      end,
      desc = "Select AWS Secrets Manager secrets to load",
    },
    EcologVaultSelect = {
      callback = function()
        if not config.integrations.secret_managers or not config.integrations.secret_managers.vault then
          notify("HashiCorp Vault is not configured", vim.log.levels.ERROR)
          return
        end
        local vault = get_secret_manager("vault")
        vault.select()
      end,
      desc = "Select HashiCorp Vault secrets to load",
    },
  }

  for name, cmd in pairs(commands) do
    api.nvim_create_user_command(name, cmd.callback, {
      nargs = cmd.nargs,
      desc = cmd.desc,
      complete = cmd.complete,
    })
  end
end

---@param opts? EcologConfig
function M.setup(opts)
  if _setup_done then
    return
  end
  _setup_done = true

  -- Merge user options with defaults
  local config = vim.tbl_deep_extend("force", DEFAULT_CONFIG, opts or {})

  -- Add this near the start of setup
  state.selected_env_file = nil -- Make sure this is tracked in state

  -- Normalize provider_patterns to table format
  if type(config.provider_patterns) == "boolean" then
    config.provider_patterns = {
      extract = config.provider_patterns,
      cmp = config.provider_patterns,
    }
  elseif type(config.provider_patterns) == "table" then
    config.provider_patterns = vim.tbl_deep_extend("force", {
      extract = true,
      cmp = true,
    }, config.provider_patterns)
  end

  state.last_opts = config

  if config.integrations.blink_cmp then
    config.integrations.nvim_cmp = false
  end

  -- Core setup
  require("ecolog.highlights").setup()
  shelter.setup({
    config = config.shelter.configuration,
    partial = config.shelter.modules,
  })
  types.setup({
    types = config.types,
    custom_types = config.custom_types,
  })

  -- Schedule integration setup
  table.insert(_lazy_setup_tasks, function() setup_integrations(config) end)

  -- Initialize secret managers if configured
  if config.integrations.secret_managers then
    schedule(function()
      -- Initialize AWS Secrets Manager
      if config.integrations.secret_managers.aws then
        local aws = get_secret_manager("aws")
        aws.load_aws_secrets(config.integrations.secret_managers.aws)
      end

      -- Initialize HashiCorp Vault
      if config.integrations.secret_managers.vault then
        local vault = get_secret_manager("vault")
        vault.load_vault_secrets(config.integrations.secret_managers.vault)
      end
    end)
  end

  -- Initial environment file selection
  local initial_env_files = utils.find_env_files({
    path = config.path,
    preferred_environment = config.preferred_environment,
    env_file_pattern = config.env_file_pattern,
    sort_fn = config.sort_fn,
  })

  if #initial_env_files > 0 then
    handle_env_file_selection(initial_env_files[1], config)
  end

  schedule(function()
    env_loader.load_environment(config, state)
    file_watcher.setup_watcher(config, state, M.refresh_env_vars)

    -- Execute lazy setup tasks
    for _, task in ipairs(_lazy_setup_tasks) do
      task()
    end

    -- Create commands
    create_commands(config)
  end)

  if opts.vim_env then
    schedule(function()
      get_env_module()
    end)
  end
end

-- Status line integration
function M.get_status()
  if not state.last_opts or not state.last_opts.integrations.statusline then
    return ""
  end

  local config = state.last_opts.integrations.statusline
  if type(config) == "table" and config.hidden_mode and not state.selected_env_file then
    return ""
  end

  return require("ecolog.integrations.statusline").get_statusline()
end

function M.get_lualine()
  if not state.last_opts or not state.last_opts.integrations.statusline then
    return ""
  end

  local config = state.last_opts.integrations.statusline
  if type(config) == "table" and config.hidden_mode and not state.selected_env_file then
    return ""
  end

  return require("ecolog.integrations.statusline").lualine()
end

-- State access
function M.get_state()
  return state
end

-- Configuration access
function M.get_config()
  return state.last_opts or DEFAULT_CONFIG
end

return M

