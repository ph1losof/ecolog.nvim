local M = {}

local api = vim.api
local fn = vim.fn
local utils = require("ecolog.utils")
local TimerManager = require("ecolog.core.timer_manager")
local NotificationManager = require("ecolog.core.notification_manager")
local FileOperations = require("ecolog.core.file_operations")

-- Adaptive debouncing configuration
local DEBOUNCE_DELAY = 250 -- milliseconds (reduced for better responsiveness)
local MONOREPO_POLL_INTERVAL = 1000 -- milliseconds (adaptive polling)
local _last_activity_time = 0
local _activity_threshold = 5000 -- 5 seconds

-- Track activity for adaptive polling
local function update_activity()
  _last_activity_time = vim.loop.now()
end

-- Get adaptive polling interval based on recent activity
local function get_adaptive_poll_interval()
  local time_since_activity = vim.loop.now() - _last_activity_time
  if time_since_activity < _activity_threshold then
    return MONOREPO_POLL_INTERVAL -- Active period: poll more frequently
  else
    return MONOREPO_POLL_INTERVAL * 2 -- Quiet period: poll less frequently
  end
end

-- Debounced callback wrapper using TimerManager
local function debounced_callback(callback_id, callback_fn, config)
  update_activity()

  TimerManager.debounce(callback_id, function()
    local success, err = pcall(callback_fn, config)
    if not success then
      NotificationManager.notify("Debounced callback error: " .. tostring(err), vim.log.levels.ERROR)
    end
  end, DEBOUNCE_DELAY)
end

---Clean up all watchers and timers
---@param state table
local function cleanup_watchers(state)
  if not state then
    return
  end

  -- Clean up all timers using TimerManager
  TimerManager.cancel_all()

  -- Clean up libuv filesystem watcher
  if state._libuv_fs_watcher then
    TimerManager.cancel_timer(state._libuv_fs_watcher)
    state._libuv_fs_watcher = nil
  end

  -- Clean up monorepo filesystem timer
  if state._monorepo_fs_timer then
    TimerManager.cancel_timer(state._monorepo_fs_timer)
    state._monorepo_fs_timer = nil
  end

  -- Clean up file tracking state
  state._last_env_files_set = nil
  state._last_known_files = nil
  state._file_stats_cache = nil

  -- Clean up autocmds
  if state._file_watchers then
    for _, watcher in pairs(state._file_watchers) do
      if watcher and type(watcher) == "number" then
        local success, err = pcall(api.nvim_del_autocmd, watcher)
        if not success then
          NotificationManager.notify("Failed to delete autocmd: " .. tostring(err), vim.log.levels.WARN)
        end
      end
    end
    state._file_watchers = {}
  end

  -- Clean up augroup
  if state.current_watcher_group then
    local success, err = pcall(api.nvim_del_augroup_by_id, state.current_watcher_group)
    if not success then
      NotificationManager.notify("Failed to delete augroup: " .. tostring(err), vim.log.levels.WARN)
    end
    state.current_watcher_group = nil
  end
end

---@param config table
---@param state table
---@param refresh_callback function
function M.setup_watcher(config, state, refresh_callback)
  -- Validate inputs
  if not config or not state or not refresh_callback then
    NotificationManager.notify("Invalid parameters passed to setup_watcher", vim.log.levels.ERROR)
    return
  end

  if type(refresh_callback) ~= "function" then
    NotificationManager.notify("refresh_callback must be a function", vim.log.levels.ERROR)
    return
  end

  -- Clean up existing watchers
  cleanup_watchers(state)

  -- Initialize state if needed
  if not state._file_watchers then
    state._file_watchers = {}
  end

  -- Create augroup with error handling
  local success, augroup = pcall(api.nvim_create_augroup, "EcologFileWatcher", { clear = true })
  if not success then
    NotificationManager.notify("Failed to create augroup: " .. tostring(augroup), vim.log.levels.ERROR)
    return
  end
  state.current_watcher_group = augroup

  local watch_patterns = utils.get_watch_patterns(config)
  if not watch_patterns or #watch_patterns == 0 then
    NotificationManager.notify("No watch patterns found", vim.log.levels.WARN)
    return
  end

  -- Filter patterns to only watch files that exist or could exist
  local valid_patterns = {}
  for i = 1, #watch_patterns do
    local pattern = watch_patterns[i]
    if pattern:find("*") then
      -- Wildcard pattern - keep as is
      valid_patterns[#valid_patterns + 1] = pattern
    else
      -- Exact file path - only add if file exists
      if vim.fn.filereadable(pattern) == 1 then
        valid_patterns[#valid_patterns + 1] = pattern
      end
    end
  end

  if #valid_patterns == 0 then
    -- If no valid patterns, fall back to basic .env pattern
    valid_patterns = { vim.fn.getcwd() .. "/.env*" }
  end

  watch_patterns = valid_patterns

  -- Create autocmd for file changes with error handling
  local function create_safe_callback(callback_fn)
    return function(ev)
      local success, err = pcall(callback_fn, ev)
      if not success then
        NotificationManager.notify("File watcher callback error: " .. tostring(err), vim.log.levels.ERROR)
      end
    end
  end

  -- File write/change watcher with debouncing
  local write_success, write_autocmd = pcall(
    api.nvim_create_autocmd,
    { "BufWritePost", "FileChangedShellPost", "FileChangedShell" },
    {
      group = state.current_watcher_group,
      pattern = watch_patterns,
      callback = create_safe_callback(function(ev)
        state.cached_env_files = nil
        state.file_cache_opts = nil
        state._env_line_cache = {}

        -- Clear monorepo cache if in monorepo mode
        if config._monorepo_root then
          M._clear_monorepo_cache(config, state)
        end

        -- Use debounced callback to prevent rapid-fire updates
        debounced_callback("write_change", refresh_callback, config)
      end),
    }
  )

  if write_success then
    table.insert(state._file_watchers, write_autocmd)
  else
    NotificationManager.notify("Failed to create write watcher: " .. tostring(write_autocmd), vim.log.levels.ERROR)
  end

  -- File delete/unload watcher with debouncing
  local delete_success, delete_autocmd = pcall(api.nvim_create_autocmd, { "BufDelete", "BufUnload" }, {
    group = state.current_watcher_group,
    pattern = watch_patterns,
    callback = create_safe_callback(function(ev)
      if ev.file and fn.filereadable(ev.file) == 0 then
        state.cached_env_files = nil
        state.file_cache_opts = nil
        state._env_line_cache = {}

        -- Clear monorepo cache if in monorepo mode
        if config._monorepo_root then
          M._clear_monorepo_cache(config, state)
        end

        if state.selected_env_file == ev.file then
          FileOperations.handle_file_deletion(state, config, ev.file)
        end

        -- Use debounced callback to prevent rapid-fire updates
        debounced_callback("delete_unload", refresh_callback, config)
      end
    end),
  })

  if delete_success then
    table.insert(state._file_watchers, delete_autocmd)
  else
    NotificationManager.notify("Failed to create delete watcher: " .. tostring(delete_autocmd), vim.log.levels.ERROR)
  end

  -- File creation watcher with debouncing
  local create_success, create_autocmd = pcall(
    api.nvim_create_autocmd,
    { "BufNewFile", "BufAdd", "BufReadPost", "BufRead" },
    {
      group = state.current_watcher_group,
      pattern = watch_patterns,
      callback = create_safe_callback(function(ev)
        if not ev.file then
          return
        end

        local matches = utils.filter_env_files({ ev.file }, config.env_file_patterns)
        if #matches > 0 then
          state.cached_env_files = nil
          state.file_cache_opts = nil
          state._env_line_cache = {}

          -- Clear monorepo cache if in monorepo mode
          if config._monorepo_root then
            M._clear_monorepo_cache(config, state)
          end

          -- Only notify for buffer events if filesystem watcher is not active
          if not config._monorepo_root then
            NotificationManager.notify_file_created(ev.file)
          end

          -- Use debounced callback to prevent rapid-fire updates
          debounced_callback("create_add", refresh_callback, config)
        end
      end),
    }
  )

  if create_success then
    table.insert(state._file_watchers, create_autocmd)
  else
    NotificationManager.notify("Failed to create creation watcher: " .. tostring(create_autocmd), vim.log.levels.ERROR)
  end

  -- Add periodic file system check for monorepo environments
  if config._monorepo_root then
    M._setup_monorepo_filesystem_watcher(config, state, refresh_callback)
    M._setup_libuv_filesystem_watcher(config, state, refresh_callback)
  end

  -- Add aggressive filesystem event detection
  local fs_events = {
    "FocusGained",
    "CursorHold",
    "CursorHoldI",
    "CursorMoved",
    "CursorMovedI",
    "VimResume",
    "DirChanged",
    "ShellFilterPost",
    "ShellCmdPost",
    "TerminalOpen",
  }

  local fs_success, fs_autocmd = pcall(api.nvim_create_autocmd, fs_events, {
    group = state.current_watcher_group,
    callback = create_safe_callback(function(ev)
      -- Check if any env files have been created/deleted
      local current_files = utils.find_env_files(config)
      local last_files = state._last_known_files or {}

      -- Convert to sets for accurate comparison
      local current_set = {}
      for _, file in ipairs(current_files) do
        current_set[file] = true
      end

      local last_set = {}
      for _, file in ipairs(last_files) do
        last_set[file] = true
      end

      -- Check for any differences
      local files_changed = false
      for file in pairs(current_set) do
        if not last_set[file] then
          files_changed = true
          break
        end
      end

      if not files_changed then
        for file in pairs(last_set) do
          if not current_set[file] then
            files_changed = true
            break
          end
        end
      end

      if files_changed then
        state._last_known_files = current_files
        state.cached_env_files = nil
        state.file_cache_opts = nil
        state._env_line_cache = {}

        -- Clear monorepo cache if in monorepo mode
        if config._monorepo_root then
          M._clear_monorepo_cache(config, state)
        end

        -- Use immediate callback for real-time responsiveness
        vim.schedule(function()
          local success, err = pcall(refresh_callback, config)
          if not success then
            NotificationManager.notify("Immediate refresh error: " .. tostring(err), vim.log.levels.ERROR)
          end
        end)
      end
    end),
  })

  if fs_success then
    table.insert(state._file_watchers, fs_autocmd)
  end
end

---Clear monorepo-specific cache when files change
---@param config table
---@param state table
function M._clear_monorepo_cache(config, state)
  if not config._monorepo_root then
    return
  end

  local monorepo = require("ecolog.monorepo")
  if monorepo and monorepo.clear_cache then
    monorepo.clear_cache()
  end

  -- Clear workspace-specific cache if available
  if config._workspace_info then
    local EnvironmentResolver = require("ecolog.monorepo.workspace.resolver")
    if EnvironmentResolver and EnvironmentResolver.clear_cache then
      EnvironmentResolver.clear_cache(config._workspace_info, config._monorepo_root, config._detected_info.provider)
    end
  end
end

---Setup optimized filesystem watcher for monorepo environments
---@param config table
---@param state table
---@param refresh_callback function
function M._setup_monorepo_filesystem_watcher(config, state, refresh_callback)
  if not config._monorepo_root then
    return
  end

  -- Initialize file stats cache for intelligent change detection
  local current_files = utils.find_env_files(config)
  state._file_stats_cache = FileOperations.get_files_stats(current_files)

  -- Create adaptive polling timer
  local function create_poll_timer()
    local interval = get_adaptive_poll_interval()

    state._monorepo_fs_timer = TimerManager.create_timer(function()
      if not state._monorepo_fs_timer then
        return -- Timer was cancelled
      end

      local success, err = pcall(function()
        local current_files = utils.find_env_files(config)
        local current_stats = FileOperations.get_files_stats(current_files)
        local last_stats = state._file_stats_cache or {}

        local files_added = {}
        local files_removed = {}
        local files_modified = {}

        -- Detect changes using file stats
        for file, stats in pairs(current_stats) do
          if not last_stats[file] then
            if stats.exists then
              table.insert(files_added, file)
            end
          elseif stats.exists and last_stats[file].exists then
            if stats.mtime > last_stats[file].mtime then
              table.insert(files_modified, file)
            end
          end
        end

        -- Check for removed files
        for file, stats in pairs(last_stats) do
          if stats.exists and (not current_stats[file] or not current_stats[file].exists) then
            table.insert(files_removed, file)
          end
        end

        -- If there are changes, update state and trigger refresh
        if #files_added > 0 or #files_removed > 0 or #files_modified > 0 then
          update_activity()
          state._file_stats_cache = current_stats
          state.cached_env_files = nil
          state.file_cache_opts = nil
          state._env_line_cache = {}

          M._clear_monorepo_cache(config, state)

          -- Handle deleted files
          for _, removed_file in ipairs(files_removed) do
            if state.selected_env_file == removed_file then
              FileOperations.handle_file_deletion(state, config, removed_file)
            end
          end

          -- Notify about new files (only if we have a previous state)
          if next(last_stats) then
            for _, added_file in ipairs(files_added) do
              NotificationManager.notify_file_created(added_file)
            end
          end

          -- Trigger refresh
          vim.schedule(function()
            local success, err = pcall(refresh_callback, config)
            if not success then
              NotificationManager.notify("Monorepo filesystem refresh error: " .. tostring(err), vim.log.levels.ERROR)
            end
          end)

          -- Recreate timer with new adaptive interval
          TimerManager.cancel_timer(state._monorepo_fs_timer)
          vim.defer_fn(create_poll_timer, 100)
        end
      end)

      if not success then
        NotificationManager.notify("Monorepo filesystem watcher error: " .. tostring(err), vim.log.levels.DEBUG)
      end
    end, interval, interval)
  end

  create_poll_timer()
end

---Setup LibUV filesystem watcher for real-time file detection
---@param config table
---@param state table
---@param refresh_callback function
function M._setup_libuv_filesystem_watcher(config, state, refresh_callback)
  if not config._monorepo_root or not vim.loop then
    return
  end

  -- Watch the monorepo root directory
  local success, fs_event = pcall(vim.loop.new_fs_event)
  if not success or not fs_event then
    return -- libuv filesystem watching not available
  end

  state._libuv_fs_watcher = fs_event

  local function on_change(err, filename, events)
    if err then
      return
    end

    -- Schedule callback to avoid fast event context restrictions
    vim.schedule(function()
      -- Check if the changed file matches our env patterns
      if filename then
        local full_path = config._monorepo_root .. "/" .. filename
        local success, matches = pcall(utils.filter_env_files, { full_path }, config.env_file_patterns)

        if success and #matches > 0 then
          update_activity()

          -- An env file was changed, trigger immediate refresh
          state.cached_env_files = nil
          state.file_cache_opts = nil
          state._env_line_cache = {}

          -- Clear file stats cache for the changed file
          if state._file_stats_cache then
            state._file_stats_cache[full_path] = nil
          end

          M._clear_monorepo_cache(config, state)

          local refresh_success, refresh_err = pcall(refresh_callback, config)
          if not refresh_success then
            NotificationManager.notify(
              "LibUV filesystem refresh error: " .. tostring(refresh_err),
              vim.log.levels.ERROR
            )
          end
        elseif not success then
          -- File pattern matching failed, but still trigger refresh for safety
          update_activity()

          state.cached_env_files = nil
          state.file_cache_opts = nil
          state._env_line_cache = {}

          M._clear_monorepo_cache(config, state)

          local refresh_success, refresh_err = pcall(refresh_callback, config)
          if not refresh_success then
            NotificationManager.notify(
              "LibUV filesystem refresh error: " .. tostring(refresh_err),
              vim.log.levels.ERROR
            )
          end
        end
      end
    end)
  end

  -- Start watching the monorepo root recursively
  local watch_success = pcall(fs_event.start, fs_event, config._monorepo_root, { recursive = true }, on_change)
  if not watch_success then
    fs_event:close()
    state._libuv_fs_watcher = nil
  end
end

-- Export notification manager for other modules
M.NotificationManager = NotificationManager

return M
