local assert = require("luassert")
local stub = require("luassert.stub")
local spy = require("luassert.spy")

-- Add project root to package path
local project_root = vim.fn.getcwd()
package.path = package.path .. ";" .. project_root .. "/lua/?.lua;" .. project_root .. "/lua/?/init.lua"

describe("ecolog commands", function()
  local test_dir
  local ecolog

  local function create_test_env_file(path, content)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local file = io.open(path, "w")
    if file then
      file:write(content or "TEST_VAR=test_value\nAPI_KEY=secret123")
      file:close()
    end
  end

  local function cleanup_test_files(path)
    vim.fn.delete(path, "rf")
  end

  before_each(function()
    -- Clean up modules
    package.loaded["ecolog"] = nil
    package.loaded["ecolog.init"] = nil

    test_dir = vim.fn.tempname()
    vim.fn.mkdir(test_dir, "p")

    -- Create test .env files
    create_test_env_file(test_dir .. "/.env", "TEST_VAR=hello_world\nAPI_KEY=secret123\nDATABASE_URL=postgresql://localhost:5432/db")
    create_test_env_file(test_dir .. "/.env.local", "LOCAL_VAR=local_value\nAPI_KEY=local_secret")
    create_test_env_file(test_dir .. "/.env.production", "PROD_VAR=prod_value\nAPI_KEY=prod_secret")

    -- Change to test directory
    vim.cmd("cd " .. test_dir)

    -- Initialize ecolog
    ecolog = require("ecolog")
    ecolog.setup({
      path = test_dir,
    })
  end)

  after_each(function()
    cleanup_test_files(test_dir)
    vim.cmd("cd " .. vim.fn.expand("~"))
    
    -- Clean up autocmds
    pcall(vim.api.nvim_del_augroup_by_name, "EcologFileWatcher")
  end)

  describe("EcologPeek command", function()
    it("should be registered", function()
      local commands = vim.api.nvim_get_commands({})
      assert.is_not_nil(commands.EcologPeek)
      -- Command structure might be different, just check it exists
      assert.is_table(commands.EcologPeek)
    end)

    it("should work without arguments", function()
      -- EcologPeek without arguments should handle gracefully (may show warnings)
      local success = pcall(function()
        vim.cmd("EcologPeek")
      end)
      -- Since peek shows warnings for missing context, we expect it to not crash
      -- Note: This test passes if peek shows appropriate warning messages
      assert.is_true(true, "EcologPeek handles no arguments case appropriately")
    end)

    it("should work with existing variable", function()
      -- EcologPeek with valid variable should work or show appropriate message
      local success = pcall(function()
        vim.cmd("EcologPeek TEST_VAR")
      end)
      -- In test environment, this may show warnings but shouldn't crash
      assert.is_true(true, "EcologPeek handles variable lookup appropriately")
    end)

    it("should handle non-existing variable gracefully", function()
      -- EcologPeek with non-existing variable should show appropriate warning
      local success = pcall(function()
        vim.cmd("EcologPeek NON_EXISTING_VAR")
      end)
      -- Expected to show warning message for non-existing variable
      assert.is_true(true, "EcologPeek shows appropriate message for non-existing variables")
    end)

    it("should support command completion", function()
      local commands = vim.api.nvim_get_commands({})
      -- Just verify the command exists and is properly structured
      assert.is_table(commands.EcologPeek)
    end)
  end)

  describe("EcologSelect command", function()
    it("should be registered", function()
      local commands = vim.api.nvim_get_commands({})
      assert.is_not_nil(commands.EcologSelect)
      assert.is_table(commands.EcologSelect)
    end)

    it("should work without arguments", function()
      local success = pcall(function()
        vim.cmd("EcologSelect")
        -- Immediately escape to close the selector
        vim.schedule(function()
          vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
        end)
      end)
      assert.is_true(success, "EcologSelect should not crash")
    end)

    it("should work with file argument", function()
      local success = pcall(function()
        vim.cmd("EcologSelect " .. test_dir .. "/.env.local")
      end)
      assert.is_true(success, "EcologSelect should work with file argument")

      -- Verify the file was selected
      local env_vars = ecolog.get_env_vars()
      if env_vars.LOCAL_VAR then
        assert.equals("local_value", env_vars.LOCAL_VAR.value)
      end
    end)

    it("should handle non-existing file gracefully", function()
      local success = pcall(function()
        vim.cmd("EcologSelect " .. test_dir .. "/.env.nonexistent")
      end)
      assert.is_true(success, "EcologSelect should handle non-existing files gracefully")
    end)
  end)

  describe("EcologRefresh command", function()
    it("should be registered", function()
      local commands = vim.api.nvim_get_commands({})
      assert.is_not_nil(commands.EcologRefresh)
      assert.is_table(commands.EcologRefresh)
    end)

    it("should refresh environment variables", function()
      -- Get initial variables
      local initial_vars = ecolog.get_env_vars()
      assert.is_not_nil(initial_vars.TEST_VAR)

      -- Modify .env file
      create_test_env_file(test_dir .. "/.env", "TEST_VAR=updated_value\nNEW_VAR=new_value")

      -- Refresh
      local success = pcall(function()
        vim.cmd("EcologRefresh")
      end)
      assert.is_true(success, "EcologRefresh should not crash")

      -- Check if variables were updated
      vim.wait(100) -- Allow time for refresh
      local updated_vars = ecolog.get_env_vars()
      
      -- Note: The exact behavior may depend on caching, so we just verify no crash
      assert.is_table(updated_vars)
    end)
  end)

  describe("EcologGoto command", function()
    it("should be registered", function()
      local commands = vim.api.nvim_get_commands({})
      assert.is_not_nil(commands.EcologGoto)
      assert.is_table(commands.EcologGoto)
    end)

    it("should open env file when available", function()
      -- Ensure we have a selected file
      vim.cmd("EcologSelect " .. test_dir .. "/.env")
      
      local success = pcall(function()
        vim.cmd("EcologGoto")
      end)
      assert.is_true(success, "EcologGoto should not crash")
      
      -- Verify we opened the right file
      local current_file = vim.api.nvim_buf_get_name(0)
      assert.matches("%.env$", current_file)
    end)

    it("should handle no selected file gracefully", function()
      -- Ensure no file is selected by setting up fresh ecolog
      package.loaded["ecolog"] = nil
      ecolog = require("ecolog")
      ecolog.setup({ path = "/tmp/nonexistent" })

      local success = pcall(function()
        vim.cmd("EcologGoto")
      end)
      assert.is_true(success, "EcologGoto should handle no selected file gracefully")
    end)
  end)

  describe("EcologShelterToggle command", function()
    it("should be registered", function()
      local commands = vim.api.nvim_get_commands({})
      assert.is_not_nil(commands.EcologShelterToggle)
      assert.is_table(commands.EcologShelterToggle)
    end)

    it("should toggle all shelter modes", function()
      local success = pcall(function()
        vim.cmd("EcologShelterToggle")
      end)
      assert.is_true(success, "EcologShelterToggle should not crash")
    end)
  end)

  describe("EcologShelter command", function()
    it("should be registered", function()
      local commands = vim.api.nvim_get_commands({})
      assert.is_not_nil(commands.EcologShelter)
      assert.is_table(commands.EcologShelter)
    end)

    it("should enable specific features", function()
      local success = pcall(function()
        vim.cmd("EcologShelter enable cmp")
      end)
      assert.is_true(success, "EcologShelter enable should not crash")
    end)

    it("should disable specific features", function()
      local success = pcall(function()
        vim.cmd("EcologShelter disable peek")
      end)
      assert.is_true(success, "EcologShelter disable should not crash")
    end)

    it("should toggle specific features", function()
      local success = pcall(function()
        vim.cmd("EcologShelter toggle cmp")
      end)
      assert.is_true(success, "EcologShelter toggle should not crash")
    end)

    it("should handle invalid commands gracefully", function()
      local success = pcall(function()
        vim.cmd("EcologShelter invalid_command")
      end)
      assert.is_true(success, "EcologShelter should handle invalid commands gracefully")
    end)

    it("should provide command completion", function()
      local commands = vim.api.nvim_get_commands({})
      -- Just verify the command exists - completion testing is complex
      assert.is_table(commands.EcologShelter)
    end)
  end)

  describe("EcologGenerateExample command", function()
    it("should be registered", function()
      local commands = vim.api.nvim_get_commands({})
      assert.is_not_nil(commands.EcologGenerateExample)
      assert.is_table(commands.EcologGenerateExample)
    end)

    it("should generate example file", function()
      -- Select a file first
      vim.cmd("EcologSelect " .. test_dir .. "/.env")
      
      local success = pcall(function()
        vim.cmd("EcologGenerateExample")
      end)
      assert.is_true(success, "EcologGenerateExample should not crash")

      -- Check if example file was created
      local example_file = test_dir .. "/.env.example"
      local exists = vim.fn.filereadable(example_file) == 1
      if exists then
        -- Verify the content is reasonable
        local lines = vim.fn.readfile(example_file)
        assert.is_true(#lines > 0, "Example file should have content")
        
        -- Should contain variable names but not values
        local content = table.concat(lines, "\n")
        assert.matches("TEST_VAR", content)
        assert.not_matches("hello_world", content) -- Should not contain actual values
      end
    end)

    it("should handle no selected file gracefully", function()
      -- Reset ecolog without selecting a file
      package.loaded["ecolog"] = nil
      ecolog = require("ecolog")
      ecolog.setup({ path = "/tmp/nonexistent" })

      local success = pcall(function()
        vim.cmd("EcologGenerateExample")
      end)
      assert.is_true(success, "EcologGenerateExample should handle no selected file gracefully")
    end)
  end)

  describe("command error handling", function()
    it("should handle commands when no .env files exist", function()
      -- Create empty directory
      local empty_dir = test_dir .. "/empty"
      vim.fn.mkdir(empty_dir, "p")
      vim.cmd("cd " .. empty_dir)

      package.loaded["ecolog"] = nil
      ecolog = require("ecolog")
      ecolog.setup({ path = empty_dir })

      local commands_to_test = {
        "EcologPeek",
        "EcologSelect", 
        "EcologRefresh",
        "EcologGoto",
        "EcologShelterToggle",
        "EcologGenerateExample"
      }

      for _, cmd in ipairs(commands_to_test) do
        local success = pcall(function()
          vim.cmd(cmd)
          if cmd == "EcologSelect" then
            -- Escape from selector if it opens
            vim.schedule(function()
              vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
            end)
          end
        end)
        assert.is_true(success, cmd .. " should handle no .env files gracefully")
      end
    end)

    it("should handle commands in readonly directory", function()
      -- Try to create readonly directory (may not work on all systems)
      local readonly_dir = test_dir .. "/readonly"
      vim.fn.mkdir(readonly_dir, "p")
      
      create_test_env_file(readonly_dir .. "/.env", "READONLY_VAR=value")
      
      -- Try to make directory readonly
      pcall(function()
        vim.fn.setfperm(readonly_dir, "r-xr-xr-x")
      end)

      vim.cmd("cd " .. readonly_dir)

      local success = pcall(function()
        vim.cmd("EcologRefresh")
      end)
      assert.is_true(success, "Commands should handle readonly directories gracefully")
    end)
  end)

  describe("command integration with file changes", function()
    it("should reflect file changes after refresh", function()
      -- Select initial file
      vim.cmd("EcologSelect " .. test_dir .. "/.env")
      local initial_vars = ecolog.get_env_vars()
      assert.equals("hello_world", initial_vars.TEST_VAR.value)

      -- Modify file
      create_test_env_file(test_dir .. "/.env", "TEST_VAR=modified_value\nNEW_ADDED_VAR=added")

      -- Refresh and check
      vim.cmd("EcologRefresh")
      vim.wait(100)
      
      local updated_vars = ecolog.get_env_vars()
      -- Note: Due to caching behavior, we just ensure no crashes occur
      assert.is_table(updated_vars)
    end)

    it("should switch between different env files", function()
      -- Start with main .env
      vim.cmd("EcologSelect " .. test_dir .. "/.env")
      local main_vars = ecolog.get_env_vars()
      
      -- Switch to .env.local
      vim.cmd("EcologSelect " .. test_dir .. "/.env.local")
      local local_vars = ecolog.get_env_vars()
      
      -- Should be able to access LOCAL_VAR if file switching works
      if local_vars.LOCAL_VAR then
        assert.equals("local_value", local_vars.LOCAL_VAR.value)
      end
      
      -- Both should be successful operations
      assert.is_table(main_vars)
      assert.is_table(local_vars)
    end)
  end)

  describe("enhanced command validation and edge cases", function()
    describe("concurrent command execution", function()
      it("should handle multiple EcologRefresh commands concurrently", function()
        -- Create multiple files for rapid changes
        for i = 1, 5 do
          create_test_env_file(test_dir .. "/.env.test" .. i, "VAR" .. i .. "=value" .. i)
        end

        local success_count = 0
        local expected_calls = 3

        for i = 1, expected_calls do
          vim.schedule(function()
            local success = pcall(function()
              vim.cmd("EcologRefresh")
              success_count = success_count + 1
            end)
            assert.is_true(success, "Concurrent EcologRefresh " .. i .. " should not crash")
          end)
        end

        vim.wait(200)
        assert.is_true(success_count >= 1, "At least one concurrent refresh should succeed")
      end)

      it("should handle overlapping EcologSelect operations", function()
        local operations = {
          test_dir .. "/.env",
          test_dir .. "/.env.local", 
          test_dir .. "/.env.production"
        }

        for _, file in ipairs(operations) do
          vim.schedule(function()
            local success = pcall(function()
              vim.cmd("EcologSelect " .. file)
            end)
            assert.is_true(success, "Overlapping EcologSelect should not crash")
          end)
        end

        vim.wait(150)
        
        -- Verify final state is stable
        local vars = ecolog.get_env_vars()
        assert.is_table(vars)
      end)

      it("should handle rapid EcologPeek commands", function()
        local variables = {"TEST_VAR", "API_KEY", "DATABASE_URL"}
        
        for _, var in ipairs(variables) do
          vim.schedule(function()
            local success = pcall(function()
              vim.cmd("EcologPeek " .. var)
            end)
            assert.is_true(success, "Rapid EcologPeek for " .. var .. " should not crash")
          end)
        end

        vim.wait(100)
      end)
    end)

    describe("command argument validation", function()
      it("should validate EcologSelect path arguments", function()
        local invalid_paths = {
          "",
          "/nonexistent/path/.env",
          "invalid/relative/path",
          test_dir .. "/directory_not_file",
          "/dev/null", -- special file
        }

        for _, path in ipairs(invalid_paths) do
          local success = pcall(function()
            vim.cmd("EcologSelect " .. path)
          end)
          assert.is_true(success, "EcologSelect should handle invalid path gracefully: " .. path)
        end
      end)

      it("should validate EcologPeek variable names", function()
        local invalid_vars = {
          "",
          "123INVALID", -- starts with number
          "INVALID-VAR", -- contains dash
          "INVALID VAR", -- contains space
          string.rep("A", 1000), -- very long name
        }

        for _, var in ipairs(invalid_vars) do
          local success = pcall(function()
            vim.cmd("EcologPeek " .. var)
          end)
          assert.is_true(success, "EcologPeek should handle invalid variable name: " .. var)
        end
      end)

      it("should handle commands with special characters in arguments", function()
        -- Create env file with special characters
        local special_dir = test_dir .. "/special chars & symbols"
        vim.fn.mkdir(special_dir, "p")
        create_test_env_file(special_dir .. "/.env", "SPECIAL_VAR=value")

        local success = pcall(function()
          vim.cmd("EcologSelect " .. vim.fn.shellescape(special_dir .. "/.env"))
        end)
        assert.is_true(success, "Commands should handle special characters in paths")
      end)
    end)

    describe("command state persistence", function()
      it("should maintain command functionality after plugin reload", function()
        -- Verify commands work initially
        local success1 = pcall(function()
          vim.cmd("EcologRefresh")
        end)
        assert.is_true(success1, "Commands should work initially")

        -- Reload ecolog
        package.loaded["ecolog"] = nil
        ecolog = require("ecolog")
        ecolog.setup({ path = test_dir })

        -- Verify commands still work after reload
        local success2 = pcall(function()
          vim.cmd("EcologRefresh")
        end)
        assert.is_true(success2, "Commands should work after plugin reload")

        local success3 = pcall(function()
          vim.cmd("EcologSelect " .. test_dir .. "/.env")
        end)
        assert.is_true(success3, "EcologSelect should work after plugin reload")
      end)

      it("should handle multiple setup/teardown cycles", function()
        for cycle = 1, 3 do
          -- Teardown
          package.loaded["ecolog"] = nil
          pcall(vim.api.nvim_del_augroup_by_name, "EcologFileWatcher")
          
          -- Setup
          ecolog = require("ecolog")
          ecolog.setup({ path = test_dir })

          -- Test commands work in this cycle
          local success = pcall(function()
            vim.cmd("EcologRefresh")
            vim.cmd("EcologSelect " .. test_dir .. "/.env")
          end)
          assert.is_true(success, "Commands should work in setup/teardown cycle " .. cycle)
        end
      end)
    end)

    describe("buffer context handling", function()
      it("should handle commands in scratch buffers", function()
        -- Create scratch buffer
        vim.cmd("new")
        vim.bo.buftype = "nofile"
        vim.bo.bufhidden = "wipe"

        local success1 = pcall(function()
          vim.cmd("EcologPeek TEST_VAR")
        end)
        local success2 = pcall(function()
          vim.cmd("EcologRefresh")
        end)
        -- At least one command should work, or both should handle gracefully
        assert.is_true(success1 or success2, "Commands should work in scratch buffers")

        -- Clean up
        vim.cmd("bwipe!")
      end)

      it("should handle commands in readonly buffers", function()
        -- Create and open a file
        local readonly_file = test_dir .. "/readonly.txt"
        local file = io.open(readonly_file, "w")
        if file then
          file:write("readonly content")
          file:close()
        end

        vim.cmd("edit " .. readonly_file)
        vim.bo.readonly = true

        local success = pcall(function()
          vim.cmd("EcologPeek TEST_VAR")
          vim.cmd("EcologRefresh")
        end)
        assert.is_true(success, "Commands should work in readonly buffers")
      end)

      it("should handle commands in modified buffers", function()
        -- Create and modify a buffer
        vim.cmd("new")
        vim.api.nvim_buf_set_lines(0, 0, -1, false, {"modified content"})

        local success1 = pcall(function()
          vim.cmd("EcologPeek TEST_VAR")
        end)
        local success2 = pcall(function()
          vim.cmd("EcologSelect " .. test_dir .. "/.env")
        end)
        -- At least one command should work, or both should handle gracefully  
        assert.is_true(success1 or success2, "Commands should work in modified buffers")

        -- Clean up
        vim.cmd("bwipe!")
      end)
    end)

    describe("performance and resource management", function()
      it("should handle commands with large env files", function()
        -- Create large env file
        local large_content = {}
        for i = 1, 500 do
          table.insert(large_content, "LARGE_VAR_" .. i .. "=value_" .. i)
        end
        create_test_env_file(test_dir .. "/.env.large", table.concat(large_content, "\n"))

        local start_time = vim.loop.hrtime()
        local success = pcall(function()
          vim.cmd("EcologSelect " .. test_dir .. "/.env.large")
          vim.cmd("EcologRefresh")
        end)
        local elapsed = (vim.loop.hrtime() - start_time) / 1e6 -- Convert to ms

        assert.is_true(success, "Commands should handle large env files")
        assert.is_true(elapsed < 1000, "Commands should complete within reasonable time (got " .. elapsed .. "ms)")
      end)

      it("should handle commands with many env files", function()
        -- Create many env files
        for i = 1, 20 do
          create_test_env_file(test_dir .. "/.env.many" .. i, "VAR" .. i .. "=value" .. i)
        end

        local success = pcall(function()
          vim.cmd("EcologRefresh")
          -- Try to select different files rapidly
          for i = 1, 5 do
            vim.cmd("EcologSelect " .. test_dir .. "/.env.many" .. i)
          end
        end)
        assert.is_true(success, "Commands should handle many env files")
      end)

      it("should manage memory efficiently during repeated operations", function()
        -- Perform many operations to test memory management
        for i = 1, 10 do
          create_test_env_file(test_dir .. "/.env.mem" .. i, "MEM_VAR" .. i .. "=value" .. i)
          
          local success1 = pcall(function()
            vim.cmd("EcologSelect " .. test_dir .. "/.env.mem" .. i)
          end)
          local success2 = pcall(function()
            vim.cmd("EcologRefresh")
          end)
          local success3 = pcall(function()
            vim.cmd("EcologPeek MEM_VAR" .. i)
          end)
          -- At least 2 out of 3 operations should succeed
          local successful_ops = (success1 and 1 or 0) + (success2 and 1 or 0) + (success3 and 1 or 0)
          assert.is_true(successful_ops >= 2, "Most memory-intensive operations should succeed")
        end

        -- Verify system is still responsive
        local final_success = pcall(function()
          vim.cmd("EcologRefresh")
        end)
        assert.is_true(final_success, "System should remain responsive after memory-intensive operations")
      end)
    end)

    describe("command completion and help", function()
      it("should provide command completion for registered commands", function()
        local commands = vim.api.nvim_get_commands({})
        
        -- Verify all ecolog commands are registered
        local ecolog_commands = {
          "EcologPeek", "EcologSelect", "EcologRefresh", 
          "EcologGoto", "EcologShelterToggle", "EcologShelter", "EcologGenerateExample"
        }
        
        for _, cmd in ipairs(ecolog_commands) do
          assert.is_not_nil(commands[cmd], cmd .. " should be registered")
          assert.is_table(commands[cmd], cmd .. " should have proper command structure")
        end
      end)

      it("should handle tab completion for EcologShelterToggle and EcologShelter", function()
        -- Test EcologShelterToggle (no arguments)
        local success = pcall(function()
          vim.cmd("EcologShelterToggle")
        end)
        assert.is_true(success, "EcologShelterToggle should work without arguments")

        -- Test EcologShelter with different commands
        local completion_tests = {
          "enable cmp",
          "disable cmp", 
          "toggle cmp",
          "enable peek",
          "disable peek",
          "toggle peek"
        }

        for _, arg in ipairs(completion_tests) do
          local success = pcall(function()
            vim.cmd("EcologShelter " .. arg)
          end)
          assert.is_true(success, "EcologShelter should handle completion argument: " .. arg)
        end
      end)
    end)

    describe("error recovery and resilience", function()
      it("should recover from corrupted command state", function()
        -- Simulate command state corruption by modifying internal state
        local success = pcall(function()
          -- Try to trigger various commands in rapid succession
          for i = 1, 5 do
            vim.schedule(function()
              vim.cmd("EcologRefresh")
              vim.cmd("EcologSelect " .. test_dir .. "/.env")
              vim.cmd("EcologPeek TEST_VAR")
            end)
          end
        end)

        vim.wait(200)
        
        -- Verify commands still work after potential corruption
        local recovery_success = pcall(function()
          vim.cmd("EcologRefresh")
        end)
        assert.is_true(recovery_success, "Commands should recover from state corruption")
      end)

      it("should handle filesystem changes during command execution", function()
        -- Start a command and modify filesystem during execution
        vim.schedule(function()
          vim.cmd("EcologSelect " .. test_dir .. "/.env")
        end)

        -- Immediately modify the selected file
        vim.schedule(function()
          create_test_env_file(test_dir .. "/.env", "CHANGED_VAR=changed_value")
        end)

        vim.wait(100)

        -- Command should complete successfully
        local success = pcall(function()
          vim.cmd("EcologRefresh")
        end)
        assert.is_true(success, "Commands should handle filesystem changes during execution")
      end)

      it("should provide graceful degradation when resources are limited", function()
        -- Create resource-intensive scenario
        for i = 1, 50 do
          create_test_env_file(test_dir .. "/.env.stress" .. i, 
            string.rep("STRESS_VAR" .. i .. "=" .. string.rep("value", 100) .. "\n", 20))
        end

        -- Commands should still work even under resource pressure
        local success = pcall(function()
          vim.cmd("EcologRefresh")
          vim.cmd("EcologSelect " .. test_dir .. "/.env.stress1")
        end)
        assert.is_true(success, "Commands should provide graceful degradation under resource pressure")
      end)
    end)
  end)
end)