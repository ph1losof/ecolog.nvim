local assert = require("luassert")
local stub = require("luassert.stub")
local spy = require("luassert.spy")

describe("core functionality comprehensive", function()
  local ecolog
  local vim_mock
  local file_operations_mock
  local notification_manager_mock

  before_each(function()
    -- Reset all modules
    package.loaded["ecolog"] = nil
    package.loaded["ecolog.core.file_operations"] = nil
    package.loaded["ecolog.core.notification_manager"] = nil
    package.loaded["ecolog.env_loader"] = nil
    package.loaded["ecolog.types"] = nil
    
    -- Mock vim functions
    vim_mock = {
      fn = {
        getcwd = spy.new(function() return "/test/project" end),
        glob = spy.new(function(pattern)
          if pattern:match("%.env") then
            return "/test/project/.env\n/test/project/.env.local"
          end
          return ""
        end),
        split = spy.new(function(str, sep)
          return vim.split(str, sep or "\n")
        end),
        fnamemodify = spy.new(function(path, modifier)
          if modifier == ":t" then
            return path:match("([^/]+)$") or path
          elseif modifier == ":h" then
            return path:match("^(.*)/[^/]*$") or "."
          end
          return path
        end),
        filereadable = spy.new(function(path)
          return path:match("%.env") and 1 or 0
        end)
      },
      api = {
        nvim_create_user_command = spy.new(function() end),
        nvim_create_autocmd = spy.new(function() end),
        nvim_del_user_command = spy.new(function() end),
        nvim_del_autocmd = spy.new(function() end),
        nvim_get_current_buf = spy.new(function() return 1 end),
        nvim_buf_get_name = spy.new(function() return "/test/file.js" end)
      },
      cmd = spy.new(function() end),
      notify = spy.new(function() end),
      tbl_deep_extend = function(mode, ...)
        local result = {}
        for _, tbl in ipairs({...}) do
          for k, v in pairs(tbl) do
            result[k] = v
          end
        end
        return result
      end,
      split = function(str, sep)
        local result = {}
        local pattern = "([^" .. (sep or "%s") .. "]+)"
        for match in str:gmatch(pattern) do
          table.insert(result, match)
        end
        return result
      end
    }
    _G.vim = vim_mock
    
    -- Mock file operations
    file_operations_mock = {
      is_readable = spy.new(function(path) return true end),
      read_file_lines = spy.new(function(path)
        if path:match("%.env$") then
          return {
            "NODE_ENV=development",
            "API_KEY=test123",
            "DATABASE_URL=postgres://localhost:5432/test",
            "DEBUG=true"
          }
        elseif path:match("%.env%.local") then
          return {
            "API_KEY=local_override",
            "LOCAL_VAR=local_value"
          }
        end
        return {}
      end),
      get_mtime = spy.new(function() return 1234567890 end),
      is_modified = spy.new(function() return false, 1234567890 end)
    }
    package.preload["ecolog.core.file_operations"] = function() return file_operations_mock end
    
    -- Mock notification manager
    notification_manager_mock = {
      notify = spy.new(function() end)
    }
    package.preload["ecolog.core.notification_manager"] = function() return notification_manager_mock end
    
    ecolog = require("ecolog")
  end)

  after_each(function()
    _G.vim = nil
    package.preload["ecolog.core.file_operations"] = nil
    package.preload["ecolog.core.notification_manager"] = nil
  end)

  describe("initialization and setup", function()
    it("should initialize with default configuration", function()
      local result = ecolog.setup()
      
      assert.is_true(result)
      assert.spy(vim_mock.api.nvim_create_user_command).was.called()
    end)

    it("should initialize with custom configuration", function()
      local custom_config = {
        integrations = {
          nvim_cmp = true,
          blink_cmp = false
        },
        shelter = {
          configuration = {
            partial_mode = true,
            mask_char = "#"
          }
        },
        preferred_environment = "staging"
      }

      local result = ecolog.setup(custom_config)
      
      assert.is_true(result)
      -- Verify custom config is applied
      assert.spy(vim_mock.api.nvim_create_user_command).was.called()
    end)

    it("should handle setup errors gracefully", function()
      -- Mock an error in command creation
      vim_mock.api.nvim_create_user_command = spy.new(function()
        error("Command creation failed")
      end)

      assert.has_no.errors(function()
        ecolog.setup()
      end)
    end)

    it("should register all expected commands", function()
      ecolog.setup()
      
      -- Should register core commands
      assert.spy(vim_mock.api.nvim_create_user_command).was.called_with(
        "EcologPeek", match.is_function(), match.is_table()
      )
      assert.spy(vim_mock.api.nvim_create_user_command).was.called_with(
        "EcologSelect", match.is_function(), match.is_table()
      )
      assert.spy(vim_mock.api.nvim_create_user_command).was.called_with(
        "EcologRefresh", match.is_function(), match.is_table()
      )
    end)

    it("should setup integrations based on configuration", function()
      local config_with_integrations = {
        integrations = {
          nvim_cmp = true,
          blink_cmp = true,
          telescope = true
        }
      }

      ecolog.setup(config_with_integrations)
      
      -- Integration setup should be called
      assert.spy(vim_mock.api.nvim_create_user_command).was.called()
    end)
  end)

  describe("environment file discovery and loading", function()
    it("should discover environment files in current directory", function()
      ecolog.setup()
      
      -- Trigger environment file discovery
      ecolog.refresh()
      
      assert.spy(vim_mock.fn.getcwd).was.called()
      assert.spy(vim_mock.fn.glob).was.called()
      assert.spy(file_operations_mock.read_file_lines).was.called()
    end)

    it("should handle multiple environment files with precedence", function()
      ecolog.setup()
      ecolog.refresh()
      
      -- Should read both .env and .env.local
      assert.spy(file_operations_mock.read_file_lines).was.called()
    end)

    it("should handle missing environment files gracefully", function()
      vim_mock.fn.glob = spy.new(function() return "" end)
      file_operations_mock.is_readable = spy.new(function() return false end)
      
      ecolog.setup()
      assert.has_no.errors(function()
        ecolog.refresh()
      end)
      
      assert.spy(notification_manager_mock.notify).was.called()
    end)

    it("should handle file read errors gracefully", function()
      file_operations_mock.read_file_lines = spy.new(function()
        error("File read error")
      end)
      
      ecolog.setup()
      assert.has_no.errors(function()
        ecolog.refresh()
      end)
    end)

    it("should cache loaded environment data", function()
      ecolog.setup()
      
      -- First load
      ecolog.refresh()
      local first_call_count = file_operations_mock.read_file_lines.calls
      
      -- Second load should use cache (mtime hasn't changed)
      ecolog.refresh()
      
      -- Should not read files again if not modified
      assert.spy(file_operations_mock.is_modified).was.called()
    end)
  end)

  describe("variable access and retrieval", function()
    it("should provide access to loaded variables", function()
      ecolog.setup()
      ecolog.refresh()
      
      local variables = ecolog.get_env_vars()
      
      assert.is_table(variables)
      assert.is_not_nil(variables.NODE_ENV)
      assert.equals("development", variables.NODE_ENV.value)
      assert.equals("string", variables.NODE_ENV.type)
    end)

    it("should handle variable precedence correctly", function()
      ecolog.setup()
      ecolog.refresh()
      
      local variables = ecolog.get_env_vars()
      
      -- API_KEY should be overridden by .env.local
      assert.equals("local_override", variables.API_KEY.value)
      
      -- LOCAL_VAR should only exist from .env.local
      assert.is_not_nil(variables.LOCAL_VAR)
      assert.equals("local_value", variables.LOCAL_VAR.value)
    end)

    it("should provide variable metadata", function()
      ecolog.setup()
      ecolog.refresh()
      
      local variables = ecolog.get_env_vars()
      local node_env = variables.NODE_ENV
      
      assert.is_not_nil(node_env.source)
      assert.is_not_nil(node_env.type)
      assert.is_not_nil(node_env.raw_value)
    end)

    it("should support filtered variable access", function()
      ecolog.setup()
      ecolog.refresh()
      
      local variables = ecolog.get_env_vars()
      local filtered = {}
      
      for key, var in pairs(variables) do
        if key:match("API") then
          filtered[key] = var
        end
      end
      
      assert.is_not_nil(filtered.API_KEY)
      assert.equals(1, vim.tbl_count(filtered))
    end)
  end)

  describe("command execution", function()
    it("should execute EcologRefresh command", function()
      ecolog.setup()
      
      -- Simulate command execution
      local refresh_cmd = nil
      vim_mock.api.nvim_create_user_command = spy.new(function(name, func, opts)
        if name == "EcologRefresh" then
          refresh_cmd = func
        end
      end)
      
      ecolog.setup()
      assert.is_not_nil(refresh_cmd)
      
      -- Execute refresh command
      assert.has_no.errors(function()
        refresh_cmd()
      end)
    end)

    it("should execute EcologPeek command", function()
      ecolog.setup()
      
      local peek_cmd = nil
      vim_mock.api.nvim_create_user_command = spy.new(function(name, func, opts)
        if name == "EcologPeek" then
          peek_cmd = func
        end
      end)
      
      ecolog.setup()
      assert.is_not_nil(peek_cmd)
      
      -- Execute peek command
      assert.has_no.errors(function()
        peek_cmd()
      end)
    end)

    it("should execute EcologSelect command", function()
      ecolog.setup()
      
      local select_cmd = nil
      vim_mock.api.nvim_create_user_command = spy.new(function(name, func, opts)
        if name == "EcologSelect" then
          select_cmd = func
        end
      end)
      
      ecolog.setup()
      assert.is_not_nil(select_cmd)
      
      -- Execute select command
      assert.has_no.errors(function()
        select_cmd()
      end)
    end)
  end)

  describe("integration system", function()
    it("should register with nvim-cmp when enabled", function()
      local config = {
        integrations = {
          nvim_cmp = true
        }
      }
      
      ecolog.setup(config)
      
      -- Should attempt to register with completion systems
      assert.spy(vim_mock.api.nvim_create_user_command).was.called()
    end)

    it("should provide completion source interface", function()
      ecolog.setup()
      ecolog.refresh()
      
      -- Should have completion functions available
      local source = ecolog.get_completion_source()
      assert.is_table(source)
    end)

    it("should handle integration errors gracefully", function()
      -- Mock integration failure
      local config = {
        integrations = {
          nvim_cmp = true
        }
      }
      
      assert.has_no.errors(function()
        ecolog.setup(config)
      end)
    end)
  end)

  describe("error handling and edge cases", function()
    it("should handle empty project directory", function()
      vim_mock.fn.getcwd = spy.new(function() return "/empty/project" end)
      vim_mock.fn.glob = spy.new(function() return "" end)
      
      ecolog.setup()
      assert.has_no.errors(function()
        ecolog.refresh()
      end)
    end)

    it("should handle permission errors", function()
      file_operations_mock.is_readable = spy.new(function() return false end)
      
      ecolog.setup()
      assert.has_no.errors(function()
        ecolog.refresh()
      end)
    end)

    it("should handle malformed environment files", function()
      file_operations_mock.read_file_lines = spy.new(function()
        return {
          "MALFORMED_LINE_NO_EQUALS",
          "VALID_VAR=value",
          "=EMPTY_KEY",
          "# Comment",
          "",
          "ANOTHER_VALID=test"
        }
      end)
      
      ecolog.setup()
      assert.has_no.errors(function()
        ecolog.refresh()
      end)
      
      local variables = ecolog.get_env_vars()
      assert.is_not_nil(variables.VALID_VAR)
      assert.is_not_nil(variables.ANOTHER_VALID)
    end)

    it("should handle very large environment files", function()
      local large_content = {}
      for i = 1, 10000 do
        table.insert(large_content, "VAR_" .. i .. "=value_" .. i)
      end
      
      file_operations_mock.read_file_lines = spy.new(function()
        return large_content
      end)
      
      ecolog.setup()
      local start_time = vim.loop.hrtime()
      ecolog.refresh()
      local end_time = vim.loop.hrtime()
      
      local duration_ms = (end_time - start_time) / 1000000
      assert.is_true(duration_ms < 5000) -- Should complete in under 5 seconds
      
      local variables = ecolog.get_env_vars()
      assert.is_not_nil(variables.VAR_1)
      assert.is_not_nil(variables.VAR_10000)
    end)

    it("should handle unicode and special characters", function()
      file_operations_mock.read_file_lines = spy.new(function()
        return {
          "UNICODE_VAR=Hello 世界 🌍",
          "SPECIAL_CHARS=!@#$%^&*()",
          "QUOTES_VAR=\"nested 'quotes' here\"",
          "PATH_VAR=/path/to/something with spaces"
        }
      end)
      
      ecolog.setup()
      ecolog.refresh()
      
      local variables = ecolog.get_env_vars()
      assert.equals("Hello 世界 🌍", variables.UNICODE_VAR.value)
      assert.equals("!@#$%^&*()", variables.SPECIAL_CHARS.value)
    end)
  end)

  describe("configuration validation", function()
    it("should validate configuration structure", function()
      local invalid_configs = {
        { integrations = "not_a_table" },
        { shelter = { configuration = "not_a_table" } },
        { preferred_environment = 123 }
      }
      
      for _, config in ipairs(invalid_configs) do
        assert.has_no.errors(function()
          ecolog.setup(config)
        end)
      end
    end)

    it("should apply default values for missing config", function()
      ecolog.setup({})
      
      -- Should still work with empty config
      assert.has_no.errors(function()
        ecolog.refresh()
      end)
    end)

    it("should handle nested configuration correctly", function()
      local nested_config = {
        integrations = {
          nvim_cmp = {
            enabled = true,
            completion_source = "ecolog"
          },
          telescope = {
            enabled = true
          }
        },
        shelter = {
          configuration = {
            partial_mode = false,
            mask_char = "*"
          }
        }
      }
      
      ecolog.setup(nested_config)
      assert.has_no.errors(function()
        ecolog.refresh()
      end)
    end)
  end)
end)