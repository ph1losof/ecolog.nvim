-- Config module tests
-- Tests configuration parsing, validation, and merging
---@diagnostic disable: undefined-global

describe("config module", function()
  local config

  before_each(function()
    -- Reset the module
    package.loaded["ecolog.config"] = nil
    config = require("ecolog.config")
  end)

  describe("default configuration", function()
    it("should have valid default values", function()
      local defaults = config.get_defaults()

      assert.is_table(defaults)
      assert.is_table(defaults.lsp)
      assert.is_table(defaults.picker)
      assert.is_table(defaults.statusline)
    end)

    it("should have lsp.enabled default to true", function()
      local defaults = config.get_defaults()
      assert.is_true(defaults.lsp.enabled)
    end)

    it("should have statusline.enabled default to true", function()
      local defaults = config.get_defaults()
      assert.is_true(defaults.statusline.enabled)
    end)

    it("should have default picker provider", function()
      local defaults = config.get_defaults()
      assert.is_not_nil(defaults.picker.default)
    end)
  end)

  describe("configuration merging", function()
    it("should merge user config with defaults", function()
      local user_config = {
        lsp = {
          enabled = false,
        },
      }

      local merged = config.merge_config(user_config)

      -- User value should override
      assert.is_false(merged.lsp.enabled)
      -- Other defaults should remain
      assert.is_table(merged.picker)
      assert.is_table(merged.statusline)
    end)

    it("should deep merge nested tables", function()
      local user_config = {
        statusline = {
          components = {
            var_count = true,
          },
        },
      }

      local merged = config.merge_config(user_config)

      assert.is_true(merged.statusline.components.var_count)
      -- Other statusline defaults should remain
      assert.is_true(merged.statusline.enabled)
    end)

    it("should handle empty user config", function()
      local merged = config.merge_config({})
      local defaults = config.get_defaults()

      assert.are.same(defaults.lsp.enabled, merged.lsp.enabled)
    end)

    it("should handle nil user config", function()
      local merged = config.merge_config(nil)
      assert.is_table(merged)
      assert.is_table(merged.lsp)
    end)
  end)

  describe("setup", function()
    it("should accept valid configuration", function()
      assert.has_no.errors(function()
        config.setup({
          lsp = { enabled = true },
        })
      end)
    end)

    it("should store configuration for later retrieval", function()
      config.setup({
        lsp = { enabled = false },
      })

      local current = config.get()
      assert.is_false(current.lsp.enabled)
    end)
  end)

  describe("validation", function()
    it("should accept valid lsp backend", function()
      assert.has_no.errors(function()
        config.setup({
          lsp = {
            backend = "lspconfig",
          },
        })
      end)
    end)

    it("should accept valid picker provider", function()
      assert.has_no.errors(function()
        config.setup({
          picker = {
            default = "telescope",
          },
        })
      end)
    end)
  end)

  describe("get_option", function()
    it("should return specific option value", function()
      config.setup({
        lsp = { enabled = true },
      })

      local value = config.get_option("lsp.enabled")
      assert.is_true(value)
    end)

    it("should return nil for non-existent option", function()
      config.setup({})

      local value = config.get_option("nonexistent.option")
      assert.is_nil(value)
    end)
  end)
end)
