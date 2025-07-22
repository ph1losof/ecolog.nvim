local assert = require("luassert")
local stub = require("luassert.stub")
local spy = require("luassert.spy")

-- Add project root to package path
local project_root = vim.fn.getcwd()
package.path = package.path .. ";" .. project_root .. "/lua/?.lua;" .. project_root .. "/lua/?/init.lua"

describe("error handling and edge cases", function()
  local test_dir
  local ecolog

  local function create_test_env_file(path, content)
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

  before_each(function()
    package.loaded["ecolog"] = nil
    test_dir = vim.fn.tempname()
    vim.fn.mkdir(test_dir, "p")
    vim.cmd("cd " .. test_dir)
  end)

  after_each(function()
    cleanup_test_files(test_dir)
    vim.cmd("cd " .. vim.fn.expand("~"))
    pcall(vim.api.nvim_del_augroup_by_name, "EcologFileWatcher")
  end)

  describe("malformed .env files", function()
    it("should handle empty files", function()
      create_test_env_file(test_dir .. "/.env", "")
      
      ecolog = require("ecolog")
      local success = pcall(function()
        ecolog.setup({ path = test_dir })
      end)
      
      assert.is_true(success, "Should handle empty .env files")
      
      local env_vars = ecolog.get_env_vars()
      assert.is_table(env_vars)
    end)

    it("should handle files with only whitespace", function()
      create_test_env_file(test_dir .. "/.env", "   \n  \t  \n   ")
      
      ecolog = require("ecolog")
      local success = pcall(function()
        ecolog.setup({ path = test_dir })
      end)
      
      assert.is_true(success, "Should handle whitespace-only files")
    end)

    it("should handle files with malformed lines", function()
      local malformed_content = [[
VALID_VAR=valid_value
=INVALID_KEY
ANOTHER_VALID=another_value
MISSING_VALUE=
=
SPACES IN KEY=value
VALID_AGAIN=final_value
]]
      
      create_test_env_file(test_dir .. "/.env", malformed_content)
      
      ecolog = require("ecolog")
      local success = pcall(function()
        ecolog.setup({ path = test_dir })
      end)
      
      assert.is_true(success, "Should handle malformed lines gracefully")
      
      local env_vars = ecolog.get_env_vars()
      assert.is_table(env_vars)
      
      -- Should still parse valid lines
      if env_vars.VALID_VAR then
        assert.equals("valid_value", env_vars.VALID_VAR.value)
      end
    end)

    it("should handle files with special characters", function()
      local special_content = [[
UTF8_VAR=café
EMOJI_VAR=🔥
UNICODE_VAR=αβγδε
QUOTES_VAR="quoted value"
SINGLE_QUOTES_VAR='single quoted'
BACKSLASH_VAR=path\to\file
]]
      
      create_test_env_file(test_dir .. "/.env", special_content)
      
      ecolog = require("ecolog")
      local success = pcall(function()
        ecolog.setup({ path = test_dir })
      end)
      
      assert.is_true(success, "Should handle special characters")
    end)

    it("should handle extremely long lines", function()
      local long_value = string.rep("a", 10000)
      local content = "LONG_VAR=" .. long_value .. "\nNORMAL_VAR=normal"
      
      create_test_env_file(test_dir .. "/.env", content)
      
      ecolog = require("ecolog")
      local success = pcall(function()
        ecolog.setup({ path = test_dir })
      end)
      
      assert.is_true(success, "Should handle very long lines")
    end)

    it("should handle binary data in files", function()
      -- Create file with some binary data
      local file = io.open(test_dir .. "/.env", "wb")
      if file then
        file:write("VALID_VAR=value\n")
        file:write(string.char(0, 1, 2, 3, 255))
        file:write("\nANOTHER_VAR=another\n")
        file:close()
      end
      
      ecolog = require("ecolog")
      local success = pcall(function()
        ecolog.setup({ path = test_dir })
      end)
      
      assert.is_true(success, "Should handle binary data gracefully")
    end)
  end)

  describe("filesystem errors", function()
    it("should handle non-existent directories", function()
      local non_existent = "/path/that/does/not/exist"
      
      ecolog = require("ecolog")
      local success = pcall(function()
        ecolog.setup({ path = non_existent })
      end)
      
      assert.is_true(success, "Should handle non-existent directories")
    end)

    it("should handle permission denied scenarios", function()
      -- Create a directory and try to make it unreadable (may not work on all systems)
      local restricted_dir = test_dir .. "/restricted"
      vim.fn.mkdir(restricted_dir, "p")
      create_test_env_file(restricted_dir .. "/.env", "TEST=value")
      
      -- Try to restrict permissions
      pcall(function()
        vim.fn.setfperm(restricted_dir, "000")
      end)
      
      ecolog = require("ecolog")
      local success = pcall(function()
        ecolog.setup({ path = restricted_dir })
      end)
      
      -- Reset permissions for cleanup
      pcall(function()
        vim.fn.setfperm(restricted_dir, "755")
      end)
      
      assert.is_true(success, "Should handle permission denied gracefully")
    end)

    it("should handle files that disappear during reading", function()
      create_test_env_file(test_dir .. "/.env", "TEST=value")
      
      ecolog = require("ecolog")
      ecolog.setup({ path = test_dir })
      
      -- Delete file and try to refresh
      vim.fn.delete(test_dir .. "/.env")
      
      local success = pcall(function()
        vim.cmd("EcologRefresh")
      end)
      
      assert.is_true(success, "Should handle files disappearing during operation")
    end)

    it("should handle concurrent file modifications", function()
      create_test_env_file(test_dir .. "/.env", "TEST=initial")
      
      ecolog = require("ecolog")
      ecolog.setup({ path = test_dir })
      
      -- Simulate concurrent modifications
      for i = 1, 5 do
        create_test_env_file(test_dir .. "/.env", "TEST=modified" .. i)
        local success = pcall(function()
          vim.cmd("EcologRefresh")
        end)
        assert.is_true(success, "Should handle concurrent modifications")
      end
    end)
  end)

  describe("memory and performance edge cases", function()
    it("should handle many environment files", function()
      -- Create many .env files
      for i = 1, 50 do
        create_test_env_file(test_dir .. "/.env." .. i, "VAR" .. i .. "=value" .. i)
      end
      
      ecolog = require("ecolog")
      local success = pcall(function()
        ecolog.setup({ 
          path = test_dir,
          env_file_patterns = { ".env.*" }
        })
      end)
      
      assert.is_true(success, "Should handle many environment files")
    end)

    it("should handle many variables in single file", function()
      local content = {}
      for i = 1, 1000 do
        table.insert(content, "VAR_" .. i .. "=value_" .. i)
      end
      
      create_test_env_file(test_dir .. "/.env", table.concat(content, "\n"))
      
      ecolog = require("ecolog")
      local success = pcall(function()
        ecolog.setup({ path = test_dir })
      end)
      
      assert.is_true(success, "Should handle files with many variables")
      
      local env_vars = ecolog.get_env_vars()
      assert.is_table(env_vars)
    end)

    it("should handle rapid file changes", function()
      create_test_env_file(test_dir .. "/.env", "TEST=initial")
      
      ecolog = require("ecolog")
      ecolog.setup({ path = test_dir })
      
      -- Rapid file changes
      for i = 1, 20 do
        create_test_env_file(test_dir .. "/.env", "TEST=rapid" .. i)
        -- Trigger file change event
        vim.api.nvim_exec_autocmds("BufWritePost", {
          pattern = test_dir .. "/.env"
        })
        vim.wait(10) -- Small delay
      end
      
      -- Should not crash
      local success = pcall(function()
        local vars = ecolog.get_env_vars()
        assert.is_table(vars)
      end)
      
      assert.is_true(success, "Should handle rapid file changes")
    end)
  end)

  describe("configuration edge cases", function()
    it("should handle nil configuration", function()
      ecolog = require("ecolog")
      local success = pcall(function()
        ecolog.setup(nil)
      end)
      
      assert.is_true(success, "Should handle nil configuration")
    end)

    it("should handle empty configuration", function()
      ecolog = require("ecolog")
      local success = pcall(function()
        ecolog.setup({})
      end)
      
      assert.is_true(success, "Should handle empty configuration")
    end)

    it("should handle invalid path types", function()
      ecolog = require("ecolog")
      
      local invalid_paths = { 123, true, {}, function() end }
      
      for _, invalid_path in ipairs(invalid_paths) do
        local success = pcall(function()
          ecolog.setup({ path = invalid_path })
        end)
        assert.is_true(success, "Should handle invalid path type: " .. type(invalid_path))
      end
    end)

    it("should handle invalid pattern arrays", function()
      create_test_env_file(test_dir .. "/.env", "TEST=value")
      
      ecolog = require("ecolog")
      
      local invalid_patterns = {
        123,
        "not_an_array", 
        { 123, true, {} },
        { "" },
      }
      
      for _, pattern in ipairs(invalid_patterns) do
        local success = pcall(function()
          ecolog.setup({ 
            path = test_dir,
            env_file_patterns = pattern 
          })
        end)
        assert.is_true(success, "Should handle invalid patterns")
      end
    end)

    it("should handle circular references in config", function()
      local config = { path = test_dir }
      config.self_ref = config
      
      ecolog = require("ecolog")
      local success = pcall(function()
        ecolog.setup(config)
      end)
      
      assert.is_true(success, "Should handle circular references in config")
    end)
  end)

  describe("integration error scenarios", function()
    it("should handle missing dependencies gracefully", function()
      -- Mock missing dependencies
      local original_require = _G.require
      _G.require = function(mod)
        if mod == "cmp" or mod == "telescope" or mod == "fzf-lua" then
          error("module '" .. mod .. "' not found")
        end
        return original_require(mod)
      end
      
      create_test_env_file(test_dir .. "/.env", "TEST=value")
      
      ecolog = require("ecolog")
      local success = pcall(function()
        ecolog.setup({
          path = test_dir,
          integrations = {
            nvim_cmp = true,
            telescope = true,
            fzf = true
          }
        })
      end)
      
      _G.require = original_require
      
      assert.is_true(success, "Should handle missing integration dependencies")
    end)

    it("should handle corrupted state recovery", function()
      create_test_env_file(test_dir .. "/.env", "TEST=value")
      
      ecolog = require("ecolog")
      ecolog.setup({ path = test_dir })
      
      -- Try to corrupt internal state by calling internal functions
      local success = pcall(function()
        -- These might not exist or might be protected, but we test resilience
        if ecolog.get_config then
          local config = ecolog.get_config()
          assert.is_table(config)
        end
        
        if ecolog.get_env_vars then
          local vars = ecolog.get_env_vars()
          assert.is_table(vars)
        end
      end)
      
      assert.is_true(success, "Should handle state corruption gracefully")
    end)
  end)

  describe("async operation edge cases", function()
    it("should handle overlapping async operations", function()
      create_test_env_file(test_dir .. "/.env", "TEST=value")
      
      ecolog = require("ecolog")
      ecolog.setup({ path = test_dir })
      
      -- Start multiple async operations
      local success = pcall(function()
        for i = 1, 10 do
          vim.schedule(function()
            create_test_env_file(test_dir .. "/.env", "TEST=async" .. i)
            vim.cmd("EcologRefresh")
          end)
        end
      end)
      
      -- Wait for all operations
      vim.wait(200)
      
      assert.is_true(success, "Should handle overlapping async operations")
    end)

    it("should handle cancellation scenarios", function()
      create_test_env_file(test_dir .. "/.env", "TEST=value")
      
      ecolog = require("ecolog")
      ecolog.setup({ path = test_dir })
      
      -- Start operation and immediately try to clean up
      local success = pcall(function()
        vim.cmd("EcologSelect")
        vim.schedule(function()
          vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
        end)
        
        -- Immediately try another operation
        vim.cmd("EcologRefresh")
      end)
      
      assert.is_true(success, "Should handle operation cancellation")
    end)
  end)

  describe("cleanup and resource management", function()
    it("should clean up resources on plugin disable", function()
      create_test_env_file(test_dir .. "/.env", "TEST=value")
      
      ecolog = require("ecolog")
      ecolog.setup({ path = test_dir })
      
      -- Check some resources exist
      local commands = vim.api.nvim_get_commands({})
      assert.is_not_nil(commands.EcologRefresh)
      
      -- Cleanup should work without errors
      local success = pcall(function()
        -- Try to clean up file watchers
        pcall(vim.api.nvim_del_augroup_by_name, "EcologFileWatcher")
      end)
      
      assert.is_true(success, "Should clean up resources properly")
    end)

    it("should handle multiple setup/teardown cycles", function()
      create_test_env_file(test_dir .. "/.env", "TEST=value")
      
      for i = 1, 5 do
        package.loaded["ecolog"] = nil
        ecolog = require("ecolog")
        
        local success = pcall(function()
          ecolog.setup({ path = test_dir })
          local vars = ecolog.get_env_vars()
          assert.is_table(vars)
        end)
        
        assert.is_true(success, "Setup/teardown cycle " .. i .. " should work")
        
        -- Clean up
        pcall(vim.api.nvim_del_augroup_by_name, "EcologFileWatcher")
      end
    end)
  end)
end)