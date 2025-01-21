local M = {}

local api = vim.api
local fn = vim.fn
local notify = vim.notify

local function cleanup_watchers(state)
  if state.current_watcher_group then
    pcall(api.nvim_del_augroup_by_id, state.current_watcher_group)
  end
  for _, watcher in pairs(state._file_watchers) do
    pcall(api.nvim_del_autocmd, watcher)
  end
  state._file_watchers = {}
end

function M.setup_watcher(opts, state, refresh_callback)
  cleanup_watchers(state)

  state.current_watcher_group = api.nvim_create_augroup("EcologFileWatcher", { clear = true })

  local watch_patterns = {}
  local utils = require("ecolog.utils")

  if not opts.env_file_pattern then
    watch_patterns = {
      opts.path .. "/.env*",
    }
  else
    local patterns = type(opts.env_file_pattern) == "string" and { opts.env_file_pattern } or opts.env_file_pattern

    for _, pattern in ipairs(patterns) do
      local glob_pattern = pattern:gsub("^%^", ""):gsub("%$$", ""):gsub("%%.", "")
      table.insert(watch_patterns, opts.path .. glob_pattern:gsub("^%.%+/", "/"))
    end
  end

  local function handle_env_file_change()
    state.cached_env_files = nil
    state.last_opts = nil
    refresh_callback(opts)
  end

  table.insert(
    state._file_watchers,
    api.nvim_create_autocmd({ "BufNewFile", "BufAdd" }, {
      group = state.current_watcher_group,
      pattern = watch_patterns,
      callback = function(ev)
        local matches = utils.filter_env_files({ ev.file }, opts.env_file_pattern)
        if #matches > 0 then
          state.cached_env_files = nil
          state.last_opts = nil

          local env_files = utils.find_env_files(opts)
          if #env_files > 0 then
            state.selected_env_file = env_files[1]
            handle_env_file_change()
            notify("New environment file detected: " .. fn.fnamemodify(ev.file, ":t"), vim.log.levels.INFO)
          end
        end
      end,
    })
  )

  if state.selected_env_file then
    table.insert(
      state._file_watchers,
      api.nvim_create_autocmd({ "BufWritePost", "FileChangedShellPost" }, {
        group = state.current_watcher_group,
        pattern = state.selected_env_file,
        callback = function()
          handle_env_file_change()
          notify("Environment file updated: " .. fn.fnamemodify(state.selected_env_file, ":t"), vim.log.levels.INFO)
        end,
      })
    )
  end
end

return M 