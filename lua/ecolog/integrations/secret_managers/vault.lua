local api = vim.api
local ecolog = require("ecolog")
local secret_utils = require("ecolog.integrations.secret_managers.utils")
local BaseSecretManager = require("ecolog.integrations.secret_managers.base").BaseSecretManager

---Parse JSON response from Vault CLI
---@param stdout string Raw stdout from Vault CLI
---@param error_context string Context for error message
---@return table|nil parsed Parsed JSON data
---@return string|nil error Error message if parsing failed
local function parse_vault_response(stdout, error_context)
  local ok, parsed = pcall(vim.json.decode, stdout)
  if not ok or type(parsed) ~= "table" then
    return nil, string.format("[%s] Failed to parse HCP Vault Secrets response", error_context)
  end
  return parsed, nil
end

---@class VaultSecretsConfig : BaseSecretManagerConfig
---@field apps? string[] Optional list of enabled HCP Vault Secrets application names

---@class VaultError
---@field message string
---@field code string
---@field level number

local VAULT_TIMEOUT_MS = 300000

---@type table<string, VaultError>
local VAULT_ERRORS = {
  CONNECTION_ERROR = {
    message = "Could not connect to HCP Vault Secrets",
    code = "ConnectionError",
    level = vim.log.levels.ERROR,
  },
  ACCESS_DENIED = {
    message = "Access denied: Check your HCP permissions",
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
  NO_HCP_CLI = {
    message = "HCP CLI is not installed or not in PATH",
    code = "NoHcpCli",
    level = vim.log.levels.ERROR,
  },
  INVALID_RESPONSE = {
    message = "Invalid response format from HCP Vault Secrets",
    code = "InvalidResponse",
    level = vim.log.levels.ERROR,
  },
  JOB_START_ERROR = {
    message = "Failed to start HCP CLI command",
    code = "JobStartError",
    level = vim.log.levels.ERROR,
  },
  INVALID_CONFIG = {
    message = "Invalid HCP Vault Secrets configuration",
    code = "InvalidConfig",
    level = vim.log.levels.ERROR,
  },
  PARSE_ERROR = {
    message = "Failed to parse HCP Vault Secrets response",
    code = "ParseError",
    level = vim.log.levels.ERROR,
  },
}

---@class VaultSecretsState : SecretManagerState
---@field app_secrets table<string, string[]> Map of app names to their selected secret paths
---@field app_loaded_secrets table<string, table<string, any>> Map of app names to their loaded secrets

---@class VaultSecretsManager : BaseSecretManager
---@field state VaultSecretsState
---@field config VaultSecretsConfig
local VaultSecretsManager = setmetatable({}, { __index = BaseSecretManager })

---Create a job with common error handling and job tracking
---@param cmd string[] Command to execute
---@param state VaultSecretsState State object to track jobs
---@param on_success fun(stdout: string) Success callback
---@param on_error fun(err: VaultError) Error callback
---@return number job_id
function VaultSecretsManager:create_vault_job(cmd, state, on_success, on_error)
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
      secret_utils.untrack_job(job_id, state.active_jobs)
      local stdout = table.concat(stdout_chunks, "\n")
      local stderr = table.concat(stderr_chunks, "\n")

      if code ~= 0 then
        local err = self:process_error(stderr)
        on_error(err)
      else
        on_success(stdout)
      end
    end,
  })

  if job_id <= 0 then
    on_error({
      message = "Failed to start HCP CLI command",
      code = "JobStartError",
      level = vim.log.levels.ERROR,
    })
  else
    secret_utils.track_job(job_id, state.active_jobs)
  end

  return job_id
end

---Validate configuration
---@param config VaultSecretsConfig
---@return boolean is_valid
---@return string|nil error_message
local function validate_config(config)
  if not config then
    return false, "Configuration is required"
  end

  if config.apps then
    if type(config.apps) ~= "table" then
      return false, "Applications list must be a table"
    end

    for _, app in ipairs(config.apps) do
      if type(app) ~= "string" or app == "" then
        return false, "Application names must be non-empty strings"
      end
    end
  end

  return true
end

---Create initial state or reset existing state
---@param preserve_token? boolean Whether to preserve token validation state
---@return VaultSecretsState
function VaultSecretsManager:create_initial_state()
  return {
    selected_secrets = {},
    loaded_secrets = {},
    app_secrets = {},
    loading_lock = nil,
    active_jobs = {},
    pending_env_updates = {},
    app_loaded_secrets = {},
    is_refreshing = false,
  }
end

---Create a new VaultSecretsManager instance
---@return VaultSecretsManager
function VaultSecretsManager:new()
  local instance = BaseSecretManager.new(self, "vault:", "HashiCorp Vault")
  instance.state = self:create_initial_state()
  setmetatable(instance, { __index = self })
  return instance
end

---Process Vault error from stderr
---@param stderr string
---@param path? string
---@return VaultError
function VaultSecretsManager:process_error(stderr, path)
  local err
  if stderr:match("permission denied") or stderr:match("access denied") then
    err = VAULT_ERRORS.ACCESS_DENIED
  elseif stderr:match("connection refused") or stderr:match("connection error") then
    err = VAULT_ERRORS.CONNECTION_ERROR
  elseif stderr:match("not found") then
    err = VAULT_ERRORS.PATH_NOT_FOUND
  elseif stderr:match("invalid response") or stderr:match("invalid format") then
    err = VAULT_ERRORS.INVALID_RESPONSE
  elseif stderr:match("failed to parse") then
    err = VAULT_ERRORS.PARSE_ERROR
  else
    err = {
      message = stderr,
      code = "UnknownError",
      level = vim.log.levels.ERROR,
    }
  end

  if path then
    err = vim.deepcopy(err)
    err.message = string.format("%s: %s", path, err.message)
  end

  return err
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

  self:create_vault_job(cmd, self.state, function(stdout)
    local parsed, err = parse_vault_response(stdout, "list_secrets")
    if err then
      callback(nil, err)
      return
    end

    local secrets = {}
    for _, secret in ipairs(parsed.secrets or {}) do
      if secret.name then
        table.insert(secrets, secret.name)
      end
    end

    callback(secrets)
  end, function(err)
    callback(nil, err.message)
  end)
end

---List available apps in HCP Vault Secrets
---@param callback fun(apps: string[]|nil, err?: string)
function VaultSecretsManager:list_apps(callback)
  local cmd = {
    "hcp",
    "vault-secrets",
    "apps",
    "list",
    "--format=json",
  }

  self:create_vault_job(cmd, self.state, function(stdout)
    local parsed, err = parse_vault_response(stdout, "list_apps")
    if err then
      callback(nil, err)
      return
    end

    local apps = {}
    for _, app in ipairs(parsed) do
      if app.name then
        table.insert(apps, app.name)
      end
    end

    callback(apps)
  end, function(err)
    callback(nil, err.message)
  end)
end

---Extract secret names from Vault response
---@param parsed table The parsed JSON response
---@return string[] secrets List of secret names
local function extract_secret_names(parsed)
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
  return secrets
end

---Implementation specific loading of secrets
---@protected
---@param config VaultSecretsConfig
function VaultSecretsManager:_load_secrets_impl(config)
  if not self.state.loading_lock then
    self.state.loading_lock = {}
  end

  if not config.enabled then
    secret_utils.cleanup_state(self.state)
    return {}
  end

  local is_valid, error_message = validate_config(config)
  if not is_valid then
    local err = vim.deepcopy(VAULT_ERRORS.INVALID_CONFIG)
    err.message = error_message
    vim.notify(err.message, err.level)
    secret_utils.cleanup_state(self.state)
    return {}
  end

  if vim.fn.executable("hcp") ~= 1 then
    vim.notify(VAULT_ERRORS.NO_HCP_CLI.message, VAULT_ERRORS.NO_HCP_CLI.level)
    secret_utils.cleanup_state(self.state)
    return {}
  end

  self.state.app_loaded_secrets = self.state.app_loaded_secrets or {}

  if not config.apps or #config.apps == 0 then
    secret_utils.cleanup_state(self.state)
    return {}
  end

  return self:_load_secrets_with_apps(config)
end

---Load secrets with known apps list
---@protected
---@param config VaultSecretsConfig
---@return table loaded_secrets
function VaultSecretsManager:_load_secrets_with_apps(config)
  local current_apps = {}
  for _, app_name in ipairs(config.apps) do
    current_apps[app_name] = true
  end

  self.state.loaded_secrets = {}

  for app_name, _ in pairs(self.state.app_secrets or {}) do
    if not current_apps[app_name] then
      self.state.app_secrets[app_name] = nil
      if self.state.app_loaded_secrets then
        self.state.app_loaded_secrets[app_name] = nil
      end
    end
  end

  self.state.timeout_timer = vim.fn.timer_start(VAULT_TIMEOUT_MS, function()
    if self.state.loading_lock then
      vim.notify(VAULT_ERRORS.TIMEOUT.message, VAULT_ERRORS.TIMEOUT.level)
      secret_utils.cleanup_state(self.state)
    end
  end)

  local total_apps = #config.apps
  local completed_apps = 0
  local total_loaded = 0
  local total_failed = 0

  local function check_completion()
    if completed_apps >= total_apps then
      if total_loaded > 0 or total_failed > 0 then
        local msg = string.format("Vault: Loaded %d secret%s", total_loaded, total_loaded == 1 and "" or "s")
        if total_failed > 0 then
          msg = msg .. string.format(", %d failed", total_failed)
        end
        vim.notify(msg, total_failed > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
      end

      local updates_to_process = self.state.pending_env_updates
      self.state.pending_env_updates = {}
      secret_utils.update_environment(self.state.loaded_secrets, config.override, "vault:")
      for _, update_fn in ipairs(updates_to_process) do
        update_fn()
      end
      secret_utils.cleanup_state(self.state)
    end
  end

  local function process_app(app_name)
    local cmd = {
      "hcp",
      "vault-secrets",
      "secrets",
      "list",
      "--app",
      app_name,
      "--format=json",
    }

    self:create_vault_job(cmd, self.state, function(stdout)
      local parsed, err = parse_vault_response(stdout, app_name)
      if err then
        vim.notify(err, vim.log.levels.ERROR)
        completed_apps = completed_apps + 1
        check_completion()
        return
      end

      local secrets = extract_secret_names(parsed)
      if #secrets == 0 then
        completed_apps = completed_apps + 1
        check_completion()
        return
      end

      self.state.app_secrets[app_name] = secrets
      self:process_app_secrets(app_name, secrets, function(loaded, failed)
        total_loaded = total_loaded + (loaded or 0)
        total_failed = total_failed + (failed or 0)
        completed_apps = completed_apps + 1
        check_completion()
      end)
    end, function(err)
      vim.notify(string.format("[%s] %s", app_name, err.message), err.level)
      completed_apps = completed_apps + 1
      check_completion()
    end)
  end

  if #config.apps > 0 then
    vim.notify("Vault: loading secrets...", vim.log.levels.INFO)
  end

  for _, app_name in ipairs(config.apps) do
    process_app(app_name)
  end

  return self.state.loaded_secrets
end

---Handle retrying a secret fetch on connection error
---@param retry_counts table<number, number>
---@param index number
---@param secret_path string
---@param app_name string
---@param callback fun()
---@return boolean should_retry
local function handle_secret_retry(retry_counts, index, secret_path, app_name, callback)
  retry_counts[index] = (retry_counts[index] or 0) + 1
  if retry_counts[index] <= secret_utils.MAX_RETRIES then
    vim.notify(
      string.format(
        "Retrying secret %s from %s (attempt %d/%d)",
        secret_path,
        app_name,
        retry_counts[index],
        secret_utils.MAX_RETRIES
      ),
      vim.log.levels.INFO
    )
    vim.defer_fn(callback, 1000 * retry_counts[index])
    return true
  end
  return false
end

---Process app secrets sequentially
---@param app_name string
---@param secrets string[]
---@param on_complete fun(loaded: number, failed: number)
function VaultSecretsManager:process_app_secrets(app_name, secrets, on_complete)
  local total_secrets = #secrets
  local completed_jobs = 0
  local current_index = 1
  local loaded_secrets = 0
  local failed_secrets = 0
  local retry_counts = {}

  self.state.app_loaded_secrets[app_name] = {}

  local function check_completion()
    if completed_jobs >= total_secrets then
      on_complete(loaded_secrets, failed_secrets)
    end
  end

  local function process_next_secret()
    if current_index > total_secrets or not self.state.loading_lock then
      return
    end

    local secret_path = secrets[current_index]
    local job_id = self:create_secret_job({ app = app_name, path = secret_path }, function(value)
      local loaded, failed = secret_utils.process_secret_value(value, {
        source_prefix = string.format("vault:%s/", app_name),
        source_path = secret_path,
      }, self.state.app_loaded_secrets[app_name])

      if loaded > 0 then
        for key, secret in pairs(self.state.app_loaded_secrets[app_name]) do
          self.state.loaded_secrets[key] = secret
        end
      end

      loaded_secrets = loaded_secrets + (loaded or 0)
      failed_secrets = failed_secrets + (failed or 0)
      completed_jobs = completed_jobs + 1

      current_index = current_index + 1
      check_completion()

      if current_index <= total_secrets then
        process_next_secret()
      end
    end, function(err)
      if
        err.code == "ConnectionError"
        and handle_secret_retry(retry_counts, current_index, secret_path, app_name, process_next_secret)
      then
        return
      end

      failed_secrets = failed_secrets + 1
      vim.notify(string.format("[%s] %s", app_name, err.message), err.level)
      completed_jobs = completed_jobs + 1

      current_index = current_index + 1
      check_completion()

      if current_index <= total_secrets then
        process_next_secret()
      end
    end)

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

  if total_secrets > 0 then
    process_next_secret()
  else
    on_complete(0, 0)
  end
end

---Handle selection of apps and update configuration
---@param selected_apps table<string, boolean>
---@param callback fun()
function VaultSecretsManager:handle_app_selection(selected_apps, callback)
  local chosen_apps = {}
  for app, is_selected in pairs(selected_apps) do
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

    self.state = self:create_initial_state()
    ecolog.refresh_env_vars()
    secret_utils.update_environment(final_vars, false, "vault:")
    vim.notify("All Vault secrets unloaded", vim.log.levels.INFO)
    return
  end

  self.state = self:create_initial_state()
  self.config = vim.tbl_extend("force", self.config or {}, {
    apps = chosen_apps,
    enabled = true,
  })

  callback()
end

---Implementation specific selection of secrets
---@protected
function VaultSecretsManager:_select_impl()
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

    local selected_apps = {}
    if self.state.app_secrets then
      for app_name, _ in pairs(self.state.app_secrets) do
        selected_apps[app_name] = true
      end
    end

    secret_utils.create_secret_selection_ui(apps, selected_apps, function(new_selected_apps)
      self:handle_app_selection(new_selected_apps, function()
        self:load_secrets(self.config)
      end)
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

---Get available configuration options for Vault
---@protected
---@return table<string, { name: string, current: string|nil, options: string[]|nil, type: "multi-select"|"single-select"|"input" }>
function VaultSecretsManager:_get_config_options()
  local options = {}

  local cmd = { "hcp", "organizations", "list", "--format=json" }
  local output = vim.fn.system(cmd)
  if vim.v.shell_error == 0 and output ~= "" then
    local ok, parsed = pcall(vim.json.decode, output)
    if ok and parsed then
      local orgs = {}
      local current_org = vim.env.HCP_ORGANIZATION

      if not current_org then
        for _, org in ipairs(parsed) do
          if org.state == "ACTIVE" then
            current_org = org.name
            break
          end
        end
      end

      for _, org in ipairs(parsed) do
        if org.name then
          table.insert(orgs, org.name)
        end
      end
      if #orgs > 0 then
        options.organization = {
          name = "HCP Organization",
          current = current_org,
          type = "single-select",
          options = orgs,
        }
      end
    end
  end

  local cmd_projects = { "hcp", "projects", "list", "--format=json" }
  local output_projects = vim.fn.system(cmd_projects)
  if vim.v.shell_error == 0 and output_projects ~= "" then
    local ok, parsed = pcall(vim.json.decode, output_projects)
    if ok and parsed then
      local projects = {}
      local current_project = vim.env.HCP_PROJECT

      if not current_project then
        for _, proj in ipairs(parsed) do
          if proj.state == "ACTIVE" then
            current_project = proj.name
            break
          end
        end
      end

      for _, proj in ipairs(parsed) do
        if proj.name then
          table.insert(projects, proj.name)
        end
      end
      if #projects > 0 then
        options.project = {
          name = "HCP Project",
          current = current_project,
          type = "single-select",
          options = projects,
        }
      end
    end
  end

  -- Add apps selection option
  options.apps = {
    name = "Vault Applications",
    current = self.config and self.config.apps and #self.config.apps > 0 and table.concat(vim.tbl_filter(function(app)
      return type(app) == "string" and app ~= ""
    end, self.config.apps), ", ") or "none",
    type = "multi-select",
    options = {},
    dynamic_options = function(callback)
      self:list_apps(function(apps, err)
        if err then
          vim.notify(err, vim.log.levels.ERROR)
          callback({})
          return
        end
        -- Filter out any empty strings from the apps list
        local filtered_apps = vim.tbl_filter(function(app)
          return type(app) == "string" and app ~= ""
        end, apps or {})
        callback(filtered_apps)
      end)
    end
  }

  return options
end

---Handle configuration change for Vault
---@protected
---@param option string The configuration option being changed
---@param value any The new value
function VaultSecretsManager:_handle_config_change(option, value)
  if not self.config then
    self.config = { enabled = true }
  end

  if option == "organization" then
    if vim.env.HCP_ORGANIZATION ~= value then
      vim.env.HCP_ORGANIZATION = value
      self.state.selected_secrets = {}
      self.state.loaded_secrets = {}
      self.state.initialized = false

      -- Clear apps from config
      self.config.apps = nil

      local current_env = ecolog.get_env_vars() or {}
      local final_vars = {}
      for key, value in pairs(current_env) do
        if not (value.source and value.source:match("^" .. self.source_prefix)) then
          final_vars[key] = value
        end
      end
      secret_utils.update_environment(final_vars, false, self.source_prefix)
      vim.notify("Vault secrets unloaded due to organization change", vim.log.levels.INFO)
    end
  elseif option == "project" then
    if vim.env.HCP_PROJECT ~= value then
      vim.env.HCP_PROJECT = value
      self.state.selected_secrets = {}
      self.state.loaded_secrets = {}
      self.state.initialized = false

      -- Clear apps from config
      self.config.apps = nil

      local current_env = ecolog.get_env_vars() or {}
      local final_vars = {}
      for key, value in pairs(current_env) do
        if not (value.source and value.source:match("^" .. self.source_prefix)) then
          final_vars[key] = value
        end
      end
      secret_utils.update_environment(final_vars, false, self.source_prefix)
      vim.notify("Vault secrets unloaded due to project change", vim.log.levels.INFO)
    end
  elseif option == "apps" then
    local selected_apps = {}
    for app_name, is_selected in pairs(value) do
      if is_selected and type(app_name) == "string" and app_name ~= "" then
        table.insert(selected_apps, app_name)
      end
    end

    if #selected_apps == 0 then
      local current_env = ecolog.get_env_vars() or {}
      local final_vars = {}

      for key, value in pairs(current_env) do
        if not (value.source and value.source:match("^vault:")) then
          final_vars[key] = value
        end
      end

      self.state = self:create_initial_state()
      
      -- Clear apps from config
      self.config.apps = nil
      
      ecolog.refresh_env_vars()
      secret_utils.update_environment(final_vars, false, "vault:")
      vim.notify("All Vault secrets unloaded", vim.log.levels.INFO)
      return
    end

    self.state = self:create_initial_state()
    self.config = vim.tbl_extend("force", self.config or {}, {
      apps = selected_apps,
      enabled = true,
    })

    self:load_secrets(self.config)
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

  return self:create_vault_job(cmd, self.state, function(stdout)
    local parsed, err = parse_vault_response(stdout, secret.path)
    if err then
      on_error({
        message = err,
        code = "InvalidResponse",
        level = vim.log.levels.ERROR,
      })
      return
    end

    if parsed and parsed.static_version and parsed.static_version.value then
      on_success(parsed.static_version.value)
    else
      on_error({
        message = string.format("Invalid response format for secret %s", secret.path),
        code = "InvalidResponse",
        level = vim.log.levels.ERROR,
      })
    end
  end, function(err)
    on_error(err)
  end)
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
  select_config = function(direct_option)
    return instance:select_config(direct_option)
  end,
  instance = instance,  -- Export the instance directly
}
