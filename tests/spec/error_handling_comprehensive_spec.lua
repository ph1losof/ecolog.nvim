local assert = require("luassert")

describe("error handling and edge cases", function()
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

  local function create_binary_file(path, size)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local file = io.open(path, "wb")
    if file then
      for i = 1, size do
        file:write(string.char(math.random(0, 255)))
      end
      file:close()
    end
  end

  local function cleanup_test_files(path)
    vim.fn.delete(path, "rf")
  end

  before_each(function()
    package.loaded["ecolog"] = nil
    package.loaded["ecolog.init"] = nil
    
    test_dir = vim.fn.tempname()
    vim.fn.mkdir(test_dir, "p")
    
    vim.cmd("cd " .. test_dir)
  end)

  after_each(function()
    cleanup_test_files(test_dir)
    vim.cmd("cd " .. vim.fn.expand("~"))
    
    pcall(vim.api.nvim_del_augroup_by_name, "EcologFileWatcher")
  end)

  describe("file system errors", function()
    it("should handle non-existent directories gracefully", function()
      local nonexistent_dir = test_dir .. "/nonexistent/nested/path"
      
      ecolog = require("ecolog")
      
      local success = pcall(function()
        ecolog.setup({
          path = nonexistent_dir,
          integrations = {
            nvim_cmp = false,
            blink_cmp = false,
          },
        })
      end)
      
      assert.is_true(success, "Should handle non-existent directories without crashing")
      
      vim.wait(100)
      
      local env_vars = ecolog.get_env_vars()
      assert.is_table(env_vars)
    end)

    it("should handle permission denied scenarios", function()
      -- Create a directory and try to make it read-only
      local restricted_dir = test_dir .. "/restricted"
      vim.fn.mkdir(restricted_dir, "p")
      create_test_file(restricted_dir .. "/.env", "TEST_VAR=value")
      
      -- Try to make directory read-only (may not work on all systems)
      pcall(function()
        vim.fn.system("chmod 000 " .. restricted_dir)
      end)

      ecolog = require("ecolog")
      
      local success = pcall(function()
        ecolog.setup({
          path = restricted_dir,
        })
      end)
      
      assert.is_true(success, "Should handle permission errors gracefully")
      
      -- Restore permissions for cleanup
      pcall(function()
        vim.fn.system("chmod 755 " .. restricted_dir)
      end)
    end)

    it("should handle binary files gracefully", function()
      create_binary_file(test_dir .. "/.env", 1000)

      ecolog = require("ecolog")
      
      local success = pcall(function()
        ecolog.setup({
          path = test_dir,
        })
      end)
      
      assert.is_true(success, "Should handle binary files without crashing")
      
      vim.wait(100)
      
      local env_vars = ecolog.get_env_vars()
      assert.is_table(env_vars)
    end)

    it("should handle corrupted files", function()
      -- Create a file with null bytes and control characters
      local corrupted_content = "VAR1=value1\0\0\0\nVAR2=value2\xFF\xFE\nVAR3=value3"
      create_test_file(test_dir .. "/.env", corrupted_content)

      ecolog = require("ecolog")
      
      local success = pcall(function()
        ecolog.setup({
          path = test_dir,
        })
      end)
      
      assert.is_true(success, "Should handle corrupted files gracefully")
      
      vim.wait(100)
      
      local env_vars = ecolog.get_env_vars()
      assert.is_table(env_vars)
      -- Should still be able to parse valid lines
      assert.is_not_nil(env_vars.VAR1)
      assert.is_not_nil(env_vars.VAR3)
    end)

    it("should handle symlink loops", function()
      local link1 = test_dir .. "/link1"
      local link2 = test_dir .. "/link2"
      
      -- Create circular symlinks (may not work on all systems)
      pcall(function()
        vim.fn.system("ln -s " .. link2 .. " " .. link1)
        vim.fn.system("ln -s " .. link1 .. " " .. link2)
      end)

      ecolog = require("ecolog")
      
      local success = pcall(function()
        ecolog.setup({
          path = test_dir,
          env_file_patterns = { "link*/.env" },
        })
      end)
      
      assert.is_true(success, "Should handle symlink loops gracefully")
    end)

    it("should handle very deep directory structures", function()
      local deep_path = test_dir
      for i = 1, 50 do
        deep_path = deep_path .. "/level" .. i
      end
      
      create_test_file(deep_path .. "/.env", "DEEP_VAR=deep_value")

      ecolog = require("ecolog")
      
      local success = pcall(function()
        ecolog.setup({
          path = test_dir,
          env_file_patterns = { "**/.env" },
        })
      end)
      
      assert.is_true(success, "Should handle deep directory structures")
    end)
  end)

  describe("configuration errors", function()
    it("should handle invalid configuration types", function()
      ecolog = require("ecolog")
      
      local invalid_configs = {
        "string_config",
        123,
        true,
        function() end,
      }

      for _, config in ipairs(invalid_configs) do
        local success = pcall(function()
          ecolog.setup(config)
        end)
        assert.is_true(success, "Should handle invalid config type: " .. type(config))
      end
    end)

    it("should handle malformed integration settings", function()
      ecolog = require("ecolog")
      
      local success = pcall(function()
        ecolog.setup({
          path = test_dir,
          integrations = {
            nvim_cmp = "invalid_type",
            blink_cmp = 123,
            lsp = function() end,
            invalid_integration = true,
          },
        })
      end)
      
      assert.is_true(success, "Should handle malformed integration settings")
    end)

    it("should handle invalid interpolation configuration", function()
      create_test_file(test_dir .. "/.env", "TEST_VAR=value")

      ecolog = require("ecolog")
      
      local success = pcall(function()
        ecolog.setup({
          path = test_dir,
          interpolation = {
            enabled = "not_a_boolean",
            max_iterations = "not_a_number",
            invalid_option = "test",
            features = {
              variables = "not_boolean",
              invalid_feature = true,
            },
          },
        })
      end)
      
      assert.is_true(success, "Should handle invalid interpolation config")
    end)

    it("should handle invalid custom types configuration", function()
      ecolog = require("ecolog")
      
      local success = pcall(function()
        ecolog.setup({
          path = test_dir,
          types = "invalid",
          custom_types = {
            invalid_type = "not_a_table",
            valid_type = {
              pattern = 123, -- Should be string
              validate = "not_a_function",
            },
          },
        })
      end)
      
      assert.is_true(success, "Should handle invalid custom types config")
    end)

    it("should handle circular provider dependencies", function()
      ecolog = require("ecolog")
      
      local success = pcall(function()
        ecolog.setup({
          path = test_dir,
          providers = {
            provider1 = {
              name = "provider1",
              pattern = "test",
              requires = { "provider2" },
            },
            provider2 = {
              name = "provider2", 
              pattern = "test",
              requires = { "provider1" }, -- Circular dependency
            },
          },
        })
      end)
      
      assert.is_true(success, "Should handle circular provider dependencies")
    end)
  end)

  describe("runtime errors", function()
    it("should handle file corruption during runtime", function()
      create_test_file(test_dir .. "/.env", "TEST_VAR=initial")

      ecolog = require("ecolog")
      ecolog.setup({
        path = test_dir,
      })
      
      vim.wait(100)
      
      local initial_vars = ecolog.get_env_vars()
      assert.equals("initial", initial_vars.TEST_VAR.value)

      -- Corrupt the file during runtime
      create_binary_file(test_dir .. "/.env", 500)
      
      local success = pcall(function()
        ecolog.refresh_env_vars({ path = test_dir })
      end)
      
      assert.is_true(success, "Should handle file corruption during runtime")
    end)

    it("should handle file deletion during operation", function()
      create_test_file(test_dir .. "/.env", "TEST_VAR=value")

      ecolog = require("ecolog")
      ecolog.setup({
        path = test_dir,
      })
      
      vim.wait(100)
      
      -- Delete file during operation
      vim.fn.delete(test_dir .. "/.env")
      
      local success = pcall(function()
        ecolog.refresh_env_vars({ path = test_dir })
      end)
      
      assert.is_true(success, "Should handle file deletion during operation")
      
      local env_vars = ecolog.get_env_vars()
      assert.is_table(env_vars)
    end)

    it("should handle rapid file changes", function()
      create_test_file(test_dir .. "/.env", "TEST_VAR=initial")

      ecolog = require("ecolog")
      ecolog.setup({
        path = test_dir,
      })
      
      vim.wait(100)

      -- Rapidly change file content
      for i = 1, 20 do
        vim.schedule(function()
          create_test_file(test_dir .. "/.env", "TEST_VAR=change_" .. i)
        end)
      end
      
      vim.wait(500)
      
      local success = pcall(function()
        local env_vars = ecolog.get_env_vars()
        assert.is_table(env_vars)
      end)
      
      assert.is_true(success, "Should handle rapid file changes")
    end)

    it("should handle memory pressure scenarios", function()
      -- Create a large file that might cause memory pressure
      local large_content = {}
      for i = 1, 10000 do
        table.insert(large_content, "VAR_" .. i .. "=" .. string.rep("x", 100))
      end
      create_test_file(test_dir .. "/.env", table.concat(large_content, "\n"))

      ecolog = require("ecolog")
      
      -- Force low memory by allocating large tables
      local memory_hog = {}
      for i = 1, 1000 do
        memory_hog[i] = string.rep("x", 10000)
      end
      
      local success = pcall(function()
        ecolog.setup({
          path = test_dir,
        })
        vim.wait(1000)
        local env_vars = ecolog.get_env_vars()
        assert.is_table(env_vars)
      end)
      
      memory_hog = nil -- Release memory
      collectgarbage("collect")
      
      assert.is_true(success, "Should handle memory pressure scenarios")
    end)
  end)

  describe("integration errors", function()
    it("should handle missing completion engines gracefully", function()
      create_test_file(test_dir .. "/.env", "TEST_VAR=value")

      ecolog = require("ecolog")
      
      local success = pcall(function()
        ecolog.setup({
          path = test_dir,
          integrations = {
            nvim_cmp = true, -- May not be available in test environment
            blink_cmp = true,
            lsp = true,
            lspsaga = true,
          },
        })
      end)
      
      assert.is_true(success, "Should handle missing completion engines")
      
      vim.wait(100)
      
      local env_vars = ecolog.get_env_vars()
      assert.is_table(env_vars)
    end)

    it("should handle LSP server errors", function()
      create_test_file(test_dir .. "/.env", "TEST_VAR=value")

      ecolog = require("ecolog")
      ecolog.setup({
        path = test_dir,
        integrations = {
          lsp = true,
        },
      })
      
      vim.wait(100)
      
      -- Simulate LSP error conditions
      local success = pcall(function()
        -- Try to trigger LSP integration without actual LSP
        vim.lsp.buf.hover = function()
          error("LSP not available")
        end
        
        local env_vars = ecolog.get_env_vars()
        assert.is_table(env_vars)
      end)
      
      assert.is_true(success, "Should handle LSP server errors")
    end)

    it("should handle telescope/fzf unavailability", function()
      create_test_file(test_dir .. "/.env", "TEST_VAR=value")

      ecolog = require("ecolog")
      
      local success = pcall(function()
        ecolog.setup({
          path = test_dir,
          integrations = {
            fzf = true, -- May not be available
            telescope = true, -- May not be available
          },
        })
      end)
      
      assert.is_true(success, "Should handle missing telescope/fzf")
    end)
  end)

  describe("command errors", function()
    it("should handle command execution failures", function()
      create_test_file(test_dir .. "/.env", "TEST_VAR=value")

      ecolog = require("ecolog")
      ecolog.setup({
        path = test_dir,
      })
      
      vim.wait(100)

      -- Test various command failures
      local commands = {
        "EcologPeek NONEXISTENT_VAR",
        "EcologSelect /nonexistent/path",
        "EcologGoto", -- When no file selected
      }

      for _, cmd in ipairs(commands) do
        local success = pcall(function()
          vim.cmd(cmd)
        end)
        assert.is_true(success, "Command should not crash: " .. cmd)
      end
    end)

    it("should handle shelter command errors", function()
      ecolog = require("ecolog")
      ecolog.setup({
        path = test_dir,
      })
      
      local invalid_shelter_commands = {
        "EcologShelter invalid_action",
        "EcologShelter enable invalid_feature",
        "EcologShelter disable nonexistent_feature",
      }

      for _, cmd in ipairs(invalid_shelter_commands) do
        local success = pcall(function()
          vim.cmd(cmd)
        end)
        assert.is_true(success, "Shelter command should handle errors: " .. cmd)
      end
    end)
  end)

  describe("network and remote file scenarios", function()
    it("should handle network timeouts gracefully", function()
      -- Simulate network file path
      local network_path = "//remote.server/share/env"
      
      ecolog = require("ecolog")
      
      local success = pcall(function()
        ecolog.setup({
          path = network_path,
        })
      end)
      
      assert.is_true(success, "Should handle network paths gracefully")
    end)

    it("should handle mounted filesystem issues", function()
      -- Test with paths that might be on mounted filesystems
      local mount_paths = {
        "/mnt/remote/.env",
        "/media/usb/.env", 
        "/tmp/nfs/.env",
      }

      ecolog = require("ecolog")
      
      for _, path in ipairs(mount_paths) do
        local success = pcall(function()
          ecolog.setup({
            path = vim.fn.fnamemodify(path, ":h"),
          })
        end)
        assert.is_true(success, "Should handle mount path: " .. path)
      end
    end)
  end)

  describe("concurrency errors", function()
    it("should handle concurrent setup calls", function()
      create_test_file(test_dir .. "/.env", "TEST_VAR=value")

      ecolog = require("ecolog")
      
      local success_count = 0
      
      -- Try to setup multiple times concurrently
      for i = 1, 5 do
        vim.schedule(function()
          local success = pcall(function()
            ecolog.setup({
              path = test_dir,
            })
          end)
          if success then
            success_count = success_count + 1
          end
        end)
      end
      
      vim.wait(500)
      
      assert.is_true(success_count >= 1, "At least one setup should succeed")
    end)

    it("should handle concurrent refresh operations", function()
      create_test_file(test_dir .. "/.env", "TEST_VAR=value")

      ecolog = require("ecolog")
      ecolog.setup({
        path = test_dir,
      })
      
      vim.wait(100)

      local success_count = 0
      
      -- Try to refresh multiple times concurrently
      for i = 1, 10 do
        vim.schedule(function()
          local success = pcall(function()
            ecolog.refresh_env_vars({ path = test_dir })
          end)
          if success then
            success_count = success_count + 1
          end
        end)
      end
      
      vim.wait(500)
      
      assert.is_true(success_count >= 5, "Most refresh operations should succeed")
    end)
  end)

  describe("edge case recovery", function()
    it("should recover from file watcher failures", function()
      create_test_file(test_dir .. "/.env", "TEST_VAR=initial")

      ecolog = require("ecolog")
      ecolog.setup({
        path = test_dir,
      })
      
      vim.wait(100)
      
      -- Simulate file watcher failure by deleting and recreating directory
      cleanup_test_files(test_dir)
      vim.fn.mkdir(test_dir, "p")
      create_test_file(test_dir .. "/.env", "TEST_VAR=recovered")
      
      local success = pcall(function()
        ecolog.refresh_env_vars({ path = test_dir })
        vim.wait(100)
        local env_vars = ecolog.get_env_vars()
        assert.is_table(env_vars)
      end)
      
      assert.is_true(success, "Should recover from file watcher failures")
    end)

    it("should maintain stability after multiple errors", function()
      ecolog = require("ecolog")
      
      -- Cause multiple errors in sequence
      local operations = {
        function() ecolog.setup({ path = "/nonexistent" }) end,
        function() ecolog.setup({ integrations = "invalid" }) end,
        function() ecolog.refresh_env_vars({ path = "/invalid" }) end,
        function() vim.cmd("EcologSelect /invalid/path") end,
      }

      local final_success = true
      
      for _, op in ipairs(operations) do
        pcall(op) -- Ignore individual failures
      end
      
      -- Should still be able to do valid operations
      create_test_file(test_dir .. "/.env", "RECOVERY_VAR=success")
      
      local success = pcall(function()
        ecolog.setup({
          path = test_dir,
        })
        vim.wait(100)
        local env_vars = ecolog.get_env_vars()
        assert.is_not_nil(env_vars.RECOVERY_VAR)
      end)
      
      assert.is_true(success, "Should maintain stability after multiple errors")
    end)
  end)
end)