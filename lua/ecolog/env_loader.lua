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

local M = {}

-- Compatibility layer for vim.loop -> vim.uv migration
local uv = vim.uv or vim.loop
local fn = vim.fn

local utils = require("ecolog.utils")
local types = require("ecolog.types")
local shell = require("ecolog.shell")
local interpolation = require("ecolog.interpolation")
local NotificationManager = require("ecolog.core.notification_manager")
local FileOperations = require("ecolog.core.file_operations")

-- Enhanced caching system
local _parse_cache = {}
local _cache_timestamps = {}
local MAX_CACHE_SIZE = 1000
local CACHE_TTL = 300000 -- 5 minutes

---@param line string The line to parse from the env file
---@param file_path string The path of the env file
---@param _env_line_cache table Cache for parsed lines
---@param env_vars table<string, EnvVarInfo> Current environment variables
---@param opts table Configuration options
---@param state table? Multi-line parsing state
---@return string? key The environment variable key if found
---@return EnvVarInfo? var_info The environment variable info if found
---@return table? state Updated multi-line parsing state
local function parse_env_line(line, file_path, _env_line_cache, env_vars, opts, state)
  if not opts then
    opts = {}
  end

  local cache_key = { line = line, path = file_path }
  local cache_entry = _env_line_cache[cache_key]
  if cache_entry and not state then
    return unpack(cache_entry)
  end

  if line:match("^%s*$") or line:match("^%s*#") then
    if not state or not state.in_multi_line then
      _env_line_cache[cache_key] = { nil }
      return nil, nil, state
    end
  end

  local key, value, comment, quote_char, updated_state = utils.extract_line_parts(line, state)
  if not key or not value then
    if not updated_state or not updated_state.in_multi_line then
      _env_line_cache[cache_key] = { nil }
    end
    return nil, nil, updated_state
  end

  local type_name, transformed_value = types.detect_type(value)

  local final_value = value
  if transformed_value ~= nil then
    final_value = transformed_value
  end

  local result = {
    key,
    {
      value = final_value,
      type = type_name,
      raw_value = value,
      source = file_path,
      source_file = fn.fnamemodify(file_path, ":t"),
      comment = comment,
      quote_char = quote_char,
    },
  }
  _env_line_cache[cache_key] = result
  return key, result[2], updated_state
end

---Parse a single environment file with intelligent caching
---@param file_path string Path to environment file
---@param content string[] Lines of file
---@param opts table Configuration options
---@return table<string, EnvVarInfo> parsed_vars
local function parse_single_file(file_path, content, opts)
  -- Check cache first using file modification time
  local mtime = FileOperations.get_mtime(file_path)
  local cache_key = file_path .. ":" .. mtime

  if _parse_cache[cache_key] and is_cache_valid(cache_key) then
    return _parse_cache[cache_key]
  end

  local env_vars = {}
  local _env_line_cache = {}

  -- Parse lines efficiently
  for i = 1, #content do
    local line = content[i]

    -- Skip empty lines and comments quickly
    if line ~= "" and not line:match("^%s*#") and not line:match("^%s*$") then
      local key, value, comment, quote_char = utils.extract_line_parts(line)

      if key and value then
        local type_name, transformed_value = types.detect_type(value)

        -- Use explicit nil check to handle boolean false correctly
        local final_value = value
        if transformed_value ~= nil then
          final_value = transformed_value
        end

        env_vars[key] = {
          value = final_value,
          type = type_name,
          raw_value = value,
          source = file_path,
          source_file = vim.fn.fnamemodify(file_path, ":t"),
          comment = comment,
          quote_char = quote_char,
        }
      end
    end
  end

  -- Apply interpolation if enabled
  if opts.interpolation and opts.interpolation.enabled then
    apply_interpolation(env_vars, opts.interpolation)
  end

  -- Cache result
  cache_result(cache_key, env_vars)

  return env_vars
end

---Apply interpolation to environment variables
---@param env_vars table<string, EnvVarInfo> Environment variables
---@param interpolation_opts table Interpolation configuration
local function apply_interpolation(env_vars, interpolation_opts)
  for key, var_info in pairs(env_vars) do
    if var_info.quote_char ~= "'" then
      local interpolated_value = interpolation.interpolate(var_info.raw_value, env_vars, interpolation_opts)
      if interpolated_value ~= var_info.raw_value then
        local type_name, transformed_value = types.detect_type(interpolated_value)
        local final_value = interpolated_value
        if transformed_value ~= nil then
          final_value = transformed_value
        end
        
        env_vars[key] = {
          value = final_value,
          type = type_name,
          raw_value = var_info.raw_value,
          source = var_info.source,
          source_file = var_info.source_file,
          comment = var_info.comment,
          quote_char = var_info.quote_char,
        }
      end
    end
  end
end

---Check if cache entry is still valid
---@param cache_key string Cache key
---@return boolean valid Whether cache entry is valid
local function is_cache_valid(cache_key)
  local timestamp = _cache_timestamps[cache_key]
  if not timestamp then
    return false
  end

  return (uv.now() - timestamp) < CACHE_TTL
end

---Cache result with automatic cleanup
---@param cache_key string Cache key
---@param env_vars table Parsed environment variables
local function cache_result(cache_key, env_vars)
  -- Clean up expired entries if cache is getting large
  if vim.tbl_count(_parse_cache) >= MAX_CACHE_SIZE then
    cleanup_cache()
  end

  _parse_cache[cache_key] = env_vars
  _cache_timestamps[cache_key] = uv.now()
end

---Clean up expired cache entries
local function cleanup_cache()
  local current_time = uv.now()
  local expired_keys = {}

  for key, timestamp in pairs(_cache_timestamps) do
    if (current_time - timestamp) > CACHE_TTL then
      table.insert(expired_keys, key)
    end
  end

  for _, key in ipairs(expired_keys) do
    _parse_cache[key] = nil
    _cache_timestamps[key] = nil
  end
end

---Count expired cache entries
---@return number count
local function count_expired_entries()
  local current_time = uv.now()
  local expired_count = 0

  for _, timestamp in pairs(_cache_timestamps) do
    if (current_time - timestamp) > CACHE_TTL then
      expired_count = expired_count + 1
    end
  end

  return expired_count
end

---Load environment file synchronously using FileOperations
---@param file_path string Path to the env file
---@param _env_line_cache table Cache for parsed lines
---@param env_vars table<string, EnvVarInfo> Current environment variables
---@param opts table Configuration options
---@return table<string, EnvVarInfo>
local function load_env_file(file_path, _env_line_cache, env_vars, opts)
  local env_vars_result = {}

  -- Validate input parameters
  if not file_path or type(file_path) ~= "string" then
    NotificationManager.error("Invalid file path provided to load_env_file")
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
  if not FileOperations.is_readable(file_path) then
    NotificationManager.warn(string.format("Environment file is not readable: %s", file_path))
    return env_vars_result
  end

  local content, err = FileOperations.read_file_sync(file_path)
  if not content then
    NotificationManager.warn(string.format("Could not read environment file: %s - %s", file_path, err or "unknown error"))
    return env_vars_result
  end

  -- Process lines
  local multi_line_state = {}
  for i = 1, #content do
    local line = content[i]
    local initial_opts = vim.tbl_deep_extend("force", {}, opts)
    local key, var_info, updated_state = parse_env_line(line, file_path, _env_line_cache, env_vars, initial_opts, multi_line_state)
    if key then
      env_vars_result[key] = var_info
    end
    multi_line_state = updated_state or multi_line_state
  end

  -- Apply interpolation if enabled
  if opts.interpolation and opts.interpolation.enabled then
    apply_interpolation(env_vars_result, opts.interpolation)
  end

  return env_vars_result
end

---Load environment file asynchronously using FileOperations
---@param file_path string Path to the env file
---@param _env_line_cache table Cache for parsed lines
---@param env_vars table<string, EnvVarInfo> Current environment variables
---@param opts table Configuration options
---@param callback function Callback function to handle result
local function load_env_file_async(file_path, _env_line_cache, env_vars, opts, callback)
  -- Validate input parameters
  if not file_path or type(file_path) ~= "string" then
    vim.schedule(function()
      callback({}, "Invalid file path provided to load_env_file_async")
    end)
    return
  end

  if not callback or type(callback) ~= "function" then
    NotificationManager.error("Invalid callback provided to load_env_file_async")
    return
  end

  -- Check file readability before attempting to read
  if not FileOperations.is_readable(file_path) then
    vim.schedule(function()
      callback({}, "Environment file is not readable: " .. file_path)
    end)
    return
  end

  FileOperations.read_file_async(file_path, function(content, err)
    if not content then
      vim.schedule(function()
        callback({}, "Error reading environment file: " .. tostring(err))
      end)
      return
    end

    -- Process lines
    local env_vars_result = {}
    local multi_line_state = {}
    for i = 1, #content do
      local line = content[i]
      local initial_opts = vim.tbl_deep_extend("force", {}, opts or {})
      local key, var_info, updated_state = parse_env_line(line, file_path, _env_line_cache or {}, env_vars or {}, initial_opts, multi_line_state)
      if key then
        env_vars_result[key] = var_info
      end
      multi_line_state = updated_state or multi_line_state
    end

    -- Apply interpolation if enabled
    if opts and opts.interpolation and opts.interpolation.enabled then
      apply_interpolation(env_vars_result, opts.interpolation)
    end

    vim.schedule(function()
      callback(env_vars_result, nil)
    end)
  end)
end

---Parse environment files in parallel using FileOperations
---@param file_paths string[] Array of file paths to parse
---@param opts table Configuration options
---@param callback function Callback function(results, errors)
function M.parse_env_files_parallel(file_paths, opts, callback)
  opts = opts or {}

  if not file_paths or #file_paths == 0 then
    callback({}, {})
    return
  end

  -- Use FileOperations for batch reading
  FileOperations.read_files_batch(file_paths, function(file_contents, read_errors)
    local results = {}
    local all_errors = read_errors

    -- Parse each file's content
    for file_path, content in pairs(file_contents) do
      local success, parsed_vars = pcall(parse_single_file, file_path, content, opts)

      if success then
        results[file_path] = parsed_vars
      else
        all_errors[file_path] = tostring(parsed_vars)
      end
    end

    callback(results, all_errors)
  end)
end

---Load environment variables from multiple files with priority
---@param file_paths string[] Array of file paths in priority order
---@param opts table Configuration options
---@param callback function Callback function(env_vars, errors)
function M.load_env_vars_with_priority(file_paths, opts, callback)
  opts = opts or {}

  if not file_paths or #file_paths == 0 then
    callback({}, {})
    return
  end

  -- Parse files in parallel
  M.parse_env_files_parallel(file_paths, opts, function(parsed_results, errors)
    local final_env_vars = {}

    -- Merge results according to file priority (first file wins)
    for _, file_path in ipairs(file_paths) do
      local parsed_vars = parsed_results[file_path]
      if parsed_vars then
        for key, var_info in pairs(parsed_vars) do
          if not final_env_vars[key] then
            final_env_vars[key] = var_info
          end
        end
      end
    end

    callback(final_env_vars, errors)
  end)
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

---Check and parse shell configuration
---@param load_shell_config any Shell configuration (boolean or table)
---@return boolean enabled Whether shell loading is enabled
---@return boolean override Whether shell should override file vars
local function parse_shell_config(load_shell_config)
  local enabled = load_shell_config
    and (
      (type(load_shell_config) == "boolean" and load_shell_config)
      or (type(load_shell_config) == "table" and load_shell_config.enabled)
    )
  local override = enabled and type(load_shell_config) == "table" and load_shell_config.override
  return enabled, override
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
    -- Preserve selected_env_file in monorepo mode or if workspace file transition was handled
    local preserved_file = opts._workspace_selected_file
      or (opts._workspace_file_handled and state.selected_env_file or nil)
      or ((opts._is_monorepo_workspace or opts._is_monorepo_manual_mode) and state.selected_env_file or nil)
    state.env_vars = {}
    state._env_line_cache = {}
    if preserved_file then
      state.selected_env_file = preserved_file
    end
  end

  if not force and next(state.env_vars) ~= nil then
    return state.env_vars
  end

  -- Optimized monorepo environment loading
  if opts._is_monorepo_workspace or opts._is_monorepo_manual_mode then
    return M.load_monorepo_environment(opts, state)
  end

  -- Only auto-select file if not handled by workspace transition
  if not state.selected_env_file and not opts._workspace_file_handled then
    local env_files = utils.find_env_files(opts)
    if #env_files > 0 then
      state.selected_env_file = env_files[1]
    end
  end

  -- Only check file readability and override if not handled by workspace transition
  if not opts._workspace_file_handled then
    if state.selected_env_file and not FileOperations.is_readable(state.selected_env_file) then
      local deleted_file = state.selected_env_file
      state.selected_env_file = nil
      state.env_vars = {}
      state._env_line_cache = {}
      local env_files = utils.find_env_files(opts)
      if #env_files > 0 then
        state.selected_env_file = env_files[1]
        local utils = require("ecolog.utils")
        local new_display_name = utils.get_env_file_display_name(env_files[1], opts)
        local deleted_display_name = utils.get_env_file_display_name(deleted_file, opts)
        NotificationManager.notify_file_deleted(deleted_file, env_files[1], opts)
      else
        local utils = require("ecolog.utils")
        local deleted_display_name = utils.get_env_file_display_name(deleted_file, opts)
        NotificationManager.notify_file_deleted(deleted_file, nil, opts)
      end
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

---Load environment asynchronously with callback
---@param opts table The configuration options
---@param state LoaderState The current loader state
---@param callback function Callback function to handle result
---@param force boolean? Whether to force reload environment variables
function M.load_environment_async(opts, state, callback, force)
  if not callback or type(callback) ~= "function" then
    NotificationManager.error("Invalid callback provided to load_env_file_async")
    return
  end

  -- Use vim.defer_fn to process in background
  vim.defer_fn(function()
    if force then
      state.env_vars = {}
      state._env_line_cache = {}
    end

    if not force and next(state.env_vars) ~= nil then
      vim.schedule(function()
        callback(state.env_vars, nil)
      end)
      return
    end

    if not state.selected_env_file then
      local env_files = utils.find_env_files(opts)
      if #env_files > 0 then
        state.selected_env_file = env_files[1]
      end
    end

    if state.selected_env_file and not FileOperations.is_readable(state.selected_env_file) then
      local deleted_file = state.selected_env_file
      state.selected_env_file = nil
      state.env_vars = {}
      state._env_line_cache = {}
      local env_files = utils.find_env_files(opts)
      if #env_files > 0 then
        state.selected_env_file = env_files[1]
        local utils = require("ecolog.utils")
        local new_display_name = utils.get_env_file_display_name(env_files[1], opts)
        local deleted_display_name = utils.get_env_file_display_name(deleted_file, opts)
        NotificationManager.notify_file_deleted(deleted_file, env_files[1], opts)
      else
        local utils = require("ecolog.utils")
        local deleted_display_name = utils.get_env_file_display_name(deleted_file, opts)
        NotificationManager.notify_file_deleted(deleted_file, nil, opts)
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
        load_env_file_async(
          state.selected_env_file,
          state._env_line_cache or {},
          env_vars,
          opts,
          function(file_vars, err)
            if err then
              vim.schedule(function()
                callback({}, err)
              end)
              return
            end

            merge_vars(env_vars, file_vars, false)
            env_vars = load_secrets(opts, env_vars)
            state.env_vars = env_vars

            vim.schedule(function()
              callback(env_vars, nil)
            end)
          end
        )
      else
        env_vars = load_secrets(opts, env_vars)
        state.env_vars = env_vars
        vim.schedule(function()
          callback(env_vars, nil)
        end)
      end
    else
      if state.selected_env_file then
        load_env_file_async(
          state.selected_env_file,
          state._env_line_cache or {},
          env_vars,
          opts,
          function(file_vars, err)
            if err then
              vim.schedule(function()
                callback({}, err)
              end)
              return
            end

            env_vars = file_vars

            if shell_enabled then
              local shell_vars = shell.load_shell_vars(opts.load_shell)
              merge_vars(env_vars, shell_vars, false)
            end

            env_vars = load_secrets(opts, env_vars)
            state.env_vars = env_vars

            vim.schedule(function()
              callback(env_vars, nil)
            end)
          end
        )
      else
        if shell_enabled then
          local shell_vars = shell.load_shell_vars(opts.load_shell)
          merge_vars(env_vars, shell_vars, false)
        end

        env_vars = load_secrets(opts, env_vars)
        state.env_vars = env_vars

        vim.schedule(function()
          callback(env_vars, nil)
        end)
      end
    end
  end, 0)
end

---Optimized monorepo environment loading with single-file selection
---@param opts table Configuration options
---@param state LoaderState Current loader state
---@return table<string, EnvVarInfo> env_vars
function M.load_monorepo_environment(opts, state)
  -- Get all environment files using optimized discovery
  local env_files = utils.find_env_files(opts)

  if #env_files == 0 then
    state.env_vars = {}
    return {}
  end

  -- Respect to user's selected file if it exists in available files
  local selected_file = nil
  if state.selected_env_file then
    -- Check if previously selected file is still available
    for _, file in ipairs(env_files) do
      if file == state.selected_env_file then
        selected_file = state.selected_env_file
        break
      end
    end
  end

  -- If no previously selected file or it's not available, use to first file (highest priority)
  if not selected_file then
    selected_file = env_files[1]
  end

  -- Update state with selected file for compatibility
  state.selected_env_file = selected_file

  local env_vars = {}
  local shell_enabled, shell_override = parse_shell_config(opts.load_shell)

  if shell_override then
    -- Load shell variables first if override is enabled
    local shell_vars = shell.load_shell_vars(opts.load_shell)
    merge_vars(env_vars, shell_vars, true)

    -- Then load file variables (won't override shell vars)
    local file_vars = load_env_file(selected_file, state._env_line_cache or {}, env_vars, opts)
    merge_vars(env_vars, file_vars, false)
  else
    -- Load file variables first
    env_vars = load_env_file(selected_file, state._env_line_cache or {}, env_vars, opts)

    -- Then add shell variables if enabled (won't override file vars)
    if shell_enabled then
      local shell_vars = shell.load_shell_vars(opts.load_shell)
      merge_vars(env_vars, shell_vars, false)
    end
  end

  -- Apply secrets from secret managers
  env_vars = load_secrets(opts, env_vars)

  state.env_vars = env_vars
  return env_vars
end

---Clear parse cache
function M.clear_cache()
  _parse_cache = {}
  _cache_timestamps = {}
end

---Get cache statistics
---@return table stats
function M.get_cache_stats()
  return {
    cache_size = vim.tbl_count(_parse_cache),
    max_cache_size = MAX_CACHE_SIZE,
    cache_ttl = CACHE_TTL,
    expired_entries = count_expired_entries(),
  }
end

return M