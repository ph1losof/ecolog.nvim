local M = {}
local NotificationManager = require("ecolog.core.notification_manager")

-- Compatibility layer for uv -> vim.uv migration
local uv = vim.uv or uv

local PATTERNS = {
  SINGLE_QUOTED = "^'(.*)'$",
  DOUBLE_QUOTED = '^"(.*)"$',
  BRACE_VAR = "${([^}]+)}",  -- Keep for backward compatibility but won't be used for nested
  SIMPLE_VAR = "$([%a_][%w_]*)",
  CMD_SUBST = "%$%((.-)%)",
  VAR_PARTS = "([%w_]+)([:%-+]?[%-+]?)(.*)",
}

local OPERATORS = {
  DEFAULT = ":-",
  ALTERNATE = "-",
  ALT_IF_SET_NON_EMPTY = ":+",
  ALT_IF_SET = "+",
}

---@class EscapeMap
---@field [string] string

local ESCAPE_MAP = {
  n = "\n",
  r = "\r",
  t = "\t",
  ["\\"] = "\\",
  ['"'] = '"',
  ["'"] = "'",
}

---@class InterpolationOptions
---@field max_iterations? number Maximum number of iterations for variable interpolation
---@field warn_on_undefined? boolean Whether to warn on undefined variables
---@field disable_security? boolean Whether to disable security sanitization for command substitution
---@field fail_on_cmd_error? boolean Whether to fail on command substitution errors
---@field features? table Control specific interpolation features
---@field features.variables? boolean Enable variable interpolation ($VAR, ${VAR})
---@field features.defaults? boolean Enable default value syntax (${VAR:-default})
---@field features.alternates? boolean Enable alternate value syntax (${VAR-alternate})
---@field features.commands? boolean Enable command substitution ($(command))
---@field features.escapes? boolean Enable escape sequences (\n, \t, etc.)

---Handle escape sequences in a string
---@param str string The string containing escape sequences
---@param opts InterpolationOptions The interpolation options
---@return string The string with escape sequences replaced
local function handle_escapes(str, opts)
  if not opts.features or opts.features.escapes then
    return str:gsub("\\([nrt\"'\\])", ESCAPE_MAP)
  end
  return str
end

---Extract the inner content of a quoted string
---@param value string The string to extract from
---@param pattern string The pattern to match
---@param opts InterpolationOptions The interpolation options
---@return string? inner The inner content if matched, nil otherwise
local function extract_quoted_content(value, pattern, opts)
  local inner = value:match(pattern)
  return inner and handle_escapes(inner, opts)
end

---Find and extract balanced brace variables like ${...}
---Handles nested braces properly
---@param str string The string to search in
---@return table Array of {start_pos, end_pos, content} for each variable found
local function find_balanced_brace_vars(str)
  local results = {}
  local i = 1

  while i <= #str do
    -- Look for ${
    local start = str:find("${", i, true)
    if not start then break end

    -- Find the matching closing brace
    local depth = 1
    local pos = start + 2
    local content_start = pos

    while pos <= #str and depth > 0 do
      local char = str:sub(pos, pos)
      if char == "{" then
        depth = depth + 1
      elseif char == "}" then
        depth = depth - 1
      end
      pos = pos + 1
    end

    if depth == 0 then
      -- Found matching closing brace
      local content = str:sub(content_start, pos - 2)
      table.insert(results, {
        start_pos = start,
        end_pos = pos - 1,
        content = content
      })
      i = pos
    else
      -- No matching brace found, skip this ${
      i = start + 2
    end
  end

  return results
end

---Find and extract balanced command substitutions like $(...)
---Handles parentheses inside quotes properly
---@param str string The string to search in
---@return table Array of {start_pos, end_pos, content} for each command found
local function find_balanced_command_substs(str)
  local results = {}
  local i = 1

  while i <= #str do
    local start = str:find("$(", i, true)
    if not start then break end

    local pos = start + 2
    local content_start = pos
    local depth = 1
    local in_single_quote = false
    local in_double_quote = false
    local prev_char = nil

    while pos <= #str and depth > 0 do
      local char = str:sub(pos, pos)

      if prev_char == "\\" then
        prev_char = nil
        pos = pos + 1
        goto continue
      end

      if char == "'" and not in_double_quote then
        in_single_quote = not in_single_quote
      elseif char == '"' and not in_single_quote then
        in_double_quote = not in_double_quote
      elseif not in_single_quote and not in_double_quote then
        if char == "(" then
          depth = depth + 1
        elseif char == ")" then
          depth = depth - 1
        end
      end

      prev_char = char
      pos = pos + 1
      ::continue::
    end

    if depth == 0 then
      local content = str:sub(content_start, pos - 2)
      table.insert(results, {
        start_pos = start,
        end_pos = pos - 1,
        content = content
      })
      i = pos
    else
      i = start + 2
    end
  end

  return results
end

-- Environment variable cache for optimization
local _env_cache = {}
local _env_cache_timestamp = 0
local ENV_CACHE_TTL = 1000 -- 1 second TTL
local ENV_CACHE_MAX_SIZE = 100 -- Maximum number of cached entries

---Get a variable's value from env_vars or shell environment (optimized)
---@param var_name string The name of the variable
---@param env_vars table<string, EnvVarInfo> The environment variables table
---@param opts InterpolationOptions The interpolation options
---@param suppress_warning boolean? Whether to suppress the undefined variable warning
---@return table? var The variable info if found
local function get_variable(var_name, env_vars, opts, suppress_warning)
  if not var_name or type(var_name) ~= "string" or var_name == "" then
    return nil
  end

  if not env_vars or type(env_vars) ~= "table" then
    return nil
  end

  local var = env_vars[var_name]
  if not var then
    -- Check cache first for shell variables
    local now = uv.now()
    if now - _env_cache_timestamp > ENV_CACHE_TTL then
      -- Cache expired, clear it
      _env_cache = {}
      _env_cache_timestamp = now
    end

    if _env_cache[var_name] then
      var = _env_cache[var_name]
    else
      -- Use vim.env for faster access (available in newer Neovim versions)
      local shell_value
      if vim.env then
        shell_value = vim.env[var_name]
      else
        shell_value = vim.fn.getenv(var_name)
      end

      if shell_value and shell_value ~= vim.NIL and shell_value ~= "" then
        var = { value = shell_value }
        -- Cache for future use with size limit
        if vim.tbl_count(_env_cache) >= ENV_CACHE_MAX_SIZE then
          -- Clear half the cache when it gets too large
          local keys = vim.tbl_keys(_env_cache)
          for i = 1, math.floor(#keys / 2) do
            _env_cache[keys[i]] = nil
          end
        end
        _env_cache[var_name] = var
      elseif opts.warn_on_undefined and not suppress_warning then
        NotificationManager.warn(string.format("Undefined variable: %s", var_name))
      end
    end
  end
  return var
end

---Process a variable substitution with optional default/alternate values
---@param match string The matched variable expression
---@param env_vars table<string, EnvVarInfo> The environment variables table
---@param opts InterpolationOptions The interpolation options
---@return string The substituted value
local function process_var_substitution(match, env_vars, opts)
  if not opts.features or not opts.features.variables then
    return match
  end

  local var_name, operator, value = match:match(PATTERNS.VAR_PARTS)

  if not var_name or var_name == "" then
    local has_operator = match:find("[:%-+]")
    if not has_operator then
      var_name = match
      operator = ""
      value = ""
    else
      return ""
    end
  end

  local suppress_warning = operator == OPERATORS.DEFAULT
    or operator == OPERATORS.ALTERNATE
    or operator == OPERATORS.ALT_IF_SET_NON_EMPTY
    or operator == OPERATORS.ALT_IF_SET

  local var = get_variable(var_name, env_vars, opts, suppress_warning)
  local is_empty = not var or not var.value or var.value == ""
  local is_set = var ~= nil

  if operator == OPERATORS.DEFAULT and is_empty then
    if not opts.features or opts.features.defaults then
      -- Recursively interpolate the default value if it contains variables
      if value:match("%$") then
        local M = require("ecolog.interpolation")
        return M.interpolate(value, env_vars, opts)
      else
        return handle_escapes(value, opts)
      end
    end
  elseif operator == OPERATORS.ALTERNATE and not is_set then
    if not opts.features or opts.features.defaults then
      if value:match("%$") then
        local M = require("ecolog.interpolation")
        return M.interpolate(value, env_vars, opts)
      else
        return handle_escapes(value, opts)
      end
    end
  end

  if operator == OPERATORS.ALT_IF_SET_NON_EMPTY and not is_empty then
    if not opts.features or opts.features.alternates then
      -- Recursively interpolate the alternate value
      local M = require("ecolog.interpolation")
      return M.interpolate(value, env_vars, opts)
    end
  elseif operator == OPERATORS.ALT_IF_SET and is_set then
    if not opts.features or opts.features.alternates then
      -- Recursively interpolate the alternate value
      local M = require("ecolog.interpolation")
      return M.interpolate(value, env_vars, opts)
    end
  end

  return var and var.value and handle_escapes(tostring(var.value), opts) or ""
end

---Process command substitution in a string
---@param cmd string The command to execute
---@param opts InterpolationOptions The interpolation options
---@return string The command output with trailing whitespace removed
local function process_cmd_substitution(cmd, opts)
  -- Validate command input
  if not cmd or type(cmd) ~= "string" or cmd == "" then
    NotificationManager.warn("Invalid command for substitution")
    return ""
  end

  -- Sanitize command to prevent injection attacks (unless disabled)
  if not opts.disable_security then
    -- Sanitize dangerous characters for security
    -- Note: This includes pipes which breaks some legitimate commands
    -- Use disable_security option if you need full shell features
    local sanitized_cmd = cmd:gsub("[;&|`$()]", "")
    if sanitized_cmd ~= cmd then
      NotificationManager.warn("Command contains potentially dangerous characters, sanitizing: " .. cmd)
      cmd = sanitized_cmd
    end
  end

  -- Use pcall to protect against system command errors
  local success, output = pcall(function()
    -- Use shell to properly handle pipes and complex commands
    return vim.fn.system({ "sh", "-c", cmd })
  end)

  if not success then
    local msg = string.format("Command substitution system call failed: %s", tostring(output))
    if opts.fail_on_cmd_error then
      error(msg)
    else
      NotificationManager.error(msg)
      return ""
    end
  end

  local exit_code = vim.v.shell_error

  if exit_code ~= 0 then
    local msg = string.format("Command substitution failed: %s (exit code: %d)", output, exit_code)
    if opts.fail_on_cmd_error then
      error(msg)
    else
      NotificationManager.warn(msg)
      return ""
    end
  end

  -- Safely handle output processing
  local result = ""
  if output and type(output) == "string" then
    result = output:gsub("%s+$", "")
  end

  return result
end

---Interpolate environment variables and command substitutions in a string value
---@param value string The value to interpolate
---@param env_vars table<string, EnvVarInfo> The environment variables table
---@param opts? InterpolationOptions Optional configuration options
---@return string interpolated_value The value with variables interpolated
function M.interpolate(value, env_vars, opts)
  if not value then
    return ""
  end
  
  if type(value) ~= "string" then
    return tostring(value) or ""
  end
  
  if not env_vars or type(env_vars) ~= "table" then
    env_vars = {}
  end

  opts = vim.tbl_deep_extend("force", {
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
  }, opts or {})

  local inner = extract_quoted_content(value, PATTERNS.SINGLE_QUOTED, opts)
  if inner then
    return handle_escapes(inner, opts)
  end

  local is_double_quoted = value:match(PATTERNS.DOUBLE_QUOTED)
  if is_double_quoted then
    value = extract_quoted_content(value, PATTERNS.DOUBLE_QUOTED, opts) or value
  end

  local prev_value
  local iteration = 0
  repeat
    prev_value = value
    if opts.features.variables then
      -- Process balanced brace variables first (handles nested properly)
      local brace_vars = find_balanced_brace_vars(value)
      -- Process from end to start to maintain positions
      for i = #brace_vars, 1, -1 do
        local var = brace_vars[i]
        if var.content and var.content ~= "" then
          local replacement = process_var_substitution(var.content, env_vars, opts)
          value = value:sub(1, var.start_pos - 1) .. replacement .. value:sub(var.end_pos + 1)
        end
      end

      value = value:gsub(PATTERNS.SIMPLE_VAR, function(match)
        return process_var_substitution(match, env_vars, opts)
      end)
    end
    iteration = iteration + 1
  until prev_value == value or iteration >= opts.max_iterations

  if iteration >= opts.max_iterations then
    NotificationManager.warn("Maximum interpolation iterations reached")
  end

  if opts.features.commands then
    local success, result = pcall(function()
      local cmd_substs = find_balanced_command_substs(value)
      for i = #cmd_substs, 1, -1 do
        local cmd_info = cmd_substs[i]
        local cmd_success, cmd_result = pcall(function()
          return process_cmd_substitution(cmd_info.content, opts)
        end)

        if not cmd_success then
          if opts.fail_on_cmd_error then
            error(cmd_result)
          else
            NotificationManager.error("Command substitution error: " .. tostring(cmd_result))
            cmd_result = ""
          end
        end

        value = value:sub(1, cmd_info.start_pos - 1) .. cmd_result .. value:sub(cmd_info.end_pos + 1)
      end
      return value
    end)

    if not success then
      if opts.fail_on_cmd_error then
        error(result)
      else
        NotificationManager.error("Command substitution processing failed: " .. tostring(result))
        return value
      end
    end
    value = result
  end

  return handle_escapes(value, opts)
end

return M
