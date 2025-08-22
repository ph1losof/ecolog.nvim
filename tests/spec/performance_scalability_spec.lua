local assert = require("luassert")

describe("performance and scalability", function()
  local ecolog
  local test_dir

  local function create_test_file(path, content)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local file = io.open(path, "w")
    if file then
      file:write(content)
      file:close()
    end
  end

  local function cleanup_test_files(path)
    vim.fn.delete(path, "rf")
  end

  local function generate_large_env_content(num_vars)
    local lines = {}
    for i = 1, num_vars do
      table.insert(lines, string.format("VAR_%d=value_%d_with_some_content_to_make_it_realistic", i, i))
    end
    return table.concat(lines, "\n")
  end

  before_each(function()
    package.loaded["ecolog"] = nil
    package.loaded["ecolog.init"] = nil
    
    test_dir = vim.fn.tempname()
    vim.fn.mkdir(test_dir, "p")
    
    -- Change to test directory
    vim.cmd("cd " .. test_dir)
  end)

  after_each(function()
    cleanup_test_files(test_dir)
    vim.cmd("cd " .. vim.fn.expand("~"))
    
    -- Clean up autocmds
    pcall(vim.api.nvim_del_augroup_by_name, "EcologFileWatcher")
  end)

  describe("large file handling", function()
    it("should handle files with many variables efficiently", function()
      local num_vars = 5000
      local content = generate_large_env_content(num_vars)
      create_test_file(test_dir .. "/.env", content)

      ecolog = require("ecolog")
      
      local start_time = vim.loop.hrtime()
      ecolog.setup({
        path = test_dir,
        integrations = {
          nvim_cmp = false,
          blink_cmp = false,
          lsp = false,
        },
      })
      
      -- Wait for async loading
      vim.wait(1000)
      
      local env_vars = ecolog.get_env_vars()
      local elapsed = (vim.loop.hrtime() - start_time) / 1e6

      assert.is_not_nil(env_vars.VAR_1)
      assert.is_not_nil(env_vars.VAR_2500)
      assert.is_not_nil(env_vars.VAR_5000)
      assert.equals("value_1_with_some_content_to_make_it_realistic", env_vars.VAR_1.value)
      assert.equals("value_5000_with_some_content_to_make_it_realistic", env_vars.VAR_5000.value)
      
      -- Should complete in reasonable time (less than 2 seconds)
      assert.is_true(elapsed < 2000, "Loading 5000 variables should complete in under 2s, took " .. elapsed .. "ms")
    end)

    it("should handle very large individual variable values", function()
      local large_value = string.rep("A", 100000) -- 100KB value
      local content = "SMALL_VAR=small\nLARGE_VAR=" .. large_value .. "\nANOTHER_SMALL=test"
      create_test_file(test_dir .. "/.env", content)

      ecolog = require("ecolog")
      
      local start_time = vim.loop.hrtime()
      ecolog.setup({
        path = test_dir,
        integrations = {
          nvim_cmp = false,
          blink_cmp = false,
        },
      })
      
      vim.wait(500)
      
      local env_vars = ecolog.get_env_vars()
      local elapsed = (vim.loop.hrtime() - start_time) / 1e6

      assert.equals("small", env_vars.SMALL_VAR.value)
      assert.equals(large_value, env_vars.LARGE_VAR.value)
      assert.equals("test", env_vars.ANOTHER_SMALL.value)
      
      assert.is_true(elapsed < 1000, "Large values should be handled efficiently, took " .. elapsed .. "ms")
    end)

    it("should handle files with complex interpolation efficiently", function()
      local content = {}
      
      -- Create a chain of variables with interpolation
      for i = 1, 1000 do
        if i == 1 then
          table.insert(content, "VAR_1=base_value")
        else
          table.insert(content, string.format("VAR_%d=${VAR_%d}_ext_%d", i, i-1, i))
        end
      end
      
      create_test_file(test_dir .. "/.env", table.concat(content, "\n"))

      ecolog = require("ecolog")
      
      local start_time = vim.loop.hrtime()
      ecolog.setup({
        path = test_dir,
        interpolation = {
          enabled = true,
          max_iterations = 100,
        },
        integrations = {
          nvim_cmp = false,
          blink_cmp = false,
        },
      })
      
      vim.wait(1000)
      
      local env_vars = ecolog.get_env_vars()
      local elapsed = (vim.loop.hrtime() - start_time) / 1e6

      assert.is_not_nil(env_vars.VAR_1)
      assert.is_not_nil(env_vars.VAR_100)
      
      assert.is_true(elapsed < 3000, "Complex interpolation should complete in under 3s, took " .. elapsed .. "ms")
    end)
  end)

  describe("multiple file handling", function()
    it("should handle many environment files efficiently", function()
      local num_files = 50
      
      for i = 1, num_files do
        local content = string.format("FILE_%d_VAR_1=value1\nFILE_%d_VAR_2=value2", i, i)
        create_test_file(test_dir .. "/.env.file" .. i, content)
      end

      ecolog = require("ecolog")
      
      local start_time = vim.loop.hrtime()
      ecolog.setup({
        path = test_dir,
        env_file_patterns = { ".env*" },
      })
      
      vim.wait(1000)
      
      local env_vars = ecolog.get_env_vars()
      local elapsed = (vim.loop.hrtime() - start_time) / 1e6

      -- Should have variables from multiple files
      local var_count = 0
      for _ in pairs(env_vars) do
        var_count = var_count + 1
      end
      
      assert.is_true(var_count > 50, "Should load variables from multiple files")
      assert.is_true(elapsed < 2000, "Multiple files should load efficiently, took " .. elapsed .. "ms")
    end)

    it("should prioritize files correctly with many options", function()
      local file_names = {
        ".env",
        ".env.local",
        ".env.development", 
        ".env.production",
        ".env.test",
        ".env.staging",
      }
      
      for i, filename in ipairs(file_names) do
        local content = string.format("PRIORITY_VAR=from_%s\nFILE_SPECIFIC_VAR_%d=value_%d", filename, i, i)
        create_test_file(test_dir .. "/" .. filename, content)
      end

      ecolog = require("ecolog")
      
      local start_time = vim.loop.hrtime()
      ecolog.setup({
        path = test_dir,
        preferred_environment = "development",
      })
      
      vim.wait(500)
      
      local env_vars = ecolog.get_env_vars()
      local elapsed = (vim.loop.hrtime() - start_time) / 1e6

      -- Should prioritize .env.development
      assert.equals("from_.env.development", env_vars.PRIORITY_VAR.value)
      
      assert.is_true(elapsed < 1000, "File prioritization should be efficient, took " .. elapsed .. "ms")
    end)
  end)

  describe("rapid operations", function()
    it("should handle rapid refresh operations", function()
      create_test_file(test_dir .. "/.env", "TEST_VAR=initial")

      ecolog = require("ecolog")
      ecolog.setup({
        path = test_dir,
      })
      
      vim.wait(100)

      local start_time = vim.loop.hrtime()
      
      -- Perform many rapid refreshes
      for i = 1, 50 do
        ecolog.refresh_env_vars({
          path = test_dir,
        })
        
        if i % 10 == 0 then
          vim.wait(10) -- Small delay every 10 operations
        end
      end
      
      local elapsed = (vim.loop.hrtime() - start_time) / 1e6

      local env_vars = ecolog.get_env_vars()
      assert.equals("initial", env_vars.TEST_VAR.value)
      
      assert.is_true(elapsed < 2000, "Rapid refreshes should complete efficiently, took " .. elapsed .. "ms")
    end)

    it("should handle rapid completion requests", function()
      local content = generate_large_env_content(500)
      create_test_file(test_dir .. "/.env", content)

      ecolog = require("ecolog")
      ecolog.setup({
        path = test_dir,
        integrations = {
          nvim_cmp = true,
        },
      })
      
      vim.wait(200)

      local nvim_cmp = require("ecolog.integrations.cmp.nvim_cmp")
      
      local start_time = vim.loop.hrtime()
      
      -- Simulate rapid completion requests
      for i = 1, 100 do
        local request = {
          context = {
            cursor = { row = 1, col = 10 },
          },
          completion_context = {
            triggerKind = 1,
          },
        }
        
        nvim_cmp:complete(request, function(result)
          -- Completion callback
        end)
      end
      
      local elapsed = (vim.loop.hrtime() - start_time) / 1e6

      assert.is_true(elapsed < 1000, "Rapid completions should be handled efficiently, took " .. elapsed .. "ms")
    end)
  end)

  describe("memory management", function()
    it("should manage memory efficiently with large datasets", function()
      local content = generate_large_env_content(2000)
      create_test_file(test_dir .. "/.env", content)

      -- Force garbage collection to get baseline
      collectgarbage("collect")
      local memory_before = collectgarbage("count")

      ecolog = require("ecolog")
      ecolog.setup({
        path = test_dir,
      })
      
      vim.wait(500)
      
      local env_vars = ecolog.get_env_vars()
      
      -- Force garbage collection
      collectgarbage("collect")
      local memory_after = collectgarbage("count")
      
      local memory_increase = memory_after - memory_before

      assert.is_not_nil(env_vars.VAR_1)
      assert.is_not_nil(env_vars.VAR_2000)
      
      -- Memory increase should be reasonable (less than 50MB for 2000 variables)
      assert.is_true(memory_increase < 50000, "Memory usage should be reasonable, increased by " .. memory_increase .. "KB")
    end)

    it("should cleanup resources on refresh", function()
      create_test_file(test_dir .. "/.env", generate_large_env_content(1000))

      ecolog = require("ecolog")
      ecolog.setup({
        path = test_dir,
      })
      
      vim.wait(200)

      -- Force garbage collection
      collectgarbage("collect")
      local memory_before_refresh = collectgarbage("count")

      -- Refresh multiple times
      for i = 1, 10 do
        ecolog.refresh_env_vars({
          path = test_dir,
        })
        vim.wait(20)
      end

      -- Force garbage collection
      collectgarbage("collect")
      local memory_after_refresh = collectgarbage("count")
      
      local memory_change = math.abs(memory_after_refresh - memory_before_refresh)

      -- Memory should not grow significantly with refreshes
      assert.is_true(memory_change < 10000, "Memory should not grow significantly with refreshes, changed by " .. memory_change .. "KB")
    end)

    it("should handle concurrent operations without memory leaks", function()
      create_test_file(test_dir .. "/.env", generate_large_env_content(500))

      ecolog = require("ecolog")
      ecolog.setup({
        path = test_dir,
      })
      
      vim.wait(200)

      collectgarbage("collect")
      local memory_before = collectgarbage("count")

      -- Simulate concurrent operations
      for i = 1, 20 do
        vim.schedule(function()
          local vars = ecolog.get_env_vars()
          ecolog.refresh_env_vars({ path = test_dir })
        end)
      end
      
      vim.wait(1000) -- Wait for all operations to complete

      collectgarbage("collect")
      local memory_after = collectgarbage("count")
      
      local memory_increase = memory_after - memory_before

      assert.is_true(memory_increase < 5000, "Concurrent operations should not cause memory leaks, increased by " .. memory_increase .. "KB")
    end)
  end)

  describe("cache performance", function()
    it("should cache frequently accessed data efficiently", function()
      create_test_file(test_dir .. "/.env", generate_large_env_content(1000))

      ecolog = require("ecolog")
      ecolog.setup({
        path = test_dir,
      })
      
      vim.wait(300)

      -- First access (should populate cache)
      local start_time_1 = vim.loop.hrtime()
      local vars_1 = ecolog.get_env_vars()
      local elapsed_1 = (vim.loop.hrtime() - start_time_1) / 1e6

      -- Second access (should use cache)
      local start_time_2 = vim.loop.hrtime()
      local vars_2 = ecolog.get_env_vars()
      local elapsed_2 = (vim.loop.hrtime() - start_time_2) / 1e6

      assert.is_not_nil(vars_1.VAR_500)
      assert.is_not_nil(vars_2.VAR_500)
      assert.equals(vars_1.VAR_500.value, vars_2.VAR_500.value)
      
      -- Cached access should be much faster
      assert.is_true(elapsed_2 < elapsed_1 / 2, "Cached access should be faster: " .. elapsed_1 .. "ms vs " .. elapsed_2 .. "ms")
    end)

    it("should invalidate cache appropriately", function()
      create_test_file(test_dir .. "/.env", "TEST_VAR=original")

      ecolog = require("ecolog")
      ecolog.setup({
        path = test_dir,
      })
      
      vim.wait(100)

      local vars_1 = ecolog.get_env_vars()
      assert.equals("original", vars_1.TEST_VAR.value)

      -- Update file
      create_test_file(test_dir .. "/.env", "TEST_VAR=updated")
      
      -- Refresh should invalidate cache
      ecolog.refresh_env_vars({ path = test_dir })
      vim.wait(100)

      local vars_2 = ecolog.get_env_vars()
      assert.equals("updated", vars_2.TEST_VAR.value)
    end)
  end)

  describe("stress testing", function()
    it("should handle extreme file sizes", function()
      local huge_value = string.rep("X", 1000000) -- 1MB value
      local content = "HUGE_VAR=" .. huge_value .. "\nNORMAL_VAR=normal"
      create_test_file(test_dir .. "/.env", content)

      ecolog = require("ecolog")
      
      local start_time = vim.loop.hrtime()
      ecolog.setup({
        path = test_dir,
      })
      
      vim.wait(2000) -- Give more time for huge file
      
      local env_vars = ecolog.get_env_vars()
      local elapsed = (vim.loop.hrtime() - start_time) / 1e6

      assert.equals(huge_value, env_vars.HUGE_VAR.value)
      assert.equals("normal", env_vars.NORMAL_VAR.value)
      
      assert.is_true(elapsed < 5000, "Huge files should be handled within reasonable time, took " .. elapsed .. "ms")
    end)

    it("should handle many simultaneous file watchers", function()
      -- Create many env files
      for i = 1, 20 do
        create_test_file(test_dir .. "/dir" .. i .. "/.env", "VAR_" .. i .. "=value" .. i)
      end

      ecolog = require("ecolog")
      
      local start_time = vim.loop.hrtime()
      ecolog.setup({
        path = test_dir,
        env_file_patterns = { "**/.env" },
      })
      
      vim.wait(1000)
      
      local elapsed = (vim.loop.hrtime() - start_time) / 1e6

      local env_vars = ecolog.get_env_vars()
      local var_count = 0
      for _ in pairs(env_vars) do
        var_count = var_count + 1
      end
      
      assert.is_true(var_count >= 10, "Should find variables from multiple directories")
      assert.is_true(elapsed < 3000, "Multiple file watchers should be efficient, took " .. elapsed .. "ms")
    end)
  end)
end)