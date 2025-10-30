local assert = require("luassert")

describe("vim.env integration", function()
  local env
  local ecolog
  local test_vars = {}
  local has_uv_getenv = vim.uv and vim.uv.os_getenv ~= nil
  local has_uv_unsetenv = vim.uv and vim.uv.os_unsetenv ~= nil

  -- Helper to get env var value (works with both old and new Neovim)
  local function get_env_value(key)
    if has_uv_getenv then
      return vim.uv.os_getenv(key)
    else
      return vim.env[key]
    end
  end

  before_each(function()
    test_vars = {}

    -- Reset modules
    package.loaded["ecolog.env"] = nil
    package.loaded["ecolog"] = nil

    -- Load modules
    env = require("ecolog.env")
    ecolog = require("ecolog")

    -- Mock ecolog.get_env_vars
    ecolog.get_env_vars = function()
      return {
        TEST_VAR = { value = "test_value", source = ".env" },
        DB_HOST = { value = "localhost", source = ".env" },
        API_KEY = { value = "secret123", source = ".env" },
      }
    end

    -- Mock ecolog.get_config to enable vim_env
    ecolog.get_config = function()
      return {
        vim_env = true,
      }
    end
  end)

  after_each(function()
    -- Clean up test environment variables
    for key, _ in pairs(test_vars) do
      if has_uv_unsetenv then
        vim.uv.os_unsetenv(key)
      else
        vim.env[key] = nil
      end
    end
  end)

  describe("update_env_vars()", function()
    it("should update vim.env with environment variables", function()
      env.update_env_vars()

      test_vars.TEST_VAR = true
      test_vars.DB_HOST = true
      test_vars.API_KEY = true

      assert.equals("test_value", get_env_value("TEST_VAR"))
      assert.equals("localhost", get_env_value("DB_HOST"))
      assert.equals("secret123", get_env_value("API_KEY"))
    end)

    it("should remove variables that no longer exist", function()
      -- Set initial env vars
      env.update_env_vars()

      test_vars.TEST_VAR = true
      test_vars.DB_HOST = true
      test_vars.API_KEY = true

      -- Change mock to remove a variable
      ecolog.get_env_vars = function()
        return {
          TEST_VAR = { value = "test_value", source = ".env" },
          DB_HOST = { value = "localhost", source = ".env" },
          -- API_KEY removed
        }
      end

      env.update_env_vars()

      assert.equals("test_value", get_env_value("TEST_VAR"))
      assert.equals("localhost", get_env_value("DB_HOST"))
      assert.is_nil(get_env_value("API_KEY"))
    end)
  end)

  describe("get()", function()
    it("should return all environment variables when no key is provided", function()
      local vars = env.get()
      assert.equals("test_value", vars.TEST_VAR.value)
      assert.equals("localhost", vars.DB_HOST.value)
      assert.equals("secret123", vars.API_KEY.value)
    end)

    it("should return specific environment variable when key is provided", function()
      local var = env.get("TEST_VAR")
      assert.equals("test_value", var.value)
      assert.equals(".env", var.source)
    end)

    it("should return nil for non-existent variables", function()
      local var = env.get("NON_EXISTENT")
      assert.is_nil(var)
    end)
  end)

  describe("setup()", function()
    it("should initialize environment variables", function()
      env.setup()

      test_vars.TEST_VAR = true
      test_vars.DB_HOST = true
      test_vars.API_KEY = true

      assert.equals("test_value", get_env_value("TEST_VAR"))
      assert.equals("localhost", get_env_value("DB_HOST"))
      assert.equals("secret123", get_env_value("API_KEY"))
    end)
  end)
end)
