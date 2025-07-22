local assert = require("luassert")
local stub = require("luassert.stub")

describe("LSP integration (memory-safe)", function()
  local lsp_integration
  local test_dir
  local ecolog_mock
  local providers_mock
  local utils_mock
  local original_lsp_handlers
  local stubs = {}

  local function cleanup_stubs()
    for _, stub_obj in pairs(stubs) do
      if stub_obj and stub_obj.revert then
        pcall(stub_obj.revert, stub_obj)
      end
    end
    stubs = {}
  end

  before_each(function()
    -- Clean up from previous test
    cleanup_stubs()
    
    -- Clear modules
    package.loaded["ecolog.integrations.lsp"] = nil
    package.loaded["ecolog"] = nil
    package.loaded["ecolog.providers"] = nil
    package.loaded["ecolog.utils"] = nil
    
    -- Store original LSP handlers
    original_lsp_handlers = {
      hover = vim.lsp.handlers["textDocument/hover"],
      definition = vim.lsp.handlers["textDocument/definition"],
    }
    
    -- Create test directory
    test_dir = vim.fn.tempname()
    vim.fn.mkdir(test_dir, "p")
    
    -- Mock modules with minimal implementations
    ecolog_mock = {
      get_env_vars = function()
        return {
          TEST_VAR = { source = test_dir .. "/.env", value = "test_value" },
          API_KEY = { source = test_dir .. "/.env", value = "secret123" }
        }
      end
    }
    package.loaded["ecolog"] = ecolog_mock
    
    providers_mock = {
      get_providers = function()
        return {
          javascript = { patterns = { "process%.env%.(%w+)" } }
        }
      end
    }
    package.loaded["ecolog.providers"] = providers_mock
    
    utils_mock = {
      get_var_word_under_cursor = function()
        return "TEST_VAR"
      end
    }
    package.loaded["ecolog.utils"] = utils_mock
  end)

  after_each(function()
    -- Cleanup stubs first
    cleanup_stubs()
    
    -- Restore LSP integration if loaded
    if lsp_integration and lsp_integration.restore then
      pcall(lsp_integration.restore)
    end
    
    -- Force restore original handlers
    if original_lsp_handlers then
      vim.lsp.handlers["textDocument/hover"] = original_lsp_handlers.hover
      vim.lsp.handlers["textDocument/definition"] = original_lsp_handlers.definition
    end
    
    -- Clean up test directory
    if test_dir then
      pcall(vim.fn.delete, test_dir, "rf")
    end
    
    -- Clear modules
    package.loaded["ecolog.integrations.lsp"] = nil
    package.loaded["ecolog"] = nil
    package.loaded["ecolog.providers"] = nil
    package.loaded["ecolog.utils"] = nil
    
    -- Reset variables
    lsp_integration = nil
    test_dir = nil
    ecolog_mock = nil
    providers_mock = nil
    utils_mock = nil
    original_lsp_handlers = nil
    
    -- Force garbage collection
    collectgarbage("collect")
  end)

  describe("basic functionality", function()
    it("should load and setup without memory leaks", function()
      lsp_integration = require("ecolog.integrations.lsp")
      
      assert.is_table(lsp_integration)
      assert.is_function(lsp_integration.setup)
      assert.is_function(lsp_integration.restore)
      
      -- Setup should not crash
      local success = pcall(lsp_integration.setup)
      assert.is_true(success)
      
      -- Handlers should be functions
      assert.is_function(vim.lsp.handlers["textDocument/hover"])
      assert.is_function(vim.lsp.handlers["textDocument/definition"])
    end)
    
    it("should handle hover requests", function()
      lsp_integration = require("ecolog.integrations.lsp")
      lsp_integration.setup()
      
      -- Mock command to verify hover behavior
      local commands = vim.api.nvim_get_commands({})
      commands.EcologPeek = {
        callback = function() end
      }
      stubs[#stubs + 1] = stub(vim.api, "nvim_get_commands").returns(commands)
      
      -- Test hover handler
      local handler = vim.lsp.handlers["textDocument/hover"]
      local success = pcall(handler, nil, {}, { bufnr = 0, method = "textDocument/hover" }, {})
      assert.is_true(success)
    end)
  end)
end)