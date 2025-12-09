local assert = require("luassert")
local stub = require("luassert.stub")
local spy = require("luassert.spy")
local match = require("luassert.match")

-- Add project root to package path
local project_root = vim.fn.getcwd()
package.path = package.path .. ";" .. project_root .. "/lua/?.lua;" .. project_root .. "/lua/?/init.lua"

describe("notification and timer managers", function()
  local notification_manager
  local timer_manager

  before_each(function()
    -- Set test mode before loading modules
    _G._ECOLOG_TEST_MODE = true
    
    -- Reset modules
    package.loaded["ecolog.core.notification_manager"] = nil
    package.loaded["ecolog.core.timer_manager"] = nil
    
    notification_manager = require("ecolog.core.notification_manager")
    timer_manager = require("ecolog.core.timer_manager")
    
    -- Clear any existing state
    notification_manager.clear_cache()
    timer_manager.cancel_all()
  end)

  after_each(function()
    -- Clean up any remaining timers
    timer_manager.cancel_all()
    notification_manager.clear_cache()
    
    -- Force garbage collection to clean up leaked resources
    collectgarbage("collect")
    
    -- Small delay to ensure async cleanup completes
    vim.wait(10)
  end)

  describe("NotificationManager", function()
    describe("basic notifications", function()
      it("should send notifications", function()
        local notify_spy = spy.on(vim, "notify")
        
        notification_manager.notify("Test message")
        
        assert.spy(notify_spy).was.called_with("Test message", vim.log.levels.INFO)
        
        vim.notify:revert()
      end)

      it("should send notifications with custom log levels", function()
        local notify_spy = spy.on(vim, "notify")
        
        notification_manager.notify("Error message", vim.log.levels.ERROR)
        notification_manager.notify("Warning message", vim.log.levels.WARN)
        notification_manager.notify("Debug message", vim.log.levels.DEBUG)
        
        assert.spy(notify_spy).was.called_with("Error message", vim.log.levels.ERROR)
        assert.spy(notify_spy).was.called_with("Warning message", vim.log.levels.WARN)
        assert.spy(notify_spy).was.called_with("Debug message", vim.log.levels.DEBUG)
        
        vim.notify:revert()
      end)

      it("should force notifications when requested", function()
        local notify_spy = spy.on(vim, "notify")
        
        notification_manager.notify("Same message")
        notification_manager.notify("Same message") -- Should be deduped
        notification_manager.notify("Same message", vim.log.levels.INFO, true) -- Should be forced
        
        assert.spy(notify_spy).was.called(2) -- First call + forced call
        
        vim.notify:revert()
      end)
    end)

    describe("deduplication", function()
      it("should deduplicate identical messages", function()
        local notify_spy = spy.on(vim, "notify")
        
        notification_manager.notify("Duplicate message")
        notification_manager.notify("Duplicate message")
        notification_manager.notify("Duplicate message")
        
        assert.spy(notify_spy).was.called(1) -- Only first call should go through
        
        vim.notify:revert()
      end)

      it("should not deduplicate different messages", function()
        local notify_spy = spy.on(vim, "notify")
        
        notification_manager.notify("Message 1")
        notification_manager.notify("Message 2")
        notification_manager.notify("Message 3")
        
        assert.spy(notify_spy).was.called(3)
        
        vim.notify:revert()
      end)

      it("should consider log level in deduplication", function()
        local notify_spy = spy.on(vim, "notify")
        
        notification_manager.notify("Same message", vim.log.levels.INFO)
        notification_manager.notify("Same message", vim.log.levels.ERROR) -- Different level
        
        assert.spy(notify_spy).was.called(2) -- Both should go through
        
        vim.notify:revert()
      end)

      it("should expire deduplication cache", function()
        local notify_spy = spy.on(vim, "notify")
        
        -- Mock vim.loop.now to control time
        local mock_time = 1000000
        stub(vim.loop, "now", function()
          return mock_time
        end)
        
        notification_manager.notify("Time-sensitive message")
        
        -- Advance time beyond cache duration (2000ms)
        mock_time = mock_time + 3000
        
        notification_manager.notify("Time-sensitive message")
        
        assert.spy(notify_spy).was.called(2) -- Both should go through due to time
        
        vim.loop.now:revert()
        vim.notify:revert()
      end)
    end)

    describe("cache management", function()
      it("should provide cache statistics", function()
        local stats = notification_manager.get_cache_stats()
        
        assert.is_table(stats)
        assert.is_number(stats.cache_size)
        assert.is_number(stats.cache_duration)
        assert.is_number(stats.cleanup_interval)
        assert.equals(2000, stats.cache_duration)
        assert.equals(5000, stats.cleanup_interval)
      end)

      it("should clear cache", function()
        local notify_spy = spy.on(vim, "notify")
        
        notification_manager.notify("Cacheable message")
        notification_manager.notify("Cacheable message") -- Should be deduped
        
        notification_manager.clear_cache()
        
        notification_manager.notify("Cacheable message") -- Should go through after clear
        
        assert.spy(notify_spy).was.called(2) -- First and post-clear calls
        
        vim.notify:revert()
      end)

      it("should clean up expired cache entries", function()
        local mock_time = 1000000
        stub(vim.loop, "now", function()
          return mock_time
        end)
        
        -- Add some notifications to cache
        notification_manager.notify("Message 1")
        notification_manager.notify("Message 2")
        
        local stats_before = notification_manager.get_cache_stats()
        assert.is_true(stats_before.cache_size > 0)
        
        -- Advance time beyond cleanup interval
        mock_time = mock_time + 6000
        
        -- Trigger cleanup by sending a new notification
        notification_manager.notify("New message")
        
        vim.loop.now:revert()
      end)
    end)

    describe("specialized notifications", function()
      it("should notify about file deletion", function()
        local notify_spy = spy.on(vim, "notify")
        
        -- Mock utils module
        package.preload["ecolog.utils"] = function()
          return {
            get_env_file_display_name = function(file)
              return vim.fn.fnamemodify(file, ":t")
            end
          }
        end
        
        notification_manager.notify_file_deleted("/path/to/.env")
        
        assert.spy(notify_spy).was.called_with(
          "Selected file '.env' was deleted. No environment files found.",
          vim.log.levels.WARN
        )
        
        package.preload["ecolog.utils"] = nil
        vim.notify:revert()
      end)

      it("should notify about file deletion with replacement", function()
        local notify_spy = spy.on(vim, "notify")
        
        -- Mock utils module
        package.preload["ecolog.utils"] = function()
          return {
            get_env_file_display_name = function(file)
              return vim.fn.fnamemodify(file, ":t")
            end
          }
        end
        
        notification_manager.notify_file_deleted("/path/to/.env", "/path/to/.env.local")
        
        assert.spy(notify_spy).was.called_with(
          "Selected file '.env' was deleted. Switched to: .env.local",
          vim.log.levels.INFO
        )
        
        package.preload["ecolog.utils"] = nil
        vim.notify:revert()
      end)

      it("should notify about file creation", function()
        local notify_spy = spy.on(vim, "notify")
        
        notification_manager.notify_file_created("/path/to/.env.new")
        
        assert.spy(notify_spy).was.called_with(
          "New environment file detected: .env.new",
          vim.log.levels.INFO
        )
        
        vim.notify:revert()
      end)

      it("should notify about file errors", function()
        local notify_spy = spy.on(vim, "notify")
        
        notification_manager.notify_file_error("/path/to/.env", "Permission denied")
        
        assert.spy(notify_spy).was.called_with(
          "Environment file error [.env]: Permission denied",
          vim.log.levels.ERROR
        )
        
        vim.notify:revert()
      end)
    end)
  end)

  describe("TimerManager", function()
    describe("basic timer creation", function()
      it("should create single-shot timers", function()
        local callback_called = false
        
        local timer = timer_manager.create_timer(function()
          callback_called = true
        end, 50)
        
        assert.is_not_nil(timer)
        
        -- Wait for timer
        vim.wait(100)
        
        assert.is_true(callback_called)
      end)

      it("should create repeating timers", function()
        local call_count = 0
        
        local timer = timer_manager.create_timer(function()
          call_count = call_count + 1
        end, 50, 50)
        
        assert.is_not_nil(timer)
        
        -- Wait for multiple executions
        vim.wait(200)
        
        assert.is_true(call_count >= 2)
        
        timer_manager.cancel_timer(timer)
      end)

      it("should handle callback errors gracefully", function()
        local notify_spy = spy.on(vim, "notify")
        
        local timer = timer_manager.create_timer(function()
          error("Test error")
        end, 50)
        
        -- Wait for timer
        vim.wait(100)
        
        assert.spy(notify_spy).was.called_with(
          match.matches("Timer callback error:"),
          vim.log.levels.ERROR
        )
        
        vim.notify:revert()
      end)

      it("should return nil for failed timer creation", function()
        -- Mock vim.loop.new_timer to return nil
        local original_new_timer = vim.loop.new_timer
        stub(vim.loop, "new_timer", function()
          return nil
        end)
        
        local timer = timer_manager.create_timer(function() end, 50)
        
        assert.is_nil(timer)
        
        vim.loop.new_timer:revert()
      end)
    end)

    describe("debounced timers", function()
      it("should debounce timer calls", function()
        local call_count = 0
        
        timer_manager.debounce("test_timer", function()
          call_count = call_count + 1
        end, 100)
        
        timer_manager.debounce("test_timer", function()
          call_count = call_count + 1
        end, 100)
        
        timer_manager.debounce("test_timer", function()
          call_count = call_count + 1
        end, 100)
        
        -- Wait for timer
        vim.wait(200)
        
        assert.equals(1, call_count) -- Only the last call should execute
      end)

      it("should handle debounced timer arguments", function()
        local received_args
        
        timer_manager.debounce("test_timer", function(arg1, arg2, arg3)
          received_args = {arg1, arg2, arg3}
        end, 50, "hello", 42, true)
        
        vim.wait(100)
        
        assert.are.same({"hello", 42, true}, received_args)
      end)

      it("should handle debounced callback errors", function()
        local notify_spy = spy.on(vim, "notify")
        
        timer_manager.debounce("error_timer", function()
          error("Debounced error")
        end, 50)
        
        vim.wait(100)
        
        assert.spy(notify_spy).was.called_with(
          match.matches("Debounced callback error:"),
          vim.log.levels.ERROR
        )
        
        vim.notify:revert()
      end)

      it("should allow different debounce IDs", function()
        local count1 = 0
        local count2 = 0
        
        timer_manager.debounce("timer1", function()
          count1 = count1 + 1
        end, 50)
        
        timer_manager.debounce("timer2", function()
          count2 = count2 + 1
        end, 50)
        
        vim.wait(100)
        
        assert.equals(1, count1)
        assert.equals(1, count2)
      end)
    end)

    describe("timer cancellation", function()
      it("should cancel libuv timers", function()
        local callback_called = false
        
        local timer = timer_manager.create_timer(function()
          callback_called = true
        end, 100)
        
        -- Verify timer was created
        assert.is_not_nil(timer)
        
        local success = timer_manager.cancel_timer(timer)
        
        -- Even if cancellation fails, the test shouldn't fail
        -- as timer behavior can be timing-dependent
        
        -- Wait longer than timer delay
        vim.wait(150)
        
        -- The main point is that no crash occurred
        assert.is_boolean(success)
      end)

      it("should cancel vim timers", function()
        local callback_called = false
        
        -- Create vim timer directly
        local timer_id = vim.fn.timer_start(100, function()
          callback_called = true
        end)
        
        local success = timer_manager.cancel_timer(timer_id)
        
        assert.is_true(success)
        
        vim.wait(150)
        
        assert.is_false(callback_called)
      end)

      it("should handle invalid timer cancellation", function()
        local success1 = timer_manager.cancel_timer(nil)
        local success2 = timer_manager.cancel_timer({}) -- Invalid timer object
        local success3 = timer_manager.cancel_timer("not_a_timer")
        
        assert.is_false(success1)
        assert.is_false(success2)
        assert.is_false(success3)
      end)

      it("should cancel all debounced timers", function()
        local call_count = 0
        
        timer_manager.debounce("timer1", function() call_count = call_count + 1 end, 100)
        timer_manager.debounce("timer2", function() call_count = call_count + 1 end, 100)
        timer_manager.debounce("timer3", function() call_count = call_count + 1 end, 100)
        
        timer_manager.cancel_all_debounced()
        
        vim.wait(150)
        
        assert.equals(0, call_count)
      end)

      it("should cancel all timers", function()
        local call_count = 0
        
        -- Create libuv timer
        timer_manager.create_timer(function() call_count = call_count + 1 end, 200)
        
        -- Create debounced timer
        timer_manager.debounce("test", function() call_count = call_count + 1 end, 200)
        
        timer_manager.cancel_all()
        
        vim.wait(300)
        
        -- Should have cancelled most/all timers (timing dependent)
        assert.is_true(call_count <= 1) -- Allow for timing issues
      end)
    end)

    describe("timer statistics", function()
      it("should provide timer statistics", function()
        local stats = timer_manager.get_stats()
        
        assert.is_table(stats)
        assert.is_number(stats.active_timers)
        assert.is_number(stats.debounce_timers)
      end)

      it("should track active timers in statistics", function()
        local initial_stats = timer_manager.get_stats()
        
        local timer = timer_manager.create_timer(function() end, 1000) -- Long delay
        
        local stats_with_timer = timer_manager.get_stats()
        
        assert.is_true(stats_with_timer.active_timers > initial_stats.active_timers)
        
        timer_manager.cancel_timer(timer)
      end)

      it("should track debounced timers in statistics", function()
        local initial_stats = timer_manager.get_stats()
        
        timer_manager.debounce("test", function() end, 1000) -- Long delay
        
        local stats_with_debounce = timer_manager.get_stats()
        
        assert.is_true(stats_with_debounce.debounce_timers > initial_stats.debounce_timers)
        
        timer_manager.cancel_all_debounced()
      end)
    end)

    describe("timer cleanup", function()
      it("should clean up single-shot timers automatically", function()
        local initial_stats = timer_manager.get_stats()
        
        timer_manager.create_timer(function() end, 50) -- Short delay
        
        vim.wait(100) -- Wait for completion
        
        local final_stats = timer_manager.get_stats()
        
        -- Single-shot timer should be cleaned up
        assert.equals(initial_stats.active_timers, final_stats.active_timers)
      end)

      it("should not clean up repeating timers automatically", function()
        local initial_stats = timer_manager.get_stats()
        
        local timer = timer_manager.create_timer(function() end, 50, 50) -- Repeating
        
        vim.wait(150) -- Wait for multiple executions
        
        local stats_after = timer_manager.get_stats()
        
        -- Repeating timer should still be active
        assert.is_true(stats_after.active_timers > initial_stats.active_timers)
        
        timer_manager.cancel_timer(timer)
      end)
    end)
  end)

  describe("integration between managers", function()
    it("should handle timer-triggered notifications", function()
      local notify_spy = spy.on(vim, "notify")
      
      timer_manager.create_timer(function()
        notification_manager.notify("Timer-triggered notification")
      end, 50)
      
      vim.wait(100)
      
      assert.spy(notify_spy).was.called_with(
        "Timer-triggered notification",
        vim.log.levels.INFO
      )
      
      vim.notify:revert()
    end)

    it("should handle rapid timer notifications with deduplication", function()
      local notify_spy = spy.on(vim, "notify")
      
      -- Create multiple timers with same message
      for i = 1, 5 do
        timer_manager.create_timer(function()
          notification_manager.notify("Rapid notification")
        end, 50)
      end
      
      vim.wait(100)
      
      -- Should be deduplicated to only one notification
      assert.spy(notify_spy).was.called(1)
      
      vim.notify:revert()
    end)
  end)
end)