local M = {}

local api = vim.api
local utils = require("ecolog.utils")
local types = require("ecolog.types")

local state = {
  selected_secrets = {},
  config = nil,
  loading = false,
  loaded_secrets = {},
  active_jobs = {},
  is_refreshing = false,
  skip_load = false
}

local function cleanup_jobs()
  for job_id, _ in pairs(state.active_jobs) do
    if vim.fn.jobwait({job_id}, 0)[1] == -1 then
      pcall(vim.fn.jobstop, job_id)
    end
  end
  state.active_jobs = {}
end

api.nvim_create_autocmd("VimLeavePre", {
  group = api.nvim_create_augroup("EcologAWSSecretsCleanup", { clear = true }),
  callback = cleanup_jobs
})

local function track_job(job_id)
  if job_id > 0 then
    state.active_jobs[job_id] = true
    vim.api.nvim_create_autocmd("VimLeave", {
      callback = function()
        if state.active_jobs[job_id] then
          if vim.fn.jobwait({job_id}, 0)[1] == -1 then
            pcall(vim.fn.jobstop, job_id)
          end
          state.active_jobs[job_id] = nil
        end
      end,
      once = true
    })
  end
end

local function untrack_job(job_id)
  if job_id then
    state.active_jobs[job_id] = nil
  end
end

---@return boolean, string? error
local function check_aws_credentials(callback)
  local cmd = {"aws", "sts", "get-caller-identity", "--query", "Account", "--output", "text"}
  
  local stdout = ""
  local stderr = ""
  
  local job_id = vim.fn.jobstart(cmd, {
    on_stdout = function(_, data)
      stdout = stdout .. table.concat(data, "\n")
    end,
    on_stderr = function(_, data)
      stderr = stderr .. table.concat(data, "\n")
    end,
    on_exit = function(_, code)
      untrack_job(job_id)
      if code ~= 0 then
        if stderr:match("InvalidSignatureException") or stderr:match("credentials") then
          callback(false, "AWS credentials are not properly configured. Please check your AWS credentials:\n" ..
                        "1. Ensure AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY are set correctly\n" ..
                        "2. Or verify ~/.aws/credentials contains valid credentials\n" ..
                        "3. If using a profile, confirm it exists and is properly configured")
        elseif stderr:match("Unable to locate credentials") then
          callback(false, "No AWS credentials found. Please configure your AWS credentials")
        else
          callback(false, "AWS credentials validation failed: " .. stderr)
        end
        return
      end
      
      stdout = stdout:gsub("^%s*(.-)%s*$", "%1")
      
      if stdout:match("^%d+$") then
        callback(true)
      else
        callback(false, "AWS credentials validation failed: " .. stdout)
      end
    end
  })
  
  if job_id <= 0 then
    callback(false, "Failed to start AWS CLI command")
  else
    track_job(job_id)
  end
end

---@param region string AWS region
---@param profile? string AWS profile
---@param callback function Callback function to receive results
local function list_secrets(region, profile, callback)
  check_aws_credentials(function(ok, err)
    if not ok then
      vim.schedule(function()
        vim.notify(err, vim.log.levels.ERROR)
        callback(nil)
      end)
      return
    end
    
    local cmd = {"aws", "secretsmanager", "list-secrets", "--query", "SecretList[].Name", "--output", "text"}
    if profile then
      table.insert(cmd, "--profile")
      table.insert(cmd, profile)
    end
    table.insert(cmd, "--region")
    table.insert(cmd, region)
    
    local stdout = ""
    local stderr = ""
    
    local job_id = vim.fn.jobstart(cmd, {
      on_stdout = function(_, data)
        stdout = stdout .. table.concat(data, "\n")
      end,
      on_stderr = function(_, data)
        stderr = stderr .. table.concat(data, "\n")
      end,
      on_exit = function(_, code)
        untrack_job(job_id)
        vim.schedule(function()
          if code ~= 0 then
            if stderr:match("Could not connect to the endpoint URL") then
              callback(nil, "Could not connect to AWS")
            elseif stderr:match("AccessDenied") then
              callback(nil, "Access denied: Check your AWS credentials")
            else
              callback(nil, "Error listing secrets: " .. stderr)
            end
            return
          end
          
          local secrets = {}
          for secret in stdout:gmatch("%S+") do
            table.insert(secrets, secret)
          end
          
          callback(secrets)
        end)
      end
    })
    
    if job_id <= 0 then
      vim.schedule(function()
        callback(nil, "Failed to start AWS CLI command")
      end)
    else
      track_job(job_id)
    end
  end)
end

---@param opts { region: string, profile?: string }
local function select_secrets(opts)
  if vim.fn.executable("aws") ~= 1 then
    vim.notify("AWS CLI is not installed or not in PATH", vim.log.levels.ERROR)
    return
  end

  state.loading = true
  local loading_msg = vim.notify("Loading AWS secrets...", vim.log.levels.INFO)

  list_secrets(opts.region, opts.profile, function(secrets, err)
    state.loading = false
    
    if err then
      vim.notify("Failed to list secrets: " .. err, vim.log.levels.ERROR, { replace = loading_msg })
      return
    end

    if not secrets or #secrets == 0 then
      vim.notify("No secrets found in region " .. opts.region, vim.log.levels.WARN, { replace = loading_msg })
      return
    end

    vim.notify("", "recall", { replace = loading_msg })

    local bufnr = api.nvim_create_buf(false, true)
    local selected_idx = 1
    local selected = {}
    for _, secret in ipairs(state.selected_secrets) do
      selected[secret] = true
    end

    local function get_content()
      local content = {}
      for i, secret in ipairs(secrets) do
        local prefix = selected[secret] and "✓ " or "  "
        table.insert(content, prefix .. secret)
      end
      return content
    end

    local function update_buffer(winid)
      local content = get_content()
      api.nvim_buf_set_option(bufnr, "modifiable", true)
      api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
      api.nvim_buf_set_option(bufnr, "modifiable", false)

      api.nvim_buf_clear_namespace(bufnr, -1, 0, -1)
      for i = 1, #content do
        local hl_group = i == selected_idx and "EcologSelected" or "EcologVariable"
        api.nvim_buf_add_highlight(bufnr, -1, hl_group, i - 1, 0, -1)
      end

      api.nvim_win_set_cursor(winid, { selected_idx, 2 })
    end

    api.nvim_buf_set_option(bufnr, "buftype", "nofile")
    api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
    api.nvim_buf_set_option(bufnr, "filetype", "ecolog")

    local width = 60
    local height = math.min(#secrets, 15)
    local win_opts = utils.create_minimal_win_opts(width, height)
    local winid = api.nvim_open_win(bufnr, true, win_opts)

    api.nvim_win_set_option(winid, "cursorline", true)
    api.nvim_win_set_option(winid, "wrap", false)

    local function set_keymap(lhs, rhs)
      api.nvim_buf_set_keymap(bufnr, "n", lhs, rhs, { silent = true, noremap = true })
    end

    set_keymap("<CR>", string.format([[<cmd>lua require('ecolog.integrations.aws_secrets_manager').toggle_secret(%d)<CR>]], bufnr))
    set_keymap("<Space>", string.format([[<cmd>lua require('ecolog.integrations.aws_secrets_manager').toggle_secret(%d)<CR>]], bufnr))
    set_keymap("q", "<cmd>q<CR>")
    set_keymap("<Esc>", "<cmd>q<CR>")
    set_keymap("j", string.format([[<cmd>lua require('ecolog.integrations.aws_secrets_manager').move_cursor(%d, 1)<CR>]], bufnr))
    set_keymap("k", string.format([[<cmd>lua require('ecolog.integrations.aws_secrets_manager').move_cursor(%d, -1)<CR>]], bufnr))

    local group = api.nvim_create_augroup("EcologAWSSecrets", { clear = true })
    api.nvim_create_autocmd("BufLeave", {
      group = group,
      buffer = bufnr,
      callback = function()
        if api.nvim_win_is_valid(winid) then
          api.nvim_win_close(winid, true)
        end
      end,
    })

    update_buffer(winid)

    state.bufnr = bufnr
    state.secrets = secrets
    state.selected_idx = selected_idx
    state.update_buffer = update_buffer
    state.winid = winid
  end)
end

function M.move_cursor(bufnr, direction)
  if bufnr ~= state.bufnr then return end
  
  local new_idx = state.selected_idx + direction
  if new_idx >= 1 and new_idx <= #state.secrets then
    state.selected_idx = new_idx
    state.update_buffer(state.winid)
  end
end

local function update_environment()
  if state.is_refreshing then return end
  state.is_refreshing = true
  state.skip_load = true
  local ecolog = require("ecolog")
  ecolog.refresh_env_vars()
  state.skip_load = false
  state.is_refreshing = false
end

function M.toggle_secret(bufnr)
  if bufnr ~= state.bufnr then return end

  local secret = state.secrets[state.selected_idx]
  if not secret then return end

  local is_selected = vim.tbl_contains(state.selected_secrets, secret)
  
  if is_selected then
    for i, s in ipairs(state.selected_secrets) do
      if s == secret then
        table.remove(state.selected_secrets, i)
        break
      end
    end

    local key = secret:match("[^/]+$")
    if state.loaded_secrets[key] then
      state.loaded_secrets[key] = nil
      if state.config then
        state.config.secrets = state.selected_secrets
        update_environment()
      end
    end
  else
    table.insert(state.selected_secrets, secret)
    if state.config then
      state.config.secrets = state.selected_secrets
      
      local loading_msg = vim.notify("Loading AWS secret...", vim.log.levels.INFO)
      
      local cmd = {"aws", "secretsmanager", "get-secret-value", 
                  "--query", "SecretString", "--output", "text",
                  "--secret-id", secret}
      
      if state.config.profile then
        table.insert(cmd, "--profile")
        table.insert(cmd, state.config.profile)
      end
      table.insert(cmd, "--region")
      table.insert(cmd, state.config.region)

      local stdout = ""
      local stderr = ""
      
      local job_id = vim.fn.jobstart(cmd, {
        on_stdout = function(_, data)
          stdout = stdout .. table.concat(data, "\n")
        end,
        on_stderr = function(_, data)
          stderr = stderr .. table.concat(data, "\n")
        end,
        on_exit = function(_, code)
          untrack_job(job_id)
          vim.schedule(function()
            if code ~= 0 then
              if stderr:match("Could not connect to the endpoint URL") then
                vim.notify("AWS connectivity error for secret " .. secret .. ": Could not connect to AWS", vim.log.levels.ERROR)
              elseif stderr:match("AccessDenied") then
                vim.notify("Access denied for secret " .. secret .. ": Check your AWS credentials", vim.log.levels.ERROR)
              elseif stderr:match("ResourceNotFound") then
                vim.notify("Secret not found: " .. secret, vim.log.levels.ERROR)
              else
                vim.notify("Error fetching secret " .. secret .. ": " .. stderr, vim.log.levels.ERROR)
              end
            else
              local secret_value = stdout:gsub("^%s*(.-)%s*$", "%1")

              if secret_value ~= "" then
                if secret_value:match("^{") then
                  local ok, parsed_secret = pcall(vim.json.decode, secret_value)
                  if ok and type(parsed_secret) == "table" then
                    for key, value in pairs(parsed_secret) do
                      if not state.config.filter or state.config.filter(key, value) then
                        if state.config.transform then
                          value = state.config.transform(key, value)
                        end

                        local type_name, transformed_value = types.detect_type(value)

                        state.loaded_secrets[key] = {
                          value = transformed_value or value,
                          type = type_name,
                          raw_value = value,
                          source = "asm:" .. secret,
                          comment = nil,
                        }
                      end
                    end
                    vim.notify("AWS Secrets Manager: Loaded secret " .. secret, vim.log.levels.INFO)
                  else
                    vim.notify("Failed to parse JSON secret from " .. secret, vim.log.levels.WARN)
                  end
                else
                  local key = secret:match("[^/]+$")
                  if not state.config.filter or state.config.filter(key, secret_value) then
                    if state.config.transform then
                      secret_value = state.config.transform(key, secret_value)
                    end

                    local type_name, transformed_value = types.detect_type(secret_value)

                    state.loaded_secrets[key] = {
                      value = transformed_value or secret_value,
                      type = type_name,
                      raw_value = secret_value,
                      source = "asm:" .. secret,
                      comment = nil,
                    }
                    vim.notify("AWS Secrets Manager: Loaded secret " .. secret, vim.log.levels.INFO)
                  end
                end

                update_environment()
              end
            end
          end)
        end
      })
      if job_id > 0 then
        track_job(job_id)
      end
    end
  end

  state.update_buffer(state.winid)
end

---@class LoadAwsSecretsConfig
---@field enabled boolean Enable loading AWS Secrets Manager secrets into environment
---@field override boolean When true, AWS secrets take precedence over .env files and shell variables
---@field region string AWS region to use
---@field profile? string Optional AWS profile to use
---@field secrets table<string> List of secret names to fetch
---@field filter? function Optional function to filter which secrets to load
---@field transform? function Optional function to transform secret values

---@param config boolean|LoadAwsSecretsConfig
---@return table<string, table>
function M.load_aws_secrets(config)
  if state.skip_load then
    return state.loaded_secrets or {}
  end

  state.config = config

  local aws_config = type(config) == "table" and config or { enabled = config, override = false }
  
  if not aws_config.enabled then
    state.selected_secrets = {}
    state.loaded_secrets = {}
    return {}
  end

  if not aws_config.region then
    vim.notify("AWS region is required for AWS Secrets Manager integration", vim.log.levels.ERROR)
    return {}
  end

  if not aws_config.secrets or #aws_config.secrets == 0 then
    vim.notify("No secrets specified for AWS Secrets Manager integration", vim.log.levels.ERROR)
    return {}
  end

  if vim.fn.executable("aws") ~= 1 then
    vim.notify("AWS CLI is not installed or not in PATH", vim.log.levels.ERROR)
    return {}
  end

  state.selected_secrets = vim.deepcopy(aws_config.secrets)

  local aws_secrets = {}
  local loaded_secrets = 0
  local failed_secrets = 0

  local loading_msg = vim.notify("Loading AWS secrets...", vim.log.levels.INFO)

  check_aws_credentials(function(ok, err)
    if not ok then
      vim.schedule(function()
        vim.notify(err, vim.log.levels.ERROR, { replace = loading_msg })
      end)
      return
    end

    local remaining_secrets = #aws_config.secrets
    
    for _, secret_name in ipairs(aws_config.secrets) do
      local cmd = {"aws", "secretsmanager", "get-secret-value", 
                  "--query", "SecretString", "--output", "text",
                  "--secret-id", secret_name}
      
      if aws_config.profile then
        table.insert(cmd, "--profile")
        table.insert(cmd, aws_config.profile)
      end
      table.insert(cmd, "--region")
      table.insert(cmd, aws_config.region)

      local stdout = ""
      local stderr = ""
      
      local job_id = vim.fn.jobstart(cmd, {
        on_stdout = function(_, data)
          stdout = stdout .. table.concat(data, "\n")
        end,
        on_stderr = function(_, data)
          stderr = stderr .. table.concat(data, "\n")
        end,
        on_exit = function(_, code)
          untrack_job(job_id)
          vim.schedule(function()
            remaining_secrets = remaining_secrets - 1
            
            if code ~= 0 then
              failed_secrets = failed_secrets + 1
              if stderr:match("Could not connect to the endpoint URL") then
                vim.notify("AWS connectivity error for secret " .. secret_name .. ": Could not connect to AWS", vim.log.levels.ERROR)
              elseif stderr:match("AccessDenied") then
                vim.notify("Access denied for secret " .. secret_name .. ": Check your AWS credentials", vim.log.levels.ERROR)
              elseif stderr:match("ResourceNotFound") then
                vim.notify("Secret not found: " .. secret_name, vim.log.levels.ERROR)
              else
                vim.notify("Error fetching secret " .. secret_name .. ": " .. stderr, vim.log.levels.ERROR)
              end
            else
              local secret_value = stdout:gsub("^%s*(.-)%s*$", "%1")

              if secret_value ~= "" then
                if secret_value:match("^{") then
                  local ok, parsed_secret = pcall(vim.json.decode, secret_value)
                  if ok and type(parsed_secret) == "table" then
                    for key, value in pairs(parsed_secret) do
                      if not aws_config.filter or aws_config.filter(key, value) then
                        if aws_config.transform then
                          value = aws_config.transform(key, value)
                        end

                        local type_name, transformed_value = types.detect_type(value)

                        aws_secrets[key] = {
                          value = transformed_value or value,
                          type = type_name,
                          raw_value = value,
                          source = "asm:" .. secret_name,
                          comment = nil,
                        }
                        loaded_secrets = loaded_secrets + 1
                      end
                    end
                  else
                    vim.notify("Failed to parse JSON secret from " .. secret_name, vim.log.levels.WARN)
                    failed_secrets = failed_secrets + 1
                  end
                else
                  local key = secret_name:match("[^/]+$")
                  if not aws_config.filter or aws_config.filter(key, secret_value) then
                    if aws_config.transform then
                      secret_value = aws_config.transform(key, secret_value)
                    end

                    local type_name, transformed_value = types.detect_type(secret_value)

                    aws_secrets[key] = {
                      value = transformed_value or secret_value,
                      type = type_name,
                      raw_value = secret_value,
                      source = "asm:" .. secret_name,
                      comment = nil,
                    }
                    loaded_secrets = loaded_secrets + 1
                  end
                end
              end
            end

            if remaining_secrets == 0 then
              if loaded_secrets > 0 or failed_secrets > 0 then
                local msg = string.format("AWS Secrets Manager: Loaded %d secret%s", 
                  loaded_secrets, 
                  loaded_secrets == 1 and "" or "s"
                )
                if failed_secrets > 0 then
                  msg = msg .. string.format(", %d failed", failed_secrets)
                end
                vim.notify(msg, failed_secrets > 0 and vim.log.levels.WARN or vim.log.levels.INFO)

                state.loaded_secrets = aws_secrets

                update_environment()
              end
            end
          end)
        end
      })
      if job_id > 0 then
        track_job(job_id)
      end
    end
  end)

  return state.loaded_secrets or {}
end

function M.update_env_vars(env_vars, override)
  local ecolog = require("ecolog")
  ecolog.refresh_env_vars()
end

function M.select()
  if not state.config then
    vim.notify("AWS Secrets Manager is not configured. Enable it in your setup first.", vim.log.levels.ERROR)
    return
  end

  if not state.config.region then
    vim.notify("AWS region is required for AWS Secrets Manager integration", vim.log.levels.ERROR)
    return
  end

  select_secrets({
    region = state.config.region,
    profile = state.config.profile
  })
end

return M