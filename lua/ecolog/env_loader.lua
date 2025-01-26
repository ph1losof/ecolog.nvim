local M = {}

local fn = vim.fn
local utils = require("ecolog.utils")
local types = require("ecolog.types")
local shell = require("ecolog.shell")

---@class EnvVarInfo
---@field value any The processed value of the environment variable
---@field type string The detected type of the variable
---@field raw_value string The original, unprocessed value
---@field source string The source of the variable (file name or "shell")
---@field comment? string Optional comment associated with the variable

---@class LoaderState
---@field env_vars table<string, EnvVarInfo>
---@field selected_env_file? string
---@field _env_line_cache table

---@param value string The value to interpolate
---@param env_vars table<string, EnvVarInfo> The environment variables table
---@return string interpolated_value The value with variables interpolated
local function interpolate_value(value, env_vars)
  if not value then
    return ""
  end

  if value:match("^'.*'$") then
    local inner = value:sub(2, -2)
    return inner:gsub("\\n", "\n")
  end

  local is_double_quoted = value:match('^".*"$')
  if is_double_quoted then
    value = value:sub(2, -2)
  end

  local function handle_escapes(str)
    return str:gsub("\\([nrt\"'\\])", {
      ["n"] = "\n",
      ["r"] = "\r",
      ["t"] = "\t",
      ["\\"] = "\\",
      ['"'] = '"',
      ["'"] = "'",
    })
  end

  local function replace_var(match)
    local var_name, operator, default_value = match:match("([^:%-]+)([:%-]?%-?)(.*)")
    local is_default = operator == ":-"
    local is_alternate = operator == "-"

    local var = env_vars[var_name]
    local shell_value
    if not var then
      shell_value = vim.fn.getenv(var_name)
      if shell_value and shell_value ~= vim.NIL then
        var = { value = shell_value }
      end
    end

    if is_default then
      if not var or not var.value or var.value == "" then
        return handle_escapes(default_value)
      end
      return handle_escapes(tostring(var.value))
    end

    if is_alternate then
      if not var then
        return handle_escapes(default_value)
      end
      return handle_escapes(tostring(var.value))
    end

    if var and var.value then
      return handle_escapes(tostring(var.value))
    end

    return ""
  end

  local prev_value
  repeat
    prev_value = value
    value = value:gsub("%${([^}]+)}", replace_var)
    value = value:gsub("$([%w_]+)", replace_var)
  until prev_value == value

  value = value:gsub("%$%((.-)%)", function(cmd)
    local output = vim.fn.system(cmd)
    local exit_code = vim.v.shell_error
    if exit_code ~= 0 then
      vim.notify(
        string.format("Command substitution failed: %s (exit code: %d)", output, exit_code),
        vim.log.levels.WARN
      )
      return ""
    end
    return output:gsub("%s+$", "")
  end)

  return handle_escapes(value)
end

---@param line string The line to parse from the env file
---@param file_path string The path of the env file
---@param _env_line_cache table Cache for parsed lines
---@param env_vars table<string, EnvVarInfo> Current environment variables
---@param opts table Configuration options
---@return string? key The environment variable key if found
---@return EnvVarInfo? var_info The environment variable info if found
local function parse_env_line(line, file_path, _env_line_cache, env_vars, opts)
  if not opts then
    opts = {}
  end

  local cache_key = { line = line, path = file_path }
  local cache_entry = _env_line_cache[cache_key]
  if cache_entry then
    return unpack(cache_entry)
  end

  if line:match("^%s*$") or line:match("^%s*#") then
    _env_line_cache[cache_key] = { nil }
    return nil
  end

  local key, value, comment = utils.extract_line_parts(line)
  if not key or not value then
    _env_line_cache[cache_key] = { nil }
    return nil
  end

  if opts.interpolation ~= false then
    value = interpolate_value(value, env_vars)
  end

  local type_name, transformed_value = types.detect_type(value)

  local result = {
    key,
    {
      value = transformed_value or value,
      type = type_name,
      raw_value = value,
      source = fn.fnamemodify(file_path, ":t"),
      comment = comment,
    },
  }
  _env_line_cache[cache_key] = result
  return unpack(result)
end

---@param file_path string Path to the env file
---@param _env_line_cache table Cache for parsed lines
---@param env_vars table<string, EnvVarInfo> Current environment variables
---@param opts table Configuration options
---@return table<string, EnvVarInfo>
local function load_env_file(file_path, _env_line_cache, env_vars, opts)
  local env_vars_result = {}
  local env_file = io.open(file_path, "r")
  if not env_file then
    vim.notify(string.format("Could not open environment file: %s", file_path), vim.log.levels.WARN)
    return env_vars_result
  end

  local lines = {}
  for line in env_file:lines() do
    table.insert(lines, line)
    local key, var_info = parse_env_line(line, file_path, _env_line_cache, env_vars, { interpolation = false })
    if key then
      env_vars_result[key] = var_info
    end
  end
  env_file:close()

  local changes_made = true
  local max_iterations = 10
  local iteration = 0

  while changes_made and iteration < max_iterations do
    changes_made = false
    iteration = iteration + 1

    for _, line in ipairs(lines) do
      local key, var_info = parse_env_line(line, file_path, {}, env_vars_result, { interpolation = true })
      if key and var_info then
        local old_value = env_vars_result[key] and env_vars_result[key].value
        local new_value = var_info.value
        if old_value ~= new_value then
          env_vars_result[key] = var_info
          changes_made = true
        end
      end
    end
  end

  if iteration >= max_iterations then
    vim.notify(
      "Warning: Maximum interpolation iterations reached. Some variables may not be fully interpolated.",
      vim.log.levels.WARN
    )
  end

  return env_vars_result
end

---@param target table<string, EnvVarInfo> Target table to merge into
---@param source table<string, EnvVarInfo> Source table to merge from
---@param override boolean Whether source values should override target values
local function merge_vars(target, source, override)
  if override then
    for k, v in pairs(source) do
      target[k] = v
    end
  else
    for k, v in pairs(source) do
      if not target[k] then
        target[k] = v
      end
    end
  end
  return target
end

---Load secrets from all configured secret managers
---@param opts table The configuration options
---@param env_vars table<string, EnvVarInfo> Current environment variables
---@return table<string, EnvVarInfo> Updated environment variables with secrets
local function load_secrets(opts, env_vars)
  if not opts.integrations or not opts.integrations.secret_managers then
    return env_vars
  end

  local secret_managers = opts.integrations.secret_managers

  if secret_managers.aws and secret_managers.aws.enabled then
    local ok, aws_secrets = pcall(require, "ecolog.integrations.secret_managers.aws")
    if ok then
      local secrets = aws_secrets.load_aws_secrets(secret_managers.aws)
      merge_vars(env_vars, secrets, secret_managers.aws.override)
    end
  end

  if secret_managers.vault and secret_managers.vault.enabled then
    local ok, vault_secrets = pcall(require, "ecolog.integrations.secret_managers.vault")
    if ok then
      local secrets = vault_secrets.load_vault_secrets(secret_managers.vault)
      merge_vars(env_vars, secrets, secret_managers.vault.override)
    end
  end

  return env_vars
end

---@param opts table The configuration options
---@param state LoaderState The current loader state
---@param force boolean? Whether to force reload environment variables
---@return table<string, EnvVarInfo>
function M.load_environment(opts, state, force)
  if force then
    state.env_vars = {}
    state._env_line_cache = {}
  end

  if not force and next(state.env_vars) ~= nil then
    return state.env_vars
  end

  if not state.selected_env_file then
    local env_files = utils.find_env_files(opts)
    if #env_files > 0 then
      state.selected_env_file = env_files[1]
    end
  end

  if state.selected_env_file and fn.filereadable(state.selected_env_file) == 0 then
    state.selected_env_file = nil
    state.env_vars = {}
    state._env_line_cache = {}
    local env_files = utils.find_env_files(opts)
    if #env_files > 0 then
      state.selected_env_file = env_files[1]
    end
  end

  local env_vars = {}
  local shell_enabled = opts.load_shell
    and (
      (type(opts.load_shell) == "boolean" and opts.load_shell)
      or (type(opts.load_shell) == "table" and opts.load_shell.enabled)
    )
  local shell_override = shell_enabled and type(opts.load_shell) == "table" and opts.load_shell.override

  if shell_override then
    local shell_vars = shell_enabled and shell.load_shell_vars(opts.load_shell) or {}
    merge_vars(env_vars, shell_vars, true)

    if state.selected_env_file then
      local file_vars = load_env_file(state.selected_env_file, state._env_line_cache or {}, env_vars, opts)
      merge_vars(env_vars, file_vars, false)
    end
  else
    if state.selected_env_file then
      env_vars = load_env_file(state.selected_env_file, state._env_line_cache or {}, env_vars, opts)
    end

    if shell_enabled then
      local shell_vars = shell.load_shell_vars(opts.load_shell)
      merge_vars(env_vars, shell_vars, false)
    end
  end

  env_vars = load_secrets(opts, env_vars)

  state.env_vars = env_vars
  return env_vars
end

return M
