local M = {}

-- Compatibility layer for vim.loop -> vim.uv migration
local uv = vim.uv or vim.loop

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
---@field monorepo? MonorepoConfig Monorepo support configuration

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
---@field disable_security boolean Whether to disable security sanitization for command substitution
---@field features table Control specific interpolation features
---@field features.variables boolean Enable variable interpolation ($VAR, ${VAR})
---@field features.defaults boolean Enable default value syntax (${VAR:-default})
---@field features.alternates boolean Enable alternate value syntax (${VAR-alternate})
---@field features.commands boolean Enable command substitution ($(command))
---@field features.escapes boolean Enable escape sequences (\n, \t, etc.)

local DEFAULT_CONFIG = {
  path = nil, -- Set dynamically in setup()
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
    disable_security = false,
    features = {
      variables = true,
      defaults = true,
      alternates = true,
      commands = true,
      escapes = true,
    },
  },
  monorepo = false,
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
  env_vars_overrides = {},
  cached_env_files = nil,
  last_opts = nil,
  file_cache_opts = nil,
  current_watcher_group = nil,
  selected_env_file = nil,
  manual_file_selection = false,  -- Track if the user manually selected a file
  _env_module = nil,
  _file_watchers = {},
  _env_line_cache = setmetatable({}, { __mode = "kv" }),
  _secret_managers = setmetatable({}, { __mode = "v" }),
  initialized = false,
}

local _loaded_modules = {}
local _loading = {}
local _setup_done = false
local _lazy_setup_tasks = {}

local MAX_CACHE_SIZE = 1000
local _cache_stats = { hits = 0, misses = 0, cleanups = 0 }
local _last_cleanup = 0
local CLEANUP_INTERVAL = 300000

local _config_cache = {}
local _config_cache_key = nil

local _state_lock = false
local _module_locks = {}
local _lock_start_time = 0
local _pending_operations = 0

local _validation_errors = 0
local _last_validation_check = 0
local VALIDATION_INTERVAL = 30000

local _health_timer = nil

local function should_cleanup_cache()
  local now = uv.now()
  return now - _last_cleanup > CLEANUP_INTERVAL
end

local function cleanup_caches()
  if not should_cleanup_cache() then
    return
  end

  _last_cleanup = uv.now()
  _cache_stats.cleanups = _cache_stats.cleanups + 1

  local module_count = 0
  for _ in pairs(_loaded_modules) do
    module_count = module_count + 1
  end

  if module_count > MAX_CACHE_SIZE then
    local essential_modules = {
      "ecolog.utils",
      "ecolog.providers",
      "ecolog.env_loader",
      "ecolog.file_watcher",
    }

    local new_modules = {}
    for _, module_name in ipairs(essential_modules) do
      if _loaded_modules[module_name] then
        new_modules[module_name] = _loaded_modules[module_name]
      end
    end
    _loaded_modules = new_modules
  end

  local cache_size = 0
  for _ in pairs(state._env_line_cache) do
    cache_size = cache_size + 1
  end

  if cache_size > MAX_CACHE_SIZE then
    state._env_line_cache = setmetatable({}, { __mode = "kv" })
  end
end

local function get_cache_stats()
  return vim.tbl_extend("force", _cache_stats, {
    module_count = vim.tbl_count(_loaded_modules),
    line_cache_size = vim.tbl_count(state._env_line_cache),
    last_cleanup = _last_cleanup,
  })
end

local function require_module(name)
  if not name or type(name) ~= "string" then
    vim.notify("Invalid module name: " .. tostring(name), vim.log.levels.ERROR)
    return {}
  end

  if _loaded_modules[name] then
    _cache_stats.hits = _cache_stats.hits + 1
    return _loaded_modules[name]
  end

  _cache_stats.misses = _cache_stats.misses + 1

  cleanup_caches()

  if _module_locks[name] then
    local start_time = uv.now()
    while _module_locks[name] do
      if uv.now() - start_time > 5000 then
        vim.notify("Module lock timeout for: " .. name, vim.log.levels.WARN)
        break
      end
      vim.wait(10)
    end

    if _loaded_modules[name] then
      return _loaded_modules[name]
    end
  end

  _module_locks[name] = true

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
        return function() end
      end,
    })
    return stub
  end

  _loading[name] = true
  local success, module = pcall(require, name)
  _loading[name] = nil

  if not success then
    vim.notify("Failed to load module: " .. name .. ". Error: " .. tostring(module), vim.log.levels.ERROR)

    local stub = {}
    setmetatable(stub, {
      __index = function(_, key)
        vim.notify("Attempted to access '" .. key .. "' from failed module: " .. name, vim.log.levels.WARN)
        return function() end
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

local function start_health_monitoring()
  if _health_timer then
    return
  end

  _health_timer = uv.new_timer()
  _health_timer:start(
    60000,
    60000,
    vim.schedule_wrap(function()
      if _state_lock and (uv.now() - _lock_start_time) > 30000 then
        vim.notify("Detected long-running lock - auto-recovering", vim.log.levels.WARN)
        _state_lock = false
        _lock_start_time = 0
      end

      if vim.tbl_count(_loaded_modules) > MAX_CACHE_SIZE * 2 then
        cleanup_caches()
      end
    end)
  )
end

local function stop_health_monitoring()
  if _health_timer then
    _health_timer:stop()
    _health_timer:close()
    _health_timer = nil
  end
end

local function safe_read_state(key)
  local now = uv.now()
  if now - _last_validation_check > VALIDATION_INTERVAL then
    _last_validation_check = now

    if state.selected_env_file and not state.env_vars then
      _validation_errors = _validation_errors + 1
      if _validation_errors > 3 then
        vim.notify("State inconsistency detected - consider running :EcologRefresh", vim.log.levels.WARN)
        _validation_errors = 0
      end
    end
  end

  if key then
    return state[key]
  end
  return state
end

local function acquire_state_lock(timeout_ms)
  timeout_ms = timeout_ms or 1000

  if not _state_lock then
    _state_lock = true
    _lock_start_time = uv.now()
    return true
  end

  local start_time = uv.now()
  local wait_time = 1

  while _state_lock do
    local elapsed = uv.now() - start_time
    if elapsed > timeout_ms then
      return false
    end

    if _lock_start_time > 0 and (uv.now() - _lock_start_time) > 10000 then
      _state_lock = false
      _lock_start_time = 0
      break
    end

    vim.wait(wait_time)
    wait_time = math.min(wait_time * 1.5, 20)
  end

  _state_lock = true
  _lock_start_time = uv.now()
  return true
end

local function release_state_lock()
  _state_lock = false
  _lock_start_time = 0
end

local utils, providers, select, peek, shelter, types, env_loader, file_watcher

local function get_utils()
  if not utils then
    utils = require_module("ecolog.utils")
  end
  return utils
end

local function get_providers()
  if not providers then
    providers = get_utils().get_module("ecolog.providers")
  end
  return providers
end

local function get_select()
  if not select then
    select = get_utils().get_module("ecolog.select")
  end
  return select
end

local function get_peek()
  if not peek then
    peek = get_utils().get_module("ecolog.peek")
  end
  return peek
end

local function get_shelter()
  if not shelter then
    shelter = get_utils().get_module("ecolog.shelter")
  end
  return shelter
end

local function get_types()
  if not types then
    types = get_utils().get_module("ecolog.types")
  end
  return types
end

local function get_env_loader()
  if not env_loader then
    env_loader = require_module("ecolog.env_loader")
  end
  return env_loader
end

local function get_file_watcher()
  if not file_watcher then
    file_watcher = require_module("ecolog.file_watcher")
  end
  return file_watcher
end

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

function M.refresh_env_vars(opts, retry_count)
  retry_count = retry_count or 0

  vim.schedule(function()
    if not acquire_state_lock(5000) then
      if retry_count < 3 then
        vim.notify("Refresh operation queued due to lock contention", vim.log.levels.INFO)
        vim.defer_fn(function()
          M.refresh_env_vars(opts, retry_count + 1)
        end, math.min(1000 * (retry_count + 1), 5000))
      else
        vim.notify("Refresh failed after 3 retries - system may be overloaded", vim.log.levels.WARN)
      end
      return
    end

    local success, err = pcall(function()
      state.cached_env_files = nil
      state.file_cache_opts = nil

      local base_opts = state.last_opts or DEFAULT_CONFIG
      opts = vim.tbl_deep_extend("force", base_opts, opts or {})

      if opts.monorepo and not opts._workspace_file_handled then
        local monorepo = require("ecolog.monorepo")
        opts = monorepo.integrate_with_ecolog_config(opts)
      end

      get_env_loader().load_environment(opts, state, true)

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
  cleanup_caches()

  local env_vars = safe_read_state("env_vars")
  local selected_file = safe_read_state("selected_env_file")

  if env_vars and next(env_vars) ~= nil then
    if not selected_file or vim.fn.filereadable(selected_file) == 1 then
      local result = {}
      for k, v in pairs(env_vars) do
        result[k] = v
      end
      local overrides = safe_read_state("env_vars_overrides")
      if overrides then
        for k, v in pairs(overrides) do
          result[k] = v
        end
      end
      return result
    end
  end

  if not acquire_state_lock(3000) then
    if next(env_vars or {}) == nil then
      vim.notify("Environment loading in progress - using cached data", vim.log.levels.INFO)
    end
    local result = {}
    if env_vars then
      for k, v in pairs(env_vars) do
        result[k] = v
      end
    end
    local overrides = safe_read_state("env_vars_overrides")
    if overrides then
      for k, v in pairs(overrides) do
        result[k] = v
      end
    end
    return result
  end

  local result = {}
  local success, err = pcall(function()
    if state.selected_env_file and vim.fn.filereadable(state.selected_env_file) == 0 then
      local deleted_file = state.selected_env_file
      state.selected_env_file = nil
      state.env_vars = {}
      state._env_line_cache = {}
      get_env_loader().load_environment(state.last_opts or DEFAULT_CONFIG, state, true)

      if state.selected_env_file then
        local utils_mod = get_utils()
        local new_display_name =
          utils_mod.get_env_file_display_name(state.selected_env_file, state.last_opts or DEFAULT_CONFIG)
        local deleted_display_name =
          utils_mod.get_env_file_display_name(deleted_file, state.last_opts or DEFAULT_CONFIG)
        vim.notify(
          string.format("Selected file '%s' was deleted. Switched to: %s", deleted_display_name, new_display_name),
          vim.log.levels.INFO
        )
      else
        local utils_mod = get_utils()
        local deleted_display_name =
          utils_mod.get_env_file_display_name(deleted_file, state.last_opts or DEFAULT_CONFIG)
        vim.notify(
          string.format("Selected file '%s' was deleted. No environment files found.", deleted_display_name),
          vim.log.levels.WARN
        )
      end
    end

    if next(state.env_vars) == nil then
      get_env_loader().load_environment(state.last_opts or DEFAULT_CONFIG, state)
    end

    result = {}
    for k, v in pairs(state.env_vars) do
      result[k] = v
    end

    for k, v in pairs(state.env_vars_overrides) do
      result[k] = v
    end
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
    state.manual_file_selection = true  -- Mark this as a manual selection
    config.preferred_environment = fn.fnamemodify(file, ":t"):gsub("^%.env%.", "")
    get_file_watcher().setup_watcher(config, state, M.refresh_env_vars)
    state.cached_env_files = nil

    -- Don't call M.refresh_env_vars here as it would cause deadlock
    -- Instead, directly call the internal function
    state.cached_env_files = nil
    state.file_cache_opts = nil
    local base_opts = state.last_opts or DEFAULT_CONFIG
    local opts = vim.tbl_deep_extend("force", base_opts, config or {})
    
    -- Preserve monorepo flags when selecting files
    if base_opts._is_monorepo_workspace then
      opts._is_monorepo_workspace = base_opts._is_monorepo_workspace
      opts._workspace_info = base_opts._workspace_info
      opts._monorepo_root = base_opts._monorepo_root
      opts._detected_info = base_opts._detected_info
    end
    if base_opts._is_monorepo_manual_mode then
      opts._is_monorepo_manual_mode = base_opts._is_monorepo_manual_mode
      opts._all_workspaces = base_opts._all_workspaces
      opts._current_workspace_info = base_opts._current_workspace_info
    end
    
    get_env_loader().load_environment(opts, state, true)

    if state._env_module then
      state._env_module.update_env_vars()
    end

    local utils_mod = get_utils()
    local display_name = utils_mod.get_env_file_display_name(file, opts)
    notify(string.format("Selected environment file: %s", display_name), vim.log.levels.INFO)
  end)

  if not success then
    vim.notify("Error in handle_env_file_selection: " .. tostring(err), vim.log.levels.ERROR)
  end
end

local function setup_integrations(config)
  if config.integrations.statusline then
    local statusline = require("ecolog.integrations.statusline")
    statusline.setup(type(config.integrations.statusline) == "table" and config.integrations.statusline or {})
  end

  if config.integrations.nvim_cmp then
    local nvim_cmp = require("ecolog.integrations.cmp.nvim_cmp")
    nvim_cmp.setup(
      config.integrations.nvim_cmp,
      state.env_vars,
      get_providers(),
      get_shelter(),
      get_types(),
      state.selected_env_file
    )
  end

  if config.integrations.blink_cmp then
    vim.defer_fn(function()
      local blink_cmp = require("ecolog.integrations.cmp.blink_cmp")
      blink_cmp.setup(
        config.integrations.blink_cmp,
        state.env_vars,
        get_providers(),
        get_shelter(),
        get_types(),
        state.selected_env_file
      )
    end, 50)
  end

  if config.integrations.omnifunc then
    vim.defer_fn(function()
      local omnifunc = require("ecolog.integrations.cmp.omnifunc")
      omnifunc.setup(config.integrations.omnifunc, state.env_vars, get_providers(), get_shelter())
    end, 100)
  end

  if config.integrations.lsp then
    vim.defer_fn(function()
      local lsp = require_module("ecolog.integrations.lsp")
      lsp.setup()
    end, 150)
  end

  if config.integrations.lspsaga then
    vim.defer_fn(function()
      local lspsaga = require_module("ecolog.integrations.lspsaga")
      lspsaga.setup()
    end, 200)
  end

  if config.integrations.fzf then
    vim.defer_fn(function()
      local fzf = require("ecolog.integrations.fzf")
      fzf.setup(type(config.integrations.fzf) == "table" and config.integrations.fzf or {})
    end, 300)
  end

  if config.integrations.snacks then
    vim.defer_fn(function()
      local snacks = require("ecolog.integrations.snacks")
      snacks.setup(type(config.integrations.snacks) == "table" and config.integrations.snacks or {})
    end, 350)
  end
end

local function create_commands(config)
  local commands = {
    EcologPeek = {
      callback = function(args)
        local success, err = pcall(function()
          local filetype = vim.bo.filetype
          local available_providers = get_providers().get_providers(filetype)
          get_peek().peek_env_var(available_providers, args.args)
        end)
        if not success then
          notify(string.format("EcologPeek error: %s", err), vim.log.levels.WARN)
        end
      end,
      nargs = "?",
      desc = "Peek environment variable value",
    },
    EcologSelect = {
      callback = function(args)
        if args.args and args.args ~= "" then
          local file_path = vim.fn.expand(args.args)
          if vim.fn.filereadable(file_path) == 1 then
            local success, err = pcall(handle_env_file_selection, file_path, config)
            if not success then
              notify(string.format("Error selecting environment file: %s", err), vim.log.levels.ERROR)
            end
          else
            notify(string.format("Environment file not found: %s", file_path), vim.log.levels.WARN)
          end
          return
        end

        local current_config = M.get_config()
        get_select().select_env_file({
          path = current_config.path,
          active_file = state.selected_env_file,
          env_file_patterns = current_config.env_file_patterns,
          sort_file_fn = current_config.sort_file_fn,
          sort_var_fn = current_config.sort_var_fn,
          preferred_environment = current_config.preferred_environment,

          _is_monorepo_workspace = current_config._is_monorepo_workspace,
          _workspace_info = current_config._workspace_info,
          _monorepo_root = current_config._monorepo_root,

          _is_monorepo_manual_mode = current_config._is_monorepo_manual_mode,
          _all_workspaces = current_config._all_workspaces,
          _current_workspace_info = current_config._current_workspace_info,
          monorepo = current_config.monorepo,
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
          notify("No environment file selected. Use :EcologSelect to select one.", vim.log.levels.WARN)
          return
        end
        local success, err = pcall(get_utils().generate_example_file, state.selected_env_file)
        if not success then
          notify(string.format("Failed to generate example file: %s", err), vim.log.levels.ERROR)
        end
      end,
      desc = "Generate .env.example file from selected .env file",
    },
    EcologShelterToggle = {
      callback = function(args)
        get_shelter().toggle_all()
      end,
      nargs = 0,
      desc = "Toggle all shelter modes",
    },
    EcologShelter = {
      callback = function(args)
        local success, err = pcall(function()
          local arg = args.args:lower()
          if arg == "" then
            notify("Usage: EcologShelter {enable|disable|toggle} [feature]", vim.log.levels.INFO)
            return
          end
          local parts = vim.split(arg, " ")
          local command = parts[1]
          local feature = parts[2]

          if command == "toggle" then
            if feature then
              get_shelter().toggle_feature(feature)
            else
              get_shelter().toggle_all()
            end
            return
          elseif command == "enable" or command == "disable" then
            get_shelter().set_state(command, feature)
          else
            notify("Invalid command. Use 'enable', 'disable', or 'toggle'", vim.log.levels.WARN)
            return
          end
        end)
        if not success then
          notify(string.format("EcologShelter error: %s", err), vim.log.levels.WARN)
        end
      end,
      nargs = "*",
      desc = "Enable/disable/toggle specific shelter features",
      complete = function(arglead, cmdline)
        local args = vim.split(cmdline, "%s+")
        if #args == 2 then
          return vim.tbl_filter(function(item)
            return item:find(arglead, 1, true)
          end, { "enable", "disable", "toggle" })
        elseif #args == 3 then
          return vim.tbl_filter(function(item)
            return item:find(arglead, 1, true)
          end, {
            "cmp",
            "peek",
            "files",
            "telescope",
            "fzf",
            "fzf_previewer",
            "telescope_previewer",
            "snacks_previewer",
            "snacks",
          })
        end
        return { "enable", "disable", "toggle" }
      end,
    },
    EcologRefresh = {
      callback = function()
        local success, err = pcall(function()
          M.refresh_env_vars(config)
        end)
        if not success then
          notify(string.format("EcologRefresh error: %s", err), vim.log.levels.WARN)
        end
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
        local available_providers = get_providers().get_providers(filetype)
        local var_name = args.args

        if var_name == "" then
          var_name = get_utils().get_var_word_under_cursor(available_providers)
        end

        if not var_name or #var_name == 0 then
          notify("No environment variable specified or found at cursor", vim.log.levels.WARN)
          return
        end

        get_env_loader().load_environment(config, state)

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
    EcologTelescope = {
      callback = function()
        local has_telescope, telescope = pcall(require, "telescope")
        if not has_telescope then
          notify(
            "Telescope is not installed. Install telescope.nvim to use this command",
            vim.log.levels.ERROR
          )
          return
        end
        telescope.load_extension("ecolog")
        telescope.extensions.ecolog.env()
      end,
      desc = "Open Telescope environment variable picker",
    },
    EcologCopy = {
      callback = function(args)
        local filetype = vim.bo.filetype
        local var_name = args.args

        if var_name == "" then
          if config.provider_patterns.extract then
            local available_providers = get_providers().get_providers(filetype)
            var_name = get_utils().get_var_word_under_cursor(available_providers)
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

        get_env_loader().load_environment(config, state)

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
    EcologWorkspaceList = {
      callback = function()
        local monorepo = require("ecolog.monorepo")
        local root_path, _ = monorepo.detect_monorepo_root()
        if not root_path then
          notify("Not in a monorepo", vim.log.levels.WARN)
          return
        end

        local ecolog_config = M.get_config()
        local provider = M._get_monorepo_provider(root_path)
        if not provider then
          notify("No monorepo provider found", vim.log.levels.WARN)
          return
        end
        local workspaces = monorepo.get_workspaces(root_path, provider)
        local current_workspace = monorepo.get_current_workspace()

        if #workspaces == 0 then
          notify("No workspaces found", vim.log.levels.WARN)
          return
        end

        print("Available workspaces:")
        for _, workspace in ipairs(workspaces) do
          local marker = workspace == current_workspace and "* " or "  "
          print(string.format("%s%s (%s)", marker, workspace.name, workspace.relative_path))
        end
      end,
      desc = "List all workspaces in monorepo",
    },
    EcologWorkspaceSwitch = {
      callback = function(args)
        local monorepo = require("ecolog.monorepo")
        local root_path, _ = monorepo.detect_monorepo_root()
        if not root_path then
          notify("Not in a monorepo", vim.log.levels.WARN)
          return
        end

        local ecolog_config = M.get_config()
        local provider = M._get_monorepo_provider(root_path)
        if not provider then
          notify("No monorepo provider found", vim.log.levels.WARN)
          return
        end
        local workspaces = monorepo.get_workspaces(root_path, provider)
        local workspace_name = args.args

        if workspace_name == "" then
          if #workspaces == 0 then
            notify("No workspaces found in monorepo", vim.log.levels.WARN)
            return
          end

          local workspace_names = {}
          for _, workspace in ipairs(workspaces) do
            table.insert(workspace_names, workspace.name)
          end

          vim.ui.select(workspace_names, {
            prompt = "Select workspace:",
          }, function(choice)
            if choice then
              for _, workspace in ipairs(workspaces) do
                if workspace.name == choice then
                  monorepo.set_current_workspace(workspace)
                  break
                end
              end
            end
          end)
        else
          for _, workspace in ipairs(workspaces) do
            if workspace.name == workspace_name then
              monorepo.set_current_workspace(workspace)
              return
            end
          end
          notify(string.format("Workspace '%s' not found", workspace_name), vim.log.levels.ERROR)
        end
      end,
      nargs = "?",
      desc = "Switch to a workspace",
      complete = function(arglead)
        local monorepo = require("ecolog.monorepo")
        local root_path, _ = monorepo.detect_monorepo_root()
        if not root_path then
          return {}
        end

        local ecolog_config = M.get_config()
        local provider = M._get_monorepo_provider(root_path)
        if not provider then
          notify("No monorepo provider found", vim.log.levels.WARN)
          return
        end
        local workspaces = monorepo.get_workspaces(root_path, provider)
        local names = {}
        for _, workspace in ipairs(workspaces) do
          if workspace.name:find(arglead, 1, true) then
            table.insert(names, workspace.name)
          end
        end
        return names
      end,
    },
    EcologWorkspaceCurrent = {
      callback = function()
        local monorepo = require("ecolog.monorepo")
        local current_workspace = monorepo.get_current_workspace()

        if current_workspace then
          print(string.format("Current workspace: %s (%s)", current_workspace.name, current_workspace.relative_path))
        else
          local root_path, _ = monorepo.detect_monorepo_root()
          if root_path then
            print("No workspace selected (using monorepo root)")
          else
            print("Not in a monorepo")
          end
        end
      end,
      desc = "Show current workspace",
    },
    EcologDebugFiles = {
      callback = function()
        local ecolog_config = M.get_config()
        local utils_mod = get_utils()

        print("=== Ecolog File Discovery Debug ===")
        print("Config path:", ecolog_config.path)
        print("Is monorepo workspace:", ecolog_config._is_monorepo_workspace)
        print("Workspace info:", vim.inspect(ecolog_config._workspace_info))
        print("Monorepo root:", ecolog_config._monorepo_root)
        print("Env file patterns:", vim.inspect(ecolog_config.env_file_patterns))

        local files = utils_mod.find_env_files(ecolog_config)
        print("Found files:")
        for i, file in ipairs(files) do
          print(string.format("  %d. %s", i, file))
        end
      end,
      desc = "Debug environment file discovery",
    },
    EcologDebugState = {
      callback = function()
        M._debug_ecolog_state()
      end,
      desc = "Debug current ecolog state",
    },
    EcologRecover = {
      callback = function()
        M.recover()
      end,
      desc = "Attempt smart recovery from issues",
    },
    EcologHealth = {
      callback = function()
        local health = M.get_lock_health()
        print("=== Ecolog Health ===")
        print("State lock:", health.state_lock and "LOCKED" or "FREE")
        print("Lock duration:", health.lock_duration .. "ms")
        print("Pending operations:", health.pending_operations)
        print("Module locks:", health.module_locks)
        print("Validation errors:", _validation_errors)
        print("Cache stats:", vim.inspect(M.get_cache_stats()))
      end,
      desc = "Show plugin health status",
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

---Handle workspace change events from monorepo system
---@param new_workspace table? New workspace information
---@param previous_workspace table? Previous workspace information
function M._handle_workspace_change(new_workspace, previous_workspace)
  _config_cache = {}
  _config_cache_key = nil

  vim.schedule(function()
    local new_config = M.get_config()

    state.last_opts = new_config

    M._clear_environment_cache()

    M.refresh_env_vars(new_config)

    vim.schedule(function()
      if new_config.monorepo and new_config.monorepo.notify_on_switch then
        M._notify_workspace_change(new_workspace, previous_workspace)
      end
    end)
  end)
end

function M._clear_environment_cache()
  state.cached_env_files = nil
  state.file_cache_opts = nil
  -- Only clear selected_env_file if it wasn't manually selected
  if state.manual_file_selection ~= true then
    state.selected_env_file = nil
  end
  state.env_vars = {}
end

---Generate cache key for configuration based on current context
---@param config table Base configuration
---@return string cache_key Generated cache key
function M._generate_config_cache_key(config)
  local current_file = vim.api.nvim_buf_get_name(0)
  local current_dir = vim.fn.getcwd()

  local monorepo_context = ""
  if config.monorepo then
    local monorepo = require("ecolog.monorepo")
    local current_workspace = monorepo.get_current_workspace()
    local monorepo_root = monorepo.detect_monorepo_root()

    monorepo_context = string.format(
      "|monorepo:%s|workspace:%s",
      monorepo_root or "none",
      current_workspace and current_workspace.name or "none"
    )
  end

  return vim.inspect(config) .. "|file:" .. current_file .. "|dir:" .. current_dir .. monorepo_context
end

---Setup monorepo integration
---@param config table Configuration with monorepo settings
---@return table config Updated configuration with monorepo integration
function M._setup_monorepo_integration(config)
  local monorepo = require("ecolog.monorepo")

  monorepo.setup(config.monorepo)

  local integrated_config = monorepo.integrate_with_ecolog_config(config)

  monorepo.add_workspace_change_listener(function(new_workspace, previous_workspace)
    if new_workspace ~= previous_workspace then
      M._handle_workspace_change(new_workspace, previous_workspace)
    end
  end)

  return integrated_config
end

---Apply monorepo integration to configuration (for cached configs)
---@param config table Configuration to integrate
---@return table config Configuration with monorepo integration applied
function M._apply_monorepo_integration(config)
  local monorepo = require("ecolog.monorepo")
  return monorepo.integrate_with_ecolog_config(config)
end

function M._debug_ecolog_state()
  vim.wait(500)

  local state = M.get_state()
  local monorepo = require("ecolog.monorepo")
  local current_workspace = monorepo.get_current_workspace()

  print("=== Ecolog State Debug ===")
  print("Selected env file:", state.selected_env_file)
  print("Env vars count:", vim.tbl_count(state.env_vars))
  print("Current workspace:", current_workspace and current_workspace.name or "none")
  print("Workspace path:", current_workspace and current_workspace.path or "none")

  if state.selected_env_file then
    print("File exists:", vim.fn.filereadable(state.selected_env_file) == 1)
  end

  local count = 0
  print("Environment variables:")
  for key, var in pairs(state.env_vars) do
    if count < 3 then
      print(string.format("  %s = %s (from: %s)", key, var.value, var.source_file or var.source))
      count = count + 1
    else
      break
    end
  end
  if vim.tbl_count(state.env_vars) > 3 then
    print(string.format("  ... and %d more", vim.tbl_count(state.env_vars) - 3))
  end
end

---Get monorepo provider for given root path
---@param root_path string Root path to detect provider for
---@return table? provider Detected monorepo provider or nil
function M._get_monorepo_provider(root_path)
  local Detection = require("ecolog.monorepo.detection")
  local _, provider = Detection.detect_monorepo(root_path)
  return provider
end

---Notify about workspace change with environment file information
---@param current_workspace table? Current workspace
---@param previous_workspace table? Previous workspace
function M._notify_workspace_change(current_workspace, previous_workspace)
  if not current_workspace then
    vim.notify("Workspace change detected", vim.log.levels.INFO)
    return
  end

  local selected_env_file = M._get_selected_env_file_info(current_workspace)

  local message
  if selected_env_file then
    message = string.format("Selected environment file: %s (%s)", selected_env_file.name, selected_env_file.location)
  else
    local workspace_name = current_workspace.name or "unknown"
    message = string.format("Entered workspace: %s", workspace_name)
  end

  vim.notify(message, vim.log.levels.INFO)
end

---Get selected environment file information for a workspace
---@param workspace table Workspace information
---@return table? env_file_info Information about the selected environment file
function M._get_selected_env_file_info(workspace)
  if not workspace then
    return nil
  end

  local current_state = M.get_state()

  if not current_state.selected_env_file then
    return nil
  end

  local filename = vim.fn.fnamemodify(current_state.selected_env_file, ":t")

  local location = string.format("%s/%s", workspace.type, workspace.name)

  return {
    name = filename,
    location = location,
    full_path = current_state.selected_env_file,
  }
end

---@param config EcologConfig
local function validate_config(config)
  -- Ensure config is a table
  if type(config) ~= "table" then
    notify("Configuration must be a table", vim.log.levels.WARN)
    return
  end

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

  -- Validate types option
  if config.types ~= nil and type(config.types) ~= "boolean" and type(config.types) ~= "table" then
    notify("types must be boolean or table, got " .. type(config.types), vim.log.levels.WARN)
    config.types = true -- fallback to default
  end

  -- Validate interpolation option
  if config.interpolation ~= nil and type(config.interpolation) ~= "boolean" and type(config.interpolation) ~= "table" then
    notify("interpolation must be boolean or table, got " .. type(config.interpolation), vim.log.levels.WARN)
    config.interpolation = { enabled = true } -- fallback to default
  end

  -- Validate integrations
  if config.integrations ~= nil and type(config.integrations) ~= "table" then
    notify("integrations must be a table, got " .. type(config.integrations), vim.log.levels.WARN)
    config.integrations = {}
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

    -- Handle invalid opts types gracefully
    if opts ~= nil and type(opts) ~= "table" then
      vim.notify("Configuration must be a table, got " .. type(opts) .. ". Using default configuration.", vim.log.levels.WARN)
      opts = {}
    end

    local config = vim.tbl_deep_extend("force", DEFAULT_CONFIG, opts or {})

    if not config.path then
      config.path = vim.fn.getcwd()
    end

    validate_config(config)

    if config.monorepo then
      config = M._setup_monorepo_integration(config)
    end

    state.last_opts = config

    _config_cache = {}
    _config_cache_key = nil

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
        disable_security = DEFAULT_CONFIG.interpolation.disable_security,
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
    -- Note: state.last_opts is set after monorepo integration

    if config.integrations.blink_cmp then
      config.integrations.nvim_cmp = false
    end

    require("ecolog.highlights").setup()
    get_shelter().setup({
      config = config.shelter.configuration,
      partial = config.shelter.modules,
    })
    get_types().setup({
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

    local initial_env_files = get_utils().find_env_files({
      path = config.path,
      preferred_environment = config.preferred_environment,
      env_file_patterns = config.env_file_patterns,
      sort_file_fn = config.sort_file_fn,
      sort_var_fn = config.sort_var_fn,
    })

    if #initial_env_files > 0 then
      vim.schedule(function()
        handle_env_file_selection(initial_env_files[1], config)
      end)
    end

    vim.schedule(function()
      get_env_loader().load_environment(config, state)
      get_file_watcher().setup_watcher(config, state, M.refresh_env_vars)
    end)

    vim.schedule(function()
      setup_integrations(config)
    end)

    create_commands(config)

    state.initialized = true

    -- Start health monitoring for early issue detection
    start_health_monitoring()

    if opts and opts.vim_env then
      schedule(function()
        get_env_module()
      end)
    end
    
    -- Mark setup as done only after successful completion
    _setup_done = true
  end)

  release_state_lock()

  if not success then
    vim.notify("Error in setup: " .. tostring(err), vim.log.levels.ERROR)
  end
end

function M.get_status()
  local selected_file = safe_read_state("selected_env_file")
  local opts = safe_read_state("last_opts")

  if not opts or not opts.integrations.statusline then
    return ""
  end

  local config = opts.integrations.statusline
  if type(config) == "table" and config.hidden_mode and not selected_file then
    return ""
  end

  if selected_file then
    return vim.fn.fnamemodify(selected_file, ":t")
  end

  return ""
end

function M.get_lualine()
  local selected_file = safe_read_state("selected_env_file")
  local opts = safe_read_state("last_opts")

  if not opts or not opts.integrations.statusline then
    return ""
  end

  local config = opts.integrations.statusline
  if type(config) == "table" and config.hidden_mode and not selected_file then
    return ""
  end

  if selected_file then
    return vim.fn.fnamemodify(selected_file, ":t")
  end

  return ""
end

function M.get_state()
  local result = {}
  for k, v in pairs(state) do
    if k == "_env_line_cache" then
      result[k] = {}
    elseif type(v) ~= "table" then
      result[k] = v
    else
      result[k] = vim.tbl_extend("force", {}, v)
    end
  end
  return result
end

---@return table health_info
function M.get_lock_health()
  return {
    state_lock = _state_lock,
    lock_start_time = _lock_start_time,
    lock_duration = _lock_start_time > 0 and (uv.now() - _lock_start_time) or 0,
    pending_operations = _pending_operations,
    module_locks = vim.tbl_count(_module_locks),
  }
end

function M.force_unlock_all()
  vim.notify("Force unlocking all state locks", vim.log.levels.WARN)
  _state_lock = false
  _lock_start_time = 0
  _pending_operations = 0
  _module_locks = {}
end

-- Safe shutdown with cleanup
function M.shutdown()
  stop_health_monitoring()
  M.force_unlock_all()

  _loaded_modules = {}
  _config_cache = {}
  state._env_line_cache = setmetatable({}, { __mode = "kv" })

  vim.notify("Ecolog safely shut down", vim.log.levels.INFO)
end

function M.recover()
  vim.notify("Attempting smart recovery...", vim.log.levels.INFO)

  M.force_unlock_all()

  state.cached_env_files = nil
  state.file_cache_opts = nil

  start_health_monitoring()

  if state.last_opts then
    M.refresh_env_vars(state.last_opts)
  end

  vim.notify("Recovery completed", vim.log.levels.INFO)
end

function M.get_config()
  local config = safe_read_state("last_opts")
  if config then
    local cache_key = M._generate_config_cache_key(config)

    if _config_cache_key == cache_key and _config_cache[cache_key] then
      return _config_cache[cache_key]
    end

    local cached_config = vim.tbl_extend("force", {}, config)

    if cached_config.monorepo then
      cached_config = M._apply_monorepo_integration(cached_config)
    end

    _config_cache[cache_key] = cached_config
    _config_cache_key = cache_key

    return cached_config
  end

  if not _config_cache["DEFAULT"] then
    local default_config = vim.tbl_extend("force", {}, DEFAULT_CONFIG)

    if default_config.monorepo and not default_config._monorepo_root then
      local monorepo = require("ecolog.monorepo")
      default_config = monorepo.integrate_with_ecolog_config(default_config)
    end

    _config_cache["DEFAULT"] = default_config
  end
  return _config_cache["DEFAULT"]
end

---Get cache statistics for debugging and monitoring
---@return table cache_stats
function M.get_cache_stats()
  return get_cache_stats()
end

---Manually trigger cache cleanup
function M.cleanup_caches()
  cleanup_caches()
end

function M.stop_health_monitoring()
  stop_health_monitoring()
end

-- Ensure cleanup on Vim exit
vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    M.shutdown()
  end,
  desc = "Ecolog cleanup on exit",
})

---Set an environment variable override for the current session
---@param var_name string The environment variable name
---@param value string The new value
---@return boolean success True if the override was set successfully
function M.set_env_override(var_name, value)
  if not var_name or not value then
    return false
  end

  if not state.env_vars_overrides then
    state.env_vars_overrides = {}
  end

  local types = require("ecolog.types")
  local type_name, transformed_value = types.detect_type(value)

  state.env_vars_overrides[var_name] = {
    value = transformed_value,
    type = type_name,
    raw_value = value,
    source = "session_override",
  }

  if state._env_module and state._env_module.update_env_vars then
    state._env_module.update_env_vars()
  end

  return true
end

return M
