---@class AutoSwitchThrottle
local Throttle = {}

-- Compatibility layer for uv -> vim.uv migration
local uv = vim.uv or uv

-- Throttle state
local _throttle_state = {
  last_check_time = 0,
  last_file_path = "",
  last_workspace = nil,
  pending_timer = nil,
  check_count = 0,
  skip_count = 0,
  burst_count = 0,
  last_burst_time = 0,
}

-- Throttle configuration
local THROTTLE_CONFIG = {
  min_interval = 50, -- Reduced from 100ms for better responsiveness
  debounce_delay = 150, -- Reduced from 250ms for faster switching
  same_file_skip = true, -- Skip check if file hasn't changed
  workspace_boundary_only = true, -- Only check when crossing workspace boundaries
  max_checks_per_second = 15, -- Increased from 10 for better responsiveness
  burst_allowance = 3, -- Allow 3 rapid checks before throttling
}

---Check if auto-switch should be throttled
---@param file_path string Current file path
---@return boolean should_throttle Whether the check should be throttled
---@return string reason Reason for throttling (for debugging)
function Throttle.should_throttle(file_path)
  local now = uv.now()

  -- Reset burst count if enough time has passed
  if (now - _throttle_state.last_burst_time) > 1000 then
    _throttle_state.burst_count = 0
    _throttle_state.check_count = 0
  end

  -- Same file check (highest priority)
  if THROTTLE_CONFIG.same_file_skip and file_path == _throttle_state.last_file_path then
    _throttle_state.skip_count = _throttle_state.skip_count + 1
    return true, "same_file"
  end

  -- Workspace boundary check (early exit for same workspace)
  if THROTTLE_CONFIG.workspace_boundary_only and _throttle_state.last_workspace then
    if Throttle._is_same_workspace_boundary(file_path, _throttle_state.last_workspace) then
      _throttle_state.skip_count = _throttle_state.skip_count + 1
      return true, "same_workspace_boundary"
    end
  end

  -- Allow burst of rapid checks
  if _throttle_state.burst_count < THROTTLE_CONFIG.burst_allowance then
    _throttle_state.burst_count = _throttle_state.burst_count + 1
    _throttle_state.last_burst_time = now
    return false, "burst_allowed"
  end

  -- Rate limiting check after burst
  if _throttle_state.check_count >= THROTTLE_CONFIG.max_checks_per_second then
    _throttle_state.skip_count = _throttle_state.skip_count + 1
    return true, "rate_limit_exceeded"
  end

  -- Minimum interval check
  if (now - _throttle_state.last_check_time) < THROTTLE_CONFIG.min_interval then
    _throttle_state.skip_count = _throttle_state.skip_count + 1
    return true, "min_interval"
  end

  return false, "not_throttled"
end

---Check if file is within the same workspace boundary
---@param file_path string Current file path
---@param last_workspace table Last known workspace
---@return boolean same_boundary Whether file is in same workspace boundary
function Throttle._is_same_workspace_boundary(file_path, last_workspace)
  if not file_path or not last_workspace or not last_workspace.path then
    return false
  end

  local workspace_path = last_workspace.path .. "/"
  return file_path:sub(1, #workspace_path) == workspace_path
end

---Execute auto-switch check with debouncing
---@param file_path string Current file path
---@param check_function function Function to execute for the check
function Throttle.debounced_check(file_path, check_function)
  -- Cancel pending timer if exists
  if _throttle_state.pending_timer then
    _throttle_state.pending_timer:stop()
    _throttle_state.pending_timer:close()
    _throttle_state.pending_timer = nil
  end

  -- Create new debounced timer
  _throttle_state.pending_timer = uv.new_timer()
  _throttle_state.pending_timer:start(
    THROTTLE_CONFIG.debounce_delay,
    0,
    vim.schedule_wrap(function()
      -- Clean up timer
      if _throttle_state.pending_timer then
        _throttle_state.pending_timer:close()
        _throttle_state.pending_timer = nil
      end

      -- Check if we should still proceed (file might have changed again)
      local current_file = vim.api.nvim_buf_get_name(0)
      if current_file == file_path then
        local should_throttle, reason = Throttle.should_throttle(file_path)
        if not should_throttle then
          Throttle._update_state(file_path)
          check_function()
        end
      end
    end)
  )
end

---Update throttle state after a check
---@param file_path string Current file path
---@param workspace? table Current workspace (optional)
function Throttle._update_state(file_path, workspace)
  local now = uv.now()

  _throttle_state.last_check_time = now
  _throttle_state.last_file_path = file_path
  _throttle_state.last_workspace = workspace
  _throttle_state.check_count = _throttle_state.check_count + 1
end

---Update workspace state (called when workspace changes)
---@param workspace table? New current workspace
function Throttle.update_workspace(workspace)
  _throttle_state.last_workspace = workspace
end

---Get throttle statistics
---@return table stats Throttle performance statistics
function Throttle.get_stats()
  local total_events = _throttle_state.check_count + _throttle_state.skip_count
  local throttle_rate = 0
  if total_events > 0 then
    throttle_rate = _throttle_state.skip_count / total_events
  end

  return {
    total_checks = _throttle_state.check_count,
    total_skips = _throttle_state.skip_count,
    throttle_rate = throttle_rate,
    last_check_time = _throttle_state.last_check_time,
    has_pending_timer = _throttle_state.pending_timer ~= nil,
    config = THROTTLE_CONFIG,
  }
end

---Configure throttle settings
---@param config table Throttle configuration options
function Throttle.configure(config)
  if config.min_interval then
    THROTTLE_CONFIG.min_interval = config.min_interval
  end
  if config.debounce_delay then
    THROTTLE_CONFIG.debounce_delay = config.debounce_delay
  end
  if config.same_file_skip ~= nil then
    THROTTLE_CONFIG.same_file_skip = config.same_file_skip
  end
  if config.workspace_boundary_only ~= nil then
    THROTTLE_CONFIG.workspace_boundary_only = config.workspace_boundary_only
  end
  if config.max_checks_per_second then
    THROTTLE_CONFIG.max_checks_per_second = config.max_checks_per_second
  end
  if config.burst_allowance then
    THROTTLE_CONFIG.burst_allowance = config.burst_allowance
  end
end

---Reset throttle state
function Throttle.reset()
  -- Cancel pending timer
  if _throttle_state.pending_timer then
    _throttle_state.pending_timer:stop()
    _throttle_state.pending_timer:close()
    _throttle_state.pending_timer = nil
  end

  _throttle_state = {
    last_check_time = 0,
    last_file_path = "",
    last_workspace = nil,
    pending_timer = nil,
    check_count = 0,
    skip_count = 0,
    burst_count = 0,
    last_burst_time = 0,
  }
end

---Check if auto-switch is currently active/enabled
---@return boolean active Whether auto-switch is active
function Throttle.is_active()
  return _throttle_state.pending_timer ~= nil
    or (_throttle_state.check_count > 0 and (uv.now() - _throttle_state.last_check_time) < 5000)
end

return Throttle

