local assert = require("luassert")
local mock = require("luassert.mock")
local stub = require("luassert.stub")

describe("ecolog", function()
  local ecolog
  local test_dir = vim.fn.tempname()
  
  before_each(function()
    -- Create temp test directory
    vim.fn.mkdir(test_dir, "p")
    
    -- Reset modules
    package.loaded["ecolog"] = nil
    package.loaded["ecolog.utils"] = nil
    package.loaded["ecolog.types"] = nil
    package.loaded["ecolog.shelter"] = nil
    
    -- Load module
    ecolog = require("ecolog")
  end)
  
  after_each(function()
    -- Clean up test directory
    vim.fn.delete(test_dir, "rf")
  end)

  describe("setup()", function()
    it("should initialize with default options", function()
      ecolog.setup({
        shelter = {
          configuration = {},
          modules = {}
        },
        integrations = {},
        types = true
      })
      local config = ecolog.get_config()
      assert.equals(vim.fn.getcwd(), config.path)
      assert.equals("", config.preferred_environment)
    end)

    it("should merge custom options with defaults", function()
      local test_dir = vim.fn.getcwd()
      local opts = {
        path = test_dir,
        preferred_environment = "test",
        shelter = {
          configuration = {},
          modules = {}
        },
        integrations = {},
        types = {
          localhost = true,
          number = true
        }
      }
      ecolog.setup(opts)
      local config = ecolog.get_config()
      assert.equals(test_dir, config.path)
      assert.equals("test", config.preferred_environment)
    end)
  end)

  describe("env file handling", function()
    before_each(function()
      -- Create test env files
      local env_content = [[
        DB_HOST=localhost
        DB_PORT=5432
        API_KEY="secret123" # API key for testing
      ]]
      vim.fn.writefile(vim.split(env_content, "\n"), test_dir .. "/.env")
    end)

    it("should find and parse env files", function()
      ecolog.setup({
        path = test_dir,
        shelter = {
          configuration = {},
          modules = {}
        },
        integrations = {},
        types = true
      })
      local env_vars = ecolog.get_env_vars()
      
      assert.is_not_nil(env_vars.DB_HOST)
      assert.equals("localhost", env_vars.DB_HOST.value)
      assert.equals("5432", env_vars.DB_PORT.value)
      assert.equals("secret123", env_vars.API_KEY.value)
    end)

    it("should detect variable types correctly", function()
      ecolog.setup({ 
        path = test_dir,
        shelter = {
          configuration = {},
          modules = {}
        },
        integrations = {},
        types = {
          localhost = true,
          number = true,
          url = true,
          database_url = true
        }
      })
      local env_vars = ecolog.get_env_vars()
      
      assert.equals("localhost", env_vars.DB_HOST.type)
      assert.equals("number", env_vars.DB_PORT.type)
      assert.equals("string", env_vars.API_KEY.type)
    end)
  end)
end) 