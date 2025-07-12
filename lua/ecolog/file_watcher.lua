local M = {}

local api = vim.api
local fn = vim.fn
local utils = require("ecolog.utils")

-- Debouncing configuration
local DEBOUNCE_DELAY = 250 -- milliseconds
local _debounce_timers = {}
local _pending_refreshes = {}

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
  _pending_refreshes = {}
end

---@param state table
local function cleanup_watchers(state)
  if not state then
    return
  end
  
  -- Clean up debounce timers first
  cleanup_debounce_timers()
  
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
  local write_success, write_autocmd = pcall(api.nvim_create_autocmd, { "BufWritePost", "FileChangedShellPost" }, {
    group = state.current_watcher_group,
    pattern = watch_patterns,
    callback = create_safe_callback(function(ev)
      state.cached_env_files = nil
      state.file_cache_opts = nil
      state._env_line_cache = {}
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
        if state.selected_env_file == ev.file then
          state.selected_env_file = nil
          state.env_vars = {}
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
  local create_success, create_autocmd = pcall(api.nvim_create_autocmd, { "BufNewFile", "BufAdd", "BufReadPost" }, {
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

        local env_files = utils.find_env_files(config)
        if #env_files > 0 then
          state.selected_env_file = env_files[1]
          -- Use debounced callback to prevent rapid-fire updates
          debounced_callback("create_add", refresh_callback, config)
        end
      end
    end),
  })
  
  if create_success then
    table.insert(state._file_watchers, create_autocmd)
  else
    vim.notify("Failed to create creation watcher: " .. tostring(create_autocmd), vim.log.levels.ERROR)
  end
end

return M
