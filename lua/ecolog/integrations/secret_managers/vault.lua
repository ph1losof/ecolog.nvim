local M = {}

local api = vim.api
local utils = require("ecolog.utils")
local ecolog = require("ecolog")
local secret_utils = require("ecolog.integrations.secret_managers.utils")

---@class VaultState
---@field selected_secrets string[] List of currently selected Vault secret paths
---@field config LoadVaultSecretsConfig|nil
---@field loading boolean
---@field loaded_secrets table<string, table>
---@field active_jobs table<number, boolean>
---@field is_refreshing boolean
---@field skip_load boolean
---@field token_valid boolean
---@field last_token_check number
---@field loading_lock table|nil
---@field timeout_timer number|nil
---@field initialized boolean
---@field pending_env_updates function[]

---@class VaultError
---@field message string
---@field code string
---@field level number

---@class LoadVaultSecretsConfig
---@field enabled boolean Enable loading HashiCorp Vault secrets into environment
---@field override boolean When true, Vault secrets take precedence over .env files and shell variables
---@field address string Vault server address (e.g. "http://127.0.0.1:8200")
---@field token string Vault authentication token
---@field paths string[] List of secret paths to fetch
---@field filter? fun(key: string, value: any): boolean Optional function to filter which secrets to load
---@field transform? fun(key: string, value: any): any Optional function to transform secret values
---@field mount_point? string Optional secrets engine mount point (defaults to "secret")

local VAULT_TIMEOUT_MS = 300000
local VAULT_TOKEN_CACHE_SEC = 300
local VAULT_MAX_RETRIES = 3
local MAX_PARALLEL_REQUESTS = 5
local REQUEST_DELAY_MS = 100

---@type table<string, VaultError>
local VAULT_ERRORS = {
  INVALID_TOKEN = {
    message = "Invalid Vault token. Please check your token and try again.",
    code = "InvalidToken",
    level = vim.log.levels.ERROR,
  },
  NO_TOKEN = {
    message = "No Vault token provided. Please configure your Vault token.",
    code = "NoToken",
    level = vim.log.levels.ERROR,
  },
  CONNECTION_ERROR = {
    message = "Could not connect to Vault server",
    code = "ConnectionError",
    level = vim.log.levels.ERROR,
  },
  ACCESS_DENIED = {
    message = "Access denied: Check your Vault token permissions",
    code = "AccessDenied",
    level = vim.log.levels.ERROR,
  },
  PATH_NOT_FOUND = {
    message = "Secret path not found",
    code = "PathNotFound",
    level = vim.log.levels.ERROR,
  },
  TIMEOUT = {
    message = "Vault secret loading timed out after 5 minutes",
    code = "Timeout",
    level = vim.log.levels.ERROR,
  },
  NO_ADDRESS = {
    message = "Vault server address is required",
    code = "NoAddress",
    level = vim.log.levels.ERROR,
  },
  NO_PATHS = {
    message = "No secret paths specified",
    code = "NoPaths",
    level = vim.log.levels.ERROR,
  },
  NO_VAULT_CLI = {
    message = "Vault CLI is not installed or not in PATH",
    code = "NoVaultCli",
    level = vim.log.levels.ERROR,
  },
  NOT_CONFIGURED = {
    message = "HashiCorp Vault is not configured. Enable it in your setup first.",
    code = "NotConfigured",
    level = vim.log.levels.ERROR,
  },
}

local state = {
  selected_secrets = {},
  config = nil,
  loading = false,
  loaded_secrets = {},
  active_jobs = {},
  is_refreshing = false,
  skip_load = false,
  token_valid = false,
  last_token_check = 0,
  loading_lock = nil,
  timeout_timer = nil,
  initialized = false,
  pending_env_updates = {},
}

---Process Vault error from stderr
---@param stderr string
---@param path? string
---@return VaultError
local function process_vault_error(stderr, path)
  if stderr:match("permission denied") or stderr:match("invalid token") then
    return VAULT_ERRORS.INVALID_TOKEN
  elseif stderr:match("no token") then
    return VAULT_ERRORS.NO_TOKEN
  elseif stderr:match("connection refused") or stderr:match("connection error") then
    local err = vim.deepcopy(VAULT_ERRORS.CONNECTION_ERROR)
    if path then
      err.message = string.format("Vault connectivity error for path %s: %s", path, err.message)
    end
    return err
  elseif stderr:match("permission denied") then
    local err = vim.deepcopy(VAULT_ERRORS.ACCESS_DENIED)
    if path then
      err.message = string.format("Access denied for path %s: %s", path, err.message)
    end
    return err
  elseif stderr:match("not found") then
    local err = vim.deepcopy(VAULT_ERRORS.PATH_NOT_FOUND)
    if path then
      err.message = string.format("Secret path not found: %s", path)
    end
    return err
  end

  return {
    message = path and string.format("Error fetching secret %s: %s", path, stderr) or stderr,
    code = "UnknownError",
    level = vim.log.levels.ERROR,
  }
end

---Process a secret value and add it to vault_secrets
---@param secret_value string
---@param path string
---@param vault_config LoadVaultSecretsConfig
---@param vault_secrets table<string, table>
---@return number loaded Number of secrets loaded
---@return number failed Number of secrets that failed to load
local function process_secret_value(secret_value, path, vault_config, vault_secrets)
  local loaded, failed = 0, 0

  if secret_value == "" then
    return loaded, failed
  end

  if secret_value:match("^{") then
    local ok, parsed_secret = pcall(vim.json.decode, secret_value)
    if ok and type(parsed_secret) == "table" then
      for key, value in pairs(parsed_secret) do
        if not vault_config.filter or vault_config.filter(key, value) then
          local transformed_value = value
          if vault_config.transform then
            local transform_ok, result = pcall(vault_config.transform, key, value)
            if transform_ok then
              transformed_value = result
            else
              vim.notify(
                string.format("Error transforming value for key %s: %s", key, tostring(result)),
                vim.log.levels.WARN
              )
            end
          end

          local type_name, detected_value = require("ecolog.types").detect_type(transformed_value)
          vault_secrets[key] = {
            value = detected_value or transformed_value,
            type = type_name,
            raw_value = value,
            source = "vault:" .. path,
            comment = nil,
          }
          loaded = loaded + 1
        end
      end
    else
      vim.notify(string.format("Failed to parse JSON secret from %s", path), vim.log.levels.WARN)
      failed = failed + 1
    end
  else
    local key = path:match("[^/]+$")
    if not vault_config.filter or vault_config.filter(key, secret_value) then
      local transformed_value = secret_value
      if vault_config.transform then
        local transform_ok, result = pcall(vault_config.transform, key, secret_value)
        if transform_ok then
          transformed_value = result
        else
          vim.notify(
            string.format("Error transforming value for key %s: %s", key, tostring(result)),
            vim.log.levels.WARN
          )
        end
      end

      local type_name, detected_value = require("ecolog.types").detect_type(transformed_value)
      vault_secrets[key] = {
        value = detected_value or transformed_value,
        type = type_name,
        raw_value = secret_value,
        source = "vault:" .. path,
        comment = nil,
      }
      loaded = loaded + 1
    end
  end

  return loaded, failed
end

---Check Vault token
---@param vault_config LoadVaultSecretsConfig
---@param callback fun(ok: boolean, err?: string)
local function check_vault_token(vault_config, callback)
  local now = os.time()
  if state.token_valid and (now - state.last_token_check) < VAULT_TOKEN_CACHE_SEC then
    callback(true)
    return
  end

  local cmd = {
    "vault",
    "token",
    "lookup",
    "-address=" .. vault_config.address,
  }

  local stdout = ""
  local stderr = ""

  local job_id = vim.fn.jobstart(cmd, {
    env = { VAULT_TOKEN = vault_config.token },
    on_stdout = function(_, data)
      if data then
        stdout = stdout .. table.concat(data, "\n")
      end
    end,
    on_stderr = function(_, data)
      if data then
        stderr = stderr .. table.concat(data, "\n")
      end
    end,
    on_exit = function(_, code)
      secret_utils.untrack_job(job_id, state.active_jobs)
      if code ~= 0 then
        state.token_valid = false
        local err = process_vault_error(stderr)
        callback(false, err.message)
        return
      end

      state.token_valid = true
      state.last_token_check = now
      callback(true)
    end,
  })

  if job_id <= 0 then
    callback(false, "Failed to start Vault CLI command")
  else
    secret_utils.track_job(job_id, state.active_jobs)
  end
end

---Process secrets in parallel batches
---@param vault_config LoadVaultSecretsConfig
---@param vault_secrets table<string, table>
---@param loaded_secrets number
---@param failed_secrets number
local function process_secrets_parallel(vault_config, vault_secrets, loaded_secrets, failed_secrets)
  if not state.loading_lock then
    return
  end

  local total_secrets = #vault_config.paths
  local active_jobs = 0
  local completed_jobs = 0
  local current_index = 1
  local retry_counts = {}

  local function check_completion()
    if completed_jobs >= total_secrets then
      if loaded_secrets > 0 or failed_secrets > 0 then
        local msg = string.format("Vault: Loaded %d secret%s", loaded_secrets, loaded_secrets == 1 and "" or "s")
        if failed_secrets > 0 then
          msg = msg .. string.format(", %d failed", failed_secrets)
        end
        vim.notify(msg, failed_secrets > 0 and vim.log.levels.WARN or vim.log.levels.INFO)

        state.loaded_secrets = vault_secrets
        state.initialized = true

        local updates_to_process = state.pending_env_updates
        state.pending_env_updates = {}

        secret_utils.update_environment(vault_secrets, vault_config.override, "vault:")

        for _, update_fn in ipairs(updates_to_process) do
          update_fn()
        end

        secret_utils.cleanup_state(state)
      end
    end
  end

  local function start_job(index)
    if index > total_secrets or not state.loading_lock then
      return
    end

    local mount_point = vault_config.mount_point or "secret"
    local cmd = {
      "vault",
      "kv",
      "get",
      "-address=" .. vault_config.address,
      "-format=json",
      "-mount=" .. mount_point,
      vault_config.paths[index],
    }

    local stdout_chunks = {}
    local stderr_chunks = {}

    local job_id = vim.fn.jobstart(cmd, {
      env = { VAULT_TOKEN = vault_config.token },
      on_stdout = function(_, data)
        if data then
          vim.list_extend(stdout_chunks, data)
        end
      end,
      on_stderr = function(_, data)
        if data then
          vim.list_extend(stderr_chunks, data)
        end
      end,
      on_exit = function(_, code)
        secret_utils.untrack_job(job_id, state.active_jobs)
        vim.schedule(function()
          if not state.loading_lock then
            return
          end

          active_jobs = active_jobs - 1
          local stdout = table.concat(stdout_chunks, "\n")
          local stderr = table.concat(stderr_chunks, "\n")

          if code ~= 0 then
            retry_counts[index] = (retry_counts[index] or 0) + 1
            if retry_counts[index] <= VAULT_MAX_RETRIES and (
              stderr:match("connection refused")
              or stderr:match("rate limit exceeded")
              or stderr:match("timeout")
            ) then
              vim.defer_fn(function()
                start_job(index)
              end, 1000 * retry_counts[index])
              return
            end

            failed_secrets = failed_secrets + 1
            local err = process_vault_error(stderr, vault_config.paths[index])
            vim.notify(err.message, err.level)
          else
            local secret_value = stdout:gsub("^%s*(.-)%s*$", "%1")
            if secret_value ~= "" then
              local loaded, failed = process_secret_value(secret_value, vault_config.paths[index], vault_config, vault_secrets)
              loaded_secrets = loaded_secrets + loaded
              failed_secrets = failed_secrets + failed
            end
          end

          completed_jobs = completed_jobs + 1
          check_completion()

          if current_index <= total_secrets then
            vim.defer_fn(function()
              start_next_job()
            end, REQUEST_DELAY_MS)
          end
        end)
      end,
    })

    if job_id > 0 then
      active_jobs = active_jobs + 1
      secret_utils.track_job(job_id, state.active_jobs)
    else
      vim.schedule(function()
        failed_secrets = failed_secrets + 1
        vim.notify(
          string.format("Failed to start Vault CLI command for path %s", vault_config.paths[index]),
          vim.log.levels.ERROR
        )
        completed_jobs = completed_jobs + 1
        check_completion()

        if current_index <= total_secrets then
          vim.defer_fn(function()
            start_next_job()
          end, REQUEST_DELAY_MS)
        end
      end)
    end
  end

  local function start_next_job()
    if current_index <= total_secrets and active_jobs < MAX_PARALLEL_REQUESTS then
      start_job(current_index)
      current_index = current_index + 1
      
      if current_index <= total_secrets and active_jobs < MAX_PARALLEL_REQUESTS then
        vim.defer_fn(function()
          start_next_job()
        end, REQUEST_DELAY_MS)
      end
    end
  end

  for _ = 1, math.min(MAX_PARALLEL_REQUESTS, total_secrets) do
    start_next_job()
  end
end

---Load Vault secrets
---@param config boolean|LoadVaultSecretsConfig
---@return table<string, table>
function M.load_vault_secrets(config)
  if state.loading_lock then
    return state.loaded_secrets or {}
  end

  if state.skip_load then
    return state.loaded_secrets or {}
  end

  if state.initialized and not state.is_refreshing then
    return state.loaded_secrets or {}
  end

  state.loading_lock = {}
  state.loading = true
  state.pending_env_updates = {}

  state.config = config
  local vault_config = type(config) == "table" and config or { enabled = config, override = false }

  if not vault_config.enabled then
    local current_env = ecolog.get_env_vars() or {}
    local final_vars = {}

    for key, value in pairs(current_env) do
      if not (value.source and value.source:match("^vault:")) then
        final_vars[key] = value
      end
    end

    state.selected_secrets = {}
    state.loaded_secrets = {}

    ecolog.refresh_env_vars()
    ecolog.add_env_vars(final_vars)
    secret_utils.cleanup_state(state)
    return {}
  end

  if not vault_config.address then
    vim.notify(VAULT_ERRORS.NO_ADDRESS.message, VAULT_ERRORS.NO_ADDRESS.level)
    secret_utils.cleanup_state(state)
    return {}
  end

  if not vault_config.token then
    vim.notify(VAULT_ERRORS.NO_TOKEN.message, VAULT_ERRORS.NO_TOKEN.level)
    secret_utils.cleanup_state(state)
    return {}
  end

  if not vault_config.paths or #vault_config.paths == 0 then
    if not state.is_refreshing then
      secret_utils.cleanup_state(state)
      return {}
    end
    vim.notify(VAULT_ERRORS.NO_PATHS.message, VAULT_ERRORS.NO_PATHS.level)
    secret_utils.cleanup_state(state)
    return {}
  end

  if vim.fn.executable("vault") ~= 1 then
    vim.notify(VAULT_ERRORS.NO_VAULT_CLI.message, VAULT_ERRORS.NO_VAULT_CLI.level)
    secret_utils.cleanup_state(state)
    return {}
  end

  state.selected_secrets = vim.deepcopy(vault_config.paths)

  local vault_secrets = {}
  vim.notify("Loading Vault secrets...", vim.log.levels.INFO)

  state.timeout_timer = vim.fn.timer_start(VAULT_TIMEOUT_MS, function()
    if state.loading_lock then
      vim.notify(VAULT_ERRORS.TIMEOUT.message, VAULT_ERRORS.TIMEOUT.level)
      secret_utils.cleanup_state(state)
    end
  end)

  check_vault_token(vault_config, function(ok, err)
    if not state.loading_lock then
      return
    end

    if not ok then
      vim.schedule(function()
        vim.notify(err, vim.log.levels.ERROR)
        secret_utils.cleanup_state(state)
      end)
      return
    end

    process_secrets_parallel(vault_config, vault_secrets, 0, 0)
  end)

  return state.loaded_secrets or {}
end

---List available secrets in Vault
---@param vault_config LoadVaultSecretsConfig
---@param callback fun(secrets: string[]|nil, err?: string)
local function list_secrets(vault_config, callback)
  local mount_point = vault_config.mount_point or "secret"
  local cmd = {
    "vault",
    "kv",
    "list",
    "-address=" .. vault_config.address,
    "-format=json",
    mount_point,
  }

  local stdout = ""
  local stderr = ""

  local job_id = vim.fn.jobstart(cmd, {
    env = { VAULT_TOKEN = vault_config.token },
    on_stdout = function(_, data)
      if data then
        stdout = stdout .. table.concat(data, "\n")
      end
    end,
    on_stderr = function(_, data)
      if data then
        stderr = stderr .. table.concat(data, "\n")
      end
    end,
    on_exit = function(_, code)
      secret_utils.untrack_job(job_id, state.active_jobs)
      if code ~= 0 then
        local err = process_vault_error(stderr)
        callback(nil, err.message)
        return
      end

      local ok, parsed = pcall(vim.json.decode, stdout)
      if not ok or type(parsed) ~= "table" then
        callback(nil, "Failed to parse Vault response")
        return
      end

      callback(parsed)
    end,
  })

  if job_id <= 0 then
    callback(nil, "Failed to start Vault CLI command")
  else
    secret_utils.track_job(job_id, state.active_jobs)
  end
end

function M.select()
  if not state.config then
    vim.notify(VAULT_ERRORS.NOT_CONFIGURED.message, VAULT_ERRORS.NOT_CONFIGURED.level)
    return
  end

  if not state.config.address then
    vim.notify(VAULT_ERRORS.NO_ADDRESS.message, VAULT_ERRORS.NO_ADDRESS.level)
    return
  end

  if not state.config.token then
    vim.notify(VAULT_ERRORS.NO_TOKEN.message, VAULT_ERRORS.NO_TOKEN.level)
    return
  end

  check_vault_token(state.config, function(ok, err)
    if not ok then
      vim.notify(err, vim.log.levels.ERROR)
      return
    end

    list_secrets(state.config, function(secrets, list_err)
      if list_err then
        vim.notify(list_err, vim.log.levels.ERROR)
        return
      end

      if not secrets or #secrets == 0 then
        vim.notify("No secrets found in Vault", vim.log.levels.WARN)
        return
      end

      local selected = {}
      for _, path in ipairs(state.selected_secrets) do
        selected[path] = true
      end

      secret_utils.create_secret_selection_ui(secrets, selected, function(new_selected)
        local chosen_secrets = {}
        for secret, is_selected in pairs(new_selected) do
          if is_selected then
            table.insert(chosen_secrets, secret)
          end
        end

        if #chosen_secrets == 0 then
          local current_env = ecolog.get_env_vars() or {}
          local final_vars = {}

          for key, value in pairs(current_env) do
            if not (value.source and value.source:match("^vault:")) then
              final_vars[key] = value
            end
          end

          state.selected_secrets = {}
          state.loaded_secrets = {}
          state.initialized = false

          ecolog.refresh_env_vars()
          secret_utils.update_environment(final_vars, false, "vault:")
          vim.notify("All Vault secrets unloaded", vim.log.levels.INFO)
          return
        end

        local new_loaded_secrets = {}
        for key, value in pairs(state.loaded_secrets) do
          local secret_name = value.source and value.source:match("^vault:(.+)$")
          if secret_name and new_selected[secret_name] then
            new_loaded_secrets[key] = value
          end
        end

        state.loaded_secrets = new_loaded_secrets
        state.selected_secrets = chosen_secrets
        state.initialized = false

        M.load_vault_secrets(vim.tbl_extend("force", state.config, {
          paths = state.selected_secrets,
          enabled = true,
        }))
      end, "vault:")
    end)
  end)
end

api.nvim_create_autocmd("VimLeavePre", {
  group = api.nvim_create_augroup("EcologVaultCleanup", { clear = true }),
  callback = function()
    secret_utils.cleanup_jobs(state.active_jobs)
  end,
})

return M 