local api = vim.api
local utils = require("ecolog.utils")
local ecolog = require("ecolog")
local secret_utils = require("ecolog.integrations.secret_managers.utils")
local BaseSecretManager = require("ecolog.integrations.secret_managers.base").BaseSecretManager

---@class VaultSecretsConfig : BaseSecretManagerConfig
---@field apps string[] List of enabled HCP Vault Secrets application names

---@class VaultError
---@field message string
---@field code string
---@field level number

local VAULT_TIMEOUT_MS = 300000
local VAULT_TOKEN_CACHE_SEC = 300

---@type table<string, VaultError>
local VAULT_ERRORS = {
  CONNECTION_ERROR = {
    message = "Could not connect to HCP Vault Secrets",
    code = "ConnectionError",
    level = vim.log.levels.ERROR,
  },
  ACCESS_DENIED = {
    message = "Access denied: Check your HCP service principal permissions",
    code = "AccessDenied",
    level = vim.log.levels.ERROR,
  },
  PATH_NOT_FOUND = {
    message = "Secret path not found",
    code = "PathNotFound",
    level = vim.log.levels.ERROR,
  },
  TIMEOUT = {
    message = "HCP Vault Secrets loading timed out after 5 minutes",
    code = "Timeout",
    level = vim.log.levels.ERROR,
  },
  NO_APPS = {
    message = "No applications configured for HCP Vault Secrets",
    code = "NoApps",
    level = vim.log.levels.ERROR,
  },
  NO_HCP_CLI = {
    message = "HCP CLI is not installed or not in PATH",
    code = "NoHcpCli",
    level = vim.log.levels.ERROR,
  },
  NO_AUTH = {
    message = "Not authenticated with HCP CLI. Please run 'hcp auth login' first",
    code = "NoAuth",
    level = vim.log.levels.ERROR,
  },
}

---@class VaultSecretsState : SecretManagerState
---@field token_valid boolean
---@field last_token_check number
---@field app_secrets table<string, string[]> Map of app names to their selected secret paths

---@class VaultSecretsManager : BaseSecretManager
---@field state VaultSecretsState
---@field config VaultSecretsConfig
local VaultSecretsManager = setmetatable({}, { __index = BaseSecretManager })

function VaultSecretsManager:new()
  local instance = BaseSecretManager.new(self, "vault:", "HashiCorp Vault")
  instance.state.token_valid = false
  instance.state.last_token_check = 0
  instance.state.app_secrets = {}
  setmetatable(instance, { __index = self })
  return instance
end

---Process Vault error from stderr
---@param stderr string
---@param path? string
---@return VaultError
function VaultSecretsManager:process_error(stderr, path)
  if stderr:match("No authentication detected") or stderr:match("failed to get new token") then
    return VAULT_ERRORS.NO_AUTH
  elseif stderr:match("permission denied") or stderr:match("access denied") then
    local err = vim.deepcopy(VAULT_ERRORS.ACCESS_DENIED)
    if path then
      err.message = string.format("Access denied for path %s: %s", path, err.message)
    end
    return err
  elseif stderr:match("connection refused") or stderr:match("connection error") then
    local err = vim.deepcopy(VAULT_ERRORS.CONNECTION_ERROR)
    if path then
      err.message = string.format("HCP Vault Secrets connectivity error for path %s: %s", path, err.message)
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

---Check HCP service principal credentials
---@param callback fun(ok: boolean, err?: string)
function VaultSecretsManager:check_token(callback)
  local now = os.time()
  if self.state.token_valid and (now - self.state.last_token_check) < VAULT_TOKEN_CACHE_SEC then
    callback(true)
    return
  end

  local cmd = {
    "hcp",
    "vault-secrets",
    "secrets",
    "list",
  }

  local stdout = ""
  local stderr = ""

  local job_id = vim.fn.jobstart(cmd, {
    env = {
      HCP_CLIENT_ID = self.config.client_id,
      HCP_CLIENT_SECRET = self.config.token,
    },
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
    callback(false, "Failed to start HCP CLI command")
  else
    secret_utils.track_job(job_id, self.state.active_jobs)
  end
end

---List available secrets in HCP Vault Secrets
---@param callback fun(secrets: string[]|nil, err?: string)
function VaultSecretsManager:list_secrets(callback)
  local cmd = {
    "hcp",
    "vault-secrets",
    "secrets",
    "list",
    "--format=json",
  }

  local stdout = ""
  local stderr = ""

  local job_id = vim.fn.jobstart(cmd, {
    env = {
      HCP_CLIENT_ID = self.config.client_id,
      HCP_CLIENT_SECRET = self.config.token,
    },
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
        callback(nil, "Failed to parse HCP Vault Secrets response")
        return
      end

      local secrets = {}
      for _, secret in ipairs(parsed.secrets or {}) do
        if secret.name then
          table.insert(secrets, secret.name)
        end
      end

      callback(secrets)
    end,
  })

  if job_id <= 0 then
    callback(nil, "Failed to start HCP CLI command")
  else
    secret_utils.track_job(job_id, self.state.active_jobs)
  end
end

---List available apps in HCP Vault Secrets
---@param callback fun(apps: string[]|nil, err?: string)
function VaultSecretsManager:list_apps(callback)
  vim.notify("Listing HCP Vault Secrets applications...", vim.log.levels.INFO)
  
  local cmd = {
    "hcp",
    "vault-secrets",
    "apps",
    "list",
    "--format=json",
  }

  local stdout = ""
  local stderr = ""

  local job_id = vim.fn.jobstart(cmd, {
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
        callback(nil, "Failed to parse HCP Vault Secrets response")
        return
      end

      local apps = {}
      -- The response is a direct array of apps
      for _, app in ipairs(parsed) do
        if app.name then
          table.insert(apps, app.name)
        end
      end

      callback(apps)
    end,
  })

  if job_id <= 0 then
    callback(nil, "Failed to start HCP CLI command")
  else
    secret_utils.track_job(job_id, self.state.active_jobs)
  end
end

---Implementation specific loading of secrets
---@protected
---@param config VaultSecretsConfig
function VaultSecretsManager:_load_secrets_impl(config)
  if not config.apps or #config.apps == 0 then
    if not self.state.is_refreshing then
      secret_utils.cleanup_state(self.state)
      return {}
    end
    vim.notify(VAULT_ERRORS.NO_APPS.message, VAULT_ERRORS.NO_APPS.level)
    secret_utils.cleanup_state(self.state)
    return {}
  end

  if vim.fn.executable("hcp") ~= 1 then
    vim.notify(VAULT_ERRORS.NO_HCP_CLI.message, VAULT_ERRORS.NO_HCP_CLI.level)
    secret_utils.cleanup_state(self.state)
    return {}
  end

  -- Collect all paths from all apps
  local all_paths = {}
  for _, app_name in ipairs(config.apps) do
    local paths = self.state.app_secrets[app_name] or {}
    for _, path in ipairs(paths) do
      table.insert(all_paths, { app = app_name, path = path })
    end
  end

  self.state.selected_secrets = all_paths

  local vault_secrets = {}
  vim.notify("Loading HCP Vault secrets...", vim.log.levels.INFO)

  self.state.timeout_timer = vim.fn.timer_start(VAULT_TIMEOUT_MS, function()
    if self.state.loading_lock then
      vim.notify(VAULT_ERRORS.TIMEOUT.message, VAULT_ERRORS.TIMEOUT.level)
      secret_utils.cleanup_state(self.state)
    end
  end)

  local total_secrets = #all_paths
  local active_jobs = 0
  local completed_jobs = 0
  local current_index = 1
  local loaded_secrets = 0
  local failed_secrets = 0
  local retry_counts = {}

  local function check_completion()
    if completed_jobs >= total_secrets then
      if loaded_secrets > 0 or failed_secrets > 0 then
        local msg = string.format("HCP Vault Secrets: Loaded %d secret%s", 
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

    local secret = all_paths[index]
    local cmd = {
      "hcp",
      "vault-secrets",
      "secrets",
      "open",
      secret.path,
      "--app",
      secret.app,
      "--format=json",
    }

    local stdout_chunks = {}
    local stderr_chunks = {}

    local job_id = vim.fn.jobstart(cmd, {
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
              retry_counts[index] <= secret_utils.MAX_RETRIES
              and (
                stderr:match("connection refused")
                or stderr:match("rate limit exceeded")
                or stderr:match("timeout")
              )
            then
              vim.notify(string.format("Retrying secret %s from %s (attempt %d/%d)", 
                secret.path, secret.app, retry_counts[index], secret_utils.MAX_RETRIES), 
                vim.log.levels.INFO)
              vim.defer_fn(function()
                start_job(index)
              end, 1000 * retry_counts[index])
              return
            end

            failed_secrets = failed_secrets + 1
            local err = self:process_error(stderr, secret.path)
            vim.notify(string.format("[%s] %s", secret.app, err.message), err.level)
          else
            local ok, response = pcall(vim.json.decode, stdout)
            if ok and response and response.static_version and response.static_version.value then
              local loaded, failed = secret_utils.process_secret_value(
                response.static_version.value,
                {
                  filter = config.filter,
                  transform = config.transform,
                  source_prefix = "vault:",
                  source_path = string.format("%s/%s", secret.app, secret.path),
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
          string.format("Failed to start HCP CLI command for path %s in app %s", secret.path, secret.app),
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

  return self.state.loaded_secrets or {}
end

---Implementation specific selection of secrets
---@protected
function VaultSecretsManager:_select_impl()
  self:list_apps(function(apps, apps_err)
    if apps_err then
      vim.notify(apps_err, vim.log.levels.ERROR)
      return
    end

    if not apps or #apps == 0 then
      vim.notify("No applications found in HCP Vault Secrets", vim.log.levels.WARN)
      return
    end

    -- Create a selection UI for apps
    local selected_apps = {}
    if self.config and self.config.apps then
      for _, app_name in ipairs(self.config.apps) do
        selected_apps[app_name] = true
      end
    end

    secret_utils.create_secret_selection_ui(apps, selected_apps, function(new_selected_apps)
      local chosen_apps = {}
      for app, is_selected in pairs(new_selected_apps) do
        if is_selected then
          table.insert(chosen_apps, app)
        end
      end

      if #chosen_apps == 0 then
        local current_env = ecolog.get_env_vars() or {}
        local final_vars = {}

        for key, value in pairs(current_env) do
          if not (value.source and value.source:match("^vault:")) then
            final_vars[key] = value
          end
        end

        self.state.selected_secrets = {}
        self.state.loaded_secrets = {}
        self.state.app_secrets = {}
        self.state.initialized = false

        ecolog.refresh_env_vars()
        secret_utils.update_environment(final_vars, false, "vault:")
        vim.notify("All Vault secrets unloaded", vim.log.levels.INFO)
        return
      end

      -- For each selected app, list and select secrets
      local completed_apps = 0

      local function process_app(app_name)
        vim.notify(string.format("Listing secrets for app: %s", app_name), vim.log.levels.INFO)
        -- Set app name for the CLI command
        local cmd = {
          "hcp",
          "vault-secrets",
          "secrets",
          "list",
          "--app",
          app_name,
          "--format=json",
        }

        local stdout = ""
        local stderr = ""

        local job_id = vim.fn.jobstart(cmd, {
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
              vim.notify(string.format("[%s] %s", app_name, err.message), err.level)
              completed_apps = completed_apps + 1
              return
            end

            local ok, parsed = pcall(vim.json.decode, stdout)
            if not ok or type(parsed) ~= "table" then
              vim.notify(string.format("[%s] Failed to parse HCP Vault Secrets response", app_name), vim.log.levels.ERROR)
              completed_apps = completed_apps + 1
              return
            end

            local secrets = {}
            -- Handle both array and single object responses
            if vim.tbl_islist(parsed) then
              for _, secret in ipairs(parsed) do
                if secret.name then
                  table.insert(secrets, secret.name)
                end
              end
            else
              if parsed.name then
                table.insert(secrets, parsed.name)
              end
            end

            if #secrets == 0 then
              vim.notify(string.format("No secrets found in application %s", app_name), vim.log.levels.WARN)
              completed_apps = completed_apps + 1
              return
            end

            -- Store all secrets for this app
            self.state.app_secrets[app_name] = secrets
            completed_apps = completed_apps + 1

            -- If all apps have been processed, update config and load secrets
            if completed_apps >= #chosen_apps then
              if vim.tbl_count(self.state.app_secrets) > 0 then
                self.config = vim.tbl_extend("force", self.config or {}, {
                  apps = chosen_apps,
                  enabled = true,
                })

                self:load_secrets(self.config)
              else
                local current_env = ecolog.get_env_vars() or {}
                local final_vars = {}

                for key, value in pairs(current_env) do
                  if not (value.source and value.source:match("^vault:")) then
                    final_vars[key] = value
                  end
                end

                self.state.selected_secrets = {}
                self.state.loaded_secrets = {}
                self.state.app_secrets = {}
                self.state.initialized = false

                ecolog.refresh_env_vars()
                secret_utils.update_environment(final_vars, false, "vault:")
                vim.notify("All Vault secrets unloaded", vim.log.levels.INFO)
              end
            end
          end,
        })

        if job_id <= 0 then
          vim.notify(string.format("Failed to start HCP CLI command for app %s", app_name), vim.log.levels.ERROR)
          completed_apps = completed_apps + 1
        else
          secret_utils.track_job(job_id, self.state.active_jobs)
        end
      end

      -- Process each selected app
      for _, app_name in ipairs(chosen_apps) do
        process_app(app_name)
      end
    end, "vault:")
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

