local M = {}

local PATTERNS = {
  SINGLE_QUOTED = "^'(.*)'$",
  DOUBLE_QUOTED = '^"(.*)"$',
  BRACE_VAR = "${([^}]+)}",
  SIMPLE_VAR = "$([%w_]+)",
  CMD_SUBST = "%$%((.-)%)",
  VAR_PARTS = "([^:%-]+)([:%-]?%-?)(.*)",
}

local OPERATORS = {
  DEFAULT = ":-",
  ALTERNATE = "-",
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

---Handle escape sequences in a string
---@param str string The string containing escape sequences
---@return string The string with escape sequences replaced
local function handle_escapes(str)
  return str:gsub("\\([nrt\"'\\])", ESCAPE_MAP)
end

---Extract the inner content of a quoted string
---@param value string The string to extract from
---@param pattern string The pattern to match
---@return string? inner The inner content if matched, nil otherwise
local function extract_quoted_content(value, pattern)
  local inner = value:match(pattern)
  return inner and handle_escapes(inner)
end

---Get a variable's value from env_vars or shell environment
---@param var_name string The name of the variable
---@param env_vars table<string, EnvVarInfo> The environment variables table
---@param opts InterpolationOptions The interpolation options
---@return table? var The variable info if found
local function get_variable(var_name, env_vars, opts)
  local var = env_vars[var_name]
  if not var then
    local shell_value = vim.fn.getenv(var_name)
    if shell_value and shell_value ~= vim.NIL then
      var = { value = shell_value }
    elseif opts.warn_on_undefined then
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
  local var_name, operator, default_value = match:match(PATTERNS.VAR_PARTS)
  if not var_name then
    return ""
  end

  local var = get_variable(var_name, env_vars, opts)
  local is_empty = not var or not var.value or var.value == ""

  if operator == OPERATORS.DEFAULT and is_empty then
    return handle_escapes(default_value)
  end

  if operator == OPERATORS.ALTERNATE and not var then
    return handle_escapes(default_value)
  end

  return var and var.value and handle_escapes(tostring(var.value)) or ""
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

  opts = vim.tbl_extend("force", {
    max_iterations = 10,
    warn_on_undefined = true,
    fail_on_cmd_error = false,
  }, opts or {})

  local inner = extract_quoted_content(value, PATTERNS.SINGLE_QUOTED)
  if inner then
    return inner:gsub("\\n", "\n")
  end

  local is_double_quoted = value:match(PATTERNS.DOUBLE_QUOTED)
  if is_double_quoted then
    value = extract_quoted_content(value, PATTERNS.DOUBLE_QUOTED) or value
  end

  local prev_value
  local iteration = 0
  repeat
    prev_value = value
    value = value:gsub(PATTERNS.BRACE_VAR, function(match)
      return process_var_substitution(match, env_vars, opts)
    end)
    value = value:gsub(PATTERNS.SIMPLE_VAR, function(match)
      return process_var_substitution(match, env_vars, opts)
    end)
    iteration = iteration + 1
  until prev_value == value or iteration >= opts.max_iterations

  if iteration >= opts.max_iterations then
    vim.notify("Maximum interpolation iterations reached", vim.log.levels.WARN)
  end

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

  return handle_escapes(result)
end

return M
