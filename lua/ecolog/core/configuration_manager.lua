---@class ConfigurationManager
local ConfigurationManager = {}

local NotificationManager = require("ecolog.core.notification_manager")

-- Default configuration templates
local DEFAULT_TEMPLATES = {
  base = {
    path = nil, -- Will be set to vim.fn.getcwd() if not provided
    types = true,
    interpolation = { enabled = true },
    integrations = {},
    provider_patterns = { extract = true, cmp = true },
    env_file_patterns = { ".env*" },
    sort_file_fn = nil,
    shelter = {
      configuration = "smart",
      modules = {},
    },
    monorepo = {
      enabled = false,
    },
  },
  
  monorepo = {
    enabled = false,
    auto_switch = true,
    notify_on_switch = false,
    providers = {
      builtin = { "turborepo", "nx" },
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
  },
}

---Validate configuration structure and types
---@param config table Configuration to validate
---@return boolean valid Whether configuration is valid
---@return string? error Error message if invalid
function ConfigurationManager.validate_config(config)
  -- Ensure config is a table
  if type(config) ~= "table" then
    return false, "Configuration must be a table"
  end

  -- Validate types option
  if config.types ~= nil and type(config.types) ~= "boolean" and type(config.types) ~= "table" then
    return false, "types must be boolean or table, got " .. type(config.types)
  end

  -- Validate interpolation option
  if config.interpolation ~= nil 
     and type(config.interpolation) ~= "boolean" 
     and type(config.interpolation) ~= "table" then
    return false, "interpolation must be boolean or table, got " .. type(config.interpolation)
  end

  -- Validate integrations
  if config.integrations ~= nil and type(config.integrations) ~= "table" then
    return false, "integrations must be a table, got " .. type(config.integrations)
  end

  -- Validate provider_patterns
  if config.provider_patterns ~= nil 
     and type(config.provider_patterns) ~= "boolean" 
     and type(config.provider_patterns) ~= "table" then
    return false, "provider_patterns must be boolean or table, got " .. type(config.provider_patterns)
  end

  -- Validate env_file_patterns
  if config.env_file_patterns ~= nil and type(config.env_file_patterns) ~= "table" then
    return false, "env_file_patterns must be a table, got " .. type(config.env_file_patterns)
  end

  -- Validate monorepo configuration if present
  if config.monorepo ~= nil then
    if type(config.monorepo) ~= "table" and type(config.monorepo) ~= "boolean" then
      return false, "monorepo must be boolean or table, got " .. type(config.monorepo)
    end
    
    if type(config.monorepo) == "table" then
      -- Use monorepo schema validation if available
      local has_schema, schema = pcall(require, "ecolog.monorepo.config.schema")
      if has_schema then
        local valid, error_msg = schema.validate(config.monorepo)
        if not valid then
          return false, "monorepo configuration invalid: " .. (error_msg or "unknown error")
        end
      end
    end
  end

  return true, nil
end

---Normalize configuration values to consistent formats
---@param config table Configuration to normalize
---@return table normalized_config Normalized configuration
function ConfigurationManager.normalize_config(config)
  local normalized = vim.deepcopy(config)

  -- Normalize provider_patterns
  if type(normalized.provider_patterns) == "boolean" then
    normalized.provider_patterns = {
      extract = normalized.provider_patterns,
      cmp = normalized.provider_patterns,
    }
  elseif type(normalized.provider_patterns) == "table" then
    normalized.provider_patterns = vim.tbl_deep_extend("force", {
      extract = true,
      cmp = true,
    }, normalized.provider_patterns)
  end

  -- Normalize interpolation
  if type(normalized.interpolation) == "boolean" then
    normalized.interpolation = { enabled = normalized.interpolation }
  end

  -- Normalize monorepo configuration
  if type(normalized.monorepo) == "boolean" then
    normalized.monorepo = { enabled = normalized.monorepo }
  end

  -- Handle deprecated fields with warnings
  if normalized.env_file_pattern ~= nil then
    NotificationManager.notify(
      "env_file_pattern is deprecated, please use env_file_patterns instead with glob patterns (e.g., '.env.*', 'config/.env*')",
      vim.log.levels.WARN
    )
    if type(normalized.env_file_pattern) == "table" and #normalized.env_file_pattern > 0 then
      normalized.env_file_patterns = normalized.env_file_pattern
    end
    normalized.env_file_pattern = nil
  end

  -- Handle backward compatibility for sort_fn -> sort_file_fn
  if normalized.sort_fn ~= nil and normalized.sort_file_fn == nil then
    NotificationManager.notify("sort_fn is deprecated, please use sort_file_fn instead", vim.log.levels.WARN)
    normalized.sort_file_fn = normalized.sort_fn
    normalized.sort_fn = nil
  end

  return normalized
end

---Merge multiple configurations with proper precedence
---@param base_config table Base configuration
---@param override_config table Configuration to merge in
---@return table merged_config Merged configuration
function ConfigurationManager.merge_configs(base_config, override_config)
  if not base_config then
    return vim.deepcopy(override_config or {})
  end
  
  if not override_config then
    return vim.deepcopy(base_config)
  end

  return vim.tbl_deep_extend("force", base_config, override_config)
end

---Get default configuration template
---@param template_name string? Name of template ("base", "monorepo", etc.)
---@return table default_config Default configuration
function ConfigurationManager.get_default_config(template_name)
  template_name = template_name or "base"
  
  local template = DEFAULT_TEMPLATES[template_name]
  if not template then
    NotificationManager.notify(
      "Unknown configuration template: " .. tostring(template_name) .. ", using base template",
      vim.log.levels.WARN
    )
    template = DEFAULT_TEMPLATES.base
  end

  local config = vim.deepcopy(template)
  
  -- Set default path if not provided
  if not config.path then
    config.path = vim.fn.getcwd()
  end

  return config
end

---Apply defaults to configuration while preserving user values
---@param config table User configuration
---@param template_name string? Template to use for defaults
---@return table complete_config Configuration with defaults applied
function ConfigurationManager.apply_defaults(config, template_name)
  local defaults = ConfigurationManager.get_default_config(template_name)
  return ConfigurationManager.merge_configs(defaults, config)
end

---Validate and normalize configuration in one step
---@param config table Raw configuration
---@param template_name string? Template to use for defaults
---@return table processed_config Processed configuration
---@return boolean valid Whether configuration is valid
---@return string? error Error message if invalid
function ConfigurationManager.process_config(config, template_name)
  -- Apply defaults first
  local processed = ConfigurationManager.apply_defaults(config or {}, template_name)
  
  -- Normalize the configuration
  processed = ConfigurationManager.normalize_config(processed)
  
  -- Validate the final configuration
  local valid, error_msg = ConfigurationManager.validate_config(processed)
  
  return processed, valid, error_msg
end

---Create a configuration with validation and error handling
---@param user_config table? User-provided configuration
---@param template_name string? Template to use
---@return table config Final configuration (may be default if user config is invalid)
function ConfigurationManager.create_config(user_config, template_name)
  -- Handle invalid user config types gracefully
  if user_config ~= nil and type(user_config) ~= "table" then
    NotificationManager.notify(
      "Configuration must be a table, got " .. type(user_config) .. ". Using default configuration.",
      vim.log.levels.WARN
    )
    user_config = {}
  end

  local processed, valid, error_msg = ConfigurationManager.process_config(user_config, template_name)
  
  if not valid then
    NotificationManager.notify(
      "Configuration validation failed: " .. (error_msg or "unknown error") .. ". Using default configuration.",
      vim.log.levels.WARN
    )
    -- Fall back to default configuration
    processed = ConfigurationManager.get_default_config(template_name)
  end

  return processed
end

---Get configuration schema information
---@return table schema_info Information about configuration structure
function ConfigurationManager.get_schema_info()
  return {
    templates = vim.tbl_keys(DEFAULT_TEMPLATES),
    required_fields = { "path" },
    optional_fields = { 
      "types", "interpolation", "integrations", "provider_patterns", 
      "env_file_patterns", "sort_file_fn", "shelter", "monorepo" 
    },
    deprecated_fields = { "env_file_pattern", "sort_fn" },
  }
end

return ConfigurationManager