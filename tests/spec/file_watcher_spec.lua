local assert = require("luassert")
local stub = require("luassert.stub")
local spy = require("luassert.spy")
local match = require("luassert.match")

describe("file_watcher", function()
  local file_watcher
  local test_dir
  local mock_utils
  local mock_timer_manager
  local mock_notification_manager
  local mock_file_operations
  local api = vim.api

  local function create_test_file(path, content)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local file = io.open(path, "w")
    if file then
      file:write(content or "test content")
      file:close()
    end
  end

  local function cleanup_test_files(path)
    vim.fn.delete(path, "rf")
  end

  before_each(function()
    -- Reset modules
    package.loaded["ecolog.file_watcher"] = nil
    package.loaded["ecolog.utils"] = nil
    package.loaded["ecolog.core.timer_manager"] = nil
    package.loaded["ecolog.core.notification_manager"] = nil
    package.loaded["ecolog.core.file_operations"] = nil

    test_dir = vim.fn.tempname()
    vim.fn.mkdir(test_dir, "p")

    -- Mock utils
    mock_utils = {
      get_watch_patterns = spy.new(function(config)
        return { test_dir .. "/.env*" }
      end),
      find_env_files = spy.new(function(config)
        return { test_dir .. "/.env" }
      end),
      filter_env_files = spy.new(function(files, patterns)
        return files
      end)
    }
    package.preload["ecolog.utils"] = function()
      return mock_utils
    end

    -- Mock timer manager
    mock_timer_manager = {
      debounce = spy.new(function(id, fn, delay) vim.schedule(fn) end),
      cancel_all = spy.new(function() end),
      cancel_timer = spy.new(function() end),
      create_timer = spy.new(function(fn, delay, repeat_delay)
        local timer = {}
        vim.defer_fn(fn, delay)
        return timer
      end)
    }
    package.preload["ecolog.core.timer_manager"] = function()
      return mock_timer_manager
    end

    -- Mock notification manager
    mock_notification_manager = {
      notify = spy.new(function() end),
      notify_file_created = spy.new(function() end),
      notify_file_deleted = spy.new(function() end)
    }
    package.preload["ecolog.core.notification_manager"] = function()
      return mock_notification_manager
    end

    -- Mock file operations
    mock_file_operations = {
      get_files_stats = spy.new(function(files)
        local stats = {}
        for _, file in ipairs(files) do
          stats[file] = {
            exists = vim.fn.filereadable(file) == 1,
            mtime = vim.fn.getftime(file),
            size = 100,
            type = "file"
          }
        end
        return stats
      end),
      handle_file_deletion = spy.new(function(state, config, deleted_file)
        return nil
      end)
    }
    package.preload["ecolog.core.file_operations"] = function()
      return mock_file_operations
    end

    -- Mock vim.loop functions for LibUV tests
    if not vim.loop._original_new_fs_event then
      vim.loop._original_new_fs_event = vim.loop.new_fs_event
      vim.loop._original_now = vim.loop.now
    end

    -- Mock vim.loop.now to control time
    local mock_time = 1000000
    stub(vim.loop, "now", function()
      return mock_time
    end)

    -- Mock autocmd functions
    stub(api, "nvim_create_augroup").returns(1)
    stub(api, "nvim_create_autocmd").returns(100)
    stub(api, "nvim_del_autocmd")
    stub(api, "nvim_del_augroup_by_id")

    file_watcher = require("ecolog.file_watcher")
  end)

  after_each(function()
    cleanup_test_files(test_dir)

    -- Restore stubs
    api.nvim_create_augroup:revert()
    api.nvim_create_autocmd:revert()
    api.nvim_del_autocmd:revert()
    api.nvim_del_augroup_by_id:revert()
    vim.loop.now:revert()

    -- Clean up any remaining timers
    if mock_timer_manager.cancel_all then
      mock_timer_manager.cancel_all()
    end

    -- Clear preloaded modules
    package.preload["ecolog.utils"] = nil
    package.preload["ecolog.core.timer_manager"] = nil
    package.preload["ecolog.core.notification_manager"] = nil
    package.preload["ecolog.core.file_operations"] = nil
    
    -- Note: Individual test stubs are reverted in their own test blocks
    
    -- Force garbage collection
    collectgarbage("collect")
  end)

  describe("setup_watcher", function()
    it("should validate input parameters", function()
      local config = {}
      local state = {}
      local callback = function() end

      -- Test with nil parameters
      file_watcher.setup_watcher(nil, state, callback)
      file_watcher.setup_watcher(config, nil, callback)
      file_watcher.setup_watcher(config, state, nil)
      file_watcher.setup_watcher(config, state, "not a function")

      assert.spy(mock_notification_manager.notify).was.called(4)
    end)

    it("should clean up existing watchers", function()
      local config = { env_file_patterns = { "*.env" } }
      local state = {
        _file_watchers = { 1, 2 },
        current_watcher_group = 1,
        _libuv_fs_watcher = {},
        _monorepo_fs_timer = {}
      }
      local callback = function() end

      file_watcher.setup_watcher(config, state, callback)

      assert.spy(mock_timer_manager.cancel_all).was.called()
      assert.spy(api.nvim_del_autocmd).was.called(2) -- For the existing watchers
      assert.spy(api.nvim_del_augroup_by_id).was.called(1)
    end)

    it("should create augroup and autocmds", function()
      local config = { env_file_patterns = { "*.env" } }
      local state = {}
      local callback = function() end

      file_watcher.setup_watcher(config, state, callback)

      assert.spy(api.nvim_create_augroup).was.called()
      assert.spy(api.nvim_create_autocmd).was.called() -- Multiple calls for different events
      assert.spy(mock_utils.get_watch_patterns).was.called()
    end)

    it("should handle augroup creation failure", function()
      local config = { env_file_patterns = { "*.env" } }
      local state = {}
      local callback = function() end

      api.nvim_create_augroup:revert()
      stub(api, "nvim_create_augroup", function()
        error("Failed to create augroup")
      end)

      file_watcher.setup_watcher(config, state, callback)

      assert.spy(mock_notification_manager.notify).was.called_with(
        match.is_string(),
        vim.log.levels.ERROR
      )
    end)

    it("should filter valid watch patterns", function()
      local test_env = test_dir .. "/.env"
      create_test_file(test_env, "TEST=value")

      local config = { env_file_patterns = { "*.env" } }
      local state = {}
      local callback = function() end

      -- Mock get_watch_patterns to return mix of existing and non-existing files
      mock_utils.get_watch_patterns = spy.new(function()
        return {
          test_dir .. "/.env",          -- exists
          test_dir .. "/.env.local",    -- doesn't exist
          test_dir .. "/.env*"          -- wildcard pattern
        }
      end)

      file_watcher.setup_watcher(config, state, callback)

      assert.spy(mock_utils.get_watch_patterns).was.called()
    end)

    it("should setup monorepo watchers when monorepo root exists", function()
      local config = {
        env_file_patterns = { "*.env" },
        _monorepo_root = test_dir
      }
      local state = {}
      local callback = function() end

      -- Mock LibUV fs_event
      local mock_fs_event = {
        start = spy.new(function() return true end),
        close = spy.new(function() end)
      }
      stub(vim.loop, "new_fs_event", function()
        return mock_fs_event
      end)

      file_watcher.setup_watcher(config, state, callback)

      -- Should set up monorepo filesystem watcher and libuv watcher
      assert.spy(mock_file_operations.get_files_stats).was.called()
      assert.spy(mock_timer_manager.create_timer).was.called()

      vim.loop.new_fs_event:revert()
    end)
  end)

  describe("filesystem event handling", function()
    it("should handle file creation events", function()
      local config = { env_file_patterns = { "*.env" } }
      local state = {}
      local callback_called = false
      local callback = function() callback_called = true end

      file_watcher.setup_watcher(config, state, callback)

      -- Simulate file creation event by calling the callback
      -- (In real usage, this would be triggered by vim autocmds)
      local create_callback = api.nvim_create_autocmd.calls[3].vals[2].callback
      create_callback({ file = test_dir .. "/.env" })

      vim.wait(100) -- Wait for debounced callback

      assert.is_true(callback_called)
      assert.spy(mock_utils.filter_env_files).was.called()
    end)

    it("should handle file write events", function()
      local config = { env_file_patterns = { "*.env" } }
      local state = {}
      local callback_called = false
      local callback = function() callback_called = true end

      file_watcher.setup_watcher(config, state, callback)

      -- Simulate write event
      local write_callback = api.nvim_create_autocmd.calls[1].vals[2].callback
      write_callback({ file = test_dir .. "/.env" })

      vim.wait(100) -- Wait for debounced callback

      assert.is_true(callback_called)
    end)

    it("should handle file deletion events", function()
      local config = { env_file_patterns = { "*.env" } }
      local state = { selected_env_file = test_dir .. "/.env" }
      local callback_called = false
      local callback = function() callback_called = true end

      file_watcher.setup_watcher(config, state, callback)

      -- Simulate deletion event
      local delete_callback = api.nvim_create_autocmd.calls[2].vals[2].callback
      delete_callback({ file = test_dir .. "/.env" })

      vim.wait(100) -- Wait for debounced callback

      assert.is_true(callback_called)
      assert.spy(mock_file_operations.handle_file_deletion).was.called_with(
        state, config, test_dir .. "/.env"
      )
    end)

    it("should detect file system changes on focus events", function()
      local config = { env_file_patterns = { "*.env" } }
      local state = {}
      local callback_called = false
      local callback = function() callback_called = true end

      file_watcher.setup_watcher(config, state, callback)

      -- Mock find_env_files to simulate file system changes
      mock_utils.find_env_files = spy.new(function()
        return { test_dir .. "/.env", test_dir .. "/.env.local" } -- Different from initial
      end)

      -- Initialize last_known_files with different content
      state._last_known_files = { test_dir .. "/.env" }

      -- Find the filesystem events autocmd (should be the last one created)
      local fs_callback
      for _, call in ipairs(api.nvim_create_autocmd.calls) do
        local events = call.vals[1]
        if type(events) == "table" and vim.tbl_contains(events, "FocusGained") then
          fs_callback = call.vals[2].callback
          break
        end
      end

      assert.is_not_nil(fs_callback)
      
      -- Simulate focus gained event (which triggers file system check)
      fs_callback({ event = "FocusGained" })

      vim.wait(200) -- Wait for scheduled callback

      assert.is_true(callback_called)
    end)
  end)

  describe("monorepo filesystem watcher", function()
    it("should setup periodic polling for monorepo", function()
      local config = {
        env_file_patterns = { "*.env" },
        _monorepo_root = test_dir
      }
      local state = {}
      local callback = function() end

      file_watcher._setup_monorepo_filesystem_watcher(config, state, callback)

      assert.spy(mock_file_operations.get_files_stats).was.called()
      assert.spy(mock_timer_manager.create_timer).was.called()
    end)

    it("should detect file changes via polling", function()
      local config = {
        env_file_patterns = { "*.env" },
        _monorepo_root = test_dir
      }
      local state = {}
      local callback_called = false
      local callback = function() callback_called = true end

      -- Mock get_files_stats to return different results on subsequent calls
      local call_count = 0
      mock_file_operations.get_files_stats = spy.new(function()
        call_count = call_count + 1
        if call_count == 1 then
          return {
            [test_dir .. "/.env"] = { exists = true, mtime = 1000 }
          }
        else
          return {
            [test_dir .. "/.env"] = { exists = true, mtime = 2000 } -- Modified
          }
        end
      end)

      file_watcher._setup_monorepo_filesystem_watcher(config, state, callback)

      -- Get the timer callback and execute it
      local timer_callback = mock_timer_manager.create_timer.calls[1].vals[1]
      timer_callback()

      vim.wait(100) -- Wait for scheduled callback

      assert.is_true(callback_called)
    end)

    it("should handle file additions and removals", function()
      local config = {
        env_file_patterns = { "*.env" },
        _monorepo_root = test_dir
      }
      local state = {}
      local callback_called = false
      local callback = function() callback_called = true end

      -- Mock get_files_stats to simulate file addition
      local call_count = 0
      mock_file_operations.get_files_stats = spy.new(function()
        call_count = call_count + 1
        if call_count == 1 then
          return {
            [test_dir .. "/.env"] = { exists = true, mtime = 1000 }
          }
        else
          return {
            [test_dir .. "/.env"] = { exists = true, mtime = 1000 },
            [test_dir .. "/.env.local"] = { exists = true, mtime = 1500 } -- Added
          }
        end
      end)

      file_watcher._setup_monorepo_filesystem_watcher(config, state, callback)

      -- Execute timer callback
      local timer_callback = mock_timer_manager.create_timer.calls[1].vals[1]
      timer_callback()

      vim.wait(100) -- Wait for scheduled callback

      assert.is_true(callback_called)
      assert.spy(mock_notification_manager.notify_file_created).was.called()
    end)
  end)

  describe("libuv filesystem watcher", function()
    it("should setup libuv watcher when available", function()
      local config = {
        env_file_patterns = { "*.env" },
        _monorepo_root = test_dir
      }
      local state = {}
      local callback = function() end

      -- Mock LibUV fs_event
      local mock_fs_event = {
        start = spy.new(function() return true end),
        close = spy.new(function() end)
      }
      stub(vim.loop, "new_fs_event", function()
        return mock_fs_event
      end)

      file_watcher._setup_libuv_filesystem_watcher(config, state, callback)

      assert.spy(vim.loop.new_fs_event).was.called()
      assert.spy(mock_fs_event.start).was.called()
      assert.is_not_nil(state._libuv_fs_watcher)

      vim.loop.new_fs_event:revert()
    end)

    it("should handle libuv not available", function()
      local config = {
        env_file_patterns = { "*.env" },
        _monorepo_root = test_dir
      }
      local state = {}
      local callback = function() end

      -- Mock LibUV not available
      stub(vim.loop, "new_fs_event", function()
        return nil
      end)

      file_watcher._setup_libuv_filesystem_watcher(config, state, callback)

      assert.spy(vim.loop.new_fs_event).was.called()
      assert.is_nil(state._libuv_fs_watcher)

      vim.loop.new_fs_event:revert()
    end)

    it("should handle filesystem events from libuv", function()
      local config = {
        env_file_patterns = { "*.env" },
        _monorepo_root = test_dir
      }
      local state = {}
      local callback_called = false
      local callback = function() callback_called = true end

      -- Mock LibUV fs_event
      local fs_change_callback
      local mock_fs_event = {
        start = spy.new(function(self, path, opts, cb)
          fs_change_callback = cb
          return true
        end),
        close = spy.new(function() end)
      }
      stub(vim.loop, "new_fs_event", function()
        return mock_fs_event
      end)

      file_watcher._setup_libuv_filesystem_watcher(config, state, callback)

      -- Simulate filesystem event
      assert.is_function(fs_change_callback)
      fs_change_callback(nil, ".env", {})

      vim.wait(100) -- Wait for scheduled callback

      assert.is_true(callback_called)

      vim.loop.new_fs_event:revert()
    end)
  end)

  describe("cache management", function()
    it("should clear monorepo cache when files change", function()
      local config = { _monorepo_root = test_dir }
      local state = {}

      -- Test the non-monorepo case first (should return early)
      file_watcher._clear_monorepo_cache({}, state)

      -- Mock monorepo module
      local mock_monorepo = {
        clear_cache = spy.new(function() end)
      }
      package.preload["ecolog.monorepo"] = function()
        return mock_monorepo
      end
      
      -- Reset all module caches to ensure fresh requires
      package.loaded["ecolog.monorepo"] = nil
      package.loaded["ecolog.file_watcher"] = nil
      package.loaded["ecolog.utils"] = nil
      package.loaded["ecolog.core.timer_manager"] = nil
      package.loaded["ecolog.core.notification_manager"] = nil
      package.loaded["ecolog.core.file_operations"] = nil
      
      local fresh_file_watcher = require("ecolog.file_watcher")

      fresh_file_watcher._clear_monorepo_cache(config, state)

      assert.spy(mock_monorepo.clear_cache).was.called()

      package.preload["ecolog.monorepo"] = nil
    end)

    it("should clear workspace resolver cache", function()
      local config = {
        _monorepo_root = test_dir,
        _workspace_info = { name = "test" },
        _detected_info = { provider = "turborepo" }
      }
      local state = {}

      -- Mock workspace resolver
      local mock_resolver = {
        clear_cache = spy.new(function() end)
      }
      package.preload["ecolog.monorepo.workspace.resolver"] = function()
        return mock_resolver
      end

      file_watcher._clear_monorepo_cache(config, state)

      assert.spy(mock_resolver.clear_cache).was.called_with(
        config._workspace_info,
        config._monorepo_root,
        config._detected_info.provider
      )

      package.preload["ecolog.monorepo.workspace.resolver"] = nil
    end)
  end)

  describe("error handling", function()
    it("should handle autocmd callback errors gracefully", function()
      local config = { env_file_patterns = { "*.env" } }
      local state = {}
      local callback = function() error("Test error") end

      file_watcher.setup_watcher(config, state, callback)

      -- Simulate callback error by triggering a write event
      local write_callback = api.nvim_create_autocmd.calls[1].vals[2].callback
      write_callback({ file = test_dir .. "/.env" })

      vim.wait(100) -- Wait for debounced callback

      assert.spy(mock_notification_manager.notify).was.called_with(
        match.matches("Debounced callback error"),
        vim.log.levels.ERROR
      )
    end)

    it("should handle timer callback errors", function()
      local config = {
        env_file_patterns = { "*.env" },
        _monorepo_root = test_dir
      }
      local state = {}
      local callback = function() end

      -- First call succeeds to set up initial state, second call fails
      local call_count = 0
      mock_file_operations.get_files_stats = spy.new(function()
        call_count = call_count + 1
        if call_count == 1 then
          return {} -- Initial call succeeds
        else
          error("Test file stats error") -- Subsequent calls fail
        end
      end)

      file_watcher._setup_monorepo_filesystem_watcher(config, state, callback)

      -- Execute timer callback (which should trigger the error)
      local timer_callback = mock_timer_manager.create_timer.calls[1].vals[1]
      timer_callback()

      vim.wait(100) -- Wait for error handling

      -- Should not crash and should log debug message
      assert.spy(mock_notification_manager.notify).was.called_with(
        match.matches("Monorepo filesystem watcher error"),
        vim.log.levels.DEBUG
      )
    end)
  end)
end)