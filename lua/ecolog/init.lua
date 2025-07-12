local M = {}

local api = vim.api
local fn = vim.fn
local notify = vim.notify
local schedule = vim.schedule

---@class EcologConfig
---@field path string Path to search for .env files
---@field shelter ShelterConfig Shelter mode configuration
---@field integrations IntegrationsConfig Integration settings
---@field types boolean|table Enable all types or specific type configuration
---@field custom_types table Custom type definitions
---@field preferred_environment string Preferred environment name
---@field load_shell LoadShellConfig Shell variables loading configuration
---@field env_file_patterns string[] Custom glob patterns for matching env files (e.g., ".env.*", "config/.env*")
---@field sort_file_fn? function Custom function for sorting env files
---@field sort_fn? function Deprecated: Use sort_file_fn instead
---@field sort_var_fn? function Custom function for sorting environment variables when returning from get_env_vars
---@field provider_patterns table|boolean Controls how environment variables are extracted from code
---@field vim_env boolean Enable vim.env integration
---@field interpolation boolean|InterpolationConfig Enable/disable and configure environment variable interpolation
---@field providers? table|table[] Custom provider(s) for environment variable detection and completion

---@class IntegrationsConfig
---@field lsp boolean Enable LSP integration
---@field lspsaga boolean Enable LSPSaga integration
---@field nvim_cmp boolean|table Enable nvim-cmp integration
---@field blink_cmp boolean|table Enable blink-cmp integration
---@field omnifunc boolean Enable omnifunc integration
---@field fzf boolean|table Enable fzf integration
---@field statusline boolean|table Enable statusline integration
---@field snacks boolean|table Enable snacks integration
---@field secret_managers? table Secret manager configurations
---@field secret_managers.aws? boolean|LoadAwsSecretsConfig AWS Secrets Manager configuration
---@field secret_managers.vault? boolean|LoadVaultSecretsConfig HashiCorp Vault configuration

---@class InterpolationConfig
---@field enabled boolean Enable/disable interpolation
---@field max_iterations number Maximum iterations for nested interpolation
---@field warn_on_undefined boolean Whether to warn about undefined variables
---@field fail_on_cmd_error boolean Whether to fail on command substitution errors
---@field features table Control specific interpolation features
---@field features.variables boolean Enable variable interpolation ($VAR, ${VAR})
---@field features.defaults boolean Enable default value syntax (${VAR:-default})
---@field features.alternates boolean Enable alternate value syntax (${VAR-alternate})
---@field features.commands boolean Enable command substitution ($(command))
---@field features.escapes boolean Enable escape sequences (\n, \t, etc.)

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
    omnifunc = false,
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
  env_file_patterns = nil,
  sort_file_fn = nil,
  sort_var_fn = nil,
  interpolation = {
    enabled = false,
    max_iterations = 10,
    warn_on_undefined = true,
    fail_on_cmd_error = false,
    features = {
      variables = true,
      defaults = true,
      alternates = true,
      commands = true,
      escapes = true,
    },
  },
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

local _loaded_modules = {}
local _loading = {}
local _setup_done = false
local _lazy_setup_tasks = {}

-- Improved synchronization primitives
local _state_lock = false
local _state_waiters = {}
local _module_locks = {}
local _lock_start_time = 0
local _lock_owner = nil
local _lock_count = 0
local _pending_operations = 0

-- Lock-free read operations for better performance
local function safe_read_state(key)
  -- Direct access for read-only operations
  if key then
    return state[key]
  end
  return state
end

-- Lightweight lock for critical sections only
local function try_acquire_lock(timeout_ms)
  timeout_ms = timeout_ms or 1000
  local start_time = vim.loop.now()
  
  while _state_lock do
    local elapsed = vim.loop.now() - start_time
    if elapsed > timeout_ms then
      return false
    end
    vim.wait(10)
  end
  
  _state_lock = true
  _lock_start_time = vim.loop.now()
  _lock_owner = debug.traceback("Lock acquired", 2)
  return true
end

-- Enhanced mutex with better error handling
local function acquire_state_lock(timeout_ms)
  timeout_ms = timeout_ms or 2000
  
  -- Track pending operations
  _pending_operations = _pending_operations + 1
  
  -- Quick path for uncontended case
  if not _state_lock then
    _state_lock = true
    _lock_start_time = vim.loop.now()
    _lock_owner = debug.traceback("Lock acquired", 2)
    return true
  end
  
  -- Check if lock is held too long
  if _lock_start_time > 0 then
    local elapsed = vim.loop.now() - _lock_start_time
    if elapsed > 15000 then -- 15 seconds is definitely too long
      vim.notify(
        string.format(
          "Lock held for %dms by:\n%s\nForcing unlock", 
          elapsed, 
          _lock_owner or "unknown"
        ), 
        vim.log.levels.ERROR
      )
      _state_lock = false
      _lock_start_time = 0
      _lock_owner = nil
    end
  end
  
  -- Try to acquire with timeout
  local start_time = vim.loop.now()
  local wait_time = 5
  
  while _state_lock do
    local elapsed = vim.loop.now() - start_time
    if elapsed > timeout_ms then
      _pending_operations = math.max(0, _pending_operations - 1)
      return false
    end
    
    vim.wait(math.min(wait_time, 50))
    wait_time = math.min(wait_time * 1.2, 100)
  end
  
  _state_lock = true
  _lock_start_time = vim.loop.now()
  _lock_owner = debug.traceback("Lock acquired", 2)
  return true
end

local function release_state_lock()
  _state_lock = false
  _lock_start_time = 0
  _lock_owner = nil
  _pending_operations = math.max(0, _pending_operations - 1)
  
  -- Wake up any waiting operations
  for _, waiter in ipairs(_state_waiters) do
    if waiter then
      vim.schedule(waiter)
    end
  end
  _state_waiters = {}
end

-- Thread-safe module loading with proper synchronization
local function require_module(name)
  if not name or type(name) ~= "string" then
    vim.notify("Invalid module name: " .. tostring(name), vim.log.levels.ERROR)
    return {}
  end

  -- Check if module is already loaded (fast path)
  if _loaded_modules[name] then
    return _loaded_modules[name]
  end

  -- Acquire lock for this specific module
  if _module_locks[name] then
    -- Another thread is loading this module, wait for it
    local start_time = vim.loop.now()
    while _module_locks[name] do
      if vim.loop.now() - start_time > 5000 then
        vim.notify("Module lock timeout for: " .. name, vim.log.levels.WARN)
        break
      end
      vim.wait(10)
    end
    
    -- Check again if module was loaded while waiting
    if _loaded_modules[name] then
      return _loaded_modules[name]
    end
  end

  -- Set lock for this module
  _module_locks[name] = true

  -- Check for circular dependencies
  if _loading[name] then
    _module_locks[name] = nil
    vim.notify("Circular dependency detected: " .. name .. ". Using fallback module.", vim.log.levels.WARN)
    local stub = {}
    setmetatable(stub, {
      __index = function(_, key)
        vim.notify(
          "Attempted to access '" .. key .. "' from stub module due to circular dependency",
          vim.log.levels.WARN
        )
        return function() end -- Return no-op function
      end,
    })
    return stub
  end

  _loading[name] = true
  local success, module = pcall(require, name)
  _loading[name] = nil

  if not success then
    vim.notify("Failed to load module: " .. name .. ". Error: " .. tostring(module), vim.log.levels.ERROR)
    -- Return stub module instead of failing
    local stub = {}
    setmetatable(stub, {
      __index = function(_, key)
        vim.notify("Attempted to access '" .. key .. "' from failed module: " .. name, vim.log.levels.WARN)
        return function() end -- Return no-op function
      end,
    })
    _loaded_modules[name] = stub
    _module_locks[name] = nil
    return stub
  end

  _loaded_modules[name] = module
  _module_locks[name] = nil
  return module
end

local utils = require_module("ecolog.utils")
local providers = utils.get_module("ecolog.providers")
local select = utils.get_module("ecolog.select")
local peek = utils.get_module("ecolog.peek")
local shelter = utils.get_module("ecolog.shelter")
local types = utils.get_module("ecolog.types")
local env_loader = require_module("ecolog.env_loader")
local file_watcher = require_module("ecolog.file_watcher")

local function get_env_module()
  if not state._env_module then
    state._env_module = require("ecolog.env")
    state._env_module.setup()
  end
  return state._env_module
end

local function get_secret_manager(name)
  if not state._secret_managers[name] then
    state._secret_managers[name] = require("ecolog.integrations.secret_managers." .. name)
  end
  return state._secret_managers[name]
end

function M.refresh_env_vars(opts)
  -- Use async approach to avoid blocking
  vim.schedule(function()
    if not acquire_state_lock(5000) then
      vim.notify("Refresh operation queued due to lock contention", vim.log.levels.INFO)
      -- Queue the operation for later
      vim.defer_fn(function()
        M.refresh_env_vars(opts)
      end, 1000)
      return
    end

    local success, err = pcall(function()
      state.cached_env_files = nil
      state.file_cache_opts = nil

      local base_opts = state.last_opts or DEFAULT_CONFIG
      opts = vim.tbl_deep_extend("force", base_opts, opts or {})
      env_loader.load_environment(opts, state, true)

      if opts.integrations.statusline then
        local statusline = require("ecolog.integrations.statusline")
        statusline.invalidate_cache()
      end

      if opts.integrations.secret_managers then
        if opts.integrations.secret_managers.aws then
          local aws = get_secret_manager("aws")
          aws.load_aws_secrets(opts.integrations.secret_managers.aws)
        end

        if opts.integrations.secret_managers.vault then
          local vault = get_secret_manager("vault")
          vault.load_vault_secrets(opts.integrations.secret_managers.vault)
        end
      end
    end)

    release_state_lock()

    if not success then
      vim.notify("Error in refresh_env_vars: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end

---Get all environment variables
---@return table<string, EnvVarInfo> Environment variables with their metadata
function M.get_env_vars()
  -- Quick read-only check first
  local env_vars = safe_read_state("env_vars")
  local selected_file = safe_read_state("selected_env_file")
  
  -- If we have vars and file is still valid, return immediately
  if env_vars and next(env_vars) ~= nil then
    if not selected_file or vim.fn.filereadable(selected_file) == 1 then
      return vim.deepcopy(env_vars)
    end
  end
  
  -- Need to modify state, acquire lock
  if not acquire_state_lock(3000) then
    -- Fallback: return what we have
    return vim.deepcopy(env_vars or {})
  end

  local result = {}
  local success, err = pcall(function()
    if state.selected_env_file and vim.fn.filereadable(state.selected_env_file) == 0 then
      state.selected_env_file = nil
      state.env_vars = {}
      state._env_line_cache = {}
      env_loader.load_environment(state.last_opts or DEFAULT_CONFIG, state, true)
    end

    if next(state.env_vars) == nil then
      env_loader.load_environment(state.last_opts or DEFAULT_CONFIG, state)
    end

    result = vim.deepcopy(state.env_vars)
  end)

  release_state_lock()

  if not success then
    vim.notify("Error in get_env_vars: " .. tostring(err), vim.log.levels.ERROR)
    return {}
  end

  return result
end

local function handle_env_file_selection(file, config)
  if not file then
    return
  end

  -- Note: This function is called from within already locked contexts,
  -- so we don't need to acquire the lock here again to avoid deadlocks
  local success, err = pcall(function()
    state.selected_env_file = file
    config.preferred_environment = fn.fnamemodify(file, ":t"):gsub("^%.env%.", "")
    file_watcher.setup_watcher(config, state, M.refresh_env_vars)
    state.cached_env_files = nil
    
    -- Don't call M.refresh_env_vars here as it would cause deadlock
    -- Instead, directly call the internal function
    state.cached_env_files = nil
    state.file_cache_opts = nil
    local base_opts = state.last_opts or DEFAULT_CONFIG
    local opts = vim.tbl_deep_extend("force", base_opts, config or {})
    env_loader.load_environment(opts, state, true)
    
    if state._env_module then
      state._env_module.update_env_vars()
    end
    notify(string.format("Selected environment file: %s", fn.fnamemodify(file, ":t")), vim.log.levels.INFO)
  end)

  if not success then
    vim.notify("Error in handle_env_file_selection: " .. tostring(err), vim.log.levels.ERROR)
  end
end

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

  if config.integrations.omnifunc then
    local omnifunc = require("ecolog.integrations.cmp.omnifunc")
    omnifunc.setup(config.integrations.omnifunc, state.env_vars, providers, shelter)
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
      callback = function(args)
        if args.args and args.args ~= "" then
          local file_path = vim.fn.expand(args.args)
          if vim.fn.filereadable(file_path) == 1 then
            handle_env_file_selection(file_path, config)
          else
            notify(string.format("Environment file not found: %s", file_path), vim.log.levels.ERROR)
          end
          return
        end

        select.select_env_file({
          path = config.path,
          active_file = state.selected_env_file,
          env_file_patterns = config.env_file_patterns,
          sort_file_fn = config.sort_file_fn,
          sort_var_fn = config.sort_var_fn,
          preferred_environment = config.preferred_environment,
        }, function(file)
          handle_env_file_selection(file, config)
        end)
      end,
      nargs = "?",
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

        if var.source == "shell" then
          notify("Cannot go to definition of shell variables", vim.log.levels.WARN)
          return
        end

        if var.source:match("^asm:") or var.source:match("^vault:") then
          notify("Cannot go to definition of secret manager variables", vim.log.levels.WARN)
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
    EcologAWSConfig = {
      callback = function(args)
        local aws = get_secret_manager("aws")
        if args.args ~= "" then
          local valid_options = { region = true, profile = true, secrets = true }
          local option = args.args:lower()
          if valid_options[option] then
            aws.instance:select_config(option)
          else
            vim.notify("Invalid AWS config option: " .. option, vim.log.levels.ERROR)
          end
        else
          aws.instance:select_config()
        end
      end,
      nargs = "?",
      desc = "Configure AWS Secrets Manager settings (region, profile, secrets)",
      complete = function(arglead)
        return vim.tbl_filter(function(item)
          return item:find(arglead, 1, true)
        end, { "region", "profile", "secrets" })
      end,
    },
    EcologVaultConfig = {
      callback = function(args)
        local vault = get_secret_manager("vault")
        if args.args ~= "" then
          local valid_options = { organization = true, project = true, apps = true }
          local option = args.args:lower()
          if valid_options[option] then
            vault.instance:select_config(option)
          else
            vim.notify("Invalid Vault config option: " .. option, vim.log.levels.ERROR)
          end
        else
          vault.instance:select_config()
        end
      end,
      nargs = "?",
      desc = "Configure HCP Vault settings (organization, project, apps)",
      complete = function(arglead)
        return vim.tbl_filter(function(item)
          return item:find(arglead, 1, true)
        end, { "organization", "project", "apps" })
      end,
    },
    EcologInterpolationToggle = {
      callback = function()
        if not state.last_opts then
          notify("Ecolog not initialized", vim.log.levels.ERROR)
          return
        end

        state.last_opts.interpolation.enabled = not state.last_opts.interpolation.enabled

        M.refresh_env_vars(state.last_opts)

        notify(
          string.format("Interpolation %s", state.last_opts.interpolation.enabled and "enabled" or "disabled"),
          vim.log.levels.INFO
        )
      end,
      desc = "Toggle environment variable interpolation",
    },
    EcologShellToggle = {
      callback = function()
        if not state.last_opts then
          notify("Ecolog not initialized", vim.log.levels.ERROR)
          return
        end

        local current_state
        if type(state.last_opts.load_shell) == "boolean" then
          current_state = not state.last_opts.load_shell
          state.last_opts.load_shell = {
            enabled = current_state,
            override = false,
            filter = nil,
            transform = nil,
          }
        else
          current_state = not state.last_opts.load_shell.enabled
          state.last_opts.load_shell.enabled = current_state
        end

        M.refresh_env_vars(state.last_opts)

        notify(string.format("Shell variables %s", current_state and "loaded" or "unloaded"), vim.log.levels.INFO)
      end,
      desc = "Toggle shell variables loading",
    },
    EcologEnvGet = {
      callback = function(cmd_opts)
        local env_module = get_env_module()
        local var = cmd_opts.args
        local value = env_module.get(var)
        if value then
          print(value.value)
        else
          print("Variable not found: " .. var)
        end
      end,
      nargs = 1,
      desc = "Get environment variable value",
    },
    EcologEnvSet = {
      callback = function(cmd_opts)
        local env_module = get_env_module()
        local args = vim.split(cmd_opts.args, " ", { plain = true })
        if #args < 2 then
          local key = args[1]
          vim.ui.input({ prompt = string.format("Value for %s: ", key) }, function(input)
            if input then
              local result = env_module.set(key, input)
              if result then
                print(string.format("Set %s = %s", key, input))
              else
                print("Failed to set variable: " .. key)
              end
            end
          end)
          return
        end

        local key = args[1]
        local value = table.concat(args, " ", 2)

        local result = env_module.set(key, value)
        if result then
          print(string.format("Set %s = %s", key, value))
        else
          print("Failed to set variable: " .. key)
        end
      end,
      nargs = "+",
      desc = "Set environment variable value",
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

---@param config EcologConfig
local function validate_config(config)
  -- Handle deprecated env_file_pattern if it exists
  if config.env_file_pattern ~= nil then
    notify(
      "env_file_pattern is deprecated, please use env_file_patterns instead with glob patterns (e.g., '.env.*', 'config/.env*')",
      vim.log.levels.WARN
    )
    if type(config.env_file_pattern) == "table" and #config.env_file_pattern > 0 then
      config.env_file_patterns = config.env_file_pattern
    end
    config.env_file_pattern = nil
  end

  -- Handle backward compatibility for sort_fn -> sort_file_fn
  if config.sort_fn ~= nil and config.sort_file_fn == nil then
    notify("sort_fn is deprecated, please use sort_file_fn instead", vim.log.levels.WARN)
    config.sort_file_fn = config.sort_fn
  end

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
end

function M.setup(opts)
  if not acquire_state_lock() then
    vim.notify("Failed to acquire state lock for setup", vim.log.levels.ERROR)
    return
  end

  local success, err = pcall(function()
    if _setup_done then
      return
    end
    _setup_done = true

    local config = vim.tbl_deep_extend("force", DEFAULT_CONFIG, opts or {})
    validate_config(config)

    if config.providers then
      local providers = require("ecolog.providers")
      if vim.islist(config.providers) then
        providers.register_many(config.providers)
      else
        providers.register(config.providers)
      end
    end

    if type(config.interpolation) == "boolean" then
      config.interpolation = {
        enabled = config.interpolation,
        max_iterations = DEFAULT_CONFIG.interpolation.max_iterations,
        warn_on_undefined = DEFAULT_CONFIG.interpolation.warn_on_undefined,
        fail_on_cmd_error = DEFAULT_CONFIG.interpolation.fail_on_cmd_error,
        features = vim.deepcopy(DEFAULT_CONFIG.interpolation.features),
      }
    elseif type(config.interpolation) == "table" then
      if config.interpolation.enabled == nil then
        config.interpolation.enabled = true
      end

      if config.interpolation.features then
        config.interpolation.features =
          vim.tbl_deep_extend("force", DEFAULT_CONFIG.interpolation.features, config.interpolation.features)
      end

      config.interpolation = vim.tbl_deep_extend("force", DEFAULT_CONFIG.interpolation, config.interpolation)
    end

    state.selected_env_file = nil
    state.last_opts = config

    if config.integrations.blink_cmp then
      config.integrations.nvim_cmp = false
    end

    require("ecolog.highlights").setup()
    shelter.setup({
      config = config.shelter.configuration,
      partial = config.shelter.modules,
    })
    types.setup({
      types = config.types,
      custom_types = config.custom_types,
    })

    if config.integrations.secret_managers then
      if config.integrations.secret_managers.aws then
        local aws = get_secret_manager("aws")
        aws.load_aws_secrets(config.integrations.secret_managers.aws)
      end

      if config.integrations.secret_managers.vault then
        local vault = get_secret_manager("vault")
        vault.load_vault_secrets(config.integrations.secret_managers.vault)
      end
    end

    local initial_env_files = utils.find_env_files({
      path = config.path,
      preferred_environment = config.preferred_environment,
      env_file_patterns = config.env_file_patterns,
      sort_file_fn = config.sort_file_fn,
      sort_var_fn = config.sort_var_fn,
    })

    if #initial_env_files > 0 then
      handle_env_file_selection(initial_env_files[1], config)
    end

    table.insert(_lazy_setup_tasks, function()
      setup_integrations(config)
    end)

    schedule(function()
      env_loader.load_environment(config, state)
      file_watcher.setup_watcher(config, state, M.refresh_env_vars)

      for _, task in ipairs(_lazy_setup_tasks) do
        local task_success, task_err = pcall(task)
        if not task_success then
          vim.notify("Error in lazy setup task: " .. tostring(task_err), vim.log.levels.ERROR)
        end
      end

      create_commands(config)
    end)

    if opts and opts.vim_env then
      schedule(function()
        get_env_module()
      end)
    end
  end)

  release_state_lock()

  if not success then
    vim.notify("Error in setup: " .. tostring(err), vim.log.levels.ERROR)
  end
end

function M.get_status()
  -- Lock-free status check
  local selected_file = safe_read_state("selected_env_file")
  local opts = safe_read_state("last_opts")
  
  if not opts or not opts.integrations.statusline then
    return ""
  end

  local config = opts.integrations.statusline
  if type(config) == "table" and config.hidden_mode and not selected_file then
    return ""
  end

  -- Simple fallback status
  if selected_file then
    return vim.fn.fnamemodify(selected_file, ":t")
  end
  
  return ""
end

function M.get_lualine()
  -- Lock-free lualine status
  local selected_file = safe_read_state("selected_env_file")
  local opts = safe_read_state("last_opts")
  
  if not opts or not opts.integrations.statusline then
    return ""
  end

  local config = opts.integrations.statusline
  if type(config) == "table" and config.hidden_mode and not selected_file then
    return ""
  end

  -- Simple fallback status for lualine
  if selected_file then
    return vim.fn.fnamemodify(selected_file, ":t")
  end
  
  return ""
end

function M.get_state()
  -- Lock-free shallow copy for most fields
  local result = {}
  for k, v in pairs(state) do
    if k == "_env_line_cache" then
      -- Skip cache to avoid expensive copy
      result[k] = {}
    elseif type(v) ~= "table" then
      result[k] = v
    else
      -- Safe shallow copy for tables
      result[k] = vim.tbl_extend("force", {}, v)
    end
  end
  return result
end

---Get lock health information for debugging
---@return table health_info
function M.get_lock_health()
  return {
    state_lock = _state_lock,
    lock_start_time = _lock_start_time,
    lock_duration = _lock_start_time > 0 and (vim.loop.now() - _lock_start_time) or 0,
    lock_owner = _lock_owner,
    pending_operations = _pending_operations,
    waiting_operations = #_state_waiters,
    module_locks = vim.tbl_count(_module_locks),
  }
end

---Force release all locks (emergency function)
function M.force_unlock_all()
  vim.notify("Force unlocking all state locks", vim.log.levels.WARN)
  _state_lock = false
  _lock_start_time = 0
  _lock_owner = nil
  _pending_operations = 0
  _state_waiters = {}
  _module_locks = {}
end

function M.get_config()
  -- Use lock-free read for config (read-only operation)
  local config = safe_read_state("last_opts")
  if config then
    return vim.deepcopy(config)
  end
  return vim.deepcopy(DEFAULT_CONFIG)
end

return M
