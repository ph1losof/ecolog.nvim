---@class TimerManager
local TimerManager = {}

-- Global timer registry for proper cleanup
local _active_timers = {}
local _debounce_timers = {}

---Create a managed timer that will be automatically cleaned up
---@param callback function The callback function to execute
---@param delay number Delay in milliseconds
---@param repeat_interval number? Repeat interval in milliseconds (optional)
---@return table timer The created timer object
function TimerManager.create_timer(callback, delay, repeat_interval)
  -- Validate inputs
  if not callback or type(callback) ~= "function" then
    vim.notify("Timer callback must be a function", vim.log.levels.ERROR)
    return nil
  end
  
  if not delay or type(delay) ~= "number" or delay < 0 then
    vim.notify("Timer delay must be a positive number", vim.log.levels.ERROR)
    return nil
  end
  
  local timer = vim.loop.new_timer()
  if not timer then
    vim.notify("Failed to create timer", vim.log.levels.ERROR)
    return nil
  end

  -- Store reference for cleanup
  _active_timers[timer] = true

  -- Wrap callback to handle cleanup on completion
  local wrapped_callback = function()
    local success, err = pcall(callback)
    if not success then
      vim.notify("Timer callback error: " .. tostring(err), vim.log.levels.ERROR)
    end

    -- Clean up single-shot timers
    if not repeat_interval then
      _active_timers[timer] = nil
    end
  end

  if repeat_interval then
    timer:start(delay, repeat_interval, vim.schedule_wrap(wrapped_callback))
  else
    timer:start(delay, 0, vim.schedule_wrap(wrapped_callback))
  end

  return timer
end

---Create a debounced timer that cancels previous calls
---@param timer_id string Unique identifier for the debounced timer
---@param callback function The callback function to execute
---@param delay number Delay in milliseconds
---@param ... any Arguments to pass to the callback
function TimerManager.debounce(timer_id, callback, delay, ...)
  local args = { ... }

  -- Cancel existing timer if present
  if _debounce_timers[timer_id] then
    TimerManager.cancel_timer(_debounce_timers[timer_id])
    _debounce_timers[timer_id] = nil
  end

  -- Create new debounced timer
  _debounce_timers[timer_id] = vim.fn.timer_start(delay, function()
    _debounce_timers[timer_id] = nil

    local success, err = pcall(callback, unpack(args))
    if not success then
      vim.notify("Debounced callback error: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end

---Cancel a specific timer
---@param timer table|number The timer object or timer ID
---@return boolean success Whether the timer was successfully cancelled
function TimerManager.cancel_timer(timer)
  if not timer then
    return false
  end

  local success = false

  if type(timer) == "number" then
    -- Handle vim timer ID
    success = pcall(vim.fn.timer_stop, timer)
  elseif type(timer) == "table" and timer.stop then
    -- Handle libuv timer
    success = pcall(timer.stop, timer)
    if success then
      _active_timers[timer] = nil
    end
  end

  return success
end

---Cancel all debounced timers
function TimerManager.cancel_all_debounced()
  for timer_id, timer in pairs(_debounce_timers) do
    TimerManager.cancel_timer(timer)
    _debounce_timers[timer_id] = nil
  end
  _debounce_timers = {}
end

---Cancel all managed timers
function TimerManager.cancel_all()
  -- Cancel debounced timers
  TimerManager.cancel_all_debounced()

  -- Cancel libuv timers
  for timer in pairs(_active_timers) do
    TimerManager.cancel_timer(timer)
  end
  _active_timers = {}
end

---Get active timer statistics
---@return table stats
function TimerManager.get_stats()
  return {
    active_timers = vim.tbl_count(_active_timers),
    debounce_timers = vim.tbl_count(_debounce_timers),
  }
end

return TimerManager

