local M = {}

local api = vim.api
local utils = require("ecolog.utils")
local types = require("ecolog.types")
local ecolog = require("ecolog")

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

---@class SelectSecretsConfig
---@field region string AWS region to use
---@field profile? string Optional AWS profile to use

local AWS_TIMEOUT_MS = 300000
local AWS_CREDENTIALS_CACHE_SEC = 300
local AWS_MAX_RETRIES = 3
local BUFFER_UPDATE_DEBOUNCE_MS = 50

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
  update_timer = nil,
  stdout_chunks = {},
  stderr_chunks = {},
}

local function cleanup_jobs()
  for job_id, _ in pairs(state.active_jobs) do
    if vim.fn.jobwait({ job_id }, 0)[1] == -1 then
      pcall(vim.fn.jobstop, job_id)
    end
  end
  state.active_jobs = {}
end

---Track a job for cleanup
---@param job_id number
local function track_job(job_id)
  if job_id > 0 then
    state.active_jobs[job_id] = true
    api.nvim_create_autocmd("VimLeave", {
      callback = function()
        if state.active_jobs[job_id] then
          if vim.fn.jobwait({ job_id }, 0)[1] == -1 then
            pcall(vim.fn.jobstop, job_id)
          end
          state.active_jobs[job_id] = nil
        end
      end,
      once = true,
    })
  end
end

---Untrack a job
---@param job_id number
local function untrack_job(job_id)
  if job_id then
    state.active_jobs[job_id] = nil
  end
end

local function cleanup_state()
  state.loading = false
  state.loading_lock = nil
  if state.timeout_timer then
    pcall(vim.fn.timer_stop, state.timeout_timer)
    state.timeout_timer = nil
  end
  cleanup_jobs()
end

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

          local type_name, detected_value = types.detect_type(transformed_value)
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

      local type_name, detected_value = types.detect_type(transformed_value)
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

---Process secrets in batches to improve performance
---@param aws_config LoadAwsSecretsConfig
---@param aws_secrets table<string, table>
---@param start_index number
---@param loaded_secrets number
---@param failed_secrets number
local function process_secrets_batch(aws_config, aws_secrets, start_index, loaded_secrets, failed_secrets)
  if not state.loading_lock then
    return
  end

  if start_index > #aws_config.secrets then
    if loaded_secrets > 0 or failed_secrets > 0 then
      local msg =
        string.format("AWS Secrets Manager: Loaded %d secret%s", loaded_secrets, loaded_secrets == 1 and "" or "s")
      if failed_secrets > 0 then
        msg = msg .. string.format(", %d failed", failed_secrets)
      end
      vim.notify(msg, failed_secrets > 0 and vim.log.levels.WARN or vim.log.levels.INFO)

      state.loaded_secrets = aws_secrets
      state.initialized = true

      local updates_to_process = state.pending_env_updates
      state.pending_env_updates = {}

      ecolog.refresh_env_vars()

      local env_updates = {}
      for k, v in pairs(aws_secrets) do
        if type(v) == "table" and v.value then
          env_updates[k] = tostring(v.value)
        else
          env_updates[k] = tostring(v)
        end
      end

      for k, v in pairs(env_updates) do
        vim.env[k] = v
      end

      for _, update_fn in ipairs(updates_to_process) do
        update_fn()
      end

      cleanup_state()
    end
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
    aws_config.secrets[start_index],
    "--region",
    aws_config.region,
  }

  if aws_config.profile then
    table.insert(cmd, "--profile")
    table.insert(cmd, aws_config.profile)
  end

  state.stdout_chunks = {}
  state.stderr_chunks = {}
  local retry_count = 0

  local function process_next()
    vim.defer_fn(function()
      process_secrets_batch(aws_config, aws_secrets, start_index + 1, loaded_secrets, failed_secrets)
    end, 100)
  end

  local job_id = vim.fn.jobstart(cmd, {
    on_stdout = function(_, data)
      if data then
        vim.list_extend(state.stdout_chunks, data)
      end
    end,
    on_stderr = function(_, data)
      if data then
        vim.list_extend(state.stderr_chunks, data)
      end
    end,
    on_exit = function(_, code)
      untrack_job(job_id)
      vim.schedule(function()
        if not state.loading_lock then
          return
        end

        local stdout = table.concat(state.stdout_chunks, "\n")
        local stderr = table.concat(state.stderr_chunks, "\n")
        state.stdout_chunks = {}
        state.stderr_chunks = {}

        if code ~= 0 then
          if
            retry_count < AWS_MAX_RETRIES
            and (
              stderr:match("Could not connect to the endpoint URL")
              or stderr:match("ThrottlingException")
              or stderr:match("RequestTimeout")
            )
          then
            retry_count = retry_count + 1
            vim.defer_fn(function()
              process_secrets_batch(aws_config, aws_secrets, start_index, loaded_secrets, failed_secrets)
            end, 1000 * retry_count)
            return
          end

          failed_secrets = failed_secrets + 1
          local err = process_aws_error(stderr, aws_config.secrets[start_index])
          vim.notify(err.message, err.level)
          process_next()
        else
          local secret_value = stdout:gsub("^%s*(.-)%s*$", "%1")
          if secret_value ~= "" then
            local loaded, failed =
              process_secret_value(secret_value, aws_config.secrets[start_index], aws_config, aws_secrets)
            loaded_secrets = loaded_secrets + loaded
            failed_secrets = failed_secrets + failed
          end
          process_next()
        end
      end)
    end,
  })

  if job_id > 0 then
    track_job(job_id)
  else
    vim.schedule(function()
      failed_secrets = failed_secrets + 1
      vim.notify(
        string.format("Failed to start AWS CLI command for secret %s", aws_config.secrets[start_index]),
        vim.log.levels.ERROR
      )
      process_next()
    end)
  end
end

---Update environment with loaded secrets
---@param secrets table<string, table>
---@param override boolean
local function update_environment(secrets, override)
  if state.is_refreshing then
    return
  end

  state.is_refreshing = true
  state.skip_load = true

  M._apply_env_updates(secrets, override)

  state.skip_load = false
  state.is_refreshing = false
end

---Update environment variables
---@param env_vars table<string, any>
---@param override boolean
function M.update_env_vars(env_vars, override)
  ecolog.refresh_env_vars()

  if state.loading or state.loading_lock then
    table.insert(state.pending_env_updates, function()
      M._apply_env_updates(env_vars, override)
    end)
    return
  end

  M._apply_env_updates(env_vars, override)
end

function M._apply_env_updates(env_vars, override)
  local final_vars = override and {} or vim.deepcopy(state.loaded_secrets or {})

  -- Track which AWS secrets variables should be kept
  local keep_vars = {}
  for k, v in pairs(final_vars) do
    if v.source and v.source:match("^asm:") then
      keep_vars[k] = true
    end
  end

  local current_env = ecolog.get_env_vars() or {}
  for k, v in pairs(current_env) do
    -- Only keep non-AWS variables or AWS variables that are in final_vars
    if not (v.source and v.source:match("^asm:")) or keep_vars[k] then
      final_vars[k] = v
    end
  end

  local new_vars = env_vars or {}
  for k, v in pairs(new_vars) do
    final_vars[k] = v
  end

  ecolog.refresh_env_vars()

  ecolog.add_env_vars(final_vars)
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
      untrack_job(job_id)
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
    track_job(job_id)
  end
end

local function select_secrets(config)
  local cmd = {
    "aws",
    "secretsmanager",
    "list-secrets",
    "--query",
    "SecretList[].Name",
    "--output",
    "text",
    "--region",
    config.region,
  }

  if config.profile then
    table.insert(cmd, "--profile")
    table.insert(cmd, config.profile)
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
      untrack_job(job_id)
      if code ~= 0 then
        local err = process_aws_error(stderr)
        vim.notify(err.message, err.level)
        return
      end

      local secrets = {}
      for secret in stdout:gmatch("%S+") do
        if secret ~= "" then
          table.insert(secrets, secret)
        end
      end

      if #secrets == 0 then
        vim.notify("No secrets found in region " .. config.region, vim.log.levels.WARN)
        return
      end

      -- Initialize selected with currently loaded secrets
      local selected = {}
      for _, secret_name in ipairs(state.selected_secrets) do
        selected[secret_name] = true
      end
      local cursor_idx = 1

      -- Set cursor to first selected secret if any
      for i, secret in ipairs(secrets) do
        if selected[secret] then
          cursor_idx = i
          break
        end
      end

      local function get_content()
        local content = {}
        for i, secret in ipairs(secrets) do
          local prefix
          if selected[secret] then
            prefix = " ✓ "
          else
            prefix = i == cursor_idx and " → " or "   "
          end
          table.insert(content, string.format("%s%s", prefix, secret))
        end
        return content
      end

      local function update_buffer(bufnr, winid)
        if state.update_timer then
          vim.fn.timer_stop(state.update_timer)
        end

        state.update_timer = vim.fn.timer_start(BUFFER_UPDATE_DEBOUNCE_MS, function()
          if not api.nvim_buf_is_valid(bufnr) or not api.nvim_win_is_valid(winid) then
            return
          end

          local content = get_content()
          api.nvim_buf_set_option(bufnr, "modifiable", true)
          api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
          api.nvim_buf_set_option(bufnr, "modifiable", false)

          api.nvim_buf_clear_namespace(bufnr, -1, 0, -1)
          for i = 1, #content do
            local hl_group = selected[secrets[i]] and "EcologVariable" or "EcologSelected"
            if i == cursor_idx then
              hl_group = "EcologCursor"
            end
            api.nvim_buf_add_highlight(bufnr, -1, hl_group, i - 1, 0, -1)
          end

          api.nvim_win_set_cursor(winid, { cursor_idx, 4 })
        end)
      end

      local float_opts = utils.create_minimal_win_opts(60, #secrets)
      local original_guicursor = vim.opt.guicursor:get()
      local bufnr = api.nvim_create_buf(false, true)

      api.nvim_buf_set_option(bufnr, "buftype", "nofile")
      api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
      api.nvim_buf_set_option(bufnr, "modifiable", true)
      api.nvim_buf_set_option(bufnr, "filetype", "ecolog")

      api.nvim_buf_set_lines(bufnr, 0, -1, false, get_content())
      api.nvim_buf_set_option(bufnr, "modifiable", false)

      local winid = api.nvim_open_win(bufnr, true, float_opts)

      api.nvim_win_set_option(winid, "conceallevel", 2)
      api.nvim_win_set_option(winid, "concealcursor", "niv")
      api.nvim_win_set_option(winid, "cursorline", true)
      api.nvim_win_set_option(winid, "winhl", "Normal:EcologNormal,FloatBorder:EcologBorder")

      update_buffer(bufnr, winid)

      vim.keymap.set("n", "j", function()
        if cursor_idx < #secrets then
          cursor_idx = cursor_idx + 1
          update_buffer(bufnr, winid)
        end
      end, { buffer = bufnr, nowait = true })

      vim.keymap.set("n", "k", function()
        if cursor_idx > 1 then
          cursor_idx = cursor_idx - 1
          update_buffer(bufnr, winid)
        end
      end, { buffer = bufnr, nowait = true })

      vim.keymap.set("n", "<space>", function()
        local current_secret = secrets[cursor_idx]
        selected[current_secret] = not selected[current_secret]
        update_buffer(bufnr, winid)
      end, { buffer = bufnr, nowait = true })

      local function close_window()
        if api.nvim_win_is_valid(winid) then
          vim.opt.guicursor = original_guicursor
          api.nvim_win_close(winid, true)
        end
      end

      local function load_selected_secrets()
        local chosen_secrets = {}
        for secret, is_selected in pairs(selected) do
          if is_selected then
            table.insert(chosen_secrets, secret)
          end
        end

        if #chosen_secrets > 0 then
          -- Unload secrets that are no longer selected
          local new_loaded_secrets = {}

          -- First identify which variables to keep
          for key, value in pairs(state.loaded_secrets) do
            local secret_name = value.source and value.source:match("^asm:(.+)$")
            if secret_name and selected[secret_name] then
              new_loaded_secrets[key] = value
            end
          end

          -- Update state
          state.loaded_secrets = new_loaded_secrets
          state.selected_secrets = chosen_secrets
          state.initialized = false

          -- Load new configuration
          M.load_aws_secrets(vim.tbl_extend("force", state.config, {
            secrets = state.selected_secrets,
            enabled = true,
            region = config.region,
            profile = config.profile,
          }))
        end
      end

      vim.keymap.set("n", "<CR>", function()
        close_window()
        load_selected_secrets()
      end, { buffer = bufnr, nowait = true })

      vim.keymap.set("n", "q", function()
        close_window()
      end, { buffer = bufnr, nowait = true })

      vim.keymap.set("n", "<ESC>", function()
        close_window()
      end, { buffer = bufnr, nowait = true })

      api.nvim_create_autocmd("BufLeave", {
        buffer = bufnr,
        once = true,
        callback = close_window,
      })
    end,
  })

  if job_id <= 0 then
    vim.notify("Failed to start AWS CLI command", vim.log.levels.ERROR)
  else
    track_job(job_id)
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
    -- Unload all AWS secrets when disabled
    local current_env = ecolog.get_env_vars() or {}
    local final_vars = {}

    -- Keep only non-AWS variables
    for key, value in pairs(current_env) do
      if not (value.source and value.source:match("^asm:")) then
        final_vars[key] = value
      end
    end

    state.selected_secrets = {}
    state.loaded_secrets = {}

    ecolog.refresh_env_vars()
    ecolog.add_env_vars(final_vars)
    cleanup_state()
    return {}
  end

  if not aws_config.region then
    vim.notify(AWS_ERRORS.NO_REGION.message, AWS_ERRORS.NO_REGION.level)
    cleanup_state()
    return {}
  end

  if not aws_config.secrets or #aws_config.secrets == 0 then
    if not state.is_refreshing then
      cleanup_state()
      return {}
    end
    vim.notify(AWS_ERRORS.NO_SECRETS.message, AWS_ERRORS.NO_SECRETS.level)
    cleanup_state()
    return {}
  end

  if vim.fn.executable("aws") ~= 1 then
    vim.notify(AWS_ERRORS.NO_AWS_CLI.message, AWS_ERRORS.NO_AWS_CLI.level)
    cleanup_state()
    return {}
  end

  state.selected_secrets = vim.deepcopy(aws_config.secrets)

  local aws_secrets = {}
  vim.notify("Loading AWS secrets...", vim.log.levels.INFO)

  state.timeout_timer = vim.fn.timer_start(AWS_TIMEOUT_MS, function()
    if state.loading_lock then
      vim.notify(AWS_ERRORS.TIMEOUT.message, AWS_ERRORS.TIMEOUT.level)
      cleanup_state()
    end
  end)

  check_aws_credentials(function(ok, err)
    if not state.loading_lock then
      return
    end

    if not ok then
      vim.schedule(function()
        vim.notify(err, vim.log.levels.ERROR)
        cleanup_state()
      end)
      return
    end

    process_secrets_batch(aws_config, aws_secrets, 1, 0, 0)
  end)

  return state.loaded_secrets or {}
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

  select_secrets({
    region = state.config.region,
    profile = state.config.profile,
  })
end

api.nvim_create_autocmd("VimLeavePre", {
  group = api.nvim_create_augroup("EcologAWSSecretsCleanup", { clear = true }),
  callback = cleanup_jobs,
})

return M

