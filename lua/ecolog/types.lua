---@class TypeDefinition
---@field pattern string Lua pattern for matching
---@field validate? fun(value: string): boolean Function for additional validation
---@field transform? fun(value: string): string Function to transform the value

---@class TypesConfig
---@field types boolean|table<string, boolean|TypeDefinition> Type configuration
---@field custom_types? table<string, TypeDefinition> Custom type definitions

local M = {}

local TYPE_DEFINITIONS = {

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
    transform = function(value)
      return tostring(tonumber(value))
    end,
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

  url = {
    pattern = "^https?://[%w%-%.]+" .. "%.[%w%-%.]+" .. "[%w%-%./:%?=&#]*$",
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
    pattern = "[%w%+]+://[^/@]+@[^/@]+/?[^%s]*",
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

      local auth_host = url:match("^[%w%+]+://([^/]+)")
      if not auth_host then
        return false
      end

      local user_pass, host = auth_host:match("([^@]+)@(.+)")
      if not (user_pass and host) then
        return false
      end

      local user, pass = user_pass:match("([^:]+):(.+)")
      if not (user and pass) then
        return false
      end

      local host_part, port = host:match("([^:]+):(%d+)")
      if host_part then
        if not port then
          return false
        end
        port = tonumber(port)
        if not port or port < 1 or port > 65535 then
          return false
        end
      else
        if protocol:lower() ~= "mongodb+srv" then
          return false
        end
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

  email = {
    pattern = "[%w%._%+%-]+@[%w%.%-]+%.[%w]+",
    validate = function(value)
      -- Basic email validation pattern
      local local_part, domain = value:match("^([%w%._%+%-]+)@([%w%.%-]+%.[%w]+)$")
      if not local_part or not domain then
        return false
      end
      -- Check for valid characters and structure
      if local_part:match("^%.") or local_part:match("%.$") or local_part:match("%.%.") then
        return false
      end
      if domain:match("^%.") or domain:match("%.$") or domain:match("%.%.") then
        return false
      end
      return true
    end,
  },

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

  hex_color = {
    pattern = "^#%x+$",
    validate = function(value)
      local hex = value:sub(2)
      return (#hex == 3 or #hex == 6) and hex:match("^%x+$") ~= nil
    end,
  },
}

local config = {
  enabled_types = {},
  custom_types = {},
}

local function init_enabled_types()
  for type_name, _ in pairs(TYPE_DEFINITIONS) do
    config.enabled_types[type_name] = true
  end
end

local function compile_patterns()
  for type_name, type_def in pairs(TYPE_DEFINITIONS) do
    if type_def.pattern then
      type_def._lua_pattern = type_def.pattern

      local vim_pattern = type_def.pattern:gsub("%%", "\\")
      type_def._compiled_pattern = vim.regex(vim_pattern)
    end
  end
end

init_enabled_types()
compile_patterns()

function M.setup(opts)
  opts = opts or {}

  init_enabled_types()
  config.custom_types = {}

  if type(opts.types) == "table" then
    for type_name, _ in pairs(TYPE_DEFINITIONS) do
      config.enabled_types[type_name] = false
    end

    for type_name, enabled in pairs(opts.types) do
      if TYPE_DEFINITIONS[type_name] then
        config.enabled_types[type_name] = enabled
      end
    end
  elseif type(opts.types) == "boolean" then
    for type_name, _ in pairs(TYPE_DEFINITIONS) do
      config.enabled_types[type_name] = opts.types
    end
  end

  if opts.custom_types then
    for name, def in pairs(opts.custom_types) do
      if type(def) == "table" and def.pattern then
        def._lua_pattern = def.pattern

        local vim_pattern = def.pattern:gsub("%%", "\\")
        def._compiled_pattern = vim.regex(vim_pattern)

        config.custom_types[name] = {
          pattern = def.pattern,
          _lua_pattern = def._lua_pattern,
          _compiled_pattern = def._compiled_pattern,
          validate = def.validate,
          transform = def.transform,
        }

        config.enabled_types[name] = true
      end
    end
  end
end

local function matches_pattern(value, type_def)
  if type_def._lua_pattern and value:match(type_def._lua_pattern) then
    return true
  end

  if type_def._compiled_pattern and type_def._compiled_pattern:match_str(value) then
    return true
  end
  return false
end

function M.detect_type(value)
  if not value then
    return "string", value
  end

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

  if config.enabled_types.boolean then
    local type_def = TYPE_DEFINITIONS.boolean
    if type_def.validate(value) then
      return "boolean", type_def.transform(value)
    end
  end

  local type_check_order = {
    "localhost",
    "database_url",
    "url",
    "email",
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

  return "string", value
end

return M
