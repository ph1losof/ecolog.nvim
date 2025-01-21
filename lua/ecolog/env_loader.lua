local M = {}

local fn = vim.fn

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

---@param line string The line to parse from the env file
---@param file_path string The path of the env file
---@param _env_line_cache table Cache for parsed lines
---@return string? key The environment variable key if found
---@return EnvVarInfo? var_info The environment variable info if found
local function parse_env_line(line, file_path, _env_line_cache)
  local cache_key = line .. file_path
  if _env_line_cache[cache_key] then
    return unpack(_env_line_cache[cache_key])
  end

  -- Skip empty lines and comments
  if line:match("^%s*$") or line:match("^%s*#") then
    _env_line_cache[cache_key] = { nil }
    return nil
  end

  local utils = require("ecolog.utils")
  local types = require("ecolog.types")
  local key, value, comment = utils.extract_line_parts(line)
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
    },
  }
  _env_line_cache[cache_key] = result
  return unpack(result)
end

---@param file_path string Path to the env file
---@param _env_line_cache table Cache for parsed lines
---@return table<string, EnvVarInfo>
local function load_env_file(file_path, _env_line_cache)
  local env_vars = {}
  local env_file = io.open(file_path, "r")
  if not env_file then
    vim.notify(string.format("Could not open environment file: %s", file_path), vim.log.levels.WARN)
    return env_vars
  end

  for line in env_file:lines() do
    local key, var_info = parse_env_line(line, file_path, _env_line_cache)
    if key then
      env_vars[key] = var_info
    end
  end
  env_file:close()
  return env_vars
end

---@param opts table The configuration options
---@param env_vars table<string, EnvVarInfo> Current environment variables
---@return table<string, EnvVarInfo>
local function merge_shell_vars(opts, env_vars)
  if not opts.load_shell or (
    type(opts.load_shell) == "table" and not opts.load_shell.enabled
  ) then
    return env_vars
  end

  local shell = require("ecolog.shell")
  local shell_config = type(opts.load_shell) == "boolean" 
    and { enabled = true, override = false } 
    or opts.load_shell

  local shell_vars = shell.load_shell_vars(shell_config)
  for key, var_info in pairs(shell_vars) do
    if shell_config.override or not env_vars[key] then
      env_vars[key] = var_info
    end
  end

  return env_vars
end

---@param opts table The configuration options
---@param env_vars table<string, EnvVarInfo> Current environment variables
---@return table<string, EnvVarInfo>
local function merge_aws_secrets(opts, env_vars)
  if not (opts.integrations and opts.integrations.aws_secrets_manager) then
    return env_vars
  end

  local aws_secrets = require("ecolog.integrations.aws_secrets_manager")
    .load_aws_secrets(opts.integrations.aws_secrets_manager)

  for key, var_info in pairs(aws_secrets) do
    if opts.integrations.aws_secrets_manager.override or not env_vars[key] then
      env_vars[key] = var_info
    end
  end

  return env_vars
end

---@param opts table The configuration options
---@param state LoaderState The current loader state
---@param force boolean? Whether to force reload environment variables
---@return table<string, EnvVarInfo>
function M.load_environment(opts, state, force)
  -- Return cached vars if available and not forcing reload
  if not force and next(state.env_vars) ~= nil then
    return state.env_vars
  end

  -- Find and set selected env file if not already set
  if not state.selected_env_file then
    local utils = require("ecolog.utils")
    local env_files = utils.find_env_files(opts)
    if #env_files > 0 then
      state.selected_env_file = env_files[1]
    end
  end

  local env_vars = {}

  -- Load variables in the correct order based on override settings
  if opts.load_shell and type(opts.load_shell) == "table" and opts.load_shell.override then
    -- Load shell vars first if they should override
    env_vars = merge_shell_vars(opts, env_vars)
    
    -- Then load env file vars
    if state.selected_env_file then
      local file_vars = load_env_file(state.selected_env_file, state._env_line_cache or {})
      for key, var_info in pairs(file_vars) do
        if not env_vars[key] then
          env_vars[key] = var_info
        end
      end
    end
  else
    -- Load env file vars first
    if state.selected_env_file then
      env_vars = load_env_file(state.selected_env_file, state._env_line_cache or {})
    end
    
    -- Then load shell vars
    env_vars = merge_shell_vars(opts, env_vars)
  end

  -- Always load AWS secrets last
  env_vars = merge_aws_secrets(opts, env_vars)

  state.env_vars = env_vars
  return env_vars
end

return M 