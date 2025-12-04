---@class MonorepoPluginSystem
local PluginSystem = {}

local Detection = require("ecolog.monorepo.detection")
local Factory = require("ecolog.monorepo.detection.providers.factory")
local NotificationManager = require("ecolog.core.notification_manager")

-- Plugin registry
local _plugins = {}
local _hooks = {
  before_detection = {},
  after_detection = {},
  before_workspace_switch = {},
  after_workspace_switch = {},
}

---Register a plugin
---@param plugin_config table Plugin configuration
function PluginSystem.register_plugin(plugin_config)
  if not plugin_config.name then
    error("Plugin name is required")
  end

  if _plugins[plugin_config.name] then
    NotificationManager.warn("Plugin '" .. plugin_config.name .. "' is already registered")
    return
  end

  -- Validate plugin configuration
  local valid, error_msg = PluginSystem._validate_plugin(plugin_config)
  if not valid then
    error("Invalid plugin configuration: " .. error_msg)
  end

  _plugins[plugin_config.name] = plugin_config

  -- Register providers if present
  if plugin_config.providers then
    for _, provider_config in ipairs(plugin_config.providers) do
      PluginSystem._register_provider_from_plugin(provider_config, plugin_config.name)
    end
  end

  -- Register hooks if present
  if plugin_config.hooks then
    for hook_name, hook_function in pairs(plugin_config.hooks) do
      PluginSystem.register_hook(hook_name, hook_function, plugin_config.name)
    end
  end

  -- Run plugin initialization if present
  if plugin_config.init then
    local success, err = pcall(plugin_config.init)
    if not success then
      NotificationManager.error("Plugin '" .. plugin_config.name .. "' initialization failed: " .. tostring(err))
    end
  end
end

---Register a provider from plugin configuration
---@param provider_config table Provider configuration
---@param plugin_name string Name of the plugin registering the provider
function PluginSystem._register_provider_from_plugin(provider_config, plugin_name)
  local provider

  if provider_config.type == "simple" then
    provider = Factory.create_simple_provider(provider_config)
  elseif provider_config.type == "json" then
    provider = Factory.create_json_provider(provider_config)
  elseif provider_config.type == "custom" then
    provider = Factory.create_custom_provider(provider_config)
  elseif provider_config.type == "template" then
    provider = Factory.create_from_template(provider_config.template, provider_config)
  elseif provider_config.instance then
    -- Direct provider instance
    provider = provider_config.instance
  else
    error("Unknown provider type: " .. tostring(provider_config.type))
  end

  -- Add plugin metadata to provider
  if provider then
    local instance = provider.new(provider_config.config)
    instance._plugin_name = plugin_name
    Detection.register_provider(instance)
  end
end

---Register a hook
---@param hook_name string Name of the hook
---@param hook_function function Function to call for the hook
---@param plugin_name? string Optional plugin name for tracking
function PluginSystem.register_hook(hook_name, hook_function, plugin_name)
  if not _hooks[hook_name] then
    _hooks[hook_name] = {}
  end

  table.insert(_hooks[hook_name], {
    func = hook_function,
    plugin = plugin_name,
  })
end

---Call hooks for a specific event
---@param hook_name string Name of the hook to call
---@param ... any Arguments to pass to hook functions
function PluginSystem.call_hooks(hook_name, ...)
  local hooks = _hooks[hook_name]
  if not hooks then
    return
  end

  for _, hook in ipairs(hooks) do
    local success, err = pcall(hook.func, ...)
    if not success then
      local plugin_info = hook.plugin and (" (plugin: " .. hook.plugin .. ")") or ""
      NotificationManager.error("Hook '" .. hook_name .. "' failed" .. plugin_info .. ": " .. tostring(err))
    end
  end
end

---Unregister a plugin
---@param plugin_name string Name of the plugin to unregister
function PluginSystem.unregister_plugin(plugin_name)
  local plugin = _plugins[plugin_name]
  if not plugin then
    return
  end

  -- Unregister providers
  if plugin.providers then
    for _, provider_config in ipairs(plugin.providers) do
      if provider_config.name then
        Detection.unregister_provider(provider_config.name)
      end
    end
  end

  -- Remove hooks
  for hook_name, hooks in pairs(_hooks) do
    for i = #hooks, 1, -1 do
      if hooks[i].plugin == plugin_name then
        table.remove(hooks, i)
      end
    end
  end

  -- Run plugin cleanup if present
  if plugin.cleanup then
    local success, err = pcall(plugin.cleanup)
    if not success then
      NotificationManager.error("Plugin '" .. plugin_name .. "' cleanup failed: " .. tostring(err))
    end
  end

  _plugins[plugin_name] = nil
end

---Get registered plugins
---@return table<string, table> plugins Map of plugin name to configuration
function PluginSystem.get_plugins()
  return vim.deepcopy(_plugins)
end

---Get plugin by name
---@param plugin_name string Name of the plugin
---@return table? plugin Plugin configuration or nil if not found
function PluginSystem.get_plugin(plugin_name)
  return _plugins[plugin_name] and vim.deepcopy(_plugins[plugin_name]) or nil
end

---Check if plugin is registered
---@param plugin_name string Name of the plugin
---@return boolean registered Whether plugin is registered
function PluginSystem.is_plugin_registered(plugin_name)
  return _plugins[plugin_name] ~= nil
end

---Validate plugin configuration
---@param plugin_config table Plugin configuration to validate
---@return boolean valid Whether configuration is valid
---@return string? error Error message if invalid
function PluginSystem._validate_plugin(plugin_config)
  if not plugin_config.name or type(plugin_config.name) ~= "string" then
    return false, "Plugin name must be a string"
  end

  if plugin_config.providers and type(plugin_config.providers) ~= "table" then
    return false, "Plugin providers must be a table"
  end

  if plugin_config.hooks and type(plugin_config.hooks) ~= "table" then
    return false, "Plugin hooks must be a table"
  end

  if plugin_config.init and type(plugin_config.init) ~= "function" then
    return false, "Plugin init must be a function"
  end

  if plugin_config.cleanup and type(plugin_config.cleanup) ~= "function" then
    return false, "Plugin cleanup must be a function"
  end

  return true, nil
end

---Create a simple plugin for quick provider registration
---@param name string Plugin name
---@param providers table[] List of provider configurations
---@return table plugin_config Plugin configuration
function PluginSystem.create_simple_plugin(name, providers)
  return {
    name = name,
    providers = providers,
    description = "Simple plugin with " .. #providers .. " provider(s)",
    version = "1.0.0",
  }
end

---Load plugins from directory
---@param plugin_dir string Directory containing plugin files
function PluginSystem.load_plugins_from_directory(plugin_dir)
  if vim.fn.isdirectory(plugin_dir) == 0 then
    return
  end

  local plugin_files = vim.fn.glob(plugin_dir .. "/*.lua", false, true)

  for _, plugin_file in ipairs(plugin_files) do
    local success, plugin_config = pcall(dofile, plugin_file)
    if success and plugin_config then
      PluginSystem.register_plugin(plugin_config)
    else
      NotificationManager.error("Failed to load plugin from " .. plugin_file .. ": " .. tostring(plugin_config))
    end
  end
end

---Get plugin statistics
---@return table stats Plugin system statistics
function PluginSystem.get_stats()
  local plugin_count = 0
  local provider_count = 0
  local hook_count = 0

  for _ in pairs(_plugins) do
    plugin_count = plugin_count + 1
  end

  for _, plugin in pairs(_plugins) do
    if plugin.providers then
      provider_count = provider_count + #plugin.providers
    end
  end

  for _, hooks in pairs(_hooks) do
    hook_count = hook_count + #hooks
  end

  return {
    plugins = plugin_count,
    providers = provider_count,
    hooks = hook_count,
    hook_types = vim.tbl_keys(_hooks),
  }
end

---Clear all plugins and hooks
function PluginSystem.clear_all()
  -- Cleanup all plugins
  for plugin_name, _ in pairs(_plugins) do
    PluginSystem.unregister_plugin(plugin_name)
  end

  _plugins = {}
  _hooks = {
    before_detection = {},
    after_detection = {},
    before_workspace_switch = {},
    after_workspace_switch = {},
  }
end

return PluginSystem

