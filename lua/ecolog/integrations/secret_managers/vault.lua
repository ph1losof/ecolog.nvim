local api = vim.api
local utils = require("ecolog.utils")
local ecolog = require("ecolog")
local secret_utils = require("ecolog.integrations.secret_managers.utils")
local BaseSecretManager = require("ecolog.integrations.secret_managers.base").BaseSecretManager

---@class VaultSecretsConfig : BaseSecretManagerConfig
---@field address string Vault server address
---@field token string Vault token
---@field paths string[] List of secret paths to fetch
---@field mount_point? string Optional secrets engine mount point (defaults to "secret")

---@class VaultError
---@field message string
---@field code string
---@field level number

local VAULT_TIMEOUT_MS = 300000
local VAULT_TOKEN_CACHE_SEC = 300
local VAULT_MAX_RETRIES = 3

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
    message = "No secret paths specified for Vault integration",
    code = "NoPaths",
    level = vim.log.levels.ERROR,
  },
  NO_VAULT_CLI = {
    message = "Vault CLI is not installed or not in PATH",
    code = "NoVaultCli",
    level = vim.log.levels.ERROR,
  },
}

---@class VaultSecretsState : SecretManagerState
---@field token_valid boolean
---@field last_token_check number

---@class VaultSecretsManager : BaseSecretManager
---@field state VaultSecretsState
---@field config VaultSecretsConfig
local VaultSecretsManager = setmetatable({}, { __index = BaseSecretManager })

function VaultSecretsManager:new()
  local instance = BaseSecretManager.new(self, "vault:", "HashiCorp Vault")
  instance.state.token_valid = false
  instance.state.last_token_check = 0
  setmetatable(instance, { __index = self })
  return instance
end

---Process Vault error from stderr
---@param stderr string
---@param path? string
---@return VaultError
function VaultSecretsManager:process_error(stderr, path)
  if stderr:match("permission denied") then
    local err = vim.deepcopy(VAULT_ERRORS.ACCESS_DENIED)
    if path then
      err.message = string.format("Access denied for path %s: %s", path, err.message)
    end
    return err
  elseif stderr:match("invalid token") or stderr:match("permission denied") then
    return VAULT_ERRORS.INVALID_TOKEN
  elseif stderr:match("no token") then
    return VAULT_ERRORS.NO_TOKEN
  elseif stderr:match("connection refused") or stderr:match("connection error") then
    local err = vim.deepcopy(VAULT_ERRORS.CONNECTION_ERROR)
    if path then
      err.message = string.format("Vault connectivity error for path %s: %s", path, err.message)
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

---Check Vault token
---@param callback fun(ok: boolean, err?: string)
function VaultSecretsManager:check_token(callback)
  local now = os.time()
  if self.state.token_valid and (now - self.state.last_token_check) < VAULT_TOKEN_CACHE_SEC then
    callback(true)
    return
  end

  local cmd = {
    "vault",
    "token",
    "lookup",
    "-address=" .. self.config.address,
  }

  local stdout = ""
  local stderr = ""

  local job_id = vim.fn.jobstart(cmd, {
    env = { VAULT_TOKEN = self.config.token },
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
      secret_utils.untrack_job(job_id, self.state.active_jobs)
      if code ~= 0 then
        self.state.token_valid = false
        local err = self:process_error(stderr)
        callback(false, err.message)
        return
      end

      self.state.token_valid = true
      self.state.last_token_check = now
      callback(true)
    end,
  })

  if job_id <= 0 then
    callback(false, "Failed to start Vault CLI command")
  else
    secret_utils.track_job(job_id, self.state.active_jobs)
  end
end

---List available secrets in Vault
---@param callback fun(secrets: string[]|nil, err?: string)
function VaultSecretsManager:list_secrets(callback)
  local mount_point = self.config.mount_point or "secret"
  local cmd = {
    "vault",
    "kv",
    "list",
    "-address=" .. self.config.address,
    "-format=json",
    mount_point,
  }

  local stdout = ""
  local stderr = ""

  local job_id = vim.fn.jobstart(cmd, {
    env = { VAULT_TOKEN = self.config.token },
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
      secret_utils.untrack_job(job_id, self.state.active_jobs)
      if code ~= 0 then
        local err = self:process_error(stderr)
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
    secret_utils.track_job(job_id, self.state.active_jobs)
  end
end

---Implementation specific loading of secrets
---@protected
---@param config VaultSecretsConfig
function VaultSecretsManager:_load_secrets_impl(config)
  if not config.address then
    vim.notify(VAULT_ERRORS.NO_ADDRESS.message, VAULT_ERRORS.NO_ADDRESS.level)
    secret_utils.cleanup_state(self.state)
    return {}
  end

  if not config.token then
    vim.notify(VAULT_ERRORS.NO_TOKEN.message, VAULT_ERRORS.NO_TOKEN.level)
    secret_utils.cleanup_state(self.state)
    return {}
  end

  if not config.paths or #config.paths == 0 then
    if not self.state.is_refreshing then
      secret_utils.cleanup_state(self.state)
      return {}
    end
    vim.notify(VAULT_ERRORS.NO_PATHS.message, VAULT_ERRORS.NO_PATHS.level)
    secret_utils.cleanup_state(self.state)
    return {}
  end

  if vim.fn.executable("vault") ~= 1 then
    vim.notify(VAULT_ERRORS.NO_VAULT_CLI.message, VAULT_ERRORS.NO_VAULT_CLI.level)
    secret_utils.cleanup_state(self.state)
    return {}
  end

  self.state.selected_secrets = vim.deepcopy(config.paths)

  local vault_secrets = {}
  vim.notify("Loading Vault secrets...", vim.log.levels.INFO)

  self.state.timeout_timer = vim.fn.timer_start(VAULT_TIMEOUT_MS, function()
    if self.state.loading_lock then
      vim.notify(VAULT_ERRORS.TIMEOUT.message, VAULT_ERRORS.TIMEOUT.level)
      secret_utils.cleanup_state(self.state)
    end
  end)

  self:check_token(function(ok, err)
    if not self.state.loading_lock then
      return
    end

    if not ok then
      vim.schedule(function()
        vim.notify(err, vim.log.levels.ERROR)
        secret_utils.cleanup_state(self.state)
      end)
      return
    end

    local total_secrets = #config.paths
    local active_jobs = 0
    local completed_jobs = 0
    local current_index = 1
    local loaded_secrets = 0
    local failed_secrets = 0
    local retry_counts = {}

    local function check_completion()
      if completed_jobs >= total_secrets then
        if loaded_secrets > 0 or failed_secrets > 0 then
          local msg = string.format("HashiCorp Vault: Loaded %d secret%s", 
            loaded_secrets, 
            loaded_secrets == 1 and "" or "s"
          )
          if failed_secrets > 0 then
            msg = msg .. string.format(", %d failed", failed_secrets)
          end
          vim.notify(msg, failed_secrets > 0 and vim.log.levels.WARN or vim.log.levels.INFO)

          self.state.loaded_secrets = vault_secrets
          self.state.initialized = true

          local updates_to_process = self.state.pending_env_updates
          self.state.pending_env_updates = {}

          secret_utils.update_environment(vault_secrets, config.override, "vault:")

          for _, update_fn in ipairs(updates_to_process) do
            update_fn()
          end

          secret_utils.cleanup_state(self.state)
        end
      end
    end

    local function start_job(index)
      if index > total_secrets or not self.state.loading_lock then
        return
      end

      local mount_point = config.mount_point or "secret"
      local cmd = {
        "vault",
        "kv",
        "get",
        "-address=" .. config.address,
        "-format=json",
        "-mount=" .. mount_point,
        config.paths[index],
      }

      local stdout_chunks = {}
      local stderr_chunks = {}

      local job_id = vim.fn.jobstart(cmd, {
        env = { VAULT_TOKEN = config.token },
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
          secret_utils.untrack_job(job_id, self.state.active_jobs)
          vim.schedule(function()
            if not self.state.loading_lock then
              return
            end

            active_jobs = active_jobs - 1
            local stdout = table.concat(stdout_chunks, "\n")
            local stderr = table.concat(stderr_chunks, "\n")

            if code ~= 0 then
              retry_counts[index] = (retry_counts[index] or 0) + 1
              if
                retry_counts[index] <= VAULT_MAX_RETRIES
                and (
                  stderr:match("connection refused")
                  or stderr:match("rate limit exceeded")
                  or stderr:match("timeout")
                )
              then
                vim.defer_fn(function()
                  start_job(index)
                end, 1000 * retry_counts[index])
                return
              end

              failed_secrets = failed_secrets + 1
              local err = self:process_error(stderr, config.paths[index])
              vim.notify(err.message, err.level)
            else
              local ok, response = pcall(vim.json.decode, stdout)
              if ok and response and response.data and response.data.data then
                local loaded, failed = secret_utils.process_secret_value(
                  vim.json.encode(response.data.data),
                  {
                    filter = config.filter,
                    transform = config.transform,
                    source_prefix = "vault:",
                    source_path = config.paths[index],
                  },
                  vault_secrets
                )
                loaded_secrets = loaded_secrets + loaded
                failed_secrets = failed_secrets + failed
              end
            end

            completed_jobs = completed_jobs + 1
            check_completion()

            if current_index <= total_secrets then
              vim.defer_fn(function()
                start_next_job()
              end, secret_utils.REQUEST_DELAY_MS)
            end
          end)
        end,
      })

      if job_id > 0 then
        active_jobs = active_jobs + 1
        secret_utils.track_job(job_id, self.state.active_jobs)
      else
        vim.schedule(function()
          failed_secrets = failed_secrets + 1
          vim.notify(
            string.format("Failed to start Vault CLI command for path %s", config.paths[index]),
            vim.log.levels.ERROR
          )
          completed_jobs = completed_jobs + 1
          check_completion()

          if current_index <= total_secrets then
            vim.defer_fn(function()
              start_next_job()
            end, secret_utils.REQUEST_DELAY_MS)
          end
        end)
      end
    end

    local function start_next_job()
      if current_index <= total_secrets and active_jobs < secret_utils.MAX_PARALLEL_REQUESTS then
        start_job(current_index)
        current_index = current_index + 1

        if current_index <= total_secrets and active_jobs < secret_utils.MAX_PARALLEL_REQUESTS then
          vim.defer_fn(function()
            start_next_job()
          end, secret_utils.REQUEST_DELAY_MS)
        end
      end
    end

    -- Start initial batch of jobs
    local max_initial_jobs = math.min(secret_utils.MAX_PARALLEL_REQUESTS, total_secrets)
    for _ = 1, max_initial_jobs do
      start_next_job()
    end
  end)

  return self.state.loaded_secrets or {}
end

---Implementation specific selection of secrets
---@protected
function VaultSecretsManager:_select_impl()
  if not self.config or not self.config.address then
    vim.notify(VAULT_ERRORS.NO_ADDRESS.message, VAULT_ERRORS.NO_ADDRESS.level)
    return
  end

  if not self.config.token then
    vim.notify(VAULT_ERRORS.NO_TOKEN.message, VAULT_ERRORS.NO_TOKEN.level)
    return
  end

  self:check_token(function(ok, err)
    if not ok then
      vim.notify(err, vim.log.levels.ERROR)
      return
    end

    self:list_secrets(function(secrets, list_err)
      if list_err then
        vim.notify(list_err, vim.log.levels.ERROR)
        return
      end

      if not secrets or #secrets == 0 then
        vim.notify("No secrets found in Vault", vim.log.levels.WARN)
        return
      end

      local selected = {}
      for _, path in ipairs(self.state.selected_secrets) do
        selected[path] = true
      end

      secret_utils.create_secret_selection_ui(secrets, selected, function(new_selected)
        local chosen_paths = {}
        for path, is_selected in pairs(new_selected) do
          if is_selected then
            table.insert(chosen_paths, path)
          end
        end

        if #chosen_paths == 0 then
          local current_env = ecolog.get_env_vars() or {}
          local final_vars = {}

          for key, value in pairs(current_env) do
            if not (value.source and value.source:match("^vault:")) then
              final_vars[key] = value
            end
          end

          self.state.selected_secrets = {}
          self.state.loaded_secrets = {}
          self.state.initialized = false

          ecolog.refresh_env_vars()
          secret_utils.update_environment(final_vars, false, "vault:")
          vim.notify("All Vault secrets unloaded", vim.log.levels.INFO)
          return
        end

        local new_loaded_secrets = {}
        for key, value in pairs(self.state.loaded_secrets) do
          local path = value.source and value.source:match("^vault:(.+)$")
          if path and new_selected[path] then
            new_loaded_secrets[key] = value
          end
        end

        self.state.loaded_secrets = new_loaded_secrets
        self.state.selected_secrets = chosen_paths
        self.state.initialized = false

        self:load_secrets(vim.tbl_extend("force", self.config, {
          paths = self.state.selected_secrets,
          enabled = true,
        }))
      end, "vault:")
    end)
  end)
end

function VaultSecretsManager:setup_cleanup()
  api.nvim_create_autocmd("VimLeavePre", {
    group = api.nvim_create_augroup("EcologVaultSecretsCleanup", { clear = true }),
    callback = function()
      secret_utils.cleanup_jobs(self.state.active_jobs)
    end,
  })
end

local instance = VaultSecretsManager:new()
instance:setup_cleanup()

return {
  load_vault_secrets = function(config)
    return instance:load_secrets(config)
  end,
  select = function()
    return instance:select()
  end,
}

