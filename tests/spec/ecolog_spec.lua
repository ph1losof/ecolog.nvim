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
    package.loaded["ecolog.providers"] = nil

    -- Mock providers module
    package.loaded["ecolog.providers"] = {
      get_providers = function(filetype)
        return {}
      end,
      load_providers_for_filetype = function(filetype) end,
      register = function() end,
      register_many = function() end
    }

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
          modules = {},
        },
        integrations = {
          nvim_cmp = false,
          blink_cmp = false,
          lsp = false,
          lspsaga = false,
          fzf = false,
        },
        types = true,
      })
      local config = ecolog.get_config()
      assert.equals(vim.fn.getcwd(), config.path)
      assert.equals("", config.preferred_environment)
    end)
  end)

  describe("provider loading", function()
    local providers
    local mock_provider = {
      pattern = "%$[%w_]*$",
      filetype = "typescript",
      extract_var = function() end,
      get_completion_trigger = function() return "$" end,
    }
    local providers_cache = {}

    before_each(function()
      package.loaded["ecolog.providers"] = nil
      providers_cache = {}
      
      -- Create providers module with caching behavior
      providers = {
        get_providers = function(filetype)
          if not providers_cache[filetype] then
            providers.load_providers_for_filetype(filetype)
            providers_cache[filetype] = {}
          end
          return providers_cache[filetype]
        end,
        load_providers_for_filetype = function() end,
        register = function() end,
        register_many = function() end
      }
      
      -- Set up stubs
      stub(providers, "load_providers_for_filetype")
      stub(providers, "register")
      
      -- Install the mocked module
      package.loaded["ecolog.providers"] = providers
    end)

    after_each(function()
      providers.load_providers_for_filetype:revert()
      providers.register:revert()
    end)

    it("should load providers on demand by filetype", function()
      local filetype = "typescript"
      providers.get_providers(filetype)
      assert.stub(providers.load_providers_for_filetype).was_called_with(filetype)
    end)

    it("should register provider for specific filetype", function()
      providers.register(mock_provider)
      assert.stub(providers.register).was_called_with(mock_provider)
    end)

    it("should cache providers after loading", function()
      local filetype = "typescript"
      providers.get_providers(filetype)
      providers.get_providers(filetype)
      assert.stub(providers.load_providers_for_filetype).was_called(1)
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
          modules = {},
        },
        integrations = {
          nvim_cmp = false,
          blink_cmp = false,
          lsp = false,
          lspsaga = false,
          fzf = false,
        },
        types = true,
      })
      local env_vars = ecolog.get_env_vars()

      assert.is_not_nil(env_vars.DB_HOST)
      assert.equals("localhost", env_vars.DB_HOST.value)
      assert.equals("5432", env_vars.DB_PORT.value)
      assert.equals("secret123", env_vars.API_KEY.value)
    end)
  end)

  describe("file watcher", function()
    local test_dir = vim.fn.tempname()
    local original_notify
    local notify_messages = {}

    before_each(function()
      vim.fn.mkdir(test_dir, "p")
      original_notify = vim.notify
      notify_messages = {}
      vim.notify = function(msg, level)
        table.insert(notify_messages, { msg = msg, level = level })
      end
    end)

    after_each(function()
      vim.fn.delete(test_dir, "rf")
      vim.notify = original_notify
    end)

    it("should detect new env file creation", function()
      ecolog.setup({
        path = test_dir,
        shelter = {
          configuration = {},
          modules = {},
        },
        integrations = {
          nvim_cmp = false,
          blink_cmp = false,
          lsp = false,
          lspsaga = false,
          fzf = false,
        },
        types = true,
      })

      -- Create new env file
      local env_content = "NEW_VAR=test_value"
      vim.fn.writefile({ env_content }, test_dir .. "/.env")

      -- Trigger BufAdd event manually since we're in a test environment
      vim.api.nvim_exec_autocmds("BufAdd", {
        pattern = test_dir .. "/.env",
        data = { file = test_dir .. "/.env" },
      })

      -- Wait for file watcher to process
      vim.wait(100, function()
        local env_vars = ecolog.get_env_vars()
        return env_vars.NEW_VAR ~= nil
      end)

      local env_vars = ecolog.get_env_vars()
      assert.is_not_nil(env_vars.NEW_VAR)
      assert.equals("test_value", env_vars.NEW_VAR.value)
    end)

    it("should detect env file modifications", function()
      -- Create initial env file
      local initial_content = "INITIAL_VAR=old_value"
      local env_file = test_dir .. "/.env"
      vim.fn.writefile({ initial_content }, env_file)

      -- Create buffer for the env file
      vim.cmd("edit " .. env_file)
      local bufnr = vim.api.nvim_get_current_buf()

      ecolog.setup({
        path = test_dir,
        shelter = {
          configuration = {},
          modules = {},
        },
        integrations = {
          nvim_cmp = false,
          blink_cmp = false,
          lsp = false,
          lspsaga = false,
          fzf = false,
        },
        types = true,
      })

      -- Modify env file through buffer
      local new_content = { "INITIAL_VAR=new_value", "ADDED_VAR=added_value" }
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_content)
      vim.cmd("write")

      -- Wait for file watcher to process
      vim.wait(500)

      -- Force refresh to ensure cache is invalidated and file is reloaded
      local config = {
        path = test_dir,
        shelter = {
          configuration = {},
          modules = {},
        },
        integrations = {
          nvim_cmp = false,
          blink_cmp = false,
          lsp = false,
          lspsaga = false,
          fzf = false,
        },
        types = true,
      }
      ecolog.refresh_env_vars(config)
      
      -- Additional wait to ensure the refresh completes
      vim.wait(100)

      local env_vars = ecolog.get_env_vars()
      assert.equals("new_value", env_vars.INITIAL_VAR.value)
      assert.equals("added_value", env_vars.ADDED_VAR.value)

      -- Clean up
      vim.cmd("bdelete!")
    end)

    it("should handle env file deletion", function()
      -- Create initial env file
      local initial_content = "TEST_VAR=value"
      local env_file = test_dir .. "/.env"
      vim.fn.writefile({ initial_content }, env_file)

      -- Create buffer for the env file
      vim.cmd("edit " .. env_file)
      local bufnr = vim.api.nvim_get_current_buf()

      ecolog.setup({
        path = test_dir,
        shelter = {
          configuration = {},
          modules = {},
        },
        integrations = {
          nvim_cmp = false,
          blink_cmp = false,
          lsp = false,
          lspsaga = false,
          fzf = false,
        },
        types = true,
      })

      -- Delete env file through buffer
      vim.cmd("bdelete!")
      vim.fn.delete(env_file)

      -- Wait for file watcher to process
      vim.wait(100)

      local env_vars = ecolog.get_env_vars()
      assert.is_nil(env_vars.TEST_VAR)
    end)
  end)

  describe("shell environment handling", function()
    local original_environ
    local test_env = {
      SHELL_VAR = "test_value",
      API_KEY = "secret123",
      DEBUG = "true",
      PORT = "3000",
    }

    before_each(function()
      -- Store original environ function
      original_environ = vim.fn.environ
      -- Mock environ function
      _G.vim = vim or {}
      _G.vim.fn = vim.fn or {}
      _G.vim.fn.environ = function()
        return test_env
      end

      -- Force refresh env vars before each test
      package.loaded["ecolog"] = nil
      ecolog = require("ecolog")
    end)

    after_each(function()
      -- Restore original environ function
      _G.vim.fn.environ = original_environ
    end)

    it("should load basic shell variables", function()
      ecolog.setup({
        load_shell = {
          enabled = true,
        },
        shelter = {
          configuration = {},
          modules = {},
        },
        integrations = {
          nvim_cmp = false,
          blink_cmp = false,
          lsp = false,
          lspsaga = false,
          fzf = false,
        },
        types = true,
      })

      -- Force refresh to load shell vars
      ecolog.refresh_env_vars({
        load_shell = {
          enabled = true,
        },
        types = true,
      })

      local env_vars = ecolog.get_env_vars()
      assert.is_not_nil(env_vars.SHELL_VAR)
      assert.equals("test_value", env_vars.SHELL_VAR.value)
      assert.equals("shell", env_vars.SHELL_VAR.source)
    end)

    it("should apply filter function", function()
      ecolog.setup({
        load_shell = {
          enabled = true,
          filter = function(key, _)
            return key:match("^API") ~= nil
          end,
        },
        shelter = {
          configuration = {},
          modules = {},
        },
        integrations = {
          nvim_cmp = false,
          blink_cmp = false,
          lsp = false,
          lspsaga = false,
          fzf = false,
        },
        types = true,
      })

      -- Force refresh with filter
      ecolog.refresh_env_vars({
        load_shell = {
          enabled = true,
          filter = function(key, _)
            return key:match("^API") ~= nil
          end,
        },
        types = true,
      })

      local env_vars = ecolog.get_env_vars()
      assert.is_not_nil(env_vars.API_KEY)
      assert.is_nil(env_vars.SHELL_VAR)
    end)

    it("should apply transform function", function()
      ecolog.setup({
        load_shell = {
          enabled = true,
          transform = function(_, value)
            return value:upper()
          end,
        },
        shelter = {
          configuration = {},
          modules = {},
        },
        integrations = {
          nvim_cmp = false,
          blink_cmp = false,
          lsp = false,
          lspsaga = false,
          fzf = false,
        },
        types = true,
      })

      -- Force refresh with transform
      ecolog.refresh_env_vars({
        load_shell = {
          enabled = true,
          transform = function(_, value)
            return value:upper()
          end,
        },
        types = true,
      })

      local env_vars = ecolog.get_env_vars()
      assert.equals("TEST_VALUE", env_vars.SHELL_VAR.value)
    end)

    it("should handle type detection for shell variables", function()
      ecolog.setup({
        load_shell = {
          enabled = true,
        },
        shelter = {
          configuration = {},
          modules = {},
        },
        integrations = {
          nvim_cmp = false,
          blink_cmp = false,
          lsp = false,
          lspsaga = false,
          fzf = false,
        },
        types = true,
      })

      -- Force refresh to load shell vars
      ecolog.refresh_env_vars({
        load_shell = {
          enabled = true,
        },
        types = true,
      })

      local env_vars = ecolog.get_env_vars()
      assert.equals("boolean", env_vars.DEBUG.type)
      assert.equals("number", env_vars.PORT.type)
    end)

    it("should respect override setting with .env files", function()
      -- Create env file with conflicting value
      local env_content = "SHELL_VAR=env_value"
      vim.fn.writefile({ env_content }, test_dir .. "/.env")

      ecolog.setup({
        path = test_dir,
        load_shell = {
          enabled = true,
          override = true,
        },
        shelter = {
          configuration = {},
          modules = {},
        },
        integrations = {
          nvim_cmp = false,
          blink_cmp = false,
          lsp = false,
          lspsaga = false,
          fzf = false,
        },
        types = true,
      })

      local env_vars = ecolog.get_env_vars()
      assert.equals("test_value", env_vars.SHELL_VAR.value)
      assert.equals("shell", env_vars.SHELL_VAR.source)
    end)
  end)

  describe("initial env file selection", function()
    it("should select initial env file with default patterns", function()
      -- Create test env files
      vim.fn.writefile({ "TEST=value" }, test_dir .. "/.env")
      vim.fn.writefile({ "TEST=dev" }, test_dir .. "/.env.development")

      ecolog.setup({
        path = test_dir,
        shelter = {
          configuration = {},
          modules = {},
        },
        integrations = {
          nvim_cmp = false,
          blink_cmp = false,
          lsp = false,
          lspsaga = false,
          fzf = false,
        },
        types = true,
      })

      local env_vars = ecolog.get_env_vars()
      assert.equals("value", env_vars.TEST.value)
    end)

    it("should select initial env file with custom patterns", function()
      local test_dir = vim.fn.tempname()
      vim.fn.mkdir(test_dir .. "/config", "p")
      
      -- Create test files
      local files = {
        [test_dir .. "/config/.env"] = "TEST=config",
        [test_dir .. "/config/.env.local"] = "TEST=config_local",
        [test_dir .. "/.env"] = "TEST=root",
      }
      
      for file, content in pairs(files) do
        local f = io.open(file, "w")
        f:write(content)
        f:close()
      end

      -- Setup with custom pattern
      ecolog.setup({
        path = test_dir,
        env_file_patterns = { "config/.env" },
      })

      -- Wait for async operations
      vim.wait(100)

      -- Get environment variables
      local env_vars = ecolog.get_env_vars()
      assert.equals("config", env_vars.TEST.raw_value)

      -- Cleanup
      vim.fn.delete(test_dir, "rf")
    end)

    it("should respect preferred environment with custom patterns", function()
      -- Create test env files
      vim.fn.writefile({ "TEST=value" }, test_dir .. "/.env")
      vim.fn.writefile({ "TEST=dev" }, test_dir .. "/.env.development")

      ecolog.setup({
        path = test_dir,
        preferred_environment = "development",
        shelter = {
          configuration = {},
          modules = {},
        },
        integrations = {
          nvim_cmp = false,
          blink_cmp = false,
          lsp = false,
          lspsaga = false,
          fzf = false,
        },
        types = true,
      })

      local env_vars = ecolog.get_env_vars()
      assert.equals("dev", env_vars.TEST.value)
    end)

    it("should handle multiple custom patterns", function()
      local test_dir = vim.fn.tempname()
      vim.fn.mkdir(test_dir .. "/config", "p")
      
      -- Create test files
      local files = {
        [test_dir .. "/config/.env"] = "TEST=config",
        [test_dir .. "/config/.env.local"] = "TEST=config_local",
        [test_dir .. "/.env"] = "TEST=root",
      }
      
      for file, content in pairs(files) do
        local f = io.open(file, "w")
        f:write(content)
        f:close()
      end

      -- Setup with multiple custom patterns
      ecolog.setup({
        path = test_dir,
        env_file_patterns = { "config/.env", "config/.env.*" },
      })

      -- Wait for async operations
      vim.wait(100)

      -- Get environment variables
      local env_vars = ecolog.get_env_vars()
      assert.equals("config", env_vars.TEST.raw_value)

      -- Cleanup
      vim.fn.delete(test_dir, "rf")
    end)
  end)
end)
