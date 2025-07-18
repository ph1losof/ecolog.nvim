---@class ConfigSchema
local Schema = {}

---@class MonorepoConfigSchema
---@field enabled boolean Enable monorepo support
---@field auto_switch boolean Automatically switch workspaces based on current file
---@field notify_on_switch boolean Show notifications when switching workspaces
---@field providers ProvidersConfigSchema Provider configuration
---@field performance PerformanceConfigSchema Performance settings

---@class ProvidersConfigSchema
---@field builtin string[] List of built-in provider names to load
---@field custom CustomProviderConfig[] List of custom provider configurations

---@class CustomProviderConfig
---@field module? string Module path to load provider from
---@field provider? table Direct provider instance
---@field config? table Configuration for the provider

---@class PerformanceConfigSchema
---@field cache CacheConfigSchema Cache configuration
---@field auto_switch_throttle ThrottleConfigSchema Auto-switch throttling configuration

---@class CacheConfigSchema
---@field max_entries number Maximum cache entries before eviction
---@field default_ttl number Default TTL in milliseconds
---@field cleanup_interval number Cleanup interval in milliseconds

---@class ThrottleConfigSchema
---@field min_interval number Minimum milliseconds between checks
---@field debounce_delay number Debounce delay for rapid buffer changes
---@field same_file_skip boolean Skip check if file hasn't changed
---@field workspace_boundary_only boolean Only check when crossing workspace boundaries
---@field max_checks_per_second number Rate limiting

-- Configuration schema definition
local CONFIG_SCHEMA = {
  enabled = { type = "boolean", default = false },
  auto_switch = { type = "boolean", default = true },
  notify_on_switch = { type = "boolean", default = false },

  providers = {
    type = "table",
    default = {},
    schema = {
      builtin = {
        type = "table",
        default = { "turborepo", "nx" },
        items = { type = "string" },
      },
      custom = {
        type = "table",
        default = {},
        items = {
          type = "table",
          schema = {
            module = { type = "string", optional = true },
            provider = { type = "table", optional = true },
            config = { type = "table", optional = true },
          },
        },
      },
    },
  },

  performance = {
    type = "table",
    default = {},
    schema = {
      cache = {
        type = "table",
        default = {},
        schema = {
          max_entries = { type = "number", default = 1000, min = 10, max = 10000 },
          default_ttl = { type = "number", default = 300000, min = 1000, max = 3600000 },
          cleanup_interval = { type = "number", default = 60000, min = 1000, max = 300000 },
        },
      },
      auto_switch_throttle = {
        type = "table",
        default = {},
        schema = {
          min_interval = { type = "number", default = 100, min = 0, max = 1000 },
          debounce_delay = { type = "number", default = 250, min = 0, max = 2000 },
          same_file_skip = { type = "boolean", default = true },
          workspace_boundary_only = { type = "boolean", default = true },
          max_checks_per_second = { type = "number", default = 10, min = 1, max = 100 },
        },
      },
    },
  },
}

---Validate configuration value against schema
---@param value any Value to validate
---@param field_schema table Schema for the field
---@param field_name string Name of the field (for error messages)
---@return boolean valid Whether value is valid
---@return string? error Error message if invalid
local function validate_field(value, field_schema, field_name)
  -- Check if field is optional and value is nil
  if field_schema.optional and value == nil then
    return true, nil
  end

  -- Check type
  if field_schema.type and type(value) ~= field_schema.type then
    return false, string.format("Field '%s' must be of type %s, got %s", field_name, field_schema.type, type(value))
  end

  -- Type-specific validation
  if field_schema.type == "number" then
    if field_schema.min and value < field_schema.min then
      return false, string.format("Field '%s' must be >= %s, got %s", field_name, field_schema.min, value)
    end
    if field_schema.max and value > field_schema.max then
      return false, string.format("Field '%s' must be <= %s, got %s", field_name, field_schema.max, value)
    end
  elseif field_schema.type == "table" then
    if field_schema.schema then
      -- Validate nested table schema
      for sub_field, sub_schema in pairs(field_schema.schema) do
        local valid, error_msg = validate_field(value[sub_field], sub_schema, field_name .. "." .. sub_field)
        if not valid then
          return false, error_msg
        end
      end
    end

    if field_schema.items then
      -- Validate array items
      for i, item in ipairs(value) do
        local valid, error_msg = validate_field(item, field_schema.items, field_name .. "[" .. i .. "]")
        if not valid then
          return false, error_msg
        end
      end
    end
  end

  return true, nil
end

---Validate configuration against schema
---@param config table Configuration to validate
---@return boolean valid Whether configuration is valid
---@return string? error Error message if invalid
function Schema.validate(config)
  if type(config) ~= "table" then
    return false, "Configuration must be a table"
  end

  -- Validate each field in the schema
  for field_name, field_schema in pairs(CONFIG_SCHEMA) do
    local value = config[field_name]
    local valid, error_msg = validate_field(value, field_schema, field_name)
    if not valid then
      return false, error_msg
    end
  end

  -- Check for unknown fields
  for field_name, _ in pairs(config) do
    if not CONFIG_SCHEMA[field_name] then
      return false, string.format("Unknown configuration field: %s", field_name)
    end
  end

  return true, nil
end

---Apply default values to configuration
---@param config table Configuration to apply defaults to
---@return table config Configuration with defaults applied
function Schema.apply_defaults(config)
  local function apply_defaults_recursive(value, schema)
    if schema.type == "table" and schema.schema then
      local result = value or {}
      for field_name, field_schema in pairs(schema.schema) do
        if result[field_name] == nil and field_schema.default ~= nil then
          result[field_name] = field_schema.default
        elseif field_schema.schema then
          result[field_name] = apply_defaults_recursive(result[field_name], field_schema)
        end
      end
      return result
    else
      return value ~= nil and value or schema.default
    end
  end

  local result = {}
  for field_name, field_schema in pairs(CONFIG_SCHEMA) do
    result[field_name] = apply_defaults_recursive(config[field_name], field_schema)
  end

  return result
end

---Get schema for a specific field
---@param field_name string Name of the field
---@return table? schema Schema for the field or nil if not found
function Schema.get_field_schema(field_name)
  return CONFIG_SCHEMA[field_name]
end

---Get full configuration schema
---@return table schema Full configuration schema
function Schema.get_schema()
  return vim.deepcopy(CONFIG_SCHEMA)
end

---Merge configuration with validation
---@param base_config table Base configuration
---@param new_config table New configuration to merge
---@return table merged_config Merged configuration
---@return boolean valid Whether merged configuration is valid
---@return string? error Error message if invalid
function Schema.merge_and_validate(base_config, new_config)
  local merged = vim.tbl_deep_extend("force", base_config, new_config)
  merged = Schema.apply_defaults(merged)

  local valid, error_msg = Schema.validate(merged)
  return merged, valid, error_msg
end

return Schema

