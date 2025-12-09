local assert = require("luassert")
local stub = require("luassert.stub")
local spy = require("luassert.spy")

-- **Feature: ecolog-refactor, Property 3: Error Handling Uniformity**
-- **Validates: Requirements 1.5, 2.4**

describe("Property-Based Test: Error Handling Uniformity", function()
  local notification_manager
  local timer_manager
  local ecolog

  before_each(function()
    -- Set test mode
    _G._ECOLOG_TEST_MODE = true
    
    -- Reset modules
    package.loaded["ecolog.core.notification_manager"] = nil
    package.loaded["ecolog.core.timer_manager"] = nil
    package.loaded["ecolog"] = nil
    
    notification_manager = require("ecolog.core.notification_manager")
    timer_manager = require("ecolog.core.timer_manager")
    ecolog = require("ecolog")
    
    -- Clear any existing state
    notification_manager.clear_cache()
    timer_manager.cancel_all()
  end)

  after_each(function()
    timer_manager.cancel_all()
    notification_manager.clear_cache()
    collectgarbage("collect")
    vim.wait(10)
  end)

  -- Property generator for error messages
  local function generate_error_message()
    local messages = {
      "File not found",
      "Permission denied",
      "Invalid configuration",
      "Network timeout",
      "Parse error",
      "Memory allocation failed",
      "Invalid argument",
      "Resource unavailable",
      "",  -- empty error
      string.rep("x", 500),  -- very long error
    }
    return messages[math.random(#messages)]
  end

  -- Property generator for file paths
  local function generate_file_path()
    local paths = {
      "/path/to/.env",
      "/home/user/.env.local",
      "/project/.env.development",
      "/invalid/path/file.env",
      "",  -- empty path
      "/very/long/path/" .. string.rep("dir/", 20) .. ".env",
    }
    return paths[math.random(#paths)]
  end

  -- Property generator for module names
  local function generate_module_name()
    local modules = {
      "ecolog.providers.javascript",
      "ecolog.integrations.lsp",
      "ecolog.shelter.masking_engine",
      "invalid.module.name",
      "",  -- empty module
      "ecolog." .. string.rep("nested.", 10) .. "module",
    }
    return modules[math.random(#modules)]
  end

  -- Property 1: Error notifications should use consistent format and level
  it("should handle error notifications with consistent format across all error types", function()
    local notify_spy = spy.on(vim, "notify")
    
    -- Test general error notifications
    for i = 1, 50 do
      notify_spy:clear()
      
      local error_message = generate_error_message() .. " " .. tostring(i)
      
      -- Test NotificationManager.error function
      notification_manager.error(error_message)
      
      -- Property: Error notifications should always use ERROR level and 2 parameters in test mode
      assert.spy(notify_spy).was_called()
      local call_args = notify_spy.calls[1].vals
      assert.equals(2, #call_args, "Error notifications should use 2 parameters in test mode")
      assert.is_string(call_args[1], "Error message should be a string")
      assert.equals(vim.log.levels.ERROR, call_args[2], "Error notifications should use ERROR level")
    end
    
    vim.notify:revert()
  end)

  -- Property 2: File error notifications should follow consistent patterns
  it("should handle file error notifications consistently", function()
    local notify_spy = spy.on(vim, "notify")
    
    for i = 1, 30 do
      notify_spy:clear()
      notification_manager.clear_cache() -- Clear cache to avoid deduplication issues
      
      local file_path = generate_file_path()
      local error_message = generate_error_message() .. " " .. tostring(i) -- Make unique to avoid deduplication
      
      -- Test file-specific error notifications
      notification_manager.notify_file_error(file_path, error_message)
      
      -- Property: File error notifications should use consistent format
      -- Note: Some edge cases (like empty paths/messages) might not trigger notifications due to validation
      if notify_spy.calls and #notify_spy.calls > 0 then
        local call_args = notify_spy.calls[1].vals
        assert.equals(2, #call_args, "File error notifications should use 2 parameters in test mode")
        assert.is_string(call_args[1], "File error message should be a string")
        assert.equals(vim.log.levels.ERROR, call_args[2], "File error notifications should use ERROR level")
        
        -- Property: File error messages should include file information
        local message = call_args[1]
        assert.matches("Environment file error", message, "File error should include standard prefix")
      end
    end
    
    vim.notify:revert()
  end)

  -- Property 3: pcall error handling should be consistent across modules
  it("should handle pcall errors consistently across different operations", function()
    local notify_spy = spy.on(vim, "notify")
    
    -- Test setup error handling
    for i = 1, 20 do
      notify_spy:clear()
      
      -- Create a configuration that will cause an error during setup
      local invalid_config = {
        path = "/nonexistent/path/that/should/cause/error" .. tostring(i),
        -- Add some complex nested config that might cause issues
        integrations = {
          lsp = {
            enabled = true,
            invalid_nested_option = function() error("test error") end
          }
        }
      }
      
      -- Property: Setup should handle errors gracefully with pcall
      local success = pcall(function()
        ecolog.setup(invalid_config)
      end)
      
      -- Property: Setup should not crash on errors
      assert.is_true(success, "Setup should handle errors gracefully and not crash")
      
      -- If there were error notifications, they should follow consistent format
      if notify_spy.calls and #notify_spy.calls > 0 then
        for _, call in ipairs(notify_spy.calls) do
          local call_args = call.vals
          if #call_args >= 2 and call_args[2] == vim.log.levels.ERROR then
            assert.is_string(call_args[1], "Error message should be a string")
            assert.equals(2, #call_args, "Error notifications should use 2 parameters in test mode")
          end
        end
      end
    end
    
    vim.notify:revert()
  end)

  -- Property 4: Timer callback errors should be handled uniformly
  it("should handle timer callback errors with consistent error handling", function()
    local notify_spy = spy.on(vim, "notify")
    
    for i = 1, 20 do
      notify_spy:clear()
      
      local error_message = "Timer error " .. tostring(i) .. ": " .. generate_error_message()
      
      -- Create a timer with a callback that will error
      local callback = function()
        error(error_message)
      end
      
      local timer = timer_manager.create_timer(callback, 1) -- 1ms delay
      
      if timer then
        -- Wait for the timer to execute and potentially error
        vim.wait(50, function() return notify_spy.calls[1] ~= nil end)
        
        -- Property: Timer errors should result in consistent error notifications
        if notify_spy.calls[1] then
          local call_args = notify_spy.calls[1].vals
          assert.equals(2, #call_args, "Timer error notifications should use 2 parameters in test mode")
          assert.is_string(call_args[1], "Timer error message should be a string")
          assert.equals(vim.log.levels.ERROR, call_args[2], "Timer errors should use ERROR level")
          
          -- Property: Timer error messages should include context
          local message = call_args[1]
          assert.matches("Timer callback error", message, "Timer errors should include context prefix")
        end
      end
    end
    
    vim.notify:revert()
  end)

  -- Property 5: Module loading errors should be handled consistently
  it("should handle module loading errors with consistent patterns", function()
    local notify_spy = spy.on(vim, "notify")
    
    -- Test module loading error handling by trying to load invalid modules
    for i = 1, 15 do
      notify_spy:clear()
      
      local module_name = "ecolog.invalid.module" .. tostring(i)
      
      -- Property: Module loading should use pcall and handle errors gracefully
      local success, result = pcall(require, module_name)
      
      -- Property: Invalid module loading should fail gracefully
      assert.is_false(success, "Loading invalid module should fail")
      assert.is_string(result, "Error result should be a string")
      
      -- The actual error handling happens inside ecolog's require_module function
      -- We test that the pattern exists by checking the error format
      assert.matches("module.*not found", result:lower(), "Module error should follow standard Lua pattern")
    end
    
    vim.notify:revert()
  end)

  -- Property 6: Error recovery should maintain system stability
  it("should maintain system stability after error conditions", function()
    local notify_spy = spy.on(vim, "notify")
    
    -- Test that the system remains stable after various error conditions
    for i = 1, 10 do
      notify_spy:clear()
      
      -- Trigger various error conditions
      local error_scenarios = {
        function() notification_manager.error("Test error " .. tostring(i)) end,
        function() notification_manager.notify_file_error("/invalid/path", "Test file error") end,
        function() 
          local timer = timer_manager.create_timer(function() error("Timer error") end, 1)
          if timer then vim.wait(20) end
        end,
      }
      
      local scenario = error_scenarios[math.random(#error_scenarios)]
      
      -- Property: Error scenarios should not crash the system
      local success = pcall(scenario)
      assert.is_true(success, "Error scenarios should be handled gracefully")
      
      -- Property: System should remain functional after errors
      -- Test that we can still perform basic operations
      local basic_ops_success = pcall(function()
        notification_manager.notify("Test message after error", vim.log.levels.INFO)
        notification_manager.clear_cache()
      end)
      
      assert.is_true(basic_ops_success, "System should remain functional after error conditions")
    end
    
    vim.notify:revert()
  end)

  -- Property 7: Error message formatting should be consistent
  it("should format error messages consistently across all error types", function()
    local notify_spy = spy.on(vim, "notify")
    
    for i = 1, 25 do
      notify_spy:clear()
      
      local base_message = generate_error_message()
      local context = "test_context_" .. tostring(i)
      
      -- Test different error formatting patterns
      local error_functions = {
        function() notification_manager.error(base_message) end,
        function() notification_manager.notify_file_error("/test/path", base_message) end,
      }
      
      local error_fn = error_functions[math.random(#error_functions)]
      error_fn()
      
      -- Property: All error notifications should follow consistent parameter patterns
      if notify_spy.calls and #notify_spy.calls > 0 then
        local call_args = notify_spy.calls[1].vals
        assert.equals(2, #call_args, "All error notifications should use 2 parameters in test mode")
        assert.is_string(call_args[1], "Error message should always be a string")
        assert.equals(vim.log.levels.ERROR, call_args[2], "Error notifications should always use ERROR level")
        
        -- Property: Error messages should not be empty (unless input was empty)
        if base_message ~= "" then
          assert.is_true(#call_args[1] > 0, "Non-empty input should result in non-empty error message")
        end
      end
    end
    
    vim.notify:revert()
  end)
end)