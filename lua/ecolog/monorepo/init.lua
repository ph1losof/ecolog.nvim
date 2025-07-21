---@class MonorepoModule
local M = {}

M.DEFAULT_MONOREPO_CONFIG = require("ecolog.monorepo.config.defaults")

local _modules = {}

local _state = {
  initialized = false,
  config = nil,
  enabled = false,
}

---Lazy load module
---@param name string Module name
---@return table module Loaded module
local function get_module(name)
  if not _modules[name] then
    _modules[name] = require("ecolog.monorepo." .. name)
  end
  return _modules[name]
end

local DEFAULT_CONFIG = {
  enabled = false,
  auto_switch = true,
  notify_on_switch = false,

  providers = {
    builtin = {
      "turborepo",
      "nx",
      "lerna",
      "yarn_workspaces",
      "cargo_workspaces",
    },
    custom = {},
  },

  performance = {
    cache = {
      max_entries = 1000,
      default_ttl = 300000,
      cleanup_interval = 60000,
    },

    auto_switch_throttle = {
      min_interval = 100,
      debounce_delay = 250,
      same_file_skip = true,
      workspace_boundary_only = true,
      max_checks_per_second = 10,
    },
  },
}

---Initialize the monorepo system
---@param config table|boolean Configuration or boolean to enable with defaults
function M.setup(config)
  if type(config) == "boolean" then
    if config then
      config = vim.tbl_deep_extend("force", DEFAULT_CONFIG, { enabled = true })
    else
      _state.enabled = false
      return
    end
  end

  local Schema = get_module("config.schema")
  local merged_config, valid, error_msg = Schema.merge_and_validate(DEFAULT_CONFIG, config or {})

  if not valid then
    error("Invalid monorepo configuration: " .. tostring(error_msg))
  end

  _state.config = merged_config
  _state.enabled = merged_config.enabled

  if not merged_config.enabled then
    return
  end

  config = merged_config

  local Detection = get_module("detection")
  Detection.configure(config.performance)

  if config.providers.builtin then
    M._load_builtin_providers(config.providers.builtin)
  end

  if config.providers.custom then
    M._load_custom_providers(config.providers.custom)
  end

  if config.plugins then
    local PluginSystem = get_module("plugin_system")
    if config.plugins.directory then
      PluginSystem.load_plugins_from_directory(config.plugins.directory)
    end
    if config.plugins.list then
      for _, plugin_config in ipairs(config.plugins.list) do
        PluginSystem.register_plugin(plugin_config)
      end
    end
  end

  local providers = Detection.get_providers()
  if not next(providers) then
    vim.notify("No monorepo providers available. Disabling monorepo system.", vim.log.levels.WARN)
    _state.enabled = false
    return
  end

  if config.auto_switch then
    local AutoSwitch = get_module("auto_switch")
    AutoSwitch.setup(config)
  end

  _state.initialized = true
end

---Load built-in providers
---@param provider_names string[] List of built-in provider names to load
function M._load_builtin_providers(provider_names)
  local Detection = get_module("detection")

  for _, name in ipairs(provider_names) do
    local success, provider_module = pcall(require, "ecolog.monorepo.detection.providers." .. name)
    if success then
      local provider = provider_module.new()
      Detection.register_provider(provider)
    else
      vim.notify("Failed to load built-in provider: " .. name, vim.log.levels.WARN)
    end
  end
end

function M.clear_providers()
  local Detection = get_module("detection")
  Detection.clear_providers()
end

---Load custom providers
---@param custom_providers table[] List of custom provider configurations
function M._load_custom_providers(custom_providers)
  local Detection = get_module("detection")

  for _, provider_config in ipairs(custom_providers) do
    if provider_config.module then
      local success, provider_module = pcall(require, provider_config.module)
      if success then
        local provider = provider_module.new(provider_config.config)
        Detection.register_provider(provider)
      else
        vim.notify("Failed to load custom provider: " .. provider_config.module, vim.log.levels.WARN)
      end
    elseif provider_config.provider then
      Detection.register_provider(provider_config.provider)
    elseif provider_config.name then
      local BaseProvider = require("ecolog.monorepo.detection.providers.base")
      local normalized_config = {
        name = provider_config.name,
        priority = provider_config.priority or 50,
        detection = provider_config.detection or {
          strategies = { "file_markers" },
          file_markers = { provider_config.name .. ".json" },
          max_depth = 4,
          cache_duration = 300000,
        },
        workspace = {
          patterns = provider_config.workspace_patterns or {},
          priority = provider_config.workspace_priority or {},
        },
        env_resolution = provider_config.env_resolution or {
          strategy = "workspace_first",
          inheritance = true,
          override_order = { "workspace", "root" },
        },
      }

      local CustomProvider = setmetatable({}, { __index = BaseProvider })
      function CustomProvider:detect(path)
        local file_markers = self.config.detection.file_markers or {}
        for _, marker in ipairs(file_markers) do
          if vim.fn.filereadable(path .. "/" .. marker) == 1 then
            return true, 90, { marker_file = marker }
          end
        end
        return false, 0, {}
      end

      function CustomProvider:get_package_managers()
        return { "package.json" }
      end

      local provider = BaseProvider.new(normalized_config)
      setmetatable(provider, { __index = CustomProvider })
      Detection.register_provider(provider)
    end
  end
end

---Detect monorepo at given path
---@param path? string Path to check (defaults to current working directory)
---@param config? table Optional configuration to use for detection
---@return string? root_path Root path of detected monorepo
---@return table? detection_info Detection information including provider
function M.detect_monorepo_root(path, config)
  local use_config

  if type(config) == "boolean" then
    use_config = { enabled = config }
  else
    use_config = config or _state.config or {}
  end

  local enabled = use_config.enabled
  if enabled == nil then
    enabled = _state.enabled
  end

  if not enabled then
    return nil, nil
  end

  local Detection = get_module("detection")

  local providers = Detection.get_providers()
  if not next(providers) then
    if use_config.providers then
      if type(use_config.providers) == "table" then
        if use_config.providers[1] and use_config.providers[1].name then
          M._load_custom_providers(use_config.providers)
        else
          local builtin_providers = use_config.providers.builtin or DEFAULT_CONFIG.providers.builtin
          M._load_builtin_providers(builtin_providers)

          if use_config.providers.custom then
            M._load_custom_providers(use_config.providers.custom)
          end
        end
      end
    else
      M._load_builtin_providers(DEFAULT_CONFIG.providers.builtin)
    end

    providers = Detection.get_providers()
    if not next(providers) then
      vim.notify("No monorepo providers registered. Disabling monorepo detection.", vim.log.levels.WARN)
      _state.enabled = false
      return nil, nil
    end
  end

  local root_path, provider, detection_info = Detection.detect_monorepo(path)
  if root_path and provider then
    local combined_info = {
      provider = provider,
      confidence = detection_info and detection_info.confidence or 1,
      metadata = detection_info and detection_info.metadata or {},
      detected_at = detection_info and detection_info.detected_at or vim.loop.now(),
    }
    return root_path, combined_info
  end

  return nil, nil
end

---Get all workspaces in a monorepo
---@param root_path string Root path of monorepo
---@param config? table Configuration for workspace detection
---@param detected_info? table Detection information including provider
---@return table[] workspaces List of workspace information
function M.get_workspaces(root_path, config, detected_info)
  local use_config

  if type(config) == "boolean" then
    use_config = { enabled = config }
  else
    use_config = config or _state.config or {}
  end

  local enabled = use_config.enabled
  if enabled == nil then
    enabled = _state.enabled
  end

  if not enabled or not root_path then
    return {}
  end

  local provider = detected_info and detected_info.provider
  if not provider then
    return {}
  end

  local WorkspaceFinder = get_module("workspace.finder")
  return WorkspaceFinder.find_workspaces(root_path, provider)
end

---Find workspace containing the current file
---@param file_path? string File path (defaults to current buffer)
---@param workspaces table[] List of workspaces to search
---@return table? workspace Workspace containing the file
function M.find_current_workspace(file_path, workspaces)
  if not _state.enabled then
    return nil
  end

  local WorkspaceManager = get_module("workspace.manager")
  return WorkspaceManager.find_workspace_for_file(file_path, workspaces)
end

---Set current workspace
---@param workspace table? Workspace to set as current
function M.set_current_workspace(workspace)
  if not _state.enabled then
    return
  end

  local WorkspaceManager = get_module("workspace.manager")
  WorkspaceManager.set_current(workspace)
end

---Get current workspace
---@return table? workspace Current workspace
function M.get_current_workspace()
  if not _state.enabled then
    return nil
  end

  local WorkspaceManager = get_module("workspace.manager")
  return WorkspaceManager.get_current()
end

---Resolve environment files for a workspace
---@param workspace table? Workspace information
---@param root_path string Monorepo root path
---@param provider table Provider that manages this workspace
---@param env_file_patterns string[]? Custom environment file patterns
---@param opts table? Additional options
---@return string[] env_files List of environment files in resolution order
function M.resolve_env_files(workspace, root_path, provider, env_file_patterns, opts)
  if not _state.enabled then
    return {}
  end

  local EnvironmentResolver = get_module("workspace.resolver")
  return EnvironmentResolver.resolve_env_files(workspace, root_path, provider, env_file_patterns, opts)
end

---Add workspace change listener
---@param listener function Callback function(new_workspace, previous_workspace)
function M.add_workspace_change_listener(listener)
  if not _state.enabled then
    return
  end

  local WorkspaceManager = get_module("workspace.manager")
  WorkspaceManager.add_change_listener(listener)
end

---Remove workspace change listener
---@param listener function Callback function to remove
function M.remove_workspace_change_listener(listener)
  if not _state.enabled then
    return
  end

  local WorkspaceManager = get_module("workspace.manager")
  WorkspaceManager.remove_change_listener(listener)
end

---Register a custom provider
---@param provider table Provider instance
function M.register_provider(provider)
  if not _state.enabled then
    return
  end

  local Detection = get_module("detection")
  Detection.register_provider(provider)
end

---Get all registered providers
---@return table<string, table> providers Map of provider name to instance
function M.get_providers()
  if not _state.enabled then
    return {}
  end

  local Detection = get_module("detection")
  return Detection.get_providers()
end

---Register a plugin
---@param plugin_config table Plugin configuration
function M.register_plugin(plugin_config)
  if not _state.enabled then
    return
  end

  local PluginSystem = get_module("plugin_system")
  PluginSystem.register_plugin(plugin_config)
end

---Unregister a plugin
---@param plugin_name string Name of the plugin to unregister
function M.unregister_plugin(plugin_name)
  if not _state.enabled then
    return
  end

  local PluginSystem = get_module("plugin_system")
  PluginSystem.unregister_plugin(plugin_name)
end

---Get registered plugins
---@return table<string, table> plugins Map of plugin name to configuration
function M.get_plugins()
  if not _state.enabled then
    return {}
  end

  local PluginSystem = get_module("plugin_system")
  return PluginSystem.get_plugins()
end

function M.enable_auto_switch()
  if not _state.enabled then
    return
  end

  local AutoSwitch = get_module("auto_switch")
  AutoSwitch.enable()
end

function M.disable_auto_switch()
  if not _state.enabled then
    return
  end

  local AutoSwitch = get_module("auto_switch")
  AutoSwitch.disable()
end

---Check if auto-switching is enabled
---@return boolean enabled Whether auto-switching is enabled
function M.is_auto_switch_enabled()
  if not _state.enabled then
    return false
  end

  local AutoSwitch = get_module("auto_switch")
  return AutoSwitch.is_enabled()
end

---Manually trigger workspace detection and switching
---@param file_path? string Optional file path to check
function M.manual_switch(file_path)
  if not _state.enabled then
    return
  end

  local AutoSwitch = get_module("auto_switch")
  AutoSwitch.manual_switch(file_path)
end

function M.clear_cache()
  if not _state.enabled then
    return
  end

  local Detection = get_module("detection")
  Detection.clear_cache()
end

---Get comprehensive statistics
---@return table stats Statistics for all components
function M.get_stats()
  if not _state.enabled then
    return {
      enabled = false,
      initialized = false,
    }
  end

  local stats = {
    enabled = _state.enabled,
    initialized = _state.initialized,
    config = _state.config,
  }

  if _modules["detection"] then
    stats.detection = _modules["detection"].get_stats()
  end

  if _modules["auto_switch"] then
    stats.auto_switch = _modules["auto_switch"].get_stats()
  end

  if _modules["workspace.manager"] then
    local current_workspace = _modules["workspace.manager"].get_current()
    if current_workspace then
      stats.current_workspace = {
        name = current_workspace.name,
        type = current_workspace.type,
        path = current_workspace.path,
      }
    end
  end

  if _modules["plugin_system"] then
    stats.plugins = _modules["plugin_system"].get_stats()
  end

  return stats
end

---Configure monorepo settings
---@param config table Configuration options
function M.configure(config)
  if not _state.enabled then
    return
  end

  _state.config = vim.tbl_deep_extend("force", _state.config or {}, config)

  if _modules["detection"] and config.performance then
    _modules["detection"].configure(config.performance)
  end

  if _modules["auto_switch"] and config.auto_switch_throttle then
    _modules["auto_switch"].configure({ throttle = config.auto_switch_throttle })
  end
end

---Check if monorepo system is enabled
---@return boolean enabled Whether the system is enabled
function M.is_enabled()
  return _state.enabled
end

---Get current configuration
---@return table? config Current configuration
function M.get_config()
  return _state.config
end

function M.shutdown()
  if _modules["auto_switch"] then
    _modules["auto_switch"].disable()
  end

  if _modules["workspace.manager"] then
    _modules["workspace.manager"].clear_listeners()
    _modules["workspace.manager"].clear_state()
  end

  M.clear_cache()

  _state.enabled = false
  _state.initialized = false
  _modules = {}
end

-- Compatibility layer for existing monorepo.lua API
---Integration with ecolog configuration (compatibility function)
---@param ecolog_config table The main ecolog configuration
---@return table modified_config Modified configuration for monorepo support
function M.integrate_with_ecolog_config(ecolog_config)
  if not ecolog_config.monorepo or ecolog_config.monorepo == false then
    return ecolog_config
  end

  if not _state.initialized then
    M.setup(ecolog_config.monorepo)
  end

  if not _state.enabled then
    return ecolog_config
  end

  local root_path, detected_info = M.detect_monorepo_root(vim.fn.getcwd(), ecolog_config.monorepo)
  if not root_path then
    return ecolog_config
  end

  local workspaces = M.get_workspaces(root_path, ecolog_config.monorepo, detected_info)
  local current_file = vim.fn.expand("%:p")
  if current_file == "" then
    current_file = vim.fn.getcwd()
  end
  local current_workspace = M.find_current_workspace(current_file, workspaces)

  ecolog_config._monorepo_root = root_path
  ecolog_config._detected_info = detected_info

  if _state.config.auto_switch then
    if current_workspace then
      M.set_current_workspace(current_workspace)
      ecolog_config.path = current_workspace.path
      ecolog_config._is_monorepo_workspace = true
      ecolog_config._workspace_info = current_workspace
    end
  else
    if #workspaces > 0 then
      ecolog_config._is_monorepo_manual_mode = true
      ecolog_config._all_workspaces = workspaces
      ecolog_config._current_workspace_info = current_workspace
    end
  end

  return ecolog_config
end

return M
