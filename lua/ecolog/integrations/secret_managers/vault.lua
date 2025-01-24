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

---Create a job to fetch a secret
---@param secret { app: string, path: string }
---@param on_success fun(value: string)
---@param on_error fun(err: VaultError)
---@return number job_id
function VaultSecretsManager:create_secret_job(secret, on_success, on_error)
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
      local stdout = table.concat(stdout_chunks, "\n")
      local stderr = table.concat(stderr_chunks, "\n")

      if code ~= 0 then
        local err = self:process_error(stderr, secret.path)
        on_error(err)
      else
        local ok, response = pcall(vim.json.decode, stdout)
        if ok and response and response.static_version and response.static_version.value then
          on_success(response.static_version.value)
        else
          on_error({
            message = string.format("Invalid response format for secret %s", secret.path),
            code = "InvalidResponse",
            level = vim.log.levels.ERROR,
          })
        end
      end
    end,
  })

  if job_id > 0 then
    secret_utils.track_job(job_id, self.state.active_jobs)
  end

  return job_id
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
  -- Set loading lock if not already set
  if not self.state.loading_lock then
    self.state.loading_lock = {}
  end

  if not config.apps or #config.apps == 0 then
    secret_utils.cleanup_state(self.state)
    return {}
  end

  if vim.fn.executable("hcp") ~= 1 then
    vim.notify(VAULT_ERRORS.NO_HCP_CLI.message, VAULT_ERRORS.NO_HCP_CLI.level)
    secret_utils.cleanup_state(self.state)
    return {}
  end

  -- Debug: Show current state
  vim.notify(string.format("Debug: is_refreshing=%s", tostring(self.state.is_refreshing)), vim.log.levels.DEBUG)

  -- Initialize per-app secrets tracking if not exists
  self.state.app_loaded_secrets = self.state.app_loaded_secrets or {}

  -- Debug: Show existing secrets count
  local existing_count = vim.tbl_count(self.state.loaded_secrets or {})
  vim.notify(string.format("Debug: Existing secrets count: %d", existing_count), vim.log.levels.DEBUG)

  -- Create a set of current apps for faster lookup
  local current_apps = {}
  for _, app_name in ipairs(config.apps) do
    current_apps[app_name] = true
  end

  -- Keep existing secrets if we're not refreshing
  if not self.state.is_refreshing then
    -- Only remove secrets from deselected apps
    local secrets_to_keep = {}
    for key, value in pairs(self.state.loaded_secrets or {}) do
      local app_name = value.source:match("^vault:([^/]+)/")
      if app_name and current_apps[app_name] then
        secrets_to_keep[key] = value
      else
        vim.notify(string.format("Debug: Removing secret %s from app %s", key, app_name or "unknown"), vim.log.levels.DEBUG)
      end
    end
    self.state.loaded_secrets = secrets_to_keep
  else
    -- Reset secrets if we're refreshing
    self.state.loaded_secrets = {}
  end

  -- Clean up app_secrets for removed apps
  for app_name, _ in pairs(self.state.app_secrets or {}) do
    if not current_apps[app_name] then
      vim.notify(string.format("Debug: Removing app %s and its secrets", app_name), vim.log.levels.DEBUG)
      self.state.app_secrets[app_name] = nil
      if self.state.app_loaded_secrets then
        self.state.app_loaded_secrets[app_name] = nil
      end
    end
  end

  -- Collect all paths from remaining apps
  local all_paths = {}
  for _, app_name in ipairs(config.apps) do
    local paths = self.state.app_secrets[app_name] or {}
    vim.notify(string.format("Debug: App %s has %d paths", app_name, #paths), vim.log.levels.DEBUG)
    for _, path in ipairs(paths) do
      table.insert(all_paths, { app = app_name, path = path })
    end
  end

  vim.notify(string.format("Debug: Total paths to process: %d", #all_paths), vim.log.levels.DEBUG)
  self.state.selected_secrets = all_paths

  vim.notify("Loading HCP Vault secrets...", vim.log.levels.INFO)

  self.state.timeout_timer = vim.fn.timer_start(VAULT_TIMEOUT_MS, function()
    if self.state.loading_lock then
      vim.notify(VAULT_ERRORS.TIMEOUT.message, VAULT_ERRORS.TIMEOUT.level)
      secret_utils.cleanup_state(self.state)
    end
  end)

  local total_apps = #config.apps
  local completed_apps = 0

  local function check_completion()
    if completed_apps >= total_apps then
      -- Debug: Show final secrets count
      local final_count = vim.tbl_count(self.state.loaded_secrets or {})
      vim.notify(string.format("Debug: Final secrets count: %d", final_count), vim.log.levels.DEBUG)

      -- Show which apps are still loaded
      local remaining_apps = {}
      for key, value in pairs(self.state.loaded_secrets or {}) do
        local app_name = value.source:match("^vault:([^/]+)/")
        if app_name then
          remaining_apps[app_name] = true
        end
      end
      vim.notify("Debug: Remaining apps with secrets: " .. vim.inspect(vim.tbl_keys(remaining_apps)), vim.log.levels.DEBUG)

      local updates_to_process = self.state.pending_env_updates
      self.state.pending_env_updates = {}
      secret_utils.update_environment(self.state.loaded_secrets, config.override, "vault:")
      for _, update_fn in ipairs(updates_to_process) do
        update_fn()
      end
      secret_utils.cleanup_state(self.state)
    end
  end

  for _, app_name in ipairs(config.apps) do
    local paths = self.state.app_secrets[app_name] or {}
    vim.notify(string.format("Debug: Processing app %s with %d paths", app_name, #paths), vim.log.levels.DEBUG)
    if #paths > 0 then
      self:process_app_secrets(app_name, paths, function()
        completed_apps = completed_apps + 1
        vim.notify(string.format("Debug: Completed app %s (%d/%d)", app_name, completed_apps, total_apps), vim.log.levels.DEBUG)
        check_completion()
      end)
    else
      completed_apps = completed_apps + 1
      vim.notify(string.format("Debug: Skipped app %s (%d/%d) - no paths", app_name, completed_apps, total_apps), vim.log.levels.DEBUG)
      check_completion()
    end
  end

  return self.state.loaded_secrets
end

---Process app secrets sequentially
---@param app_name string
---@param secrets string[]
---@param on_complete fun()
function VaultSecretsManager:process_app_secrets(app_name, secrets, on_complete)
  local total_secrets = #secrets
  local completed_jobs = 0
  local current_index = 1
  local loaded_secrets = 0
  local failed_secrets = 0
  local retry_counts = {}

  -- Initialize app-specific secrets storage
  self.state.app_loaded_secrets[app_name] = {}

  vim.notify(string.format("Debug: Starting to process %d secrets for app %s", total_secrets, app_name), vim.log.levels.DEBUG)

  local function check_completion()
    if completed_jobs >= total_secrets then
      vim.notify(string.format("Debug: App %s completed - loaded: %d, failed: %d", 
        app_name, loaded_secrets, failed_secrets), vim.log.levels.DEBUG)
      if loaded_secrets > 0 or failed_secrets > 0 then
        local msg = string.format("[%s] Loaded %d secret%s", 
          app_name,
          loaded_secrets, 
          loaded_secrets == 1 and "" or "s"
        )
        if failed_secrets > 0 then
          msg = msg .. string.format(", %d failed", failed_secrets)
        end
        vim.notify(msg, failed_secrets > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
      end
      on_complete()
    end
  end

  local function process_next_secret()
    if current_index > total_secrets or not self.state.loading_lock then
      return
    end

    local secret_path = secrets[current_index]
    vim.notify(string.format("Debug: Processing secret %d/%d: %s for app %s", 
      current_index, total_secrets, secret_path, app_name), vim.log.levels.DEBUG)

    local job_id = self:create_secret_job(
      { app = app_name, path = secret_path },
      function(value)
        local loaded, failed = self:process_secret_value(
          value,
          string.format("%s/%s", app_name, secret_path),
          self.state.loaded_secrets
        )
        loaded_secrets = loaded_secrets + (loaded or 0)
        failed_secrets = failed_secrets + (failed or 0)
        completed_jobs = completed_jobs + 1
        
        vim.notify(string.format("Debug: Secret %s completed successfully", secret_path), vim.log.levels.DEBUG)
        
        -- Move to next secret after this one completes
        current_index = current_index + 1
        check_completion()
        
        if current_index <= total_secrets then
          process_next_secret()
        end
      end,
      function(err)
        retry_counts[current_index] = (retry_counts[current_index] or 0) + 1
        if
          retry_counts[current_index] <= secret_utils.MAX_RETRIES
          and err.code == "ConnectionError"
        then
          vim.notify(string.format("Retrying secret %s from %s (attempt %d/%d)", 
            secret_path, app_name, retry_counts[current_index], secret_utils.MAX_RETRIES), 
            vim.log.levels.INFO)
          vim.defer_fn(function()
            process_next_secret()
          end, 1000 * retry_counts[current_index])
          return
        end

        failed_secrets = failed_secrets + 1
        vim.notify(string.format("[%s] %s", app_name, err.message), err.level)
        completed_jobs = completed_jobs + 1
        
        -- Move to next secret after this one fails
        current_index = current_index + 1
        check_completion()
        
        if current_index <= total_secrets then
          process_next_secret()
        end
      end
    )

    if job_id <= 0 then
      failed_secrets = failed_secrets + 1
      completed_jobs = completed_jobs + 1
      current_index = current_index + 1
      check_completion()
      
      if current_index <= total_secrets then
        process_next_secret()
      end
    end
  end

  -- Start processing the first secret
  if total_secrets > 0 then
    process_next_secret()
  else
    on_complete()
  end
end

---Implementation specific selection of secrets
---@protected
function VaultSecretsManager:_select_impl()
  -- Reset loading lock to allow new selections
  self.state.loading_lock = nil

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
    -- Initialize with currently loaded apps
    if self.state.app_secrets then
      for app_name, _ in pairs(self.state.app_secrets) do
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

      vim.notify("Debug: Newly chosen apps: " .. vim.inspect(chosen_apps), vim.log.levels.DEBUG)

      if #chosen_apps == 0 then
        -- Clear all state and environment
        local current_env = ecolog.get_env_vars() or {}
        local final_vars = {}

        for key, value in pairs(current_env) do
          if not (value.source and value.source:match("^vault:")) then
            final_vars[key] = value
          end
        end

        self.state = {
          selected_secrets = {},
          loaded_secrets = {},
          app_secrets = {},
          loading_lock = nil,
          active_jobs = {},
          pending_env_updates = {},
          app_loaded_secrets = {},
          is_refreshing = false
        }

        ecolog.refresh_env_vars()
        secret_utils.update_environment(final_vars, false, "vault:")
        vim.notify("All Vault secrets unloaded", vim.log.levels.INFO)
        return
      end

      -- Reset state for clean reload
      self.state = {
        selected_secrets = {},
        loaded_secrets = {},
        app_secrets = {},
        loading_lock = nil,
        active_jobs = {},
        pending_env_updates = {},
        app_loaded_secrets = {},
        is_refreshing = false
      }

      -- Update config with chosen apps
      self.config = vim.tbl_extend("force", self.config or {}, {
        apps = chosen_apps,
        enabled = true,
      })

      -- Process all chosen apps
      local completed_apps = 0
      local total_apps = #chosen_apps

      local function check_completion()
        if completed_apps >= total_apps then
          -- Load all secrets with fresh state
          self:load_secrets(self.config)
        end
      end

      local function process_app(app_name)
        vim.notify(string.format("Listing secrets for app: %s", app_name), vim.log.levels.INFO)
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
              check_completion()
              return
            end

            local ok, parsed = pcall(vim.json.decode, stdout)
            if not ok or type(parsed) ~= "table" then
              vim.notify(string.format("[%s] Failed to parse HCP Vault Secrets response", app_name), vim.log.levels.ERROR)
              completed_apps = completed_apps + 1
              check_completion()
              return
            end

            local secrets = {}
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
              check_completion()
              return
            end

            -- Store secrets for this app
            self.state.app_secrets[app_name] = secrets
            completed_apps = completed_apps + 1
            check_completion()
          end,
        })

        if job_id <= 0 then
          vim.notify(string.format("Failed to start HCP CLI command for app %s", app_name), vim.log.levels.ERROR)
          completed_apps = completed_apps + 1
          check_completion()
        else
          secret_utils.track_job(job_id, self.state.active_jobs)
        end
      end

      -- Process all chosen apps
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

