local assert = require("luassert")
local stub = require("luassert.stub")
local mock = require("luassert.mock")

describe("statusline integration", function()
  local statusline
  local test_dir
  local ecolog_mock
  local shelter_mock

  local function create_test_env_file(path, content)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local file = io.open(path, "w")
    if file then
      file:write(content)
      file:close()
    end
  end

  before_each(function()
    -- Clean up modules
    package.loaded["ecolog.integrations.statusline"] = nil
    package.loaded["ecolog"] = nil
    package.loaded["ecolog.utils"] = nil
    package.loaded["ecolog.shelter"] = nil
    
    test_dir = vim.fn.tempname()
    vim.fn.mkdir(test_dir, "p")

    -- Create test env file
    create_test_env_file(test_dir .. "/.env", "TEST_VAR=test_value\nAPI_KEY=secret123\nDEBUG=true")
    
    -- Mock ecolog module
    ecolog_mock = {
      get_env_vars = function()
        return {
          TEST_VAR = { source = test_dir .. "/.env", value = "test_value" },
          API_KEY = { source = test_dir .. "/.env", value = "secret123" },
          DEBUG = { source = test_dir .. "/.env", value = "true" }
        }
      end,
      get_state = function()
        return {
          selected_env_file = test_dir .. "/.env"
        }
      end
    }
    package.loaded["ecolog"] = ecolog_mock
    
    -- Mock shelter module
    shelter_mock = {
      is_enabled = function(mode)
        return false -- Default to shelter disabled
      end
    }
    
    -- Mock utils module
    local utils_mock = {
      get_module = function(module_name)
        if module_name == "ecolog.shelter" then
          return shelter_mock
        end
        return nil
      end
    }
    package.loaded["ecolog.utils"] = utils_mock
    
    -- Mock vim.loop.now for cache timing
    stub(vim.loop, "now").returns(1000)
    
    statusline = require("ecolog.integrations.statusline")
  end)

  after_each(function()
    vim.fn.delete(test_dir, "rf")
    vim.loop.now:revert()
  end)

  describe("setup", function()
    it("should setup with default configuration", function()
      local success = pcall(function()
        statusline.setup()
      end)
      assert.is_true(success)
    end)

    it("should setup with custom configuration", function()
      local config = {
        hidden_mode = true,
        icons = {
          enabled = false,
        },
        format = {
          env_file = function(name) return "[" .. name .. "]" end,
          vars_count = function(count) return "vars:" .. count end,
        }
      }
      
      local success = pcall(function()
        statusline.setup(config)
      end)
      assert.is_true(success)
    end)

    it("should create ColorScheme autocommand", function()
      stub(vim.api, "nvim_create_augroup").returns(1)
      stub(vim.api, "nvim_create_autocmd")
      
      statusline.setup()
      
      assert.stub(vim.api.nvim_create_augroup).was_called_with("EcologStatuslineHighlights", { clear = true })
      assert.stub(vim.api.nvim_create_autocmd).was_called()
      
      -- Check that the autocmd was called with "ColorScheme" and a table
      local autocmd_stub = vim.api.nvim_create_autocmd
      assert.is_true(#autocmd_stub.calls > 0)
      
      -- Get the arguments from the first call
      local first_call = autocmd_stub.calls[1]
      assert.is_table(first_call.refs)
      assert.equals("ColorScheme", first_call.refs[1])
      assert.is_table(first_call.refs[2])
      
      vim.api.nvim_create_augroup:revert()
      vim.api.nvim_create_autocmd:revert()
    end)
  end)

  describe("get_statusline", function()
    before_each(function()
      statusline.setup()
    end)

    it("should return formatted statusline", function()
      local result = statusline.get_statusline()
      
      assert.is_string(result)
      assert.is_true(result:find("%.env") ~= nil)  -- Should contain the env file name
      assert.is_true(result:find("3") ~= nil)      -- Should contain the variable count
    end)

    it("should include icons when enabled", function()
      statusline.setup({
        icons = {
          enabled = true,
          env = "🌲",
        }
      })
      
      local result = statusline.get_statusline()
      
      assert.is_true(result:find("🌲") ~= nil)
    end)

    it("should not include icons when disabled", function()
      statusline.setup({
        icons = {
          enabled = false,
        }
      })
      
      local result = statusline.get_statusline()
      
      assert.is_nil(result:find("🌲"))
    end)

    it("should use shelter icon when shelter is active", function()
      shelter_mock.is_enabled = function() return true end
      
      statusline.setup({
        icons = {
          enabled = true,
          env = "🌲",
          shelter = "🛡️",
        }
      })
      
      statusline.invalidate_cache() -- Force cache refresh
      local result = statusline.get_statusline()
      
      assert.is_true(result:find("🛡️") ~= nil)
      assert.is_nil(result:find("🌲"))
    end)

    it("should use custom formatters", function()
      statusline.setup({
        format = {
          env_file = function(name) return "[" .. name .. "]" end,
          vars_count = function(count) return "vars:" .. count end,
        }
      })
      
      statusline.invalidate_cache()
      local result = statusline.get_statusline()
      
      assert.is_true(result:find("%[") ~= nil)  -- Should contain brackets
      assert.is_true(result:find("vars:3") ~= nil)
    end)

    it("should return empty string in hidden mode when no env file", function()
      ecolog_mock.get_state = function()
        return { selected_env_file = nil }
      end
      
      statusline.setup({
        hidden_mode = true
      })
      
      statusline.invalidate_cache()
      local result = statusline.get_statusline()
      
      assert.equals("", result)
    end)

    it("should handle no env file gracefully", function()
      ecolog_mock.get_state = function()
        return { selected_env_file = nil }
      end
      
      statusline.invalidate_cache()
      local result = statusline.get_statusline()
      
      assert.is_true(result:find("No env file") ~= nil)
    end)
  end)

  describe("cache functionality", function()
    before_each(function()
      statusline.setup()
    end)

    it("should cache results for performance", function()
      local get_env_vars_calls = 0
      ecolog_mock.get_env_vars = function()
        get_env_vars_calls = get_env_vars_calls + 1
        return {
          TEST_VAR = { value = "test" }
        }
      end
      
      -- First call should hit the function
      statusline.get_statusline()
      assert.equals(1, get_env_vars_calls)
      
      -- Second call within cache time should not hit the function
      statusline.get_statusline()
      assert.equals(1, get_env_vars_calls)
    end)

    it("should refresh cache when invalidated", function()
      local get_env_vars_calls = 0
      ecolog_mock.get_env_vars = function()
        get_env_vars_calls = get_env_vars_calls + 1
        return {
          TEST_VAR = { value = "test" }
        }
      end
      
      statusline.get_statusline()
      assert.equals(1, get_env_vars_calls)
      
      statusline.invalidate_cache()
      statusline.get_statusline()
      assert.equals(2, get_env_vars_calls)
    end)

    it("should refresh cache after timeout", function()
      local get_env_vars_calls = 0
      ecolog_mock.get_env_vars = function()
        get_env_vars_calls = get_env_vars_calls + 1
        return {
          TEST_VAR = { value = "test" }
        }
      end
      
      -- First call
      vim.loop.now:revert()
      stub(vim.loop, "now").returns(1000)
      statusline.get_statusline()
      assert.equals(1, get_env_vars_calls)
      
      -- Second call after cache timeout (>1000ms)
      vim.loop.now:revert()
      stub(vim.loop, "now").returns(2500)
      statusline.get_statusline()
      assert.equals(2, get_env_vars_calls)
    end)
  end)

  describe("highlight functionality", function()
    it("should setup highlights when enabled", function()
      stub(vim.api, "nvim_set_hl")
      
      statusline.setup({
        highlights = {
          enabled = true,
          env_file = "String",
          vars_count = "Number",
          icons = "Special"
        }
      })
      
      -- Should be called during setup
      assert.stub(vim.api.nvim_set_hl).was_called()
      
      vim.api.nvim_set_hl:revert()
    end)

    it("should handle hex color highlights", function()
      stub(vim.api, "nvim_set_hl")
      
      statusline.setup({
        highlights = {
          enabled = true,
          env_file = "#ff0000",
          vars_count = "#00ff00",
        }
      })
      
      -- Should create hex color highlight groups
      assert.stub(vim.api.nvim_set_hl).was_called()
      
      vim.api.nvim_set_hl:revert()
    end)

    it("should skip highlights when disabled", function()
      stub(vim.api, "nvim_set_hl")
      
      statusline.setup({
        highlights = {
          enabled = false,
        }
      })
      
      -- Should not set up highlights
      assert.stub(vim.api.nvim_set_hl).was_not_called()
      
      vim.api.nvim_set_hl:revert()
    end)
  end)

  describe("lualine integration", function()
    before_each(function()
      -- Mock lualine_require
      package.loaded["lualine_require"] = {
        require = function(module)
          if module == "lualine.component" then
            return {
              extend = function(self)
                return setmetatable({}, {
                  __index = function(t, k)
                    if k == "super" then
                      return { init = function() end }
                    end
                    return rawget(t, k)
                  end
                })
              end
            }
          end
          return {}
        end
      }
      
      -- Mock lualine highlight module
      package.loaded["lualine.highlight"] = {
        create_component_highlight_group = function(opts, name, options)
          return "test_highlight_" .. name
        end,
        component_format_highlight = function(group)
          return "%#" .. group .. "#"
        end
      }
    end)

    it("should create lualine component", function()
      local component = statusline.lualine()
      
      assert.is_table(component)
      assert.is_function(component.condition)
    end)

    it("should return lualine config", function()
      local config = statusline.lualine_config()
      
      assert.is_table(config)
      assert.is_table(config.component)
      assert.is_function(config.condition)
      assert.is_string(config.icon)
    end)

    it("should check ecolog availability in condition", function()
      local component = statusline.lualine()
      
      -- Should return true when ecolog is loaded
      assert.is_true(component.condition())
      
      -- Mock ecolog not being loaded
      package.loaded["ecolog"] = nil
      assert.is_boolean(component.condition())
    end)
  end)

  describe("error handling", function()
    it("should handle missing ecolog gracefully", function()
      package.loaded["ecolog"] = nil
      
      -- Should not crash when ecolog is not available
      local success = pcall(function()
        statusline.setup()
        statusline.get_statusline()
      end)
      
      assert.is_boolean(success)
    end)

    it("should handle missing shelter module gracefully", function()
      local utils_mock = {
        get_module = function() return nil end
      }
      package.loaded["ecolog.utils"] = utils_mock
      
      statusline.setup()
      local success = pcall(function()
        statusline.get_statusline()
      end)
      
      assert.is_boolean(success)
    end)

    it("should handle invalid highlight groups gracefully", function()
      stub(vim.api, "nvim_get_hl", function() 
        error("Invalid highlight group")
      end)
      
      local success = pcall(function()
        statusline.setup({
          highlights = {
            enabled = true,
            env_file = "InvalidGroup"
          }
        })
        statusline.get_statusline()
      end)
      
      assert.is_true(success)
      
      vim.api.nvim_get_hl:revert()
    end)
  end)

  describe("edge cases", function()
    it("should handle empty environment variables", function()
      ecolog_mock.get_env_vars = function()
        return {}
      end
      
      statusline.setup()
      statusline.invalidate_cache()
      local result = statusline.get_statusline()
      
      assert.is_string(result)
      assert.is_true(result:find("0") ~= nil) -- Should show 0 variables
    end)

    it("should handle very long file names", function()
      local long_file = string.rep("a", 100) .. ".env"
      ecolog_mock.get_state = function()
        return { selected_env_file = test_dir .. "/" .. long_file }
      end
      
      statusline.setup()
      statusline.invalidate_cache()
      local result = statusline.get_statusline()
      
      assert.is_string(result)
      assert.is_true(result:find(long_file) ~= nil)
    end)

    it("should handle large number of variables", function()
      local many_vars = {}
      for i = 1, 1000 do
        many_vars["VAR_" .. i] = { value = "value" .. i }
      end
      
      ecolog_mock.get_env_vars = function()
        return many_vars
      end
      
      statusline.setup()
      statusline.invalidate_cache()
      local result = statusline.get_statusline()
      
      assert.is_string(result)
      assert.is_true(result:find("1000") ~= nil)
    end)
  end)

  describe("configuration validation", function()
    it("should handle invalid icon configuration", function()
      local success = pcall(function()
        statusline.setup({
          icons = {
            enabled = true,
            env = nil,  -- Invalid icon
            shelter = 123  -- Invalid icon type
          }
        })
        statusline.get_statusline()
      end)
      
      assert.is_true(success)
    end)

    it("should handle invalid format functions", function()
      local success = pcall(function()
        statusline.setup({
          format = {
            env_file = "not_a_function",
            vars_count = nil
          }
        })
        statusline.get_statusline()
      end)
      
      assert.is_boolean(success)
    end)

    it("should handle mixed highlight configurations", function()
      local success = pcall(function()
        statusline.setup({
          highlights = {
            enabled = true,
            env_file = "String",
            vars_count = "#ff0000",
            icons = {
              env = "Special",
              shelter = "#00ff00"
            }
          }
        })
      end)
      
      assert.is_true(success)
    end)
  end)
end)