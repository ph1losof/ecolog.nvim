local M = {}

local api = vim.api
local fn = vim.fn
local utils = require("ecolog.utils")

-- Debouncing configuration
local DEBOUNCE_DELAY = 500 -- milliseconds (increased for better coordination)
local _debounce_timers = {}
local _notification_cache = {} -- Track recent notifications to prevent duplicates

-- Deduplicated notification helper
local function safe_notify(message, level)
  local cache_key = message .. (level or vim.log.levels.INFO)
  local current_time = vim.loop.now()
  
  -- Check if we've shown this notification recently (within 2 seconds)
  if _notification_cache[cache_key] and (current_time - _notification_cache[cache_key]) < 2000 then
    return -- Skip duplicate notification
  end
  
  _notification_cache[cache_key] = current_time
  vim.notify(message, level or vim.log.levels.INFO)
  
  -- Clean up old cache entries (older than 5 seconds)
  for key, time in pairs(_notification_cache) do
    if (current_time - time) > 5000 then
      _notification_cache[key] = nil
    end
  end
end

-- Debounced callback wrapper
local function debounced_callback(callback_id, callback_fn, config)
  -- Cancel existing timer if present
  if _debounce_timers[callback_id] then
    local success, err = pcall(vim.fn.timer_stop, _debounce_timers[callback_id])
    if not success then
      vim.notify("Failed to stop debounce timer: " .. tostring(err), vim.log.levels.WARN)
    end
    _debounce_timers[callback_id] = nil
  end

  -- Set up new timer
  _debounce_timers[callback_id] = vim.fn.timer_start(DEBOUNCE_DELAY, function()
    _debounce_timers[callback_id] = nil

    -- Execute the callback safely
    local success, err = pcall(callback_fn, config)
    if not success then
      vim.notify("Debounced callback error: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end

-- Cleanup debounce timers
local function cleanup_debounce_timers()
  for callback_id, timer_id in pairs(_debounce_timers) do
    local success, err = pcall(vim.fn.timer_stop, timer_id)
    if not success then
      vim.notify("Failed to stop debounce timer " .. callback_id .. ": " .. tostring(err), vim.log.levels.WARN)
    end
  end
  _debounce_timers = {}
  _notification_cache = {}
  _pending_refreshes = {}
end

---@param state table
local function cleanup_watchers(state)
  if not state then
    return
  end

  -- Clean up debounce timers first
  cleanup_debounce_timers()

  -- Clean up monorepo filesystem timer
  if state._monorepo_fs_timer then
    local success, err = pcall(state._monorepo_fs_timer.stop, state._monorepo_fs_timer)
    if not success then
      vim.notify("Failed to stop monorepo filesystem timer: " .. tostring(err), vim.log.levels.WARN)
    end
    state._monorepo_fs_timer = nil
  end
  
  -- Clean up libuv filesystem watcher
  if state._libuv_fs_watcher then
    local success, err = pcall(state._libuv_fs_watcher.close, state._libuv_fs_watcher)
    if not success then
      vim.notify("Failed to close libuv filesystem watcher: " .. tostring(err), vim.log.levels.WARN)
    end
    state._libuv_fs_watcher = nil
  end
  
  -- Clean up monorepo file tracking state
  state._last_env_files_set = nil
  state._last_known_files = nil

  -- Clean up autocmds
  if state._file_watchers then
    for _, watcher in pairs(state._file_watchers) do
      if watcher and type(watcher) == "number" then
        local success, err = pcall(api.nvim_del_autocmd, watcher)
        if not success then
          vim.notify("Failed to delete autocmd: " .. tostring(err), vim.log.levels.WARN)
        end
      end
    end
    state._file_watchers = {}
  end

  -- Clean up augroup last
  if state.current_watcher_group then
    local success, err = pcall(api.nvim_del_augroup_by_id, state.current_watcher_group)
    if not success then
      vim.notify("Failed to delete augroup: " .. tostring(err), vim.log.levels.WARN)
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
    vim.notify("Invalid parameters passed to setup_watcher", vim.log.levels.ERROR)
    return
  end

  if type(refresh_callback) ~= "function" then
    vim.notify("refresh_callback must be a function", vim.log.levels.ERROR)
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
    vim.notify("Failed to create augroup: " .. tostring(augroup), vim.log.levels.ERROR)
    return
  end
  state.current_watcher_group = augroup

  local watch_patterns = utils.get_watch_patterns(config)
  if not watch_patterns or #watch_patterns == 0 then
    vim.notify("No watch patterns found", vim.log.levels.WARN)
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
        vim.notify("File watcher callback error: " .. tostring(err), vim.log.levels.ERROR)
      end
    end
  end

  -- File write/change watcher with debouncing
  local write_success, write_autocmd = pcall(api.nvim_create_autocmd, { "BufWritePost", "FileChangedShellPost", "FileChangedShell" }, {
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
  })

  if write_success then
    table.insert(state._file_watchers, write_autocmd)
  else
    vim.notify("Failed to create write watcher: " .. tostring(write_autocmd), vim.log.levels.ERROR)
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
          -- Find a replacement file
          local env_files = utils.find_env_files(config)
          if #env_files > 0 then
            state.selected_env_file = env_files[1]
            vim.notify("Selected file was deleted. Switched to: " .. utils.get_env_file_display_name(env_files[1], config), vim.log.levels.INFO)
          else
            state.selected_env_file = nil
            state.env_vars = {}
            vim.notify("Selected file was deleted. No environment files found.", vim.log.levels.WARN)
          end
        end
        
        -- Use debounced callback to prevent rapid-fire updates
        debounced_callback("delete_unload", refresh_callback, config)
      end
    end),
  })

  if delete_success then
    table.insert(state._file_watchers, delete_autocmd)
  else
    vim.notify("Failed to create delete watcher: " .. tostring(delete_autocmd), vim.log.levels.ERROR)
  end

  -- File creation watcher with debouncing
  local create_success, create_autocmd = pcall(api.nvim_create_autocmd, { "BufNewFile", "BufAdd", "BufReadPost", "BufRead" }, {
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
          vim.notify("New environment file detected: " .. vim.fn.fnamemodify(ev.file, ":t"), vim.log.levels.INFO)
        end
        
        -- Use debounced callback to prevent rapid-fire updates
        debounced_callback("create_add", refresh_callback, config)
      end
    end),
  })

  if create_success then
    table.insert(state._file_watchers, create_autocmd)
  else
    vim.notify("Failed to create creation watcher: " .. tostring(create_autocmd), vim.log.levels.ERROR)
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
    "TerminalOpen"
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
            vim.notify("Immediate refresh error: " .. tostring(err), vim.log.levels.ERROR)
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

---Setup filesystem watcher for monorepo environments that can detect file changes
---outside of buffer events (e.g., file creation/deletion via external tools)
---@param config table
---@param state table
---@param refresh_callback function
function M._setup_monorepo_filesystem_watcher(config, state, refresh_callback)
  if not config._monorepo_root then
    return
  end
  
  -- Initialize file set for comparison
  local current_files = utils.find_env_files(config)
  state._last_env_files_set = {}
  for _, file in ipairs(current_files) do
    state._last_env_files_set[file] = true
  end
  
  -- Create a timer to periodically check for file changes
  local timer = vim.loop.new_timer()
  if not timer then
    return
  end
  
  state._monorepo_fs_timer = timer
  
  -- Check every 500ms for file changes (real-time responsiveness)
  timer:start(500, 500, vim.schedule_wrap(function()
    if not state._monorepo_fs_timer then
      return -- Timer was cancelled
    end
    
    local success, err = pcall(function()
      local current_files = utils.find_env_files(config)
      local last_files_set = state._last_env_files_set or {}
      
      -- Create current files set
      local current_files_set = {}
      for _, file in ipairs(current_files) do
        current_files_set[file] = true
      end
      
      -- Detect additions and deletions
      local files_added = {}
      local files_removed = {}
      
      -- Check for new files
      for file in pairs(current_files_set) do
        if not last_files_set[file] then
          table.insert(files_added, file)
        end
      end
      
      -- Check for removed files
      for file in pairs(last_files_set) do
        if not current_files_set[file] then
          table.insert(files_removed, file)
        end
      end
      
      -- If there are changes, update state and trigger refresh
      if #files_added > 0 or #files_removed > 0 then
        state._last_env_files_set = current_files_set
        state.cached_env_files = nil
        state.file_cache_opts = nil
        state._env_line_cache = {}
        
        M._clear_monorepo_cache(config, state)
        
        -- Handle deleted files (only notify for selected file)
        for _, removed_file in ipairs(files_removed) do
          if state.selected_env_file == removed_file then
            -- Select a new file if the current one was deleted
            if #current_files > 0 then
              state.selected_env_file = current_files[1]
              safe_notify("Selected file was deleted. Switched to: " .. vim.fn.fnamemodify(current_files[1], ":t"), vim.log.levels.INFO)
            else
              state.selected_env_file = nil
              state.env_vars = {}
              safe_notify("Selected file was deleted. No environment files found.", vim.log.levels.WARN)
            end
          end
        end
        
        -- Only notify about new files if there are actual additions (not on initial scan)
        if next(last_files_set) then -- Only if we have a previous state
          for _, added_file in ipairs(files_added) do
            safe_notify("New environment file detected: " .. vim.fn.fnamemodify(added_file, ":t"), vim.log.levels.INFO)
          end
        end
        
        -- Use immediate callback for real-time responsiveness
        vim.schedule(function()
          local success, err = pcall(refresh_callback, config)
          if not success then
            vim.notify("Monorepo filesystem refresh error: " .. tostring(err), vim.log.levels.ERROR)
          end
        end)
      end
    end)
    
    if not success then
      vim.notify("Monorepo filesystem watcher error: " .. tostring(err), vim.log.levels.DEBUG)
    end
  end))
end

---Setup libuv filesystem watcher for real-time file detection
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
          -- An env file was changed, trigger immediate refresh
          state.cached_env_files = nil
          state.file_cache_opts = nil
          state._env_line_cache = {}
          
          M._clear_monorepo_cache(config, state)
          
          local refresh_success, refresh_err = pcall(refresh_callback, config)
          if not refresh_success then
            vim.notify("LibUV filesystem refresh error: " .. tostring(refresh_err), vim.log.levels.ERROR)
          end
        elseif not success then
          -- File pattern matching failed, but still trigger refresh for safety
          state.cached_env_files = nil
          state.file_cache_opts = nil
          state._env_line_cache = {}
          
          M._clear_monorepo_cache(config, state)
          
          local refresh_success, refresh_err = pcall(refresh_callback, config)
          if not refresh_success then
            vim.notify("LibUV filesystem refresh error: " .. tostring(refresh_err), vim.log.levels.ERROR)
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

-- Export notification deduplication for other modules
M.safe_notify = safe_notify

return M
