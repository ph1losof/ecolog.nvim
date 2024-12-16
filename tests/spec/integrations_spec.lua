describe("integrations", function()
  local nvim_cmp
  local blink_cmp
  local mock = require("luassert.mock")
  local stub = require("luassert.stub")
  local match = require("luassert.match")

  before_each(function()
    package.loaded["ecolog.integrations.cmp.nvim_cmp"] = nil
    package.loaded["ecolog.integrations.cmp.blink_cmp"] = nil
    package.loaded["ecolog"] = nil
    
    nvim_cmp = require("ecolog.integrations.cmp.nvim_cmp")
    blink_cmp = require("ecolog.integrations.cmp.blink_cmp")
  end)

  describe("nvim-cmp integration", function()
    it("should create completion source", function()
      local cmp = mock({
        register_source = function() end,
        lsp = {
          CompletionItemKind = {
            Variable = 1
          }
        }
      }, true)
      
      local providers = {
        get_providers = function() return {} end,
        load_providers = function() end
      }
      
      local shelter = {
        is_enabled = function() return false end,
        mask_value = function(val) return val end
      }

      nvim_cmp.setup({
        integrations = { nvim_cmp = true }
      }, {}, providers, shelter)

      -- Mock require to return our cmp mock
      local old_require = _G.require
      _G.require = function(mod)
        if mod == "cmp" then
          return cmp
        end
        return old_require(mod)
      end

      -- Trigger lazy loading
      vim.api.nvim_exec_autocmds("InsertEnter", {})
      
      assert.stub(cmp.register_source).was_called(1)
      assert.stub(cmp.register_source).was_called_with("ecolog", match._)

      -- Restore original require
      _G.require = old_require
    end)

    it("should respect shelter mode in completions", function()
      local shelter = {
        is_enabled = function() return true end,
        mask_value = function(val) return string.rep("*", #val) end
      }
      
      local env_vars = {
        TEST_VAR = {
          value = "secret123",
          type = "string",
          source = ".env"
        }
      }

      -- Mock ecolog module
      package.loaded["ecolog"] = {
        get_env_vars = function() return env_vars end
      }

      -- Create mock completion source with shelter mode
      local source = {
        complete = function(_, _, callback)
          callback({
            items = {
              {
                label = "TEST_VAR",
                detail = shelter.mask_value("secret123"),
                kind = 1
              }
            }
          })
        end
      }

      -- Mock nvim-cmp
      local cmp = mock({
        register_source = function() return source end,
        lsp = {
          CompletionItemKind = {
            Variable = 1
          }
        }
      }, true)

      -- Mock require
      local old_require = _G.require
      _G.require = function(mod)
        if mod == "cmp" then
          return cmp
        end
        return old_require(mod)
      end

      -- Set up nvim-cmp with shelter mode
      nvim_cmp.setup({
        integrations = { nvim_cmp = true }
      }, env_vars, {
        get_providers = function() return {
          { get_completion_trigger = function() return "process.env." end }
        } end,
        load_providers = function() end
      }, shelter)

      -- Trigger completion
      source.complete({}, {}, function(result)
        assert.equals("*********", result.items[1].detail)
      end)

      -- Restore require
      _G.require = old_require
    end)
  end)

  describe("blink-cmp integration", function()
    it("should create blink source", function()
      local source = blink_cmp.new()
      assert.is_table(source)
      assert.is_function(source.get_completions)
      assert.is_function(source.get_trigger_characters)
    end)
  end)
end) 