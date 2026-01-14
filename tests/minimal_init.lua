-- Minimal init for testing ecolog.nvim
-- Run with: nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/plenary/ {minimal_init = 'tests/minimal_init.lua'}"

-- Try to load plenary from various locations
local plenary_path = vim.fn.stdpath("data") .. "/lazy/plenary.nvim"
if not vim.loop.fs_stat(plenary_path) then
  plenary_path = vim.fn.stdpath("data") .. "/site/pack/packer/start/plenary.nvim"
end

if vim.loop.fs_stat(plenary_path) then
  vim.opt.rtp:prepend(plenary_path)
end

-- Add current plugin to rtp
vim.opt.rtp:prepend(vim.fn.getcwd())

-- Add lua path for require
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

-- Disable swap files
vim.opt.swapfile = false

-- ============================================
-- Picker detection
-- ============================================

-- Try to load optional picker plugins
local has_telescope = pcall(require, "telescope")
local has_fzf = pcall(require, "fzf-lua")
local has_snacks = pcall(require, "snacks")

-- Export availability for tests to check
_G.ECOLOG_TEST_TELESCOPE = has_telescope
_G.ECOLOG_TEST_FZF = has_fzf
_G.ECOLOG_TEST_SNACKS = has_snacks

-- ============================================
-- Mock LSP client and results
-- ============================================

_G.MockLspClient = nil
_G.MockLspResults = {}
_G.MockLspCommands = {}

-- Create a mock LSP client factory
function _G.create_mock_lsp_client(id, results)
  results = results or {}
  return {
    id = id or 1,
    name = "ecolog",
    request = function(method, params, callback)
      local result = results[method]
      if type(result) == "function" then
        result = result(params)
      end
      if callback then
        vim.schedule(function()
          callback(nil, result)
        end)
      end
      return true, 1 -- success, request_id
    end,
    request_sync = function(method, params, timeout)
      local result = results[method]
      if type(result) == "function" then
        result = result(params)
      end
      return { result = result }, nil
    end,
    notify = function()
      return true
    end,
    is_stopped = function()
      return false
    end,
    supports_method = function(method)
      return true
    end,
  }
end

-- Helper to set up mock for a test
function _G.setup_mock_lsp(results)
  _G.MockLspResults = results or {}
  _G.MockLspClient = _G.create_mock_lsp_client(1, _G.MockLspResults)

  -- Override vim.lsp.get_clients to return our mock
  local original_get_clients = vim.lsp.get_clients
  vim.lsp.get_clients = function(opts)
    if opts and opts.name == "ecolog" then
      return { _G.MockLspClient }
    end
    return original_get_clients(opts)
  end

  return _G.MockLspClient
end

-- Helper to clean up mock
function _G.teardown_mock_lsp()
  _G.MockLspClient = nil
  _G.MockLspResults = {}
end

-- ============================================
-- Test utilities
-- ============================================

-- Create a temporary .env file for testing
function _G.create_temp_env_file(content)
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, "p")
  local env_path = temp_dir .. "/.env"
  local file = io.open(env_path, "w")
  if file then
    file:write(content or "TEST_VAR=test_value\nAPI_KEY=secret123\n")
    file:close()
  end
  return temp_dir, env_path
end

-- Clean up temporary directory
function _G.cleanup_temp_dir(dir)
  if dir and vim.fn.isdirectory(dir) == 1 then
    vim.fn.delete(dir, "rf")
  end
end

-- Wait for async operations
function _G.wait_for(condition, timeout)
  timeout = timeout or 1000
  local start = vim.loop.now()
  while not condition() do
    if vim.loop.now() - start > timeout then
      return false
    end
    vim.wait(10)
  end
  return true
end

-- ============================================
-- Default mock results
-- ============================================

_G.DEFAULT_MOCK_RESULTS = {
  ["ecolog.listEnvVariables"] = {
    variables = {
      { name = "TEST_VAR", value = "test_value", source = ".env" },
      { name = "API_KEY", value = "secret123", source = ".env" },
      { name = "DEBUG", value = "true", source = ".env" },
      { name = "PORT", value = "8080", source = ".env" },
    },
  },
  ["ecolog.file.list"] = {
    files = { ".env", ".env.local" },
  },
  ["ecolog.source.list"] = {
    sources = {
      { name = "Shell", enabled = true, priority = 1 },
      { name = "File", enabled = true, priority = 2 },
      { name = "Remote", enabled = false, priority = 3 },
    },
  },
  ["ecolog.variable.get"] = function(params)
    local vars = {
      TEST_VAR = { name = "TEST_VAR", value = "test_value", source = ".env" },
      API_KEY = { name = "API_KEY", value = "secret123", source = ".env" },
    }
    local key = params and params[1]
    return vars[key]
  end,
  ["ecolog.file.setActive"] = { success = true },
  ["ecolog.source.setPrecedence"] = { success = true },
  ["ecolog.interpolation.set"] = function(params)
    return { success = true, enabled = params and params[1] or false }
  end,
  ["ecolog.interpolation.get"] = { enabled = true },
}
