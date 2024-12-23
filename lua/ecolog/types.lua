---@class TypeDefinition
---@field pattern string Lua pattern for matching
---@field validate? fun(value: string): boolean Function for additional validation
---@field transform? fun(value: string): string Function to transform the value

---@class TypesConfig
---@field types boolean|table<string, boolean|TypeDefinition> Type configuration
---@field custom_types? table<string, TypeDefinition> Custom type definitions

local M = {}

-- Built-in type definitions with their patterns and validation functions
local TYPE_DEFINITIONS = {
  -- Data types
  boolean = {
    pattern = "^[a-zA-Z0-9]+$",
    validate = function(value)
      local lower = value:lower()
      return lower == "true" or lower == "false" or lower == "yes" or lower == "no" or lower == "1" or lower == "0"
    end,
    transform = function(value)
      local lower = value:lower()
      if lower == "yes" or lower == "1" or lower == "true" then
        return "true"
      end
      return "false"
    end,
  },
  number = {
    pattern = "^-?%d+%.?%d*$",
  },
  json = {
    pattern = "^%s*[{%[].*[%]}]%s*$",
    validate = function(str)
      local status = pcall(function()
        vim.json.decode(str)
      end)
      return status
    end,
  },
  -- Network types
  url = {
    pattern = "^https?://[%w%-%.]+"  -- hostname part
      .. "%.[%w%-%.]+"  -- domain part
      .. "[%w%-%./:%?=&#]*$",  -- path and query part
  },
  localhost = {
    pattern = "^https?://[^/:]+:?%d*/?.*$",
    validate = function(url)
      local host = url:match("^https?://([^/:]+)")
      if not (host == "localhost" or host == "127.0.0.1") then
        return false
      end
      local port = url:match(":(%d+)")
      if port then
        port = tonumber(port)
        if not port or port < 1 or port > 65535 then
          return false
        end
      end
      return true
    end,
  },
  database_url = {
    pattern = "[%w%+]+://"  -- protocol
      .. "[^:/@]+"  -- username
      .. ":[^@]+"   -- password
      .. "@[^/:]+"  -- host
      .. ":[0-9]+"  -- port
      .. "/[^%?]+", -- database name
    validate = function(url)
      local protocol = url:match("^([%w%+]+)://")
      if not protocol then
        return false
      end

      local valid_protocols = {
        ["postgresql"] = true,
        ["postgres"] = true,
        ["mysql"] = true,
        ["mongodb"] = true,
        ["mongodb+srv"] = true,
        ["redis"] = true,
        ["rediss"] = true,
        ["sqlite"] = true,
        ["mariadb"] = true,
        ["cockroachdb"] = true,
      }

      if not valid_protocols[protocol:lower()] then
        return false
      end

      local user, pass, host, port = url:match("^[%w%+]+://([^:]+):([^@]+)@([^:]+):(%d+)")
      if not (user and pass and host and port) then
        return false
      end

      port = tonumber(port)
      if not port or port < 1 or port > 65535 then
        return false
      end

      return true
    end,
  },
  ipv4 = {
    pattern = "(%d%d?%d?)%.(%d%d?%d?)%.(%d%d?%d?)%.(%d%d?%d?)",
    validate = function(value)
      local parts = { value:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$") }
      if #parts ~= 4 then
        return false
      end
      for _, part in ipairs(parts) do
        local num = tonumber(part)
        if not num or num < 0 or num > 255 then
          return false
        end
      end
      return true
    end,
  },
  -- Date and time
  iso_date = {
    pattern = "^%d%d%d%d%-%d%d%-%d%d$",
    validate = function(value)
      local year, month, day = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
      year, month, day = tonumber(year), tonumber(month), tonumber(day)
      if not (year and month and day) then
        return false
      end
      if month < 1 or month > 12 then
        return false
      end
      if day < 1 or day > 31 then
        return false
      end
      if (month == 4 or month == 6 or month == 9 or month == 11) and day > 30 then
        return false
      end
      if month == 2 then
        local is_leap = (year % 4 == 0 and year % 100 ~= 0) or (year % 400 == 0)
        if (is_leap and day > 29) or (not is_leap and day > 28) then
          return false
        end
      end
      return true
    end,
  },
  iso_time = {
    pattern = "(%d%d):(%d%d):(%d%d)",
    validate = function(value)
      local hour, minute, second = value:match("^(%d%d):(%d%d):(%d%d)$")
      hour, minute, second = tonumber(hour), tonumber(minute), tonumber(second)
      if not (hour and minute and second) then
        return false
      end
      return hour >= 0 and hour < 24 and minute >= 0 and minute < 60 and second >= 0 and second < 60
    end,
  },
  -- Visual
  hex_color = {
    pattern = "^#%x+$",
    validate = function(value)
      local hex = value:sub(2)  -- Remove the #
      return (#hex == 3 or #hex == 6) and hex:match("^%x+$") ~= nil
    end,
  },
}

-- Configuration state
local config = {
  enabled_types = {},
  custom_types = {},
}

-- Initialize enabled types with all TYPE_DEFINITIONS enabled
local function init_enabled_types()
  for type_name, _ in pairs(TYPE_DEFINITIONS) do
    config.enabled_types[type_name] = true
  end
end

-- Pre-compile all patterns for better performance
local function compile_patterns()
  for type_name, type_def in pairs(TYPE_DEFINITIONS) do
    if type_def.pattern then
      -- Store both Lua pattern and vim.regex pattern
      type_def._lua_pattern = type_def.pattern
      -- Convert Lua pattern to vim regex pattern
      local vim_pattern = type_def.pattern:gsub("%%", "\\")
      type_def._compiled_pattern = vim.regex(vim_pattern)
    end
  end
end

-- Initialize configuration with defaults
init_enabled_types()
compile_patterns()

-- Setup function for types module
function M.setup(opts)
  opts = opts or {}

  -- Reset to defaults first
  init_enabled_types()
  config.custom_types = {}

  -- Handle types configuration
  if type(opts.types) == "table" then
    -- Reset all types to false first
    for type_name, _ in pairs(TYPE_DEFINITIONS) do
      config.enabled_types[type_name] = false
    end
    -- Enable only specified types
    for type_name, enabled in pairs(opts.types) do
      if TYPE_DEFINITIONS[type_name] then
        config.enabled_types[type_name] = enabled
      end
    end
  elseif type(opts.types) == "boolean" then
    -- Enable/disable all built-in types based on boolean value
    for type_name, _ in pairs(TYPE_DEFINITIONS) do
      config.enabled_types[type_name] = opts.types
    end
  end

  -- Handle custom types
  if opts.custom_types then
    for name, def in pairs(opts.custom_types) do
      if type(def) == "table" and def.pattern then
        -- Store both Lua pattern and vim.regex pattern
        def._lua_pattern = def.pattern
        -- Convert Lua pattern to vim regex pattern
        local vim_pattern = def.pattern:gsub("%%", "\\")
        def._compiled_pattern = vim.regex(vim_pattern)
        
        config.custom_types[name] = {
          pattern = def.pattern,
          _lua_pattern = def._lua_pattern,
          _compiled_pattern = def._compiled_pattern,
          validate = def.validate,
          transform = def.transform,
        }
        -- Always enable custom types
        config.enabled_types[name] = true
      end
    end
  end
end

-- Helper function to check if a value matches a pattern
local function matches_pattern(value, type_def)
  -- First try Lua pattern match
  if type_def._lua_pattern and value:match(type_def._lua_pattern) then
    return true
  end
  -- Then try vim.regex match
  if type_def._compiled_pattern and type_def._compiled_pattern:match_str(value) then
    return true
  end
  return false
end

-- Optimized type detection function
function M.detect_type(value)
  if not value then
    return "string", value
  end

  -- Check custom types first
  for type_name, type_def in pairs(config.custom_types) do
    if matches_pattern(value, type_def) then
      if not type_def.validate or type_def.validate(value) then
        if type_def.transform then
          value = type_def.transform(value)
        end
        return type_name, value
      end
    end
  end

  -- Special case for boolean - check validation first
  if config.enabled_types.boolean then
    local type_def = TYPE_DEFINITIONS.boolean
    if type_def.validate(value) then
      return "boolean", type_def.transform(value)
    end
  end

  -- Check built-in types in specific order
  local type_check_order = {
    "localhost",
    "database_url",
    "url",
    "iso_date",
    "iso_time",
    "hex_color",
    "ipv4",
    "number",
    "json",
  }

  for _, type_name in ipairs(type_check_order) do
    local type_def = TYPE_DEFINITIONS[type_name]
    if type_def and config.enabled_types[type_name] then
      if matches_pattern(value, type_def) then
        if type_def.validate then
          local is_valid = type_def.validate(value)
          if not is_valid then
            goto continue
          end
        end

        if type_def.transform then
          value = type_def.transform(value)
        end

        return type_name, value
      end

      ::continue::
    end
  end

  -- Default to string type
  return "string", value
end

return M
