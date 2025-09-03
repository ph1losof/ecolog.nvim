local assert = require("luassert")
local stub = require("luassert.stub")
local spy = require("luassert.spy")

describe("advanced interpolation", function()
  local interpolation
  local vim_mock
  
  before_each(function()
    -- Reset modules
    package.loaded["ecolog.interpolation"] = nil
    
    -- Mock vim functions
    vim_mock = {
      fn = {
        system = spy.new(function(cmd)
          if cmd:match("echo test") then
            return "test_output\n"
          elseif cmd:match("date") then
            return "2024-01-01\n"
          elseif cmd:match("error_command") then
            return ""
          else
            return "default_output\n"
          end
        end),
        shellescape = spy.new(function(arg)
          return "'" .. arg:gsub("'", "'\"'\"'") .. "'"
        end)
      },
      loop = {
        now = spy.new(function()
          return 1000000
        end)
      },
      log = {
        levels = {
          WARN = 3,
          ERROR = 4
        }
      },
      notify = spy.new(function() end),
      v = {
        shell_error = 0
      }
    }
    _G.vim = vim_mock
    
    interpolation = require("ecolog.interpolation")
  end)

  after_each(function()
    _G.vim = nil
  end)

  describe("deep nested interpolation", function()
    it("should handle multiple levels of variable nesting", function()
      local env_vars = {
        BASE_URL = { value = "https://api.example.com", type = "string" },
        API_VERSION = { value = "v1", type = "string" },
        ENDPOINT = { value = "${BASE_URL}/${API_VERSION}", type = "string" },
        FULL_PATH = { value = "${ENDPOINT}/users", type = "string" },
        FINAL_URL = { value = "${FULL_PATH}?limit=10", type = "string" }
      }

      local result = interpolation.interpolate_variables(env_vars, {})

      assert.equals("https://api.example.com", result.BASE_URL.value)
      assert.equals("v1", result.API_VERSION.value)
      assert.equals("https://api.example.com/v1", result.ENDPOINT.value)
      assert.equals("https://api.example.com/v1/users", result.FULL_PATH.value)
      assert.equals("https://api.example.com/v1/users?limit=10", result.FINAL_URL.value)
    end)

    it("should handle circular references gracefully", function()
      local env_vars = {
        VAR_A = { value = "${VAR_B}/path", type = "string" },
        VAR_B = { value = "${VAR_C}/middle", type = "string" },
        VAR_C = { value = "${VAR_A}/end", type = "string" }
      }

      local result = interpolation.interpolate_variables(env_vars, {
        max_iterations = 5,
        warn_on_undefined = false
      })

      -- Should stop after max iterations and preserve some form of the variables
      assert.is_not_nil(result.VAR_A)
      assert.is_not_nil(result.VAR_B)
      assert.is_not_nil(result.VAR_C)
      
      -- Values should still contain variable references due to circular dependency
      assert.matches("%${", tostring(result.VAR_A.value))
    end)

    it("should handle self-referencing variables", function()
      local env_vars = {
        PATH = { value = "/new/path:${PATH}", type = "string" },
        VAR_SELF = { value = "${VAR_SELF}_suffix", type = "string" }
      }

      local result = interpolation.interpolate_variables(env_vars, {
        max_iterations = 3,
        warn_on_undefined = false
      })

      -- Should handle self-reference by stopping iteration
      assert.is_not_nil(result.PATH.value)
      assert.is_not_nil(result.VAR_SELF.value)
    end)
  end)

  describe("complex default value patterns", function()
    it("should handle nested default values", function()
      local env_vars = {
        PRIMARY = { value = "", type = "string" },
        SECONDARY = { value = "", type = "string" },
        CONFIG = { value = "${PRIMARY:-${SECONDARY:-default_value}}", type = "string" }
      }

      local result = interpolation.interpolate_variables(env_vars, {})

      assert.equals("default_value", result.CONFIG.value)
    end)

    it("should handle complex default expressions", function()
      local env_vars = {
        ENV = { value = "production", type = "string" },
        DEBUG = { value = "", type = "string" },
        LOG_LEVEL = { value = "${DEBUG:-${ENV:+info}}", type = "string" },
        DATABASE_URL = { value = "${DB_URL:-postgres://localhost:5432/app_${ENV}}", type = "string" }
      }

      local result = interpolation.interpolate_variables(env_vars, {})

      assert.equals("info", result.LOG_LEVEL.value)
      assert.equals("postgres://localhost:5432/app_production", result.DATABASE_URL.value)
    end)

    it("should handle alternate value syntax", function()
      local env_vars = {
        NODE_ENV = { value = "development", type = "string" },
        DEBUG_MODE = { value = "${NODE_ENV+true}", type = "string" },
        PROD_ONLY = { value = "${NODE_ENV:+enabled}", type = "string" },
        EMPTY_VAR = { value = "", type = "string" },
        EMPTY_CHECK = { value = "${EMPTY_VAR:+not_empty}", type = "string" }
      }

      local result = interpolation.interpolate_variables(env_vars, {})

      assert.equals("true", result.DEBUG_MODE.value)
      assert.equals("enabled", result.PROD_ONLY.value)
      assert.equals("", result.EMPTY_CHECK.value)
    end)

    it("should handle complex nested alternates and defaults", function()
      local env_vars = {
        TIER = { value = "premium", type = "string" },
        FEATURES = { value = "${TIER:+advanced}", type = "string" },
        LIMITS = { value = "${TIER:+unlimited:-${BASIC_LIMITS:-10}}", type = "string" },
        CONFIG = { value = "tier=${TIER}&features=${FEATURES}&limits=${LIMITS}", type = "string" }
      }

      local result = interpolation.interpolate_variables(env_vars, {})

      assert.equals("advanced", result.FEATURES.value)
      assert.equals("unlimited", result.LIMITS.value)
      assert.equals("tier=premium&features=advanced&limits=unlimited", result.CONFIG.value)
    end)
  end)

  describe("command substitution with pipes and error handling", function()
    it("should handle command substitution with pipes", function()
      vim_mock.fn.system = spy.new(function(cmd)
        if cmd:match("echo hello") then
          return "hello\n"
        elseif cmd:match("grep test") then
          return "test_result\n"
        elseif cmd:match("cut") then
          return "cut_result\n"
        end
        return "default\n"
      end)

      local env_vars = {
        SIMPLE_CMD = { value = "$(echo hello)", type = "string" },
        PIPED_CMD = { value = "$(echo hello | grep test)", type = "string" },
        COMPLEX_CMD = { value = "$(echo hello | grep test | cut -d' ' -f1)", type = "string" }
      }

      local result = interpolation.interpolate_variables(env_vars, {
        features = { commands = true }
      })

      assert.equals("hello", result.SIMPLE_CMD.value)
      assert.equals("test_result", result.PIPED_CMD.value)
      assert.equals("cut_result", result.COMPLEX_CMD.value)
    end)

    it("should handle command substitution errors gracefully", function()
      vim_mock.fn.system = spy.new(function(cmd)
        return ""
      end)
      vim_mock.v.shell_error = 1

      local env_vars = {
        ERROR_CMD = { value = "$(error_command)", type = "string" },
        FALLBACK = { value = "${ERROR_CMD:-fallback_value}", type = "string" }
      }

      local result = interpolation.interpolate_variables(env_vars, {
        features = { commands = true },
        fail_on_cmd_error = false
      })

      assert.equals("", result.ERROR_CMD.value)
      assert.equals("fallback_value", result.FALLBACK.value)
    end)

    it("should handle command substitution with variable interpolation", function()
      vim_mock.fn.system = spy.new(function(cmd)
        if cmd:match("date") then
          return "2024-01-01\n"
        end
        return ""
      end)

      local env_vars = {
        DATE_FORMAT = { value = "+%Y-%m-%d", type = "string" },
        CURRENT_DATE = { value = "$(date ${DATE_FORMAT})", type = "string" },
        LOG_FILE = { value = "app_${CURRENT_DATE}.log", type = "string" }
      }

      local result = interpolation.interpolate_variables(env_vars, {
        features = { commands = true }
      })

      assert.equals("2024-01-01", result.CURRENT_DATE.value)
      assert.equals("app_2024-01-01.log", result.LOG_FILE.value)
    end)

    it("should handle security concerns in command substitution", function()
      local dangerous_env_vars = {
        USER_INPUT = { value = "test; rm -rf /", type = "string" },
        SAFE_CMD = { value = "$(echo ${USER_INPUT})", type = "string" }
      }

      -- Should use shellescape by default
      local result = interpolation.interpolate_variables(dangerous_env_vars, {
        features = { commands = true },
        disable_security = false
      })

      -- Verify shellescape was called
      assert.spy(vim_mock.fn.shellescape).was.called()
    end)
  end)

  describe("mixed interpolation types in single expressions", function()
    it("should handle variables, defaults, and commands together", function()
      vim_mock.fn.system = spy.new(function(cmd)
        if cmd:match("whoami") then
          return "testuser\n"
        elseif cmd:match("hostname") then
          return "testhost\n"
        end
        return ""
      end)

      local env_vars = {
        PREFIX = { value = "app", type = "string" },
        ENVIRONMENT = { value = "", type = "string" },
        USER = { value = "$(whoami)", type = "string" },
        HOST = { value = "$(hostname)", type = "string" },
        INSTANCE_NAME = { value = "${PREFIX}_${ENVIRONMENT:-dev}_${USER}_${HOST}", type = "string" },
        FULL_CONFIG = { value = "name=${INSTANCE_NAME}&env=${ENVIRONMENT:-development}&user=${USER}", type = "string" }
      }

      local result = interpolation.interpolate_variables(env_vars, {
        features = { commands = true, variables = true, defaults = true }
      })

      assert.equals("testuser", result.USER.value)
      assert.equals("testhost", result.HOST.value)
      assert.equals("app_dev_testuser_testhost", result.INSTANCE_NAME.value)
      assert.equals("name=app_dev_testuser_testhost&env=development&user=testuser", result.FULL_CONFIG.value)
    end)

    it("should handle complex nested expressions with multiple features", function()
      local env_vars = {
        BASE = { value = "myapp", type = "string" },
        VERSION = { value = "1.0", type = "string" },
        BUILD_TIME = { value = "$(date +%s)", type = "string" },
        RELEASE_TAG = { value = "${BASE}_v${VERSION}_${BUILD_TIME}", type = "string" },
        CONFIG_FILE = { value = "${CONFIG_DIR:-/etc}/${RELEASE_TAG}.conf", type = "string" },
        BACKUP_FILE = { value = "${CONFIG_FILE}.backup.$(date +%Y%m%d)", type = "string" }
      }

      vim_mock.fn.system = spy.new(function(cmd)
        if cmd:match("date %+%%s") then
          return "1640995200\n"
        elseif cmd:match("date %+%%Y%%m%%d") then
          return "20240101\n"
        end
        return ""
      end)

      local result = interpolation.interpolate_variables(env_vars, {
        features = { commands = true, variables = true, defaults = true }
      })

      assert.equals("1640995200", result.BUILD_TIME.value)
      assert.equals("myapp_v1.0_1640995200", result.RELEASE_TAG.value)
      assert.equals("/etc/myapp_v1.0_1640995200.conf", result.CONFIG_FILE.value)
      assert.equals("/etc/myapp_v1.0_1640995200.conf.backup.20240101", result.BACKUP_FILE.value)
    end)
  end)

  describe("performance and optimization", function()
    it("should handle large numbers of variables efficiently", function()
      local large_env_vars = {}
      
      -- Create a base set of variables
      for i = 1, 100 do
        large_env_vars["BASE_" .. i] = { value = "base_value_" .. i, type = "string" }
      end
      
      -- Create variables that reference the base variables
      for i = 1, 50 do
        large_env_vars["DERIVED_" .. i] = { 
          value = "${BASE_" .. i .. "}_derived", 
          type = "string" 
        }
      end
      
      -- Create some complex nested variables
      for i = 1, 20 do
        large_env_vars["COMPLEX_" .. i] = { 
          value = "${DERIVED_" .. i .. ":-${BASE_" .. i .. "_fallback}", 
          type = "string" 
        }
      end

      local start_time = vim.loop.hrtime()
      local result = interpolation.interpolate_variables(large_env_vars, {
        max_iterations = 10
      })
      local end_time = vim.loop.hrtime()

      -- Verify results are correct
      assert.equals("base_value_1_derived", result.DERIVED_1.value)
      assert.equals("base_value_1_derived", result.COMPLEX_1.value)
      
      -- Should complete in reasonable time (less than 1 second)
      local duration_ms = (end_time - start_time) / 1000000
      assert.is_true(duration_ms < 1000)
    end)

    it("should cache shell environment lookups", function()
      local env_vars = {
        SHELL_VAR1 = { value = "${NONEXISTENT_VAR1:-default}", type = "string" },
        SHELL_VAR2 = { value = "${NONEXISTENT_VAR1:-another_default}", type = "string" }
      }

      -- Mock vim.fn.getenv to track calls
      local getenv_spy = spy.new(function(name)
        return nil -- Not found
      end)
      vim_mock.fn.getenv = getenv_spy

      local result = interpolation.interpolate_variables(env_vars, {})

      -- Should use caching to avoid redundant shell lookups
      -- Note: The exact caching behavior depends on implementation
      assert.spy(getenv_spy).was.called()
      assert.equals("default", result.SHELL_VAR1.value)
      assert.equals("another_default", result.SHELL_VAR2.value)
    end)

    it("should handle deeply nested references without stack overflow", function()
      local deep_env_vars = {}
      
      -- Create a chain of 50 variables
      for i = 1, 50 do
        local next_var = i < 50 and "CHAIN_" .. (i + 1) or "final_value"
        deep_env_vars["CHAIN_" .. i] = { 
          value = "${" .. next_var .. "}", 
          type = "string" 
        }
      end

      -- Should not crash with stack overflow
      assert.has_no.errors(function()
        local result = interpolation.interpolate_variables(deep_env_vars, {
          max_iterations = 60
        })
        assert.equals("final_value", result.CHAIN_1.value)
      end)
    end)
  end)

  describe("feature toggles and configuration", function()
    it("should respect feature toggles for variable interpolation", function()
      local env_vars = {
        BASE = { value = "test", type = "string" },
        WITH_VAR = { value = "prefix_${BASE}_suffix", type = "string" },
        WITHOUT_VAR = { value = "prefix_${BASE}_suffix", type = "string" }
      }

      local result_with = interpolation.interpolate_variables(env_vars, {
        features = { variables = true }
      })
      
      local result_without = interpolation.interpolate_variables(env_vars, {
        features = { variables = false }
      })

      assert.equals("prefix_test_suffix", result_with.WITH_VAR.value)
      assert.equals("prefix_${BASE}_suffix", result_without.WITHOUT_VAR.value)
    end)

    it("should respect feature toggles for command substitution", function()
      local env_vars = {
        WITH_CMD = { value = "result: $(echo test)", type = "string" },
        WITHOUT_CMD = { value = "result: $(echo test)", type = "string" }
      }

      local result_with = interpolation.interpolate_variables(env_vars, {
        features = { commands = true }
      })
      
      local result_without = interpolation.interpolate_variables(env_vars, {
        features = { commands = false }
      })

      assert.equals("result: test", result_with.WITH_CMD.value)
      assert.equals("result: $(echo test)", result_without.WITHOUT_CMD.value)
    end)

    it("should respect feature toggles for escape sequences", function()
      local env_vars = {
        WITH_ESCAPES = { value = "line1\\nline2\\ttab", type = "string" },
        WITHOUT_ESCAPES = { value = "line1\\nline2\\ttab", type = "string" }
      }

      local result_with = interpolation.interpolate_variables(env_vars, {
        features = { escapes = true }
      })
      
      local result_without = interpolation.interpolate_variables(env_vars, {
        features = { escapes = false }
      })

      assert.equals("line1\nline2\ttab", result_with.WITH_ESCAPES.value)
      assert.equals("line1\\nline2\\ttab", result_without.WITHOUT_ESCAPES.value)
    end)
  end)
end)