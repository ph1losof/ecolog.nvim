local env_loader = require("ecolog.env_loader")
local utils = require("ecolog.utils")

describe("monorepo environment file selection", function()
  local state
  local opts
  
  before_each(function()
    -- Initialize state and options
    state = {
      env_vars = {},
      selected_env_file = nil,
      _env_line_cache = {}
    }
    
    opts = {
      _is_monorepo_workspace = true,
      _monorepo_root = "/test/monorepo",
      env_file_patterns = { ".env", ".env.*" },
      load_shell = false
    }
    
    -- Mock utils.find_env_files to return multiple files
    local original_find = utils.find_env_files
    utils.find_env_files = function(o)
      return {
        "/test/monorepo/.env",  -- Root file (highest priority)
        "/test/monorepo/packages/frontend/.env",  -- Package file
        "/test/monorepo/packages/backend/.env"  -- Another package file
      }
    end
    
    -- Mock file reading
    local original_io_open = io.open
    io.open = function(path, mode)
      if path:match("%.env$") then
        return {
          lines = function()
            local lines = {
              "NODE_ENV=development",
              "API_KEY=test123"
            }
            local i = 0
            return function()
              i = i + 1
              return lines[i]
            end
          end,
          close = function() end
        }
      end
      return original_io_open(path, mode)
    end
    
    -- Mock vim.fn.filereadable
    vim.fn = vim.fn or {}
    vim.fn.filereadable = function(path)
      if path:match("%.env$") then
        return 1
      end
      return 0
    end
    
    vim.fn.fnamemodify = function(path, modifier)
      if modifier == ":t" then
        return path:match("([^/]+)$") or path
      end
      return path
    end
  end)
  
  after_each(function()
    -- Restore original functions
    package.loaded["ecolog.utils"] = nil
    package.loaded["ecolog.env_loader"] = nil
  end)
  
  it("should use first file by default when no file is selected", function()
    -- Load environment without any file selected
    env_loader.load_monorepo_environment(opts, state)
    
    -- Should select the first file (root .env)
    assert.equals("/test/monorepo/.env", state.selected_env_file)
  end)
  
  it("should preserve user's selected file when it exists in available files", function()
    -- User selects a package-specific file
    state.selected_env_file = "/test/monorepo/packages/frontend/.env"
    
    -- Load environment
    env_loader.load_monorepo_environment(opts, state)
    
    -- Should preserve the user's selection
    assert.equals("/test/monorepo/packages/frontend/.env", state.selected_env_file)
  end)
  
  it("should fallback to first file if selected file is not available", function()
    -- User has a file selected that's no longer available
    state.selected_env_file = "/test/monorepo/packages/deleted/.env"
    
    -- Load environment
    env_loader.load_monorepo_environment(opts, state)
    
    -- Should fallback to the first available file
    assert.equals("/test/monorepo/.env", state.selected_env_file)
  end)
  
  it("should preserve selected file during force reload in monorepo mode", function()
    -- User selects a package-specific file
    state.selected_env_file = "/test/monorepo/packages/backend/.env"
    
    -- Force reload environment
    env_loader.load_environment(opts, state, true)
    
    -- Should preserve the user's selection even after force reload
    assert.equals("/test/monorepo/packages/backend/.env", state.selected_env_file)
  end)
end)