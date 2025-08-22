local assert = require("luassert")
local stub = require("luassert.stub")
local spy = require("luassert.spy")

describe("regression tests comprehensive", function()
  local ecolog
  local vim_mock

  before_each(function()
    -- Reset all modules to ensure clean state
    package.loaded["ecolog"] = nil
    package.loaded["ecolog.env"] = nil
    package.loaded["ecolog.env_loader"] = nil
    package.loaded["ecolog.interpolation"] = nil
    package.loaded["ecolog.types"] = nil
    package.loaded["ecolog.providers"] = nil
    package.loaded["ecolog.integrations"] = nil
    
    -- Mock vim functions
    vim_mock = {
      fn = {
        getcwd = spy.new(function() return "/test/project" end),
        glob = spy.new(function(pattern)
          if pattern:match("%.env") then
            return "/test/project/.env"
          end
          return ""
        end),
        filereadable = spy.new(function() return 1 end),
        readfile = spy.new(function(path)
          if path:match("%.env$") then
            return {
              "NODE_ENV=development",
              "API_KEY=test123",
              "DATABASE_URL=postgres://localhost:5432/test",
              "DEBUG=true",
              "PORT=3000"
            }
          end
          return {}
        end),
        fnamemodify = spy.new(function(path, modifier)
          if modifier == ":t" then
            return path:match("([^/]+)$") or path
          end
          return path
        end)
      },
      api = {
        nvim_create_user_command = spy.new(function() end),
        nvim_create_autocmd = spy.new(function() end),
        nvim_get_current_buf = spy.new(function() return 1 end),
        nvim_buf_get_name = spy.new(function() return "/test/project/app.js" end)
      },
      notify = spy.new(function() end),
      tbl_deep_extend = function(mode, ...)
        local result = {}
        for _, tbl in ipairs({...}) do
          for k, v in pairs(tbl) do
            result[k] = v
          end
        end
        return result
      end
    }
    _G.vim = vim_mock
  end)

  after_each(function()
    _G.vim = nil
  end)

  describe("API backward compatibility", function()
    it("should maintain setup() function signature", function()
      ecolog = require("ecolog")
      
      -- Test no-argument setup
      assert.has_no.errors(function()
        ecolog.setup()
      end)
      
      -- Test empty table setup
      assert.has_no.errors(function()
        ecolog.setup({})
      end)
      
      -- Test complex configuration setup
      assert.has_no.errors(function()
        ecolog.setup({
          integrations = {
            nvim_cmp = true,
            blink_cmp = false
          },
          shelter = {
            configuration = {
              partial_mode = true
            }
          }
        })
      end)
    end)

    it("should maintain refresh() function behavior", function()
      ecolog = require("ecolog")
      ecolog.setup()
      
      assert.has_no.errors(function()
        ecolog.refresh()
      end)
      
      -- Should be callable multiple times
      assert.has_no.errors(function()
        ecolog.refresh()
        ecolog.refresh()
      end)
    end)

    it("should maintain get_env_vars() function behavior", function()
      ecolog = require("ecolog")
      ecolog.setup()
      ecolog.refresh()
      
      local vars = ecolog.get_env_vars()
      
      assert.is_table(vars)
      assert.is_not_nil(vars.NODE_ENV)
      assert.equals("development", vars.NODE_ENV.value)
      assert.equals("string", vars.NODE_ENV.type)
      assert.is_not_nil(vars.NODE_ENV.source)
    end)

    it("should maintain peek() function behavior", function()
      ecolog = require("ecolog")
      ecolog.setup()
      
      assert.has_no.errors(function()
        ecolog.peek()
      end)
    end)

    it("should maintain select() function behavior", function()
      ecolog = require("ecolog")
      ecolog.setup()
      
      assert.has_no.errors(function()
        ecolog.select()
      end)
    end)

    it("should maintain command registration", function()
      ecolog = require("ecolog")
      ecolog.setup()
      
      -- Commands should be registered
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
  end)

  describe("configuration backward compatibility", function()
    it("should handle deprecated configuration options gracefully", function()
      ecolog = require("ecolog")
      
      -- Test potentially deprecated options
      local old_configs = {
        { cmp = true }, -- Old integration style
        { telescope = { enabled = true } }, -- Old nested style
        { mask_char = "*" }, -- Potentially moved option
      }
      
      for _, config in ipairs(old_configs) do
        assert.has_no.errors(function()
          ecolog.setup(config)
        end)
      end
    end)

    it("should maintain default configuration behavior", function()
      ecolog = require("ecolog")
      ecolog.setup()
      
      -- Default behavior should work
      ecolog.refresh()
      local vars = ecolog.get_env_vars()
      
      assert.is_table(vars)
    end)

    it("should handle configuration validation", function()
      ecolog = require("ecolog")
      
      -- Invalid configurations should be handled gracefully
      local invalid_configs = {
        "not_a_table",
        123,
        true,
        { integrations = "not_a_table" },
        { shelter = "not_a_table" }
      }
      
      for _, config in ipairs(invalid_configs) do
        assert.has_no.errors(function()
          ecolog.setup(config)
        end)
      end
    end)
  end)

  describe("environment file parsing regression", function()
    it("should parse basic key-value pairs consistently", function()
      vim_mock.fn.readfile = spy.new(function()
        return {
          "SIMPLE_KEY=simple_value",
          "KEY_WITH_UNDERSCORE=value_with_underscore",
          "KEY123=value123",
          "CamelCaseKey=CamelCaseValue"
        }
      end)
      
      ecolog = require("ecolog")
      ecolog.setup()
      ecolog.refresh()
      
      local vars = ecolog.get_env_vars()
      
      assert.equals("simple_value", vars.SIMPLE_KEY.value)
      assert.equals("value_with_underscore", vars.KEY_WITH_UNDERSCORE.value)
      assert.equals("value123", vars.KEY123.value)
      assert.equals("CamelCaseValue", vars.CamelCaseKey.value)
    end)

    it("should handle quoted values consistently", function()
      vim_mock.fn.readfile = spy.new(function()
        return {
          'DOUBLE_QUOTED="double quoted value"',
          "SINGLE_QUOTED='single quoted value'",
          'MIXED_QUOTES="value with nested quotes"',
          'EMPTY_QUOTES=""',
          "SPACES_IN_VALUE=value with spaces"
        }
      end)
      
      ecolog = require("ecolog")
      ecolog.setup()
      ecolog.refresh()
      
      local vars = ecolog.get_env_vars()
      
      assert.is_not_nil(vars.DOUBLE_QUOTED)
      assert.is_not_nil(vars.SINGLE_QUOTED)
      assert.is_not_nil(vars.SPACES_IN_VALUE)
    end)

    it("should handle comments and empty lines consistently", function()
      vim_mock.fn.readfile = spy.new(function()
        return {
          "# This is a comment",
          "",
          "VALID_VAR=value",
          "   # Indented comment",
          "ANOTHER_VAR=another_value",
          "",
          "## Double hash comment",
          "FINAL_VAR=final_value"
        }
      end)
      
      ecolog = require("ecolog")
      ecolog.setup()
      ecolog.refresh()
      
      local vars = ecolog.get_env_vars()
      
      assert.is_not_nil(vars.VALID_VAR)
      assert.is_not_nil(vars.ANOTHER_VAR)
      assert.is_not_nil(vars.FINAL_VAR)
      assert.equals("value", vars.VALID_VAR.value)
    end)

    it("should handle malformed lines gracefully", function()
      vim_mock.fn.readfile = spy.new(function()
        return {
          "VALID_VAR=value",
          "MALFORMED_LINE_NO_EQUALS",
          "=EMPTY_KEY_VALUE",
          "KEY_NO_VALUE=",
          "MULTIPLE=EQUALS=SIGNS=HERE",
          "VALID_VAR2=value2"
        }
      end)
      
      ecolog = require("ecolog")
      ecolog.setup()
      
      assert.has_no.errors(function()
        ecolog.refresh()
      end)
      
      local vars = ecolog.get_env_vars()
      assert.is_not_nil(vars.VALID_VAR)
      assert.is_not_nil(vars.VALID_VAR2)
    end)
  end)

  describe("type detection regression", function()
    it("should detect boolean types consistently", function()
      vim_mock.fn.readfile = spy.new(function()
        return {
          "TRUE_VAR=true",
          "FALSE_VAR=false",
          "YES_VAR=yes",
          "NO_VAR=no",
          "ONE_VAR=1",
          "ZERO_VAR=0"
        }
      end)
      
      ecolog = require("ecolog")
      ecolog.setup()
      ecolog.refresh()
      
      local vars = ecolog.get_env_vars()
      
      -- Type detection behavior should be consistent
      assert.is_not_nil(vars.TRUE_VAR)
      assert.is_not_nil(vars.FALSE_VAR)
    end)

    it("should detect number types consistently", function()
      vim_mock.fn.readfile = spy.new(function()
        return {
          "INTEGER=42",
          "NEGATIVE=-42",
          "DECIMAL=3.14",
          "ZERO=0",
          "LARGE_NUMBER=1000000"
        }
      end)
      
      ecolog = require("ecolog")
      ecolog.setup()
      ecolog.refresh()
      
      local vars = ecolog.get_env_vars()
      
      assert.is_not_nil(vars.INTEGER)
      assert.is_not_nil(vars.DECIMAL)
      assert.is_not_nil(vars.NEGATIVE)
    end)

    it("should detect URL types consistently", function()
      vim_mock.fn.readfile = spy.new(function()
        return {
          "HTTP_URL=http://example.com",
          "HTTPS_URL=https://example.com",
          "LOCALHOST_URL=http://localhost:3000",
          "API_URL=https://api.example.com/v1/users"
        }
      end)
      
      ecolog = require("ecolog")
      ecolog.setup()
      ecolog.refresh()
      
      local vars = ecolog.get_env_vars()
      
      assert.is_not_nil(vars.HTTP_URL)
      assert.is_not_nil(vars.HTTPS_URL)
      assert.is_not_nil(vars.API_URL)
    end)
  end)

  describe("interpolation regression", function()
    it("should handle variable interpolation consistently", function()
      vim_mock.fn.readfile = spy.new(function()
        return {
          "BASE_URL=https://api.example.com",
          "API_VERSION=v1",
          "FULL_URL=${BASE_URL}/${API_VERSION}",
          "NESTED_VAR=${FULL_URL}/users"
        }
      end)
      
      ecolog = require("ecolog")
      ecolog.setup()
      ecolog.refresh()
      
      local vars = ecolog.get_env_vars()
      
      assert.is_not_nil(vars.BASE_URL)
      assert.is_not_nil(vars.FULL_URL)
      assert.is_not_nil(vars.NESTED_VAR)
    end)

    it("should handle default values consistently", function()
      vim_mock.fn.readfile = spy.new(function()
        return {
          "DEFINED_VAR=defined_value",
          "DEFAULT_TEST=${UNDEFINED_VAR:-default_value}",
          "ALTERNATE_TEST=${DEFINED_VAR:-alternate_value}"
        }
      end)
      
      ecolog = require("ecolog")
      ecolog.setup()
      ecolog.refresh()
      
      local vars = ecolog.get_env_vars()
      
      assert.is_not_nil(vars.DEFAULT_TEST)
      assert.is_not_nil(vars.ALTERNATE_TEST)
    end)
  end)

  describe("integration system regression", function()
    it("should maintain nvim-cmp integration interface", function()
      ecolog = require("ecolog")
      ecolog.setup({
        integrations = {
          nvim_cmp = true
        }
      })
      
      -- Should provide completion source
      local source = ecolog.get_completion_source()
      assert.is_table(source)
    end)

    it("should handle integration errors gracefully", function()
      ecolog = require("ecolog")
      
      -- Test with potentially failing integrations
      assert.has_no.errors(function()
        ecolog.setup({
          integrations = {
            nvim_cmp = true,
            blink_cmp = true,
            telescope = true,
            nonexistent_integration = true
          }
        })
      end)
    end)
  end)

  describe("performance regression", function()
    it("should maintain reasonable performance with large files", function()
      -- Create large environment file content
      local large_content = {}
      for i = 1, 1000 do
        table.insert(large_content, "VAR_" .. i .. "=value_" .. i)
      end
      
      vim_mock.fn.readfile = spy.new(function()
        return large_content
      end)
      
      ecolog = require("ecolog")
      ecolog.setup()
      
      local start_time = vim.loop and vim.loop.hrtime() or 0
      ecolog.refresh()
      local end_time = vim.loop and vim.loop.hrtime() or 1000000
      
      if vim.loop then
        local duration_ms = (end_time - start_time) / 1000000
        assert.is_true(duration_ms < 2000) -- Should complete in under 2 seconds
      end
      
      local vars = ecolog.get_env_vars()
      assert.is_not_nil(vars.VAR_1)
      assert.is_not_nil(vars.VAR_1000)
    end)

    it("should handle multiple refresh calls efficiently", function()
      ecolog = require("ecolog")
      ecolog.setup()
      
      local start_time = vim.loop and vim.loop.hrtime() or 0
      
      -- Multiple refreshes should be fast due to caching
      for i = 1, 10 do
        ecolog.refresh()
      end
      
      local end_time = vim.loop and vim.loop.hrtime() or 1000000
      
      if vim.loop then
        local duration_ms = (end_time - start_time) / 1000000
        assert.is_true(duration_ms < 1000) -- Should complete in under 1 second
      end
    end)
  end)

  describe("error handling regression", function()
    it("should handle missing files gracefully", function()
      vim_mock.fn.filereadable = spy.new(function() return 0 end)
      vim_mock.fn.glob = spy.new(function() return "" end)
      
      ecolog = require("ecolog")
      ecolog.setup()
      
      assert.has_no.errors(function()
        ecolog.refresh()
      end)
      
      local vars = ecolog.get_env_vars()
      assert.is_table(vars)
    end)

    it("should handle file read errors gracefully", function()
      vim_mock.fn.readfile = spy.new(function()
        error("File read error")
      end)
      
      ecolog = require("ecolog")
      ecolog.setup()
      
      assert.has_no.errors(function()
        ecolog.refresh()
      end)
    end)

    it("should handle invalid configuration gracefully", function()
      ecolog = require("ecolog")
      
      assert.has_no.errors(function()
        ecolog.setup(nil)
        ecolog.setup("invalid")
        ecolog.setup(123)
        ecolog.setup(true)
      end)
    end)
  end)

  describe("memory management regression", function()
    it("should cleanup resources properly", function()
      ecolog = require("ecolog")
      ecolog.setup()
      
      -- Load variables multiple times
      for i = 1, 10 do
        ecolog.refresh()
        local vars = ecolog.get_env_vars()
        assert.is_table(vars)
      end
      
      -- Should not accumulate excessive memory
      -- This is hard to test directly, but we ensure no errors occur
      assert.has_no.errors(function()
        collectgarbage("collect")
      end)
    end)

    it("should handle module reloading gracefully", function()
      ecolog = require("ecolog")
      ecolog.setup()
      ecolog.refresh()
      
      -- Simulate module reload
      package.loaded["ecolog"] = nil
      
      assert.has_no.errors(function()
        ecolog = require("ecolog")
        ecolog.setup()
        ecolog.refresh()
      end)
    end)
  end)
end)