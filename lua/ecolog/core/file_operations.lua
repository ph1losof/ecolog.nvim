---@class FileOperations
local FileOperations = {}

local NotificationManager = require("ecolog.core.notification_manager")

-- File modification time cache for intelligent invalidation
local _file_mtime_cache = {}
local MTIME_CACHE_DURATION = 30000 -- 30 seconds

---Check if a file is readable with caching
---@param file_path string Path to the file
---@return boolean readable Whether the file is readable
function FileOperations.is_readable(file_path)
  if not file_path or type(file_path) ~= "string" then
    return false
  end

  return vim.fn.filereadable(file_path) == 1
end

---Get file modification time with caching
---@param file_path string Path to the file
---@return number mtime Modification time (0 if file doesn't exist)
function FileOperations.get_mtime(file_path)
  local current_time = vim.loop.now()
  local cache_entry = _file_mtime_cache[file_path]

  -- Use cached value if recent
  if cache_entry and (current_time - cache_entry.cached_at) < MTIME_CACHE_DURATION then
    return cache_entry.mtime
  end

  local stat = vim.loop.fs_stat(file_path)
  local mtime = stat and stat.mtime.sec or 0

  -- Cache the result
  _file_mtime_cache[file_path] = {
    mtime = mtime,
    cached_at = current_time,
  }

  return mtime
end

---Check if file has been modified since last check
---@param file_path string Path to the file
---@param last_mtime number? Last known modification time
---@return boolean modified Whether the file has been modified
---@return number current_mtime Current modification time
function FileOperations.is_modified(file_path, last_mtime)
  local current_mtime = FileOperations.get_mtime(file_path)
  local modified = not last_mtime or current_mtime > last_mtime
  return modified, current_mtime
end

---Read file content synchronously with error handling
---@param file_path string Path to the file
---@return string[]? content File lines or nil on error
---@return string? error_msg Error message if read failed
function FileOperations.read_file_sync(file_path)
  if not FileOperations.is_readable(file_path) then
    return nil, "File is not readable: " .. file_path
  end

  local file_handle, open_err = io.open(file_path, "r")
  if not file_handle then
    return nil, "Could not open file: " .. tostring(open_err)
  end

  local content = {}
  local line_num = 1

  local success, err = pcall(function()
    for line in file_handle:lines() do
      content[line_num] = line
      line_num = line_num + 1
    end
  end)

  -- Always close the file
  local close_success = pcall(file_handle.close, file_handle)
  if not close_success then
    NotificationManager.notify("Failed to close file: " .. file_path, vim.log.levels.WARN)
  end

  if not success then
    return nil, "Error reading file: " .. tostring(err)
  end

  return content, nil
end

---Read file content asynchronously with callback
---@param file_path string Path to the file
---@param callback function Callback function(content, error)
function FileOperations.read_file_async(file_path, callback)
  if not callback or type(callback) ~= "function" then
    NotificationManager.notify("Invalid callback for async file read", vim.log.levels.ERROR)
    return
  end

  if not FileOperations.is_readable(file_path) then
    vim.schedule(function()
      callback(nil, "File is not readable: " .. file_path)
    end)
    return
  end

  vim.defer_fn(function()
    local success, content = pcall(vim.fn.readfile, file_path)

    vim.schedule(function()
      if success then
        callback(content, nil)
      else
        callback(nil, "Error reading file: " .. tostring(content))
      end
    end)
  end, 0)
end

---Batch read multiple files asynchronously
---@param file_paths string[] Array of file paths to read
---@param callback function Callback function(results, errors)
function FileOperations.read_files_batch(file_paths, callback)
  if not callback or type(callback) ~= "function" then
    NotificationManager.notify("Invalid callback for batch file read", vim.log.levels.ERROR)
    return
  end

  if not file_paths or #file_paths == 0 then
    vim.schedule(function()
      callback({}, {})
    end)
    return
  end

  local results = {}
  local errors = {}
  local completed = 0
  local total = #file_paths

  for _, file_path in ipairs(file_paths) do
    FileOperations.read_file_async(file_path, function(content, error)
      if content then
        results[file_path] = content
      else
        errors[file_path] = error
      end

      completed = completed + 1

      if completed == total then
        callback(results, errors)
      end
    end)
  end
end

---Check if multiple files exist in batch
---@param file_paths string[] Array of file paths to check
---@return table<string, boolean> readable_map Map of file_path to readable status
function FileOperations.check_files_batch(file_paths)
  local readable_map = {}

  for _, file_path in ipairs(file_paths) do
    readable_map[file_path] = FileOperations.is_readable(file_path)
  end

  return readable_map
end

---Get file statistics for multiple files
---@param file_paths string[] Array of file paths
---@return table<string, table> stats_map Map of file_path to stats
function FileOperations.get_files_stats(file_paths)
  local stats_map = {}

  for _, file_path in ipairs(file_paths) do
    local stat = vim.loop.fs_stat(file_path)
    if stat then
      stats_map[file_path] = {
        mtime = stat.mtime.sec,
        size = stat.size,
        type = stat.type,
        exists = true,
      }
    else
      stats_map[file_path] = {
        exists = false,
      }
    end
  end

  return stats_map
end

---Clear file modification time cache
---@param file_path string? Specific file to clear (optional, clears all if not provided)
function FileOperations.clear_mtime_cache(file_path)
  if file_path then
    _file_mtime_cache[file_path] = nil
  else
    _file_mtime_cache = {}
  end
end

---Get cache statistics
---@return table stats
function FileOperations.get_cache_stats()
  return {
    mtime_cache_size = vim.tbl_count(_file_mtime_cache),
    mtime_cache_duration = MTIME_CACHE_DURATION,
  }
end

---Handle file deletion with automatic fallback selection
---@param state table Current loader state
---@param config table Configuration options
---@param deleted_file string Path to the deleted file
---@return string? new_file Path to the new selected file (if any)
function FileOperations.handle_file_deletion(state, config, deleted_file)
  if not state or not config then
    return nil
  end

  local utils = require("ecolog.utils")
  local env_files = utils.find_env_files(config)

  -- Clear state
  state.env_vars = {}
  state._env_line_cache = {}

  if #env_files > 0 then
    local new_file = env_files[1]
    state.selected_env_file = new_file
    NotificationManager.notify_file_deleted(deleted_file, new_file, config)
    return new_file
  else
    state.selected_env_file = nil
    NotificationManager.notify_file_deleted(deleted_file, nil, config)
    return nil
  end
end

return FileOperations

