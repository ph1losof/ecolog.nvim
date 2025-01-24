local M = {}

local api = vim.api
local fn = vim.fn

---@param state table
local function cleanup_watchers(state)
  if state.current_watcher_group then
    pcall(api.nvim_del_augroup_by_id, state.current_watcher_group)
  end
  for _, watcher in pairs(state._file_watchers) do
    pcall(api.nvim_del_autocmd, watcher)
  end
  state._file_watchers = {}
end

---@param config table
---@param state table
---@param refresh_callback function
function M.setup_watcher(config, state, refresh_callback)
  cleanup_watchers(state)

  state.current_watcher_group = api.nvim_create_augroup("EcologFileWatcher", { clear = true })

  local watch_patterns = {}

  if not config.env_file_pattern then
    watch_patterns = {
      config.path .. "/.env*",
    }
  else
    local patterns = type(config.env_file_pattern) == "string" and { config.env_file_pattern }
      or config.env_file_pattern

    for _, pattern in ipairs(patterns) do
      local glob_pattern = pattern:gsub("^%^", ""):gsub("%$$", ""):gsub("%%.", "")
      table.insert(watch_patterns, config.path .. glob_pattern:gsub("^%.%+/", "/"))
    end
  end

  table.insert(
    state._file_watchers,
    api.nvim_create_autocmd({ "BufWritePost", "FileChangedShellPost" }, {
      group = state.current_watcher_group,
      pattern = watch_patterns,
      callback = function(ev)
        state.cached_env_files = nil
        state.file_cache_opts = nil
        state._env_line_cache = {}
        refresh_callback(config)
      end,
    })
  )

  table.insert(
    state._file_watchers,
    api.nvim_create_autocmd({ "BufDelete", "BufUnload" }, {
      group = state.current_watcher_group,
      pattern = watch_patterns,
      callback = function(ev)
        if fn.filereadable(ev.file) == 0 then
          state.cached_env_files = nil
          state.file_cache_opts = nil
          state._env_line_cache = {}
          if state.selected_env_file == ev.file then
            state.selected_env_file = nil
            state.env_vars = {}
          end
          refresh_callback(config)
        end
      end,
    })
  )

  table.insert(
    state._file_watchers,
    api.nvim_create_autocmd({ "BufNewFile", "BufAdd", "BufReadPost" }, {
      group = state.current_watcher_group,
      pattern = watch_patterns,
      callback = function(ev)
        local utils = require("ecolog.utils")
        local matches = utils.filter_env_files({ ev.file }, config.env_file_pattern)
        if #matches > 0 then
          state.cached_env_files = nil
          state.file_cache_opts = nil
          state._env_line_cache = {}

          local env_files = utils.find_env_files(config)
          if #env_files > 0 then
            state.selected_env_file = env_files[1]
            refresh_callback(config)
          end
        end
      end,
    })
  )

  table.insert(
    state._file_watchers,
    api.nvim_create_autocmd({ "FileChangedShellPost" }, {
      group = state.current_watcher_group,
      pattern = watch_patterns,
      callback = function(ev)
        state.cached_env_files = nil
        state.file_cache_opts = nil
        state._env_line_cache = {}
        refresh_callback(config)
      end,
    })
  )
end

return M

