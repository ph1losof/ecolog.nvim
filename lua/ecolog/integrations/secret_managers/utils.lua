local M = {}

local api = vim.api
local utils = require("ecolog.utils")
local ecolog = require("ecolog")

M.BUFFER_UPDATE_DEBOUNCE_MS = 50
M.MAX_PARALLEL_REQUESTS = 5
M.REQUEST_DELAY_MS = 100
M.MAX_RETRIES = 3

---@class SecretManagerState
---@field selected_secrets string[] List of currently selected secret names
---@field config table|nil
---@field loading boolean
---@field loaded_secrets table<string, table>
---@field active_jobs table<number, boolean>
---@field is_refreshing boolean
---@field skip_load boolean
---@field loading_lock table|nil
---@field timeout_timer number|nil
---@field initialized boolean
---@field pending_env_updates function[]

---@class SecretError
---@field message string
---@field code string
---@field level number

---@class ProcessSecretOptions
---@field filter? fun(key: string, value: any): boolean Optional function to filter which secrets to load
---@field transform? fun(key: string, value: any): any Optional function to transform secret values
---@field source_prefix string The prefix to identify the source of secrets (e.g. "asm:", "vault:")
---@field source_path string The path or name of the secret

---Track a job for cleanup
---@param job_id number
---@param active_jobs table<number, boolean>
function M.track_job(job_id, active_jobs)
  if job_id > 0 then
    active_jobs[job_id] = true
    api.nvim_create_autocmd("VimLeave", {
      callback = function()
        if active_jobs[job_id] then
          if vim.fn.jobwait({ job_id }, 0)[1] == -1 then
            pcall(vim.fn.jobstop, job_id)
          end
          active_jobs[job_id] = nil
        end
      end,
      once = true,
    })
  end
end

---Untrack a job
---@param job_id number
---@param active_jobs table<number, boolean>
function M.untrack_job(job_id, active_jobs)
  if job_id then
    active_jobs[job_id] = nil
  end
end

---Cleanup jobs
---@param active_jobs table<number, boolean>
function M.cleanup_jobs(active_jobs)
  for job_id, _ in pairs(active_jobs) do
    if vim.fn.jobwait({ job_id }, 0)[1] == -1 then
      pcall(vim.fn.jobstop, job_id)
    end
  end
  active_jobs = {}
end

---Cleanup state
---@param state SecretManagerState
function M.cleanup_state(state)
  state.loading = false
  state.loading_lock = nil
  if state.timeout_timer then
    pcall(vim.fn.timer_stop, state.timeout_timer)
    state.timeout_timer = nil
  end
  M.cleanup_jobs(state.active_jobs)
end

---Update environment with loaded secrets
---@param secrets table<string, table>
---@param override boolean
---@param source_prefix string The prefix to identify the source of secrets (e.g. "asm:", "vault:")
function M.update_environment(secrets, override, source_prefix)
  local current_env = ecolog.get_env_vars() or {}
  local final_vars = {}

  if not override then
    for k, v in pairs(current_env) do
      if not (v.source and v.source:match("^" .. source_prefix)) then
        final_vars[k] = v
      end
    end
  end

  for k, v in pairs(secrets) do
    final_vars[k] = v
  end

  local ecolog_state = ecolog.get_state()
  ecolog_state.env_vars = final_vars

  for k, v in pairs(final_vars) do
    if type(v) == "table" and v.value then
      -- Use vim.env for faster access if available, fallback to vim.fn.setenv
      if vim.env then
        vim.env[k] = tostring(v.value)
      else
        vim.fn.setenv(k, tostring(v.value))
      end
    else
      if vim.env then
        vim.env[k] = tostring(v)
      else
        vim.fn.setenv(k, tostring(v))
      end
    end
  end
end

---Create a UI for selecting secrets
---@param secrets string[] List of secrets to select from
---@param selected table<string, boolean> Table of currently selected secrets
---@param on_select fun(selected: table<string, boolean>) Callback when selection is complete
---@param source_prefix string The prefix to identify the source of secrets (e.g. "asm:", "vault:")
function M.create_secret_selection_ui(secrets, selected, on_select, source_prefix)
  local cursor_idx = 1

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
    local content = get_content()
    vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
    api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
    vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

    api.nvim_buf_clear_namespace(bufnr, -1, 0, -1)
    for i = 1, #content do
      local hl_group = selected[secrets[i]] and "EcologVariable" or "EcologSelected"
      if i == cursor_idx then
        hl_group = "EcologCursor"
      end
      api.nvim_buf_add_highlight(bufnr, -1, hl_group, i - 1, 0, -1)
    end

    api.nvim_win_set_cursor(winid, { cursor_idx, 4 })
  end

  local float_opts = utils.create_minimal_win_opts(60, #secrets)
  local original_guicursor = vim.opt.guicursor:get()
  local bufnr = api.nvim_create_buf(false, true)

  vim.api.nvim_set_option_value("buftype", "nofile", { buf = bufnr })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = bufnr })
  vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
  vim.api.nvim_set_option_value("filetype", "ecolog", { buf = bufnr })

  api.nvim_buf_set_lines(bufnr, 0, -1, false, get_content())
  vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

  local winid = api.nvim_open_win(bufnr, true, float_opts)

  vim.api.nvim_set_option_value("conceallevel", 2, { win = winid })
  vim.api.nvim_set_option_value("concealcursor", "niv", { win = winid })
  vim.api.nvim_set_option_value("cursorline", true, { win = winid })
  vim.api.nvim_set_option_value("winhl", "Normal:EcologNormal,FloatBorder:EcologBorder", { win = winid })

  update_buffer(bufnr, winid)

  local function close_window()
    if api.nvim_win_is_valid(winid) then
      vim.opt.guicursor = original_guicursor
      api.nvim_win_close(winid, true)
    end
  end

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

  vim.keymap.set("n", "<CR>", function()
    close_window()
    on_select(selected)
  end, { buffer = bufnr, nowait = true })

  vim.keymap.set("n", "q", close_window, { buffer = bufnr, nowait = true })
  vim.keymap.set("n", "<ESC>", close_window, { buffer = bufnr, nowait = true })

  api.nvim_create_autocmd("BufLeave", {
    buffer = bufnr,
    once = true,
    callback = close_window,
  })
end

---Process a secret value and add it to secrets table
---@param secret_value string
---@param options ProcessSecretOptions
---@param secrets table<string, table>
---@return number loaded Number of secrets loaded
---@return number failed Number of secrets that failed to load
function M.process_secret_value(secret_value, options, secrets)
  local loaded, failed = 0, 0

  if secret_value == "" then
    return loaded, failed
  end

  if secret_value:match("^{") then
    local ok, parsed_secret = pcall(vim.json.decode, secret_value)
    if ok and type(parsed_secret) == "table" then
      for key, value in pairs(parsed_secret) do
        if not options.filter or options.filter(key, value) then
          local transformed_value = value
          if options.transform then
            local transform_ok, result = pcall(options.transform, key, value)
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
          secrets[key] = {
            value = detected_value or transformed_value,
            type = type_name,
            raw_value = value,
            source = options.source_prefix .. options.source_path,
            comment = nil,
          }
          loaded = loaded + 1
        end
      end
    else
      vim.notify(string.format("Failed to parse JSON secret from %s", options.source_path), vim.log.levels.WARN)
      failed = failed + 1
    end
  else
    local key = options.source_path:match("[^/]+$")
    if not options.filter or options.filter(key, secret_value) then
      local transformed_value = secret_value
      if options.transform then
        local transform_ok, result = pcall(options.transform, key, secret_value)
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
      secrets[key] = {
        value = detected_value or transformed_value,
        type = type_name,
        raw_value = secret_value,
        source = options.source_prefix .. options.source_path,
        comment = nil,
      }
      loaded = loaded + 1
    end
  end

  return loaded, failed
end

---Process secrets in parallel batches
---@param config table Configuration for the secret manager
---@param state SecretManagerState State of the secret manager
---@param secrets table<string, table> Table to store loaded secrets
---@param options table Additional options for processing
---@param start_job fun(index: number) Function to start a job for a specific index
function M.process_secrets_parallel(config, state, secrets, options, start_job)
  if not state.loading_lock then
    return
  end

  local total_secrets = #(config.secrets or config.paths)
  local active_jobs = 0
  local completed_jobs = 0
  local current_index = 1
  local loaded_secrets = 0
  local failed_secrets = 0
  local retry_counts = {}

  local function check_completion()
    if completed_jobs >= total_secrets then
      if loaded_secrets > 0 or failed_secrets > 0 then
        local msg = string.format(
          "%s: Loaded %d secret%s",
          options.manager_name,
          loaded_secrets,
          loaded_secrets == 1 and "" or "s"
        )
        if failed_secrets > 0 then
          msg = msg .. string.format(", %d failed", failed_secrets)
        end
        vim.notify(msg, failed_secrets > 0 and vim.log.levels.WARN or vim.log.levels.INFO)

        state.loaded_secrets = secrets
        state.initialized = true

        local updates_to_process = state.pending_env_updates
        state.pending_env_updates = {}

        M.update_environment(secrets, config.override, options.source_prefix)

        for _, update_fn in ipairs(updates_to_process) do
          update_fn()
        end

        M.cleanup_state(state)
      end
    end
  end

  local function start_next_job()
    if current_index <= total_secrets and active_jobs < M.MAX_PARALLEL_REQUESTS then
      active_jobs = active_jobs + 1
      start_job(current_index)
      current_index = current_index + 1

      if current_index <= total_secrets and active_jobs < M.MAX_PARALLEL_REQUESTS then
        vim.defer_fn(function()
          start_next_job()
        end, M.REQUEST_DELAY_MS)
      end
    end
  end

  for _ = 1, math.min(M.MAX_PARALLEL_REQUESTS, total_secrets) do
    start_next_job()
  end

  return {
    active_jobs = active_jobs,
    completed_jobs = completed_jobs,
    loaded_secrets = loaded_secrets,
    failed_secrets = failed_secrets,
    retry_counts = retry_counts,
    check_completion = check_completion,
  }
end

return M
