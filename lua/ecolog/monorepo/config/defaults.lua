---@class ConfigDefaults
local Defaults = {}

---Default configuration for the monorepo system
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
      default_ttl = 300000, -- 5 minutes
      cleanup_interval = 60000, -- 1 minute
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

---Built-in provider configurations
local BUILTIN_PROVIDERS = {
  turborepo = {
    name = "turborepo",
    detection = {
      strategies = { "file_markers" },
      file_markers = { "turbo.json" },
      max_depth = 4,
      cache_duration = 300000,
    },
    workspace = {
      patterns = { "apps/*", "packages/*" },
      priority = { "apps", "packages" },
    },
    env_resolution = {
      strategy = "workspace_first",
      inheritance = true,
      override_order = { "workspace", "root" },
    },
    priority = 1,
  },

  nx = {
    name = "nx",
    detection = {
      strategies = { "file_markers" },
      file_markers = { "nx.json", "workspace.json" },
      max_depth = 4,
      cache_duration = 300000,
    },
    workspace = {
      patterns = { "apps/*", "libs/*", "tools/*", "e2e/*" },
      priority = { "apps", "libs", "tools", "e2e" },
    },
    env_resolution = {
      strategy = "workspace_first",
      inheritance = true,
      override_order = { "workspace", "root" },
    },
    priority = 2,
  },

  lerna = {
    name = "lerna",
    detection = {
      strategies = { "file_markers" },
      file_markers = { "lerna.json" },
      max_depth = 4,
      cache_duration = 300000,
    },
    workspace = {
      patterns = { "packages/*" },
      priority = { "packages" },
    },
    env_resolution = {
      strategy = "workspace_first",
      inheritance = true,
      override_order = { "workspace", "root" },
    },
    priority = 3,
  },

  rush = {
    name = "rush",
    detection = {
      strategies = { "file_markers" },
      file_markers = { "rush.json" },
      max_depth = 4,
      cache_duration = 300000,
    },
    workspace = {
      patterns = { "apps/*", "libraries/*", "tools/*" },
      priority = { "apps", "libraries", "tools" },
    },
    env_resolution = {
      strategy = "workspace_first",
      inheritance = true,
      override_order = { "workspace", "root" },
    },
    priority = 4,
  },

  yarn_workspaces = {
    name = "yarn_workspaces",
    detection = {
      strategies = { "file_markers" },
      file_markers = { "package.json" },
      max_depth = 4,
      cache_duration = 300000,
    },
    workspace = {
      patterns = { "packages/*", "apps/*", "services/*" },
      priority = { "apps", "packages", "services" },
    },
    env_resolution = {
      strategy = "workspace_first",
      inheritance = true,
      override_order = { "workspace", "root" },
    },
    priority = 5,
  },

  cargo_workspaces = {
    name = "cargo_workspaces",
    detection = {
      strategies = { "file_markers" },
      file_markers = { "Cargo.toml" },
      max_depth = 4,
      cache_duration = 300000,
    },
    workspace = {
      patterns = { "crates/*", "libs/*", "bins/*" },
      priority = { "bins", "crates", "libs" },
    },
    env_resolution = {
      strategy = "workspace_first",
      inheritance = true,
      override_order = { "workspace", "root" },
    },
    priority = 6,
  },
}

---Get default configuration
---@return table config Default configuration
function Defaults.get_config()
  return vim.deepcopy(DEFAULT_CONFIG)
end

---Get built-in provider configuration
---@param provider_name string Name of the provider
---@return table? config Provider configuration or nil if not found
function Defaults.get_provider_config(provider_name)
  local config = BUILTIN_PROVIDERS[provider_name]
  return config and vim.deepcopy(config) or nil
end

---Get all built-in provider configurations
---@return table<string, table> configs Map of provider name to configuration
function Defaults.get_all_provider_configs()
  return vim.deepcopy(BUILTIN_PROVIDERS)
end

---Get list of available built-in providers
---@return string[] provider_names List of built-in provider names
function Defaults.get_builtin_provider_names()
  local names = {}
  for name, _ in pairs(BUILTIN_PROVIDERS) do
    table.insert(names, name)
  end
  table.sort(names)
  return names
end

---Create configuration with specific providers enabled
---@param provider_names string[] List of provider names to enable
---@return table config Configuration with specified providers
function Defaults.create_config_with_providers(provider_names)
  local config = Defaults.get_config()
  config.enabled = true
  config.providers.builtin = provider_names
  return config
end

---Create minimal configuration for testing
---@return table config Minimal test configuration
function Defaults.get_test_config()
  return {
    enabled = true,
    auto_switch = false,
    notify_on_switch = false,
    providers = {
      builtin = { "turborepo" },
      custom = {},
    },
    performance = {
      cache = {
        max_entries = 100,
        default_ttl = 10000, -- 10 seconds for testing
        cleanup_interval = 5000, -- 5 seconds
      },
      auto_switch_throttle = {
        min_interval = 10,
        debounce_delay = 50,
        same_file_skip = false,
        workspace_boundary_only = false,
        max_checks_per_second = 100,
      },
    },
  }
end

---Create configuration for specific monorepo type
---@param monorepo_type string Type of monorepo (turborepo, nx, lerna, etc.)
---@return table config Configuration optimized for the monorepo type
function Defaults.create_config_for_type(monorepo_type)
  local config = Defaults.get_config()
  config.enabled = true

  -- Set primary provider for this type
  config.providers.builtin = { monorepo_type }

  -- Add complementary providers based on type
  if monorepo_type == "turborepo" then
    config.providers.builtin = { "turborepo", "nx" }
  elseif monorepo_type == "nx" then
    config.providers.builtin = { "nx", "turborepo" }
  elseif monorepo_type == "lerna" then
    config.providers.builtin = { "lerna", "yarn_workspaces" }
  elseif monorepo_type == "yarn_workspaces" then
    config.providers.builtin = { "yarn_workspaces", "lerna" }
  end

  return config
end

---Merge user configuration with defaults
---@param user_config table User configuration
---@return table config Merged configuration
function Defaults.merge_with_user_config(user_config)
  local default_config = Defaults.get_config()
  return vim.tbl_deep_extend("force", default_config, user_config)
end

---Get configuration for development/debugging
---@return table config Development configuration with verbose logging
function Defaults.get_development_config()
  local config = Defaults.get_config()
  config.enabled = true
  config.notify_on_switch = true
  config.performance.cache.default_ttl = 30000 -- 30 seconds
  config.performance.auto_switch_throttle.min_interval = 50
  config.performance.auto_switch_throttle.debounce_delay = 100
  return config
end

return Defaults

