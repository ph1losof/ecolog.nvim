local M = {}

local PATTERNS = {
  SINGLE_QUOTED = "^'(.*)'$",
  DOUBLE_QUOTED = '^"(.*)"$',
  BRACE_VAR = "${([^}]+)}",
  SIMPLE_VAR = "$([%w_]+)",
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

---Get a variable's value from env_vars or shell environment
---@param var_name string The name of the variable
---@param env_vars table<string, EnvVarInfo> The environment variables table
---@param opts InterpolationOptions The interpolation options
---@param suppress_warning boolean? Whether to suppress the undefined variable warning
---@return table? var The variable info if found
local function get_variable(var_name, env_vars, opts, suppress_warning)
  local var = env_vars[var_name]
  if not var then
    local shell_value = vim.fn.getenv(var_name)
    if shell_value and shell_value ~= vim.NIL then
      var.value = shell_value
    elseif opts.warn_on_undefined and not suppress_warning then
      vim.notify(string.format("Undefined variable: %s", var_name), vim.log.levels.WARN)
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
  if not var_name then
    return ""
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
      return handle_escapes(value, opts)
    end
  elseif operator == OPERATORS.ALTERNATE and not is_set then
    if not opts.features or opts.features.defaults then
      return handle_escapes(value, opts)
    end
  end

  if operator == OPERATORS.ALT_IF_SET_NON_EMPTY and not is_empty then
    if not opts.features or opts.features.alternates then
      return handle_escapes(value, opts)
    end
  elseif operator == OPERATORS.ALT_IF_SET and is_set then
    if not opts.features or opts.features.alternates then
      return handle_escapes(value, opts)
    end
  end

  return var and var.value and handle_escapes(tostring(var.value), opts) or ""
end

---Process command substitution in a string
---@param cmd string The command to execute
---@param opts InterpolationOptions The interpolation options
---@return string The command output with trailing whitespace removed
local function process_cmd_substitution(cmd, opts)
  local output = vim.fn.system(cmd)
  local exit_code = vim.v.shell_error

  if exit_code ~= 0 then
    local msg = string.format("Command substitution failed: %s (exit code: %d)", output, exit_code)
    if opts.fail_on_cmd_error then
      error(msg)
    else
      vim.notify(msg, vim.log.levels.WARN)
      return ""
    end
  end

  return output:gsub("%s+$", "")
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

  opts = vim.tbl_deep_extend("force", {
    max_iterations = 10,
    warn_on_undefined = true,
    fail_on_cmd_error = false,
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
    return inner:gsub("\\n", "\n")
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
      value = value:gsub(PATTERNS.BRACE_VAR, function(match)
        return process_var_substitution(match, env_vars, opts)
      end)
      value = value:gsub(PATTERNS.SIMPLE_VAR, function(match)
        return process_var_substitution(match, env_vars, opts)
      end)
    end
    iteration = iteration + 1
  until prev_value == value or iteration >= opts.max_iterations

  if iteration >= opts.max_iterations then
    vim.notify("Maximum interpolation iterations reached", vim.log.levels.WARN)
  end

  if opts.features.commands then
    local success, result = pcall(function()
      return value:gsub(PATTERNS.CMD_SUBST, function(cmd)
        return process_cmd_substitution(cmd, opts)
      end)
    end)

    if not success then
      if opts.fail_on_cmd_error then
        error(result)
      else
        vim.notify(result, vim.log.levels.ERROR)
        return value
      end
    end
    value = result
  end

  return value
end

return M
