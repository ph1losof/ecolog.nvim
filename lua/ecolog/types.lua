---@class TypeDefinition
---@field pattern string Lua pattern for matching
---@field validate? fun(value: string): boolean Function for additional validation
---@field transform? fun(value: string): string Function to transform the value

---@class TypesConfig
---@field types boolean|table<string, boolean|TypeDefinition> Type configuration
---@field custom_types? table<string, TypeDefinition> Custom type definitions

local M = {}

-- Configuration state
---@type table<string, boolean>
local config = {
  built_in_types = {
    -- Network types
    url = true,
    localhost = true,
    ipv4 = true,
    database_url = true,
    -- Data types
    number = true,
    boolean = true,
    json = true,
    -- Date and time
    iso_date = true,
    iso_time = true,
    -- Visual
    hex_color = true,
  }
}

-- Setup function for types module
function M.setup(opts)
  opts = opts or {}
  
  -- Handle types configuration
  if type(opts.types) == "table" then
    -- Reset all types to false first
    for type_name in pairs(config.built_in_types) do
      config.built_in_types[type_name] = false
    end
    -- Enable specified types and store custom types
    for type_name, type_def in pairs(opts.types) do
      if config.built_in_types[type_name] ~= nil then
        config.built_in_types[type_name] = type_def
      elseif type(type_def) == "table" and type_def.pattern then
        -- Store custom type
        M.custom_types[type_name] = {
          pattern = type_def.pattern,
          validate = type_def.validate,
          transform = type_def.transform,
        }
      end
    end
  elseif type(opts.types) == "boolean" then
    -- Enable/disable all built-in types based on boolean value
    for type_name in pairs(config.built_in_types) do
      config.built_in_types[type_name] = opts.types
    end
  end
end

-- Pre-compile patterns for better performance
M.PATTERNS = {
  -- Core types
  number = "^-?%d+%.?%d*$", -- Integers and decimals
  boolean = "^(true|false|yes|no|1|0)$",
  -- Network types
  ipv4 = "^(%d%d?%d?)%.(%d%d?%d?)%.(%d%d?%d?)%.(%d%d?%d?)$",
  url = "^https?://[%w%-%.]+%.[%w%-%.]+[%w%-%./:?=&]*$", -- Updated pattern to include query params
  localhost = "^https?://(localhost|127%.0%.0%.1)(:%d+)?[%w%-%./:]*$", -- Localhost URLs
  -- Database URLs
  database_url = "^([%w+]+)://([^:/@]+:[^@]*@)?([^/:]+)(:%d+)?(/[^?]*)?(%?.*)?$",
  -- Date and time
  iso_date = "^(%d%d%d%d)-(%d%d)-(%d%d)$",
  iso_time = "^(%d%d):(%d%d):(%d%d)$",
  -- Data formats
  json = "^[%s]*[{%[].-[}%]][%s]*$",
  -- Color formats
  hex_color = "^#([%x][%x][%x]|[%x][%x][%x][%x][%x][%x])$", -- #RGB or #RRGGBB
}

-- Known database protocols
local DB_PROTOCOLS = {
  ["postgresql"] = true,
  ["postgres"] = true,
  ["mysql"] = true,
  ["mongodb"] = true,
  ["mongodb+srv"] = true,
  ["redis"] = true,
  ["rediss"] = true, -- Redis with SSL
  ["sqlite"] = true,
  ["mariadb"] = true,
  ["cockroachdb"] = true,
}

-- Store custom types
M.custom_types = {}

-- Cache compiled patterns
local compiled_patterns = {}

local function get_compiled_pattern(pattern)
  if not compiled_patterns[pattern] then
    compiled_patterns[pattern] = {
      match = string.match,
      pattern = pattern
    }
  end
  return compiled_patterns[pattern]
end

-- Validation functions
local function is_valid_ipv4(matches)
  for i = 1, 4 do
    local num = tonumber(matches[i])
    if not num or num < 0 or num > 255 then
      return false
    end
  end
  return true
end

local function is_valid_url(url)
  -- Basic URL validation that matches common REST API URLs
  return url:match("^https?://[%w%-%.]+%.[%w%-%.]+[%w%-%./:?=&]*$") ~= nil
end

local function is_valid_localhost(url)
  -- Basic URL validation
  if not url:match("^https?://") then
    return false
  end

  -- Extract host and optional port
  local host, port = url:match("^https?://([^/:]+)(:%d+)?")
  if not host then
    return false
  end

  -- Validate localhost variants
  if host ~= "localhost" and host ~= "127.0.0.1" then
    return false
  end

  -- Validate port if present
  if port then
    local port_num = tonumber(port:sub(2)) -- Remove the colon
    if not port_num or port_num < 1 or port_num > 65535 then
      return false
    end
  end

  return true
end

local function is_valid_database_url(url)
  -- Extract URL components
  local protocol, auth, host, port, path, query = url:match(M.PATTERNS.database_url)
  if not protocol or not host then
    return false
  end

  -- Validate protocol
  if not DB_PROTOCOLS[protocol:lower()] then
    return false
  end

  -- Validate port if present
  if port then
    local port_num = tonumber(port:sub(2)) -- Remove the colon
    if not port_num or port_num < 1 or port_num > 65535 then
      return false
    end
  end

  -- Special validation for sqlite
  if protocol:lower() == "sqlite" then
    -- SQLite requires a path
    if not path or path == "/" then
      return false
    end
    return true
  end

  -- Special validation for mongodb+srv
  if protocol:lower() == "mongodb+srv" then
    -- mongodb+srv requires a hostname and doesn't use ports
    if port then
      return false
    end
    -- Must have at least one dot in hostname (DNS requirement)
    if not host:find("%.") then
      return false
    end
  end

  return true
end

local function is_valid_json(str)
  local status = pcall(function()
    vim.json.decode(str)
  end)
  return status
end

local function is_valid_hex_color(hex)
  -- Remove the # prefix
  hex = hex:sub(2)
  -- Convert 3-digit hex to 6-digit
  if #hex == 3 then
    hex = hex:gsub(".", function(c)
      return c .. c
    end)
  end
  -- Check if all characters are valid hex digits
  return #hex == 6 and hex:match("^%x+$") ~= nil
end

local function is_valid_date(year, month, day)
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

  -- Check months with 30 days
  if (month == 4 or month == 6 or month == 9 or month == 11) and day > 30 then
    return false
  end

  -- Check February
  if month == 2 then
    local is_leap = (year % 4 == 0 and year % 100 ~= 0) or (year % 400 == 0)
    if (is_leap and day > 29) or (not is_leap and day > 28) then
      return false
    end
  end

  return true
end

local function is_valid_time(hour, minute, second)
  hour, minute, second = tonumber(hour), tonumber(minute), tonumber(second)
  if not (hour and minute and second) then
    return false
  end

  return hour >= 0 and hour < 24 and minute >= 0 and minute < 60 and second >= 0 and second < 60
end

-- Type detection function
function M.detect_type(value)
  -- Check for database URLs first (must start with a database protocol)
  local protocol = value:match("^([%w+]+)://")
  if protocol and DB_PROTOCOLS[protocol:lower()] then
    return "database_url", value
  end
  
  -- Check for regular URLs - ensure type is enabled and validation passes
  if config.built_in_types.url and value:match("^https?://[%w%-%.]+%.[%w%-%.]+[%w%-%./:]*$") then
    -- Simplified URL validation for common cases
    return "url", value
  end
  
  if config.built_in_types.localhost and value:match(M.PATTERNS.localhost) and is_valid_localhost(value) then
    return "localhost", value
  end
  
  if config.built_in_types.database_url and value:match(M.PATTERNS.database_url) and is_valid_database_url(value) then
    return "database_url", value
  end

  -- Check custom types if enabled
  if config.custom_types_enabled then
    for type_name, type_def in pairs(M.custom_types) do
      if value:match(type_def.pattern) then
        if not type_def.validate or type_def.validate(value) then
          if type_def.transform then
            value = type_def.transform(value)
          end
          return type_name, value
        end
      end
    end
  end

  if config.built_in_types.boolean and value:match(M.PATTERNS.boolean) then
    -- Normalize boolean values
    value = value:lower()
    if value == "yes" or value == "1" or value == "true" then
      value = "true"
    else
      value = "false"
    end
    return "boolean", value
  end

  if config.built_in_types.json and value:match(M.PATTERNS.json) and is_valid_json(value) then
    return "json", value
  end

  if config.built_in_types.hex_color and value:match(M.PATTERNS.hex_color) and is_valid_hex_color(value) then
    return "hex_color", value
  end

  if config.built_in_types.ipv4 then
    local ip_parts = { value:match(M.PATTERNS.ipv4) }
    if #ip_parts == 4 and is_valid_ipv4(ip_parts) then
      return "ipv4", value
    end
  end

  if config.built_in_types.iso_date and value:match(M.PATTERNS.iso_date) then
    local year, month, day = value:match(M.PATTERNS.iso_date)
    if is_valid_date(year, month, day) then
      return "iso_date", value
    end
  end

  if config.built_in_types.iso_time and value:match(M.PATTERNS.iso_time) then
    local hour, minute, second = value:match(M.PATTERNS.iso_time)
    if is_valid_time(hour, minute, second) then
      return "iso_time", value
    end
  end

  if config.built_in_types.number and value:match(M.PATTERNS.number) then
    return "number", value
  end

  -- Default to string type
  return "string", value
end

-- Register custom types
function M.register_custom_types(types)
  M.custom_types = {} -- Clear existing custom types
  for type_name, type_def in pairs(types or {}) do
    if type(type_def) == "table" and type_def.pattern then
      M.custom_types[type_name] = {
        pattern = type_def.pattern,
        validate = type_def.validate,
        transform = type_def.transform,
      }
    else
      vim.notify(
        string.format(
          "Invalid custom type definition for '%s': must be a table with at least a 'pattern' field",
          type_name
        ),
        vim.log.levels.WARN
      )
    end
  end
end

-- Optimize type validation
function M.validate_type(value, type_name)
  local pattern = M.PATTERNS[type_name]
  if not pattern then return false end
  
  local compiled = get_compiled_pattern(pattern)
  return compiled.match(value, compiled.pattern) ~= nil
end

return M

