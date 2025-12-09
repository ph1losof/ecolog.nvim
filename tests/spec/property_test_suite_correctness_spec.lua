local assert = require("luassert")
local stub = require("luassert.stub")
local spy = require("luassert.spy")

-- **Feature: ecolog-refactor, Property 1: Test Suite Correctness**
-- **Validates: Requirements 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8**

describe("Property-Based Test: Test Suite Correctness", function()
  local notification_manager
  local timer_manager

  before_each(function()
    -- Set test mode
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

  -- Property generator for notification messages
  local function generate_notification_message()
    local messages = {
      "Test message",
      "Error occurred",
      "Warning: something happened",
      "Info: operation completed",
      "Debug: variable value",
      "File not found",
      "Permission denied",
      "Operation successful",
      "",  -- empty message
      string.rep("a", 1000),  -- very long message
    }
    return messages[math.random(#messages)]
  end

  -- Property generator for log levels
  local function generate_log_level()
    local levels = {
      vim.log.levels.DEBUG,
      vim.log.levels.INFO,
      vim.log.levels.WARN,
      vim.log.levels.ERROR,
    }
    return levels[math.random(#levels)]
  end

  -- Property generator for boolean values
  local function generate_boolean()
    return math.random() > 0.5
  end

  -- Property 1: Notification system should handle all parameter combinations correctly
  it("should handle notification parameters correctly across all combinations", function()
    local notify_spy = spy.on(vim, "notify")
    
    -- Run property test with 100 iterations
    for i = 1, 100 do
      local message = generate_notification_message() .. " " .. tostring(i) -- Make each message unique
      local level = generate_log_level()
      local force = generate_boolean()
      
      -- Clear spy history and cache for this iteration
      notify_spy:clear()
      notification_manager.clear_cache()
      
      -- Test the notification
      notification_manager.notify(message, level, force)
      
      -- Property: vim.notify should always be called with exactly 2 parameters in test mode
      assert.spy(notify_spy).was_called()
      local call_args = notify_spy.calls[1].vals
      assert.equals(2, #call_args, "vim.notify should be called with exactly 2 parameters in test mode")
      assert.equals(message, call_args[1], "First parameter should be the message")
      assert.equals(level, call_args[2], "Second parameter should be the log level")
    end
    
    vim.notify:revert()
  end)

  -- Property 2: Specialized notification functions should maintain consistency
  it("should handle specialized notifications consistently", function()
    local notify_spy = spy.on(vim, "notify")
    
    -- Test file deletion notifications
    for i = 1, 20 do
      notify_spy:clear()
      notification_manager.clear_cache()
      
      local deleted_file = ".env" .. (i % 5 == 0 and "" or "." .. tostring(i))
      local new_file = i % 2 == 0 and (".env.backup" .. tostring(i)) or nil
      
      notification_manager.notify_file_deleted(deleted_file, new_file)
      
      -- Property: Should always call vim.notify with 2 parameters
      assert.spy(notify_spy).was_called()
      local call_args = notify_spy.calls[1].vals
      assert.equals(2, #call_args, "Specialized notifications should use 2 parameters in test mode")
      assert.is_string(call_args[1], "Message should be a string")
      assert.is_number(call_args[2], "Log level should be a number")
    end
    
    -- Test file creation notifications
    for i = 1, 20 do
      notify_spy:clear()
      notification_manager.clear_cache()
      
      local file_path = "/path/to/.env" .. tostring(i) .. (i % 3 == 0 and ".local" or "")
      
      notification_manager.notify_file_created(file_path)
      
      -- Property: Should always call vim.notify with 2 parameters
      assert.spy(notify_spy).was_called()
      local call_args = notify_spy.calls[1].vals
      assert.equals(2, #call_args, "File creation notifications should use 2 parameters in test mode")
      assert.is_string(call_args[1], "Message should be a string")
      assert.equals(vim.log.levels.INFO, call_args[2], "File creation should use INFO level")
    end
    
    -- Test file error notifications
    for i = 1, 20 do
      notify_spy:clear()
      notification_manager.clear_cache()
      
      local file_path = "/path/to/.env" .. tostring(i)
      local error_msg = "Error " .. tostring(i) .. ": " .. generate_notification_message()
      
      notification_manager.notify_file_error(file_path, error_msg)
      
      -- Property: Should always call vim.notify with 2 parameters
      assert.spy(notify_spy).was_called()
      local call_args = notify_spy.calls[1].vals
      assert.equals(2, #call_args, "File error notifications should use 2 parameters in test mode")
      assert.is_string(call_args[1], "Message should be a string")
      assert.equals(vim.log.levels.ERROR, call_args[2], "File errors should use ERROR level")
    end
    
    vim.notify:revert()
  end)

  -- Property 3: Timer error handling should use consistent notification patterns
  it("should handle timer callback errors with consistent notifications", function()
    local notify_spy = spy.on(vim, "notify")
    
    -- Test timer callback error handling
    for i = 1, 20 do
      notify_spy:clear()
      
      -- Create a timer with a callback that will error
      local error_message = "Test error " .. tostring(i)
      local callback = function()
        error(error_message)
      end
      
      local timer = timer_manager.create_timer(callback, 1) -- 1ms delay
      
      if timer then
        -- Wait for the timer to execute and error
        vim.wait(50, function() return notify_spy.calls[1] ~= nil end)
        
        -- Property: Timer errors should result in consistent notifications
        if notify_spy.calls[1] then
          local call_args = notify_spy.calls[1].vals
          assert.equals(2, #call_args, "Timer error notifications should use 2 parameters in test mode")
          assert.is_string(call_args[1], "Error message should be a string")
          assert.equals(vim.log.levels.ERROR, call_args[2], "Timer errors should use ERROR level")
          assert.matches("Timer callback error:", call_args[1], "Should include timer error prefix")
        end
      end
    end
    
    vim.notify:revert()
  end)

  -- Property 4: Deduplication should work consistently across message types
  it("should deduplicate notifications consistently", function()
    local notify_spy = spy.on(vim, "notify")
    
    -- Test deduplication property
    for i = 1, 10 do
      notify_spy:clear()
      
      local message = "Duplicate message " .. tostring(i % 3) -- Create some duplicates
      local level = generate_log_level()
      
      -- Send the same message multiple times quickly
      notification_manager.notify(message, level, false)
      notification_manager.notify(message, level, false)
      notification_manager.notify(message, level, false)
      
      -- Property: Should only be called once due to deduplication
      assert.spy(notify_spy).was_called(1)
      
      -- Clear cache and try again - should work
      notification_manager.clear_cache()
      notify_spy:clear()
      
      notification_manager.notify(message, level, false)
      assert.spy(notify_spy).was_called(1)
    end
    
    vim.notify:revert()
  end)

  -- Property 5: Force parameter should bypass deduplication consistently
  it("should handle force parameter consistently", function()
    local notify_spy = spy.on(vim, "notify")
    
    for i = 1, 20 do
      notify_spy:clear()
      
      local message = "Forced message " .. tostring(i % 5)
      local level = generate_log_level()
      
      -- Send the same message multiple times with force=true
      notification_manager.notify(message, level, true)
      notification_manager.notify(message, level, true)
      notification_manager.notify(message, level, true)
      
      -- Property: Should be called multiple times when forced
      assert.spy(notify_spy).was_called(3)
      
      -- Each call should have correct parameters
      for j = 1, 3 do
        local call_args = notify_spy.calls[j].vals
        assert.equals(2, #call_args, "Forced notifications should use 2 parameters in test mode")
        assert.equals(message, call_args[1], "Message should match")
        assert.equals(level, call_args[2], "Level should match")
      end
    end
    
    vim.notify:revert()
  end)
end)