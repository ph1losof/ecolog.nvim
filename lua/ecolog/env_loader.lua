local M = {}

local fn = vim.fn
local utils = require("ecolog.utils")
local types = require("ecolog.types")
local shell = require("ecolog.shell")
local interpolation = require("ecolog.interpolation")

---@class EnvVarInfo
---@field value any The processed value of the environment variable
---@field type string The detected type of the variable
---@field raw_value string The original, unprocessed value
---@field source string The source of the variable (file name or "shell")
---@field comment? string Optional comment associated with the variable
---@field quote_char? string The quote character used in the original value (if any)

---@class LoaderState
---@field env_vars table<string, EnvVarInfo>
---@field selected_env_file? string
---@field _env_line_cache table

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

  local key, value, comment, quote_char = utils.extract_line_parts(line)
  if not key or not value then
    _env_line_cache[cache_key] = { nil }
    return nil
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
      quote_char = quote_char,
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
  
  -- Validate input parameters
  if not file_path or type(file_path) ~= "string" then
    vim.notify("Invalid file path provided to load_env_file", vim.log.levels.ERROR)
    return env_vars_result
  end
  
  if not _env_line_cache then
    _env_line_cache = {}
  end
  
  if not env_vars then
    env_vars = {}
  end
  
  if not opts then
    opts = {}
  end
  
  -- Check file readability before attempting to open
  if vim.fn.filereadable(file_path) == 0 then
    vim.notify(string.format("Environment file is not readable: %s", file_path), vim.log.levels.WARN)
    return env_vars_result
  end
  
  local env_file = io.open(file_path, "r")
  if not env_file then
    vim.notify(string.format("Could not open environment file: %s", file_path), vim.log.levels.WARN)
    return env_vars_result
  end

  -- Use pcall to protect against file reading errors
  local success, err = pcall(function()
    for line in env_file:lines() do
      local initial_opts = vim.tbl_deep_extend("force", {}, opts)
      local key, var_info = parse_env_line(line, file_path, _env_line_cache, env_vars, initial_opts)
      if key then
        env_vars_result[key] = var_info
      end
    end
  end)
  
  -- Ensure file is always closed, even on error
  local close_success, close_err = pcall(function()
    env_file:close()
  end)
  
  if not success then
    vim.notify(string.format("Error reading environment file %s: %s", file_path, tostring(err)), vim.log.levels.ERROR)
    return env_vars_result
  end
  
  if not close_success then
    vim.notify(string.format("Error closing environment file %s: %s", file_path, tostring(close_err)), vim.log.levels.WARN)
  end

  if opts.interpolation and opts.interpolation.enabled then
    for key, var_info in pairs(env_vars_result) do
      if var_info.quote_char ~= "'" then
        local interpolated_value = interpolation.interpolate(var_info.raw_value, env_vars_result, opts.interpolation)
        if interpolated_value ~= var_info.raw_value then
          local type_name, transformed_value = types.detect_type(interpolated_value)
          env_vars_result[key] = {
            value = transformed_value or interpolated_value,
            type = type_name,
            raw_value = var_info.raw_value,
            source = var_info.source,
            comment = var_info.comment,
            quote_char = var_info.quote_char,
          }
        end
      end
    end
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
