local assert = require("luassert")

describe("vim.env integration", function()
  local env
  local ecolog
  local original_env

  before_each(function()
    -- Store original vim.env
    original_env = vim.env
    vim.env = {}

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
    -- Restore original vim.env
    vim.env = original_env
  end)

  describe("update_env_vars()", function()
    it("should update vim.env with environment variables", function()
      env.update_env_vars()

      assert.equals("test_value", vim.env.TEST_VAR)
      assert.equals("localhost", vim.env.DB_HOST)
      assert.equals("secret123", vim.env.API_KEY)
    end)

    it("should remove variables that no longer exist", function()
      -- Set initial env vars
      env.update_env_vars()

      -- Change mock to remove a variable
      ecolog.get_env_vars = function()
        return {
          TEST_VAR = { value = "test_value", source = ".env" },
          DB_HOST = { value = "localhost", source = ".env" },
          -- API_KEY removed
        }
      end

      env.update_env_vars()

      assert.equals("test_value", vim.env.TEST_VAR)
      assert.equals("localhost", vim.env.DB_HOST)
      assert.is_nil(vim.env.API_KEY)
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

      assert.equals("test_value", vim.env.TEST_VAR)
      assert.equals("localhost", vim.env.DB_HOST)
      assert.equals("secret123", vim.env.API_KEY)
    end)
  end)
end)

