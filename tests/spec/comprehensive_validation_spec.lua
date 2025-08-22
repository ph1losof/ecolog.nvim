local assert = require("luassert")

-- Final validation test suite for ecolog.nvim
-- This test file serves as a comprehensive verification of all key functionality
-- and serves as regression testing for critical features

describe("ecolog.nvim comprehensive validation", function()
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

  before_each(function()
    -- Fix package.path to ensure ecolog is available even after directory changes
    local ecolog_dir = vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":p:h:h:h")
    local ecolog_lua_path = ecolog_dir .. "/lua/?.lua;" .. ecolog_dir .. "/lua/?/init.lua"
    if not package.path:find(ecolog_lua_path, 1, true) then
      package.path = ecolog_lua_path .. ";" .. package.path
    end
    
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

  describe("core functionality validation", function()
    it("should provide complete environment variable management", function()
      -- Create test environment files
      create_test_file(test_dir .. "/.env", [[
# Core environment variables
APP_NAME=EcologTest
API_KEY=secret123
DATABASE_URL=postgresql://localhost:5432/test
DEBUG=true
PORT=3000
]])

      create_test_file(test_dir .. "/.env.local", [[
# Local overrides
API_KEY=local_secret
LOCAL_VAR=local_only
]])

      ecolog = require("ecolog")
      ecolog.setup({
        path = test_dir,
        integrations = {
          nvim_cmp = false, -- Disable to avoid dependency issues in tests
          blink_cmp = false,
          lsp = false,
        },
        types = true,
        interpolation = {
          enabled = true,
        },
      })

      vim.wait(200)

      local env_vars = ecolog.get_env_vars()

      -- Verify core variables are loaded
      assert.is_not_nil(env_vars.APP_NAME)
      assert.equals("EcologTest", env_vars.APP_NAME.value)

      -- Verify type detection
      assert.is_not_nil(env_vars.DEBUG)
      assert.is_not_nil(env_vars.PORT)
      assert.is_not_nil(env_vars.DATABASE_URL)

      -- Verify file priority (local should override)
      assert.equals("local_secret", env_vars.API_KEY.value)
      assert.equals("local_only", env_vars.LOCAL_VAR.value)

      -- Verify source tracking
      assert.equals(test_dir .. "/.env", env_vars.APP_NAME.source)
      assert.equals(test_dir .. "/.env.local", env_vars.API_KEY.source)
    end)

    it("should handle interpolation correctly", function()
      create_test_file(test_dir .. "/.env", [[
BASE_URL=https://api.example.com
VERSION=v1
API_ENDPOINT=${BASE_URL}/${VERSION}
FULL_PATH=${API_ENDPOINT}/users
DEFAULT_HOST=${UNDEFINED_HOST:-localhost}
]])

      ecolog = require("ecolog")
      ecolog.setup({
        path = test_dir,
        interpolation = { enabled = true },
      })

      vim.wait(200)

      local env_vars = ecolog.get_env_vars()

      assert.equals("https://api.example.com/v1", env_vars.API_ENDPOINT.value)
      assert.equals("https://api.example.com/v1/users", env_vars.FULL_PATH.value)
      assert.equals("localhost", env_vars.DEFAULT_HOST.value)
    end)

    it("should provide working commands", function()
      create_test_file(test_dir .. "/.env", "TEST_VAR=command_test")

      ecolog = require("ecolog")
      ecolog.setup({
        path = test_dir,
      })

      vim.wait(100)

      -- Verify commands are registered
      local commands = vim.api.nvim_get_commands({})
      assert.is_not_nil(commands.EcologRefresh)
      assert.is_not_nil(commands.EcologPeek)
      assert.is_not_nil(commands.EcologSelect)
      assert.is_not_nil(commands.EcologShelterToggle)

      -- Test command execution
      local success = pcall(function()
        vim.cmd("EcologRefresh")
      end)
      assert.is_true(success, "EcologRefresh should work")

      local success2 = pcall(function()
        vim.cmd("EcologPeek TEST_VAR")
      end)
      assert.is_true(success2, "EcologPeek should work")
    end)
  end)

  describe("integration functionality validation", function()
    it("should provide completion integration capabilities", function()
      create_test_file(test_dir .. "/.env", [[
COMPLETION_VAR=test_value
API_KEY=secret123
DATABASE_URL=postgresql://localhost:5432/test
]])

      ecolog = require("ecolog")
      ecolog.setup({
        path = test_dir,
        integrations = {
          nvim_cmp = true,
          blink_cmp = true,
        },
      })

      vim.wait(200)

      -- Test that integration modules can be loaded
      local success_nvim_cmp = pcall(function()
        return require("ecolog.integrations.cmp.nvim_cmp")
      end)

      local success_blink_cmp = pcall(function()
        return require("ecolog.integrations.cmp.blink_cmp")
      end)

      assert.is_true(success_nvim_cmp, "nvim-cmp integration should load")
      assert.is_true(success_blink_cmp, "blink-cmp integration should load")
    end)

    it("should provide file watching capabilities", function()
      create_test_file(test_dir .. "/.env", "WATCH_VAR=initial")

      ecolog = require("ecolog")
      ecolog.setup({
        path = test_dir,
      })

      vim.wait(200)

      local initial_vars = ecolog.get_env_vars()
      assert.equals("initial", initial_vars.WATCH_VAR.value)

      -- Update file
      create_test_file(test_dir .. "/.env", "WATCH_VAR=updated")

      -- Trigger refresh
      ecolog.refresh_env_vars({ path = test_dir })
      vim.wait(100)

      local updated_vars = ecolog.get_env_vars()
      assert.equals("updated", updated_vars.WATCH_VAR.value)
    end)
  end)

  describe("security functionality validation", function()
    it("should provide shelter mode capabilities", function()
      create_test_file(test_dir .. "/.env", [[
API_KEY=secret123456
PUBLIC_VAR=not_secret
PASSWORD=supersecret
]])

      ecolog = require("ecolog")
      ecolog.setup({
        path = test_dir,
        shelter = {
          configuration = {
            partial_mode = {
              show_start = 2,
              show_end = 2,
              min_mask = 4,
            },
            mask_char = "*",
          },
          modules = {
            cmp = true,
            peek = false,
            files = true,
          },
        },
      })

      vim.wait(200)

      local shelter = require("ecolog.shelter")

      -- Test masking functionality
      local masked_secret = shelter.mask_value("secret123456", "files")
      assert.is_true(masked_secret:find("*") ~= nil, "Should mask sensitive values")

      -- Test feature toggles
      assert.is_true(shelter.is_enabled("cmp"))
      assert.is_false(shelter.is_enabled("peek"))

      shelter.set_state("toggle", "peek")
      assert.is_true(shelter.is_enabled("peek"))
    end)
  end)

  describe("type system validation", function()
    it("should detect and validate types correctly", function()
      create_test_file(test_dir .. "/.env", [[
DEBUG=true
PORT=3000
API_URL=https://api.example.com
DATABASE_URL=postgresql://user:pass@localhost:5432/db
IP_ADDRESS=192.168.1.1
EMAIL=test@example.com
JSON_CONFIG={"key":"value"}
]])

      ecolog = require("ecolog")
      ecolog.setup({
        path = test_dir,
        types = true,
      })

      vim.wait(200)

      local types = require("ecolog.types")

      -- Test type detection
      assert.equals("boolean", types.detect_type("true"))
      assert.equals("number", types.detect_type("3000"))
      assert.equals("url", types.detect_type("https://api.example.com"))
      assert.equals("database_url", types.detect_type("postgresql://user:pass@localhost:5432/db"))
      assert.equals("ipv4", types.detect_type("192.168.1.1"))
      assert.equals("email", types.detect_type("test@example.com"))
    end)
  end)

  describe("performance validation", function()
    it("should handle reasonable file sizes efficiently", function()
      local content = {}
      for i = 1, 500 do
        table.insert(content, "VAR_" .. i .. "=value_" .. i)
      end
      create_test_file(test_dir .. "/.env", table.concat(content, "\n"))

      ecolog = require("ecolog")

      local start_time = vim.loop.hrtime()
      ecolog.setup({
        path = test_dir,
      })

      vim.wait(500)

      local env_vars = ecolog.get_env_vars()
      local elapsed = (vim.loop.hrtime() - start_time) / 1e6

      assert.is_not_nil(env_vars.VAR_1)
      assert.is_not_nil(env_vars.VAR_500)
      assert.equals("value_1", env_vars.VAR_1.value)
      assert.equals("value_500", env_vars.VAR_500.value)

      -- Should handle 500 variables in reasonable time
      assert.is_true(elapsed < 2000, "Should handle 500 variables efficiently, took " .. elapsed .. "ms")
    end)

    it("should manage memory reasonably", function()
      collectgarbage("collect")
      local memory_before = collectgarbage("count")

      local content = {}
      for i = 1, 100 do
        table.insert(content, "MEMORY_VAR_" .. i .. "=" .. string.rep("x", 100))
      end
      create_test_file(test_dir .. "/.env", table.concat(content, "\n"))

      ecolog = require("ecolog")
      ecolog.setup({
        path = test_dir,
      })

      vim.wait(300)

      local env_vars = ecolog.get_env_vars()

      collectgarbage("collect")
      local memory_after = collectgarbage("count")
      local memory_increase = memory_after - memory_before

      assert.is_not_nil(env_vars.MEMORY_VAR_1)
      assert.is_not_nil(env_vars.MEMORY_VAR_100)

      -- Memory increase should be reasonable (less than 10MB)
      assert.is_true(memory_increase < 10000, "Memory usage should be reasonable, increased by " .. memory_increase .. "KB")
    end)
  end)

  describe("error resilience validation", function()
    it("should handle missing files gracefully", function()
      ecolog = require("ecolog")

      local success = pcall(function()
        ecolog.setup({
          path = test_dir .. "/nonexistent",
        })
      end)

      assert.is_true(success, "Should handle missing directories gracefully")

      vim.wait(100)

      local env_vars = ecolog.get_env_vars()
      assert.is_table(env_vars)
    end)

    it("should handle malformed files gracefully", function()
      create_test_file(test_dir .. "/.env", [[
VALID_VAR=value
INVALID LINE WITHOUT EQUALS
ANOTHER_VALID=another
=INVALID_KEY
]])

      ecolog = require("ecolog")

      local success = pcall(function()
        ecolog.setup({
          path = test_dir,
        })
      end)

      assert.is_true(success, "Should handle malformed files gracefully")

      vim.wait(100)

      local env_vars = ecolog.get_env_vars()
      assert.is_not_nil(env_vars.VALID_VAR)
      assert.is_not_nil(env_vars.ANOTHER_VALID)
      assert.equals("value", env_vars.VALID_VAR.value)
      assert.equals("another", env_vars.ANOTHER_VALID.value)
    end)

    it("should handle invalid configurations gracefully", function()
      create_test_file(test_dir .. "/.env", "TEST_VAR=value")

      ecolog = require("ecolog")

      local success = pcall(function()
        ecolog.setup({
          path = test_dir,
          invalid_option = "invalid",
          types = "invalid_type",
          interpolation = "invalid_interpolation",
        })
      end)

      assert.is_true(success, "Should handle invalid configuration gracefully")
    end)
  end)

  describe("regression testing", function()
    it("should maintain backward compatibility", function()
      -- Test that all public APIs are available and working
      ecolog = require("ecolog")

      assert.is_function(ecolog.setup)
      assert.is_function(ecolog.get_env_vars)
      assert.is_function(ecolog.refresh_env_vars)
      assert.is_function(ecolog.get_config)
      assert.is_function(ecolog.get_status)

      -- Test basic functionality works
      create_test_file(test_dir .. "/.env", "COMPAT_VAR=test")

      ecolog.setup({
        path = test_dir,
      })

      vim.wait(100)

      local env_vars = ecolog.get_env_vars()
      assert.is_not_nil(env_vars.COMPAT_VAR)
      assert.equals("test", env_vars.COMPAT_VAR.value)

      local config = ecolog.get_config()
      assert.is_table(config)
      assert.equals(test_dir, config.path)

      local status = ecolog.get_status()
      assert.is_string(status)
    end)

    it("should handle common user scenarios", function()
      -- Simulate a typical user setup
      create_test_file(test_dir .. "/.env", [[
# Database configuration
DATABASE_URL=postgresql://localhost:5432/myapp
REDIS_URL=redis://localhost:6379

# API configuration  
API_KEY=your_api_key_here
API_SECRET=your_api_secret_here
BASE_URL=https://api.myapp.com

# Application settings
DEBUG=false
PORT=3000
NODE_ENV=development
]])

      create_test_file(test_dir .. "/.env.local", [[
# Local development overrides
DEBUG=true
DATABASE_URL=postgresql://localhost:5432/myapp_dev
API_KEY=dev_api_key
]])

      ecolog = require("ecolog")
      ecolog.setup({
        path = test_dir,
        types = true,
        interpolation = { enabled = true },
        shelter = {
          configuration = {
            patterns = {
              ["*_KEY"] = "partial",
              ["*_SECRET"] = "full",
            },
          },
          modules = {
            cmp = true,
          },
        },
      })

      vim.wait(200)

      local env_vars = ecolog.get_env_vars()

      -- Verify expected behavior
      assert.equals("true", env_vars.DEBUG.value) -- Local override
      assert.equals("postgresql://localhost:5432/myapp_dev", env_vars.DATABASE_URL.value) -- Local override
      assert.equals("dev_api_key", env_vars.API_KEY.value) -- Local override
      assert.equals("3000", env_vars.PORT.value) -- From main .env
      assert.equals("development", env_vars.NODE_ENV.value) -- From main .env

      -- Test commands work
      local success = pcall(function()
        vim.cmd("EcologRefresh")
        vim.cmd("EcologShelterToggle")
      end)
      assert.is_true(success, "Common commands should work")
    end)
  end)
end)