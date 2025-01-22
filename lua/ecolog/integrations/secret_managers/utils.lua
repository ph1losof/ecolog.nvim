local M = {}

local api = vim.api
local utils = require("ecolog.utils")
local ecolog = require("ecolog")

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

-- Constants
local BUFFER_UPDATE_DEBOUNCE_MS = 50

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
  local final_vars = override and {} or vim.deepcopy(secrets or {})

  local keep_vars = {}
  for k, v in pairs(final_vars) do
    if v.source and v.source:match("^" .. source_prefix) then
      keep_vars[k] = true
    end
  end

  local current_env = ecolog.get_env_vars() or {}
  for k, v in pairs(current_env) do
    if not (v.source and v.source:match("^" .. source_prefix)) or keep_vars[k] then
      final_vars[k] = v
    end
  end

  ecolog.refresh_env_vars()
  local ecolog_state = ecolog.get_state()
  ecolog_state.env_vars = final_vars

  for k, v in pairs(final_vars) do
    if type(v) == "table" and v.value then
      vim.env[k] = tostring(v.value)
    else
      vim.env[k] = tostring(v)
    end
  end
end

---Create a secret selection UI
---@param secrets string[] List of available secrets
---@param selected table<string, boolean> Currently selected secrets
---@param on_select function Callback when selection is confirmed
---@param source_prefix string The prefix to identify the source of secrets
function M.create_secret_selection_ui(secrets, selected, on_select, source_prefix)
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

return M 