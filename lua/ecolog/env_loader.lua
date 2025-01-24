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

---@param line string The line to parse from the env file
---@param file_path string The path of the env file
---@param _env_line_cache table Cache for parsed lines
---@return string? key The environment variable key if found
---@return EnvVarInfo? var_info The environment variable info if found
local function parse_env_line(line, file_path, _env_line_cache)
  -- Use table as cache key to avoid string concatenation
  local cache_key = { line = line, path = file_path }
  local cache_entry = _env_line_cache[cache_key]
  if cache_entry then
    return unpack(cache_entry)
  end

  -- Skip empty lines and comments
  if line:match("^%s*$") or line:match("^%s*#") then
    _env_line_cache[cache_key] = { nil }
    return nil
  end

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

  -- Read file in chunks for better performance
  local buffer = ""
  local chunk_size = 4096 -- 4KB chunks
  while true do
    local chunk = env_file:read(chunk_size)
    if not chunk then break end
    buffer = buffer .. chunk
    
    -- Process complete lines
    local start = 1
    local line_end = buffer:find("\n", start)
    while line_end do
      local line = buffer:sub(start, line_end - 1)
      local key, var_info = parse_env_line(line, file_path, _env_line_cache)
      if key then
        env_vars[key] = var_info
      end
      start = line_end + 1
      line_end = buffer:find("\n", start)
    end
    
    -- Keep remaining partial line in buffer
    buffer = buffer:sub(start)
  end

  -- Process any remaining content
  if #buffer > 0 then
    local key, var_info = parse_env_line(buffer, file_path, _env_line_cache)
    if key then
      env_vars[key] = var_info
    end
  end

  env_file:close()
  return env_vars
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

---@param opts table The configuration options
---@param state LoaderState The current loader state
---@param force boolean? Whether to force reload environment variables
---@return table<string, EnvVarInfo>
function M.load_environment(opts, state, force)
  -- Clear cache if forcing reload
  if force then
    state.env_vars = {}
    state._env_line_cache = {}
  end

  -- Return cached vars if available and not forcing reload
  if not force and next(state.env_vars) ~= nil then
    return state.env_vars
  end

  -- Find and set selected env file if not already set
  if not state.selected_env_file then
    local env_files = utils.find_env_files(opts)
    if #env_files > 0 then
      state.selected_env_file = env_files[1]
    end
  end

  -- Check if selected file still exists
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
  local shell_enabled = opts.load_shell and (
    (type(opts.load_shell) == "boolean" and opts.load_shell) or
    (type(opts.load_shell) == "table" and opts.load_shell.enabled)
  )
  local shell_override = shell_enabled and type(opts.load_shell) == "table" and opts.load_shell.override

  -- Load variables in the correct order based on override settings
  if shell_override then
    -- Load shell vars first if they should override
    local shell_vars = shell_enabled and shell.load_shell_vars(opts.load_shell) or {}
    merge_vars(env_vars, shell_vars, true)
    
    -- Then load env file vars
    if state.selected_env_file and fn.filereadable(state.selected_env_file) == 0 then
      state.selected_env_file = nil
    end
    if state.selected_env_file then
      local file_vars = load_env_file(state.selected_env_file, state._env_line_cache or {})
      merge_vars(env_vars, file_vars, false)
    end
  else
    -- Load env file vars first
    if state.selected_env_file and fn.filereadable(state.selected_env_file) == 0 then
      state.selected_env_file = nil
    end
    if state.selected_env_file then
      env_vars = load_env_file(state.selected_env_file, state._env_line_cache or {})
    end
    
    -- Then load shell vars
    if shell_enabled then
      local shell_vars = shell.load_shell_vars(opts.load_shell)
      merge_vars(env_vars, shell_vars, false)
    end
  end

  -- Always load AWS secrets last
  if opts.integrations and opts.integrations.aws_secrets_manager then
    local ok, aws_secrets = pcall(require, "ecolog.integrations.aws_secrets_manager")
    if ok then
      local secrets = aws_secrets.load_aws_secrets(opts.integrations.aws_secrets_manager)
      merge_vars(env_vars, secrets, opts.integrations.aws_secrets_manager.override)
    end
  end

  if opts.integrations and opts.integrations.secret_managers and opts.integrations.secret_managers.vault then
    local ok, vault_secrets = pcall(require, "ecolog.integrations.secret_managers.vault")
    if ok then
      local secrets = vault_secrets.load_vault_secrets(opts.integrations.secret_managers.vault)
      merge_vars(env_vars, secrets, opts.integrations.secret_managers.vault.override)
    end
  end

  state.env_vars = env_vars
  return env_vars
end

return M 