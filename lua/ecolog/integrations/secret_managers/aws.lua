local api = vim.api
local ecolog = require("ecolog")
local utils = require("ecolog.utils")
local secret_utils = require("ecolog.integrations.secret_managers.utils")
local BaseSecretManager = require("ecolog.integrations.secret_managers.base").BaseSecretManager

---@class AwsSecretsConfig : BaseSecretManagerConfig
---@field region string AWS region to use
---@field profile? string Optional AWS profile to use
---@field secrets string[] List of secret names to fetch

---@class AwsError
---@field message string
---@field code string
---@field level number

local AWS_TIMEOUT_MS = 300000
local AWS_CREDENTIALS_CACHE_SEC = 300

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
}

---@class AwsSecretsState : SecretManagerState
---@field credentials_valid boolean
---@field last_credentials_check number

---@class AwsSecretsManager : BaseSecretManager
---@field state AwsSecretsState
---@field config AwsSecretsConfig
local AwsSecretsManager = setmetatable({}, { __index = BaseSecretManager })

function AwsSecretsManager:new()
  local instance = BaseSecretManager.new(self, "asm:", "AWS Secrets Manager")
  instance.state.credentials_valid = false
  instance.state.last_credentials_check = 0
  setmetatable(instance, { __index = self })
  return instance
end

---Process AWS error from stderr
---@param stderr string
---@param secret_name? string
---@return AwsError
function AwsSecretsManager:process_error(stderr, secret_name)
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

---Check AWS credentials
---@param callback fun(ok: boolean, err?: string)
function AwsSecretsManager:check_credentials(callback)
  local now = os.time()
  if self.state.credentials_valid and (now - self.state.last_credentials_check) < AWS_CREDENTIALS_CACHE_SEC then
    callback(true)
    return
  end

  local cmd = { "aws", "sts", "get-caller-identity", "--query", "Account", "--output", "text" }

  self:create_aws_job(cmd, function(stdout)
    if stdout:match("^%d+$") then
      self.state.credentials_valid = true
      self.state.last_credentials_check = now
      callback(true)
    else
      self.state.credentials_valid = false
      callback(false, "AWS credentials validation failed: " .. stdout)
    end
  end, function(err)
    self.state.credentials_valid = false
    callback(false, err.message)
  end)
end

---List available secrets in AWS Secrets Manager
---@param callback fun(secrets: string[]|nil, err?: string)
function AwsSecretsManager:list_secrets(callback)
  local cmd = {
    "aws",
    "secretsmanager",
    "list-secrets",
    "--query",
    "SecretList[].Name",
    "--output",
    "text",
    "--region",
    self.config.region,
  }

  if self.config.profile then
    table.insert(cmd, "--profile")
    table.insert(cmd, self.config.profile)
  end

  self:create_aws_job(cmd, function(stdout)
    local secrets = {}
    for secret in stdout:gmatch("%S+") do
      if secret ~= "" then
        table.insert(secrets, secret)
      end
    end
    callback(secrets)
  end, function(err)
    callback(nil, err.message)
  end)
end

---Create a job with common error handling and job tracking
---@param cmd string[] Command to execute
---@param on_success fun(stdout: string) Success callback
---@param on_error fun(err: AwsError) Error callback
---@return number job_id
function AwsSecretsManager:create_aws_job(cmd, on_success, on_error)
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
        local err = self:process_error(stderr)
        on_error(err)
      else
        on_success(stdout:gsub("^%s*(.-)%s*$", "%1"))
      end
    end,
  })

  if job_id <= 0 then
    on_error({
      message = "Failed to start AWS CLI command",
      code = "JobStartError",
      level = vim.log.levels.ERROR,
    })
  else
    secret_utils.track_job(job_id, self.state.active_jobs)
  end

  return job_id
end

---Create a job to fetch a secret
---@param secret_name string
---@param on_success fun(value: string)
---@param on_error fun(err: AwsError)
---@return number job_id
function AwsSecretsManager:create_secret_job(secret_name, on_success, on_error)
  local cmd = {
    "aws",
    "secretsmanager",
    "get-secret-value",
    "--query",
    "SecretString",
    "--output",
    "text",
    "--secret-id",
    secret_name,
    "--region",
    self.config.region,
  }

  if self.config.profile then
    table.insert(cmd, "--profile")
    table.insert(cmd, self.config.profile)
  end

  return self:create_aws_job(cmd, function(stdout)
    if stdout ~= "" then
      on_success(stdout)
    else
      on_error({
        message = string.format("Empty secret value for %s", secret_name),
        code = "EmptySecret",
        level = vim.log.levels.WARN,
      })
    end
  end, function(err)
    on_error(err)
  end)
end

---Process secrets in parallel batches
---@param config AwsSecretsConfig
---@param aws_secrets table<string, table>
---@param on_complete fun(loaded: number, failed: number)
function AwsSecretsManager:process_secrets_parallel(config, aws_secrets, on_complete)
  local total_secrets = #config.secrets
  local active_jobs = 0
  local completed_jobs = 0
  local current_index = 1
  local loaded_secrets = 0
  local failed_secrets = 0
  local retry_counts = {}

  local function check_completion()
    if completed_jobs >= total_secrets then
      on_complete(loaded_secrets, failed_secrets)
    end
  end

  local function start_job(index)
    if index > total_secrets or not self.state.loading_lock then
      return
    end

    local secret_name = config.secrets[index]
    local job_id = self:create_secret_job(secret_name, function(value)
      local loaded, failed = secret_utils.process_secret_value(value, {
        filter = config.filter,
        transform = config.transform,
        source_prefix = "asm:",
        source_path = secret_name,
      }, aws_secrets)

      loaded_secrets = loaded_secrets + (loaded or 0)
      failed_secrets = failed_secrets + (failed or 0)
      completed_jobs = completed_jobs + 1

      active_jobs = active_jobs - 1
      check_completion()

      if current_index <= total_secrets then
        vim.defer_fn(function()
          start_next_job()
        end, secret_utils.REQUEST_DELAY_MS)
      end
    end, function(err)
      if err.code == "ConnectionError" then
        retry_counts[index] = (retry_counts[index] or 0) + 1
        if retry_counts[index] <= secret_utils.MAX_RETRIES then
          vim.defer_fn(function()
            start_job(index)
          end, 1000 * retry_counts[index])
          return
        end
      end

      failed_secrets = failed_secrets + 1
      vim.notify(err.message, err.level)
      completed_jobs = completed_jobs + 1

      active_jobs = active_jobs - 1
      check_completion()

      if current_index <= total_secrets then
        vim.defer_fn(function()
          start_next_job()
        end, secret_utils.REQUEST_DELAY_MS)
      end
    end)

    if job_id > 0 then
      active_jobs = active_jobs + 1
    else
      failed_secrets = failed_secrets + 1
      completed_jobs = completed_jobs + 1
      check_completion()

      if current_index <= total_secrets then
        vim.defer_fn(function()
          start_next_job()
        end, secret_utils.REQUEST_DELAY_MS)
      end
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

  if total_secrets > 0 then
    local max_initial_jobs = math.min(secret_utils.MAX_PARALLEL_REQUESTS, total_secrets)
    for _ = 1, max_initial_jobs do
      start_next_job()
    end
  else
    on_complete(0, 0)
  end
end

---Implementation specific loading of secrets
---@protected
---@param config AwsSecretsConfig
function AwsSecretsManager:_load_secrets_impl(config)
  if not config.enabled then
    secret_utils.cleanup_state(self.state)
    return {}
  end

  if not config.region then
    vim.notify(AWS_ERRORS.NO_REGION.message, AWS_ERRORS.NO_REGION.level)
    secret_utils.cleanup_state(self.state)
    return {}
  end

  if not config.secrets or #config.secrets == 0 then
    if not self.state.is_refreshing then
      secret_utils.cleanup_state(self.state)
      return {}
    end
    vim.notify(AWS_ERRORS.NO_SECRETS.message, AWS_ERRORS.NO_SECRETS.level)
    secret_utils.cleanup_state(self.state)
    return {}
  end

  if vim.fn.executable("aws") ~= 1 then
    vim.notify(AWS_ERRORS.NO_AWS_CLI.message, AWS_ERRORS.NO_AWS_CLI.level)
    secret_utils.cleanup_state(self.state)
    return {}
  end

  self.state.selected_secrets = vim.deepcopy(config.secrets)

  local aws_secrets = {}
  vim.notify("Loading AWS secrets...", vim.log.levels.INFO)

  self.state.timeout_timer = vim.fn.timer_start(AWS_TIMEOUT_MS, function()
    if self.state.loading_lock then
      vim.notify(AWS_ERRORS.TIMEOUT.message, AWS_ERRORS.TIMEOUT.level)
      secret_utils.cleanup_state(self.state)
    end
  end)

  self:check_credentials(function(ok, err)
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

    self:process_secrets_parallel(config, aws_secrets, function(loaded, failed)
      if loaded > 0 or failed > 0 then
        local msg = string.format("AWS Secrets Manager: Loaded %d secret%s", loaded, loaded == 1 and "" or "s")
        if failed > 0 then
          msg = msg .. string.format(", %d failed", failed)
        end
        vim.notify(msg, failed > 0 and vim.log.levels.WARN or vim.log.levels.INFO)

        self.state.loaded_secrets = aws_secrets
        self.state.initialized = true

        local updates_to_process = self.state.pending_env_updates
        self.state.pending_env_updates = {}

        secret_utils.update_environment(aws_secrets, config.override, "asm:")

        for _, update_fn in ipairs(updates_to_process) do
          update_fn()
        end
      end

      secret_utils.cleanup_state(self.state)
    end)
  end)

  return self.state.loaded_secrets or {}
end

---Implementation specific selection of secrets
---@protected
function AwsSecretsManager:_select_impl()
  if not self.config or not self.config.region then
    vim.notify(AWS_ERRORS.NO_REGION.message, AWS_ERRORS.NO_REGION.level)
    return
  end

  self:check_credentials(function(ok, err)
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
        vim.notify("No secrets found in AWS Secrets Manager", vim.log.levels.WARN)
        return
      end

      local selected = {}
      for _, secret_name in ipairs(self.state.selected_secrets) do
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

          self.state.selected_secrets = {}
          self.state.loaded_secrets = {}
          self.state.initialized = false

          ecolog.refresh_env_vars()
          secret_utils.update_environment(final_vars, false, "asm:")
          vim.notify("All AWS secrets unloaded", vim.log.levels.INFO)
          return
        end

        local new_loaded_secrets = {}
        for key, value in pairs(self.state.loaded_secrets) do
          local secret_name = value.source and value.source:match("^asm:(.+)$")
          if secret_name and new_selected[secret_name] then
            new_loaded_secrets[key] = value
          end
        end

        self.state.loaded_secrets = new_loaded_secrets
        self.state.selected_secrets = chosen_secrets
        self.state.initialized = false

        self:load_secrets(vim.tbl_extend("force", self.config, {
          secrets = self.state.selected_secrets,
          enabled = true,
        }))
      end, "asm:")
    end)
  end)
end

function AwsSecretsManager:setup_cleanup()
  api.nvim_create_autocmd("VimLeavePre", {
    group = api.nvim_create_augroup("EcologAwsSecretsCleanup", { clear = true }),
    callback = function()
      secret_utils.cleanup_jobs(self.state.active_jobs)
    end,
  })
end

---Get available configuration options for AWS Secrets Manager
---@protected
---@return table<string, { name: string, current: string|nil, options: string[]|nil, type: "multi-select"|"single-select"|"input" }>
function AwsSecretsManager:_get_config_options()
  local options = {}
  
  -- Region configuration
  options.region = {
    name = "AWS Region",
    current = self.config and self.config.region or nil,
    type = "single-select",
    options = {
      "us-east-1", "us-east-2", "us-west-1", "us-west-2",
      "eu-west-1", "eu-west-2", "eu-central-1",
      "ap-northeast-1", "ap-northeast-2", "ap-southeast-1", "ap-southeast-2",
      "sa-east-1"
    }
  }

  -- Profile configuration
  local cmd = { "aws", "configure", "list-profiles" }
  local output = vim.fn.system(cmd)
  if vim.v.shell_error == 0 and output ~= "" then
    local profiles = {}
    for profile in output:gmatch("[^\r\n]+") do
      table.insert(profiles, profile)
    end
    if #profiles > 0 then
      options.profile = {
        name = "AWS Profile",
        current = self.config and self.config.profile or nil,
        type = "single-select",
        options = profiles
      }
    end
  end

  return options
end

---Handle configuration change for AWS Secrets Manager
---@protected
---@param option string The configuration option being changed
---@param value any The new value
function AwsSecretsManager:_handle_config_change(option, value)
  if not self.config then
    self.config = { enabled = true }
  end

  if option == "region" then
    -- Only reset if region actually changes
    if self.config.region ~= value then
      self.config.region = value
      -- Reset and unload secrets when region changes
      self.state.selected_secrets = {}
      self.state.loaded_secrets = {}
      self.state.initialized = false
      
      -- Update environment to remove AWS secrets
      local current_env = ecolog.get_env_vars() or {}
      local final_vars = {}
      for key, value in pairs(current_env) do
        if not (value.source and value.source:match("^" .. self.source_prefix)) then
          final_vars[key] = value
        end
      end
      secret_utils.update_environment(final_vars, false, self.source_prefix)
      vim.notify("AWS secrets unloaded due to region change", vim.log.levels.INFO)
    end
  elseif option == "profile" then
    -- Only reset if profile actually changes
    if self.config.profile ~= value then
      self.config.profile = value
      -- Reset and unload secrets when profile changes
      self.state.selected_secrets = {}
      self.state.loaded_secrets = {}
      self.state.initialized = false
      
      -- Update environment to remove AWS secrets
      local current_env = ecolog.get_env_vars() or {}
      local final_vars = {}
      for key, value in pairs(current_env) do
        if not (value.source and value.source:match("^" .. self.source_prefix)) then
          final_vars[key] = value
        end
      end
      secret_utils.update_environment(final_vars, false, self.source_prefix)
      vim.notify("AWS secrets unloaded due to profile change", vim.log.levels.INFO)
    end
  end

  -- Don't automatically reload secrets after config change
  -- Let user explicitly select secrets again
end

---Show configuration selection UI
function AwsSecretsManager:select_config()
  local options = self:_get_config_options()
  if vim.tbl_isempty(options) then
    vim.notify("No configurable options available for " .. self.manager_name, vim.log.levels.WARN)
    return
  end

  local option_names = vim.tbl_keys(options)
  table.sort(option_names)

  local cursor_idx = 1
  local function get_content()
    local content = {}
    for i, option_name in ipairs(option_names) do
      local option = options[option_name]
      local current = option.current or "not set"
      local prefix = i == cursor_idx and " → " or "   "
      table.insert(content, string.format("%s%s: %s", prefix, option.name, current))
    end
    return content
  end

  local float_opts = utils.create_minimal_win_opts(60, #option_names)
  local bufnr = api.nvim_create_buf(false, true)

  api.nvim_buf_set_option(bufnr, "buftype", "nofile")
  api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
  api.nvim_buf_set_option(bufnr, "modifiable", true)
  api.nvim_buf_set_option(bufnr, "filetype", "ecolog")

  local winid = api.nvim_open_win(bufnr, true, float_opts)

  api.nvim_win_set_option(winid, "conceallevel", 2)
  api.nvim_win_set_option(winid, "concealcursor", "niv")
  api.nvim_win_set_option(winid, "cursorline", true)
  api.nvim_win_set_option(winid, "winhl", "Normal:EcologNormal,FloatBorder:EcologBorder")

  local function update_buffer()
    local content = get_content()
    api.nvim_buf_set_option(bufnr, "modifiable", true)
    api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
    api.nvim_buf_set_option(bufnr, "modifiable", false)

    api.nvim_buf_clear_namespace(bufnr, -1, 0, -1)
    for i = 1, #content do
      local hl_group = i == cursor_idx and "EcologCursor" or "EcologVariable"
      api.nvim_buf_add_highlight(bufnr, -1, hl_group, i - 1, 0, -1)
    end

    api.nvim_win_set_cursor(winid, { cursor_idx, 4 })
  end

  local function close_window()
    if api.nvim_win_is_valid(winid) then
      api.nvim_win_close(winid, true)
    end
  end

  local function handle_option_selection()
    local option_name = option_names[cursor_idx]
    local option = options[option_name]

    if option.type == "single-select" then
      close_window()
      -- For both region and profile, show a simple selection UI
      local current_value = option.current
      local select_idx = 1
      
      -- Find current selection index
      for i, value in ipairs(option.options) do
        if value == current_value then
          select_idx = i
          break
        end
      end

      local select_bufnr = api.nvim_create_buf(false, true)
      local select_winid = api.nvim_open_win(select_bufnr, true, utils.create_minimal_win_opts(30, #option.options))

      local function update_select_buffer()
        local content = {}
        for i, value in ipairs(option.options) do
          local prefix = i == select_idx and " → " or "   "
          table.insert(content, string.format("%s%s", prefix, value))
        end

        api.nvim_buf_set_option(select_bufnr, "modifiable", true)
        api.nvim_buf_set_lines(select_bufnr, 0, -1, false, content)
        api.nvim_buf_set_option(select_bufnr, "modifiable", false)

        api.nvim_buf_clear_namespace(select_bufnr, -1, 0, -1)
        for i = 1, #content do
          local hl_group = i == select_idx and "EcologCursor" or "EcologVariable"
          api.nvim_buf_add_highlight(select_bufnr, -1, hl_group, i - 1, 0, -1)
        end

        api.nvim_win_set_cursor(select_winid, { select_idx, 4 })
      end

      local function close_select_window()
        if api.nvim_win_is_valid(select_winid) then
          api.nvim_win_close(select_winid, true)
        end
      end

      api.nvim_buf_set_option(select_bufnr, "buftype", "nofile")
      api.nvim_buf_set_option(select_bufnr, "bufhidden", "wipe")
      api.nvim_buf_set_option(select_bufnr, "modifiable", true)
      api.nvim_buf_set_option(select_bufnr, "filetype", "ecolog")

      api.nvim_win_set_option(select_winid, "conceallevel", 2)
      api.nvim_win_set_option(select_winid, "concealcursor", "niv")
      api.nvim_win_set_option(select_winid, "cursorline", true)
      api.nvim_win_set_option(select_winid, "winhl", "Normal:EcologNormal,FloatBorder:EcologBorder")

      vim.keymap.set("n", "j", function()
        if select_idx < #option.options then
          select_idx = select_idx + 1
          update_select_buffer()
        end
      end, { buffer = select_bufnr, nowait = true })

      vim.keymap.set("n", "k", function()
        if select_idx > 1 then
          select_idx = select_idx - 1
          update_select_buffer()
        end
      end, { buffer = select_bufnr, nowait = true })

      vim.keymap.set("n", "<CR>", function()
        local selected_value = option.options[select_idx]
        close_select_window()
        self:_handle_config_change(option_name, selected_value)
      end, { buffer = select_bufnr, nowait = true })

      vim.keymap.set("n", "q", close_select_window, { buffer = select_bufnr, nowait = true })
      vim.keymap.set("n", "<ESC>", close_select_window, { buffer = select_bufnr, nowait = true })

      api.nvim_create_autocmd("BufLeave", {
        buffer = select_bufnr,
        once = true,
        callback = close_select_window,
      })

      update_select_buffer()
    elseif option.type == "input" then
      close_window()
      vim.ui.input({
        prompt = string.format("Enter %s: ", option.name),
        default = option.current or "",
      }, function(value)
        if value then
          self:_handle_config_change(option_name, value)
        end
      end)
    end
  end

  vim.keymap.set("n", "j", function()
    if cursor_idx < #option_names then
      cursor_idx = cursor_idx + 1
      update_buffer()
    end
  end, { buffer = bufnr, nowait = true })

  vim.keymap.set("n", "k", function()
    if cursor_idx > 1 then
      cursor_idx = cursor_idx - 1
      update_buffer()
    end
  end, { buffer = bufnr, nowait = true })

  vim.keymap.set("n", "<CR>", handle_option_selection, { buffer = bufnr, nowait = true })
  vim.keymap.set("n", "q", close_window, { buffer = bufnr, nowait = true })
  vim.keymap.set("n", "<ESC>", close_window, { buffer = bufnr, nowait = true })

  api.nvim_create_autocmd("BufLeave", {
    buffer = bufnr,
    once = true,
    callback = close_window,
  })

  update_buffer()
end

local instance = AwsSecretsManager:new()
instance:setup_cleanup()

return {
  load_aws_secrets = function(config)
    return instance:load_secrets(config)
  end,
  select = function()
    return instance:select()
  end,
  select_config = function()
    return instance:select_config()
  end,
}
