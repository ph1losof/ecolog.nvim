---@class NotificationManager
local NotificationManager = {}

-- Compatibility layer for uv -> vim.uv migration
local uv = require("ecolog.core.compat").uv

-- Centralized notification cache and configuration
local _notification_cache = {}
local CACHE_DURATION = 2000 -- 2 seconds
local CACHE_CLEANUP_INTERVAL = 5000 -- 5 seconds

---Send a notification with deduplication
---@param message string The notification message
---@param level number? The log level (defaults to vim.log.levels.INFO)
---@param force boolean? Whether to force the notification even if duplicate
function NotificationManager.notify(message, level, force)
  level = level or vim.log.levels.INFO

  if not force then
    local cache_key = message .. tostring(level)
    local current_time = uv.now()

    -- Check for recent duplicate
    if _notification_cache[cache_key] and (current_time - _notification_cache[cache_key]) < CACHE_DURATION then
      return -- Skip duplicate
    end

    _notification_cache[cache_key] = current_time

    -- Clean up old cache entries
    NotificationManager._cleanup_cache(current_time)
  end

  vim.notify(message, level, { title = "Ecolog" })
end

---Send a notification only once per session (or until cache clears)
---@param message string The notification message
---@param level number? The log level
---@param opts table? Additional options
function NotificationManager.notify_once(message, level, opts)
  NotificationManager.notify(message, level, false)
end

---Send an info notification
---@param message string The notification message
---@param opts table? Additional options
function NotificationManager.info(message, opts)
  NotificationManager.notify(message, vim.log.levels.INFO, opts and opts.force)
end

---Send a warning notification
---@param message string The notification message
---@param opts table? Additional options
function NotificationManager.warn(message, opts)
  NotificationManager.notify(message, vim.log.levels.WARN, opts and opts.force)
end

---Send an error notification
---@param message string The notification message
---@param opts table? Additional options
function NotificationManager.error(message, opts)
  NotificationManager.notify(message, vim.log.levels.ERROR, opts and opts.force)
end

---Clean up expired cache entries
---@param current_time number? Current time (optional, will get current time if not provided)
function NotificationManager._cleanup_cache(current_time)
  current_time = current_time or uv.now()

  for key, time in pairs(_notification_cache) do
    if (current_time - time) > CACHE_CLEANUP_INTERVAL then
      _notification_cache[key] = nil
    end
  end
end

---Clear all notification cache
function NotificationManager.clear_cache()
  _notification_cache = {}
end

---Get cache statistics
---@return table stats
function NotificationManager.get_cache_stats()
  return {
    cache_size = vim.tbl_count(_notification_cache),
    cache_duration = CACHE_DURATION,
    cleanup_interval = CACHE_CLEANUP_INTERVAL,
  }
end

---Notify about file deletion with automatic fallback selection
---@param deleted_file string Path to the deleted file
---@param new_file string? Path to the new selected file (optional)
---@param opts table? Configuration options for display names
function NotificationManager.notify_file_deleted(deleted_file, new_file, opts)
  local utils = require("ecolog.utils")
  local deleted_display_name = utils.get_env_file_display_name(deleted_file, opts or {})

  if new_file then
    local new_display_name = utils.get_env_file_display_name(new_file, opts or {})
    NotificationManager.notify(
      string.format("Selected file '%s' was deleted. Switched to: %s", deleted_display_name, new_display_name),
      vim.log.levels.INFO
    )
  else
    NotificationManager.notify(
      string.format("Selected file '%s' was deleted. No environment files found.", deleted_display_name),
      vim.log.levels.WARN
    )
  end
end

---Notify about new file detection
---@param file_path string Path to the new file
function NotificationManager.notify_file_created(file_path)
  local file_name = vim.fn.fnamemodify(file_path, ":t")
  NotificationManager.notify(string.format("New environment file detected: %s", file_name), vim.log.levels.INFO)
end

---Notify about file loading errors
---@param file_path string Path to the file that failed to load
---@param error_msg string Error message
function NotificationManager.notify_file_error(file_path, error_msg)
  NotificationManager.notify(
    string.format("Environment file error [%s]: %s", vim.fn.fnamemodify(file_path, ":t"), error_msg),
    vim.log.levels.ERROR
  )
end

return NotificationManager

