local M = {}

local api = vim.api
local utils = require("ecolog.utils")
local ecolog = require("ecolog")
local secret_utils = require("ecolog.integrations.secret_managers.utils")

---@class AwsSecretsState
---@field selected_secrets string[] List of currently selected AWS secret names
---@field config LoadAwsSecretsConfig|nil
---@field loading boolean
---@field loaded_secrets table<string, table>
---@field active_jobs table<number, boolean>
---@field is_refreshing boolean
---@field skip_load boolean
---@field credentials_valid boolean
---@field last_credentials_check number
---@field loading_lock table|nil
---@field timeout_timer number|nil
---@field initialized boolean
---@field pending_env_updates function[]

---@class AwsError
---@field message string
---@field code string
---@field level number

---@class LoadAwsSecretsConfig
---@field enabled boolean Enable loading AWS Secrets Manager secrets into environment
---@field override boolean When true, AWS secrets take precedence over .env files and shell variables
---@field region string AWS region to use
---@field profile? string Optional AWS profile to use
---@field secrets string[] List of secret names to fetch
---@field filter? fun(key: string, value: any): boolean Optional function to filter which secrets to load
---@field transform? fun(key: string, value: any): any Optional function to transform secret values

local AWS_TIMEOUT_MS = 300000
local AWS_CREDENTIALS_CACHE_SEC = 300
local AWS_MAX_RETRIES = 3
local MAX_PARALLEL_REQUESTS = 5
local REQUEST_DELAY_MS = 100

---@type table<string, AwsError>
local AWS_ERRORS = {
  INVALID_CREDENTIALS = {
    message = "AWS credentials are not properly configured. Please check your AWS credentials:\n"
      .. "1. Ensure AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY are set correctly\n"
      .. "2. Or verify ~/.aws/credentials contains valid credentials\n"
      .. "3. If using a profile, confirm it exists and is properly configured",
    code = "InvalidCredentials",
    level = vim.log.levels.ERROR,
  },
  NO_CREDENTIALS = {
    message = "No AWS credentials found. Please configure your AWS credentials",
    code = "NoCredentials",
    level = vim.log.levels.ERROR,
  },
  CONNECTION_ERROR = {
    message = "Could not connect to AWS",
    code = "ConnectionError",
    level = vim.log.levels.ERROR,
  },
  ACCESS_DENIED = {
    message = "Access denied: Check your AWS credentials",
    code = "AccessDenied",
    level = vim.log.levels.ERROR,
  },
  RESOURCE_NOT_FOUND = {
    message = "Secret not found",
    code = "ResourceNotFound",
    level = vim.log.levels.ERROR,
  },
  TIMEOUT = {
    message = "AWS Secrets Manager loading timed out after 5 minutes",
    code = "Timeout",
    level = vim.log.levels.ERROR,
  },
  NO_REGION = {
    message = "AWS region is required for AWS Secrets Manager integration",
    code = "NoRegion",
    level = vim.log.levels.ERROR,
  },
  NO_SECRETS = {
    message = "No secrets specified for AWS Secrets Manager integration",
    code = "NoSecrets",
    level = vim.log.levels.ERROR,
  },
  NO_AWS_CLI = {
    message = "AWS CLI is not installed or not in PATH",
    code = "NoAwsCli",
    level = vim.log.levels.ERROR,
  },
  NOT_CONFIGURED = {
    message = "AWS Secrets Manager is not configured. Enable it in your setup first.",
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
  credentials_valid = false,
  last_credentials_check = 0,
  loading_lock = nil,
  timeout_timer = nil,
  initialized = false,
  pending_env_updates = {},
}

---Process AWS error from stderr
---@param stderr string
---@param secret_name? string
---@return AwsError
local function process_aws_error(stderr, secret_name)
  if stderr:match("InvalidSignatureException") or stderr:match("credentials") then
    return AWS_ERRORS.INVALID_CREDENTIALS
  elseif stderr:match("Unable to locate credentials") then
    return AWS_ERRORS.NO_CREDENTIALS
  elseif stderr:match("Could not connect to the endpoint URL") then
    local err = vim.deepcopy(AWS_ERRORS.CONNECTION_ERROR)
    if secret_name then
      err.message = string.format("AWS connectivity error for secret %s: %s", secret_name, err.message)
    end
    return err
  elseif stderr:match("AccessDenied") then
    local err = vim.deepcopy(AWS_ERRORS.ACCESS_DENIED)
    if secret_name then
      err.message = string.format("Access denied for secret %s: %s", secret_name, err.message)
    end
    return err
  elseif stderr:match("ResourceNotFound") then
    local err = vim.deepcopy(AWS_ERRORS.RESOURCE_NOT_FOUND)
    if secret_name then
      err.message = string.format("Secret not found: %s", secret_name)
    end
    return err
  end

  return {
    message = secret_name and string.format("Error fetching secret %s: %s", secret_name, stderr) or stderr,
    code = "UnknownError",
    level = vim.log.levels.ERROR,
  }
end

---Process a secret value and add it to aws_secrets
---@param secret_value string
---@param secret_name string
---@param aws_config LoadAwsSecretsConfig
---@param aws_secrets table<string, table>
---@return number loaded Number of secrets loaded
---@return number failed Number of secrets that failed to load
local function process_secret_value(secret_value, secret_name, aws_config, aws_secrets)
  local loaded, failed = 0, 0

  if secret_value == "" then
    return loaded, failed
  end

  if secret_value:match("^{") then
    local ok, parsed_secret = pcall(vim.json.decode, secret_value)
    if ok and type(parsed_secret) == "table" then
      for key, value in pairs(parsed_secret) do
        if not aws_config.filter or aws_config.filter(key, value) then
          local transformed_value = value
          if aws_config.transform then
            local transform_ok, result = pcall(aws_config.transform, key, value)
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
          aws_secrets[key] = {
            value = detected_value or transformed_value,
            type = type_name,
            raw_value = value,
            source = "asm:" .. secret_name,
            comment = nil,
          }
          loaded = loaded + 1
        end
      end
    else
      vim.notify(string.format("Failed to parse JSON secret from %s", secret_name), vim.log.levels.WARN)
      failed = failed + 1
    end
  else
    local key = secret_name:match("[^/]+$")
    if not aws_config.filter or aws_config.filter(key, secret_value) then
      local transformed_value = secret_value
      if aws_config.transform then
        local transform_ok, result = pcall(aws_config.transform, key, secret_value)
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
      aws_secrets[key] = {
        value = detected_value or transformed_value,
        type = type_name,
        raw_value = secret_value,
        source = "asm:" .. secret_name,
        comment = nil,
      }
      loaded = loaded + 1
    end
  end

  return loaded, failed
end

---Check AWS credentials
---@param callback fun(ok: boolean, err?: string)
local function check_aws_credentials(callback)
  local now = os.time()
  if state.credentials_valid and (now - state.last_credentials_check) < AWS_CREDENTIALS_CACHE_SEC then
    callback(true)
    return
  end

  local cmd = { "aws", "sts", "get-caller-identity", "--query", "Account", "--output", "text" }

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
      secret_utils.untrack_job(job_id, state.active_jobs)
      if code ~= 0 then
        state.credentials_valid = false
        local err = process_aws_error(stderr)
        callback(false, err.message)
        return
      end

      stdout = stdout:gsub("^%s*(.-)%s*$", "%1")

      if stdout:match("^%d+$") then
        state.credentials_valid = true
        state.last_credentials_check = now
        callback(true)
      else
        state.credentials_valid = false
        callback(false, "AWS credentials validation failed: " .. stdout)
      end
    end,
  })

  if job_id <= 0 then
    callback(false, "Failed to start AWS CLI command")
  else
    secret_utils.track_job(job_id, state.active_jobs)
  end
end

---Process secrets in parallel batches
---@param aws_config LoadAwsSecretsConfig
---@param aws_secrets table<string, table>
---@param loaded_secrets number
---@param failed_secrets number
local function process_secrets_parallel(aws_config, aws_secrets, loaded_secrets, failed_secrets)
  if not state.loading_lock then
    return
  end

  local total_secrets = #aws_config.secrets
  local active_jobs = 0
  local completed_jobs = 0
  local current_index = 1
  local retry_counts = {}

  local function check_completion()
    if completed_jobs >= total_secrets then
      if loaded_secrets > 0 or failed_secrets > 0 then
        local msg = string.format("AWS Secrets Manager: Loaded %d secret%s", loaded_secrets, loaded_secrets == 1 and "" or "s")
        if failed_secrets > 0 then
          msg = msg .. string.format(", %d failed", failed_secrets)
        end
        vim.notify(msg, failed_secrets > 0 and vim.log.levels.WARN or vim.log.levels.INFO)

        state.loaded_secrets = aws_secrets
        state.initialized = true

        local updates_to_process = state.pending_env_updates
        state.pending_env_updates = {}

        secret_utils.update_environment(aws_secrets, aws_config.override, "asm:")

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

    local cmd = {
      "aws",
      "secretsmanager",
      "get-secret-value",
      "--query",
      "SecretString",
      "--output",
      "text",
      "--secret-id",
      aws_config.secrets[index],
      "--region",
      aws_config.region,
    }

    if aws_config.profile then
      table.insert(cmd, "--profile")
      table.insert(cmd, aws_config.profile)
    end

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
        vim.schedule(function()
          if not state.loading_lock then
            return
          end

          active_jobs = active_jobs - 1
          local stdout = table.concat(stdout_chunks, "\n")
          local stderr = table.concat(stderr_chunks, "\n")

          if code ~= 0 then
            retry_counts[index] = (retry_counts[index] or 0) + 1
            if retry_counts[index] <= AWS_MAX_RETRIES and (
              stderr:match("Could not connect to the endpoint URL")
              or stderr:match("ThrottlingException")
              or stderr:match("RequestTimeout")
            ) then
              vim.defer_fn(function()
                start_job(index)
              end, 1000 * retry_counts[index])
              return
            end

            failed_secrets = failed_secrets + 1
            local err = process_aws_error(stderr, aws_config.secrets[index])
            vim.notify(err.message, err.level)
          else
            local secret_value = stdout:gsub("^%s*(.-)%s*$", "%1")
            if secret_value ~= "" then
              local loaded, failed = process_secret_value(secret_value, aws_config.secrets[index], aws_config, aws_secrets)
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
          string.format("Failed to start AWS CLI command for secret %s", aws_config.secrets[index]),
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

---Load AWS secrets
---@param config boolean|LoadAwsSecretsConfig
---@return table<string, table>
function M.load_aws_secrets(config)
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
  local aws_config = type(config) == "table" and config or { enabled = config, override = false }

  if not aws_config.enabled then
    local current_env = ecolog.get_env_vars() or {}
    local final_vars = {}

    for key, value in pairs(current_env) do
      if not (value.source and value.source:match("^asm:")) then
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

  if not aws_config.region then
    vim.notify(AWS_ERRORS.NO_REGION.message, AWS_ERRORS.NO_REGION.level)
    secret_utils.cleanup_state(state)
    return {}
  end

  if not aws_config.secrets or #aws_config.secrets == 0 then
    if not state.is_refreshing then
      secret_utils.cleanup_state(state)
      return {}
    end
    vim.notify(AWS_ERRORS.NO_SECRETS.message, AWS_ERRORS.NO_SECRETS.level)
    secret_utils.cleanup_state(state)
    return {}
  end

  if vim.fn.executable("aws") ~= 1 then
    vim.notify(AWS_ERRORS.NO_AWS_CLI.message, AWS_ERRORS.NO_AWS_CLI.level)
    secret_utils.cleanup_state(state)
    return {}
  end

  state.selected_secrets = vim.deepcopy(aws_config.secrets)

  local aws_secrets = {}
  vim.notify("Loading AWS secrets...", vim.log.levels.INFO)

  state.timeout_timer = vim.fn.timer_start(AWS_TIMEOUT_MS, function()
    if state.loading_lock then
      vim.notify(AWS_ERRORS.TIMEOUT.message, AWS_ERRORS.TIMEOUT.level)
      secret_utils.cleanup_state(state)
    end
  end)

  check_aws_credentials(function(ok, err)
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

    process_secrets_parallel(aws_config, aws_secrets, 0, 0)
  end)

  return state.loaded_secrets or {}
end

---List available secrets in AWS Secrets Manager
---@param aws_config LoadAwsSecretsConfig
---@param callback fun(secrets: string[]|nil, err?: string)
local function list_secrets(aws_config, callback)
  local cmd = {
    "aws",
    "secretsmanager",
    "list-secrets",
    "--query",
    "SecretList[].Name",
    "--output",
    "text",
    "--region",
    aws_config.region,
  }

  if aws_config.profile then
    table.insert(cmd, "--profile")
    table.insert(cmd, aws_config.profile)
  end

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
      secret_utils.untrack_job(job_id, state.active_jobs)
      if code ~= 0 then
        local err = process_aws_error(stderr)
        callback(nil, err.message)
        return
      end

      local secrets = {}
      for secret in stdout:gmatch("%S+") do
        if secret ~= "" then
          table.insert(secrets, secret)
        end
      end

      callback(secrets)
    end,
  })

  if job_id <= 0 then
    callback(nil, "Failed to start AWS CLI command")
  else
    secret_utils.track_job(job_id, state.active_jobs)
  end
end

function M.select()
  if not state.config then
    vim.notify(AWS_ERRORS.NOT_CONFIGURED.message, AWS_ERRORS.NOT_CONFIGURED.level)
    return
  end

  if not state.config.region then
    vim.notify(AWS_ERRORS.NO_REGION.message, AWS_ERRORS.NO_REGION.level)
    return
  end

  check_aws_credentials(function(ok, err)
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
        vim.notify("No secrets found in AWS Secrets Manager", vim.log.levels.WARN)
        return
      end

      local selected = {}
      for _, secret_name in ipairs(state.selected_secrets) do
        selected[secret_name] = true
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
            if not (value.source and value.source:match("^asm:")) then
              final_vars[key] = value
            end
          end

          state.selected_secrets = {}
          state.loaded_secrets = {}
          state.initialized = false

          ecolog.refresh_env_vars()
          secret_utils.update_environment(final_vars, false, "asm:")
          vim.notify("All AWS secrets unloaded", vim.log.levels.INFO)
          return
        end

        local new_loaded_secrets = {}
        for key, value in pairs(state.loaded_secrets) do
          local secret_name = value.source and value.source:match("^asm:(.+)$")
          if secret_name and new_selected[secret_name] then
            new_loaded_secrets[key] = value
          end
        end

        state.loaded_secrets = new_loaded_secrets
        state.selected_secrets = chosen_secrets
        state.initialized = false

        M.load_aws_secrets(vim.tbl_extend("force", state.config, {
          secrets = state.selected_secrets,
          enabled = true,
        }))
      end, "asm:")
    end)
  end)
end

api.nvim_create_autocmd("VimLeavePre", {
  group = api.nvim_create_augroup("EcologAwsSecretsCleanup", { clear = true }),
  callback = function()
    secret_utils.cleanup_jobs(state.active_jobs)
  end,
})

return M 