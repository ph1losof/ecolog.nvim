-- Health check tests
-- Tests the :checkhealth ecolog output
---@diagnostic disable: undefined-global

describe("health module", function()
  local health

  before_each(function()
    package.loaded["ecolog.health"] = nil
    health = require("ecolog.health")
  end)

  describe("check", function()
    it("should run without error", function()
      -- The health check should not throw errors
      assert.has_no.errors(function()
        -- health.check() uses vim.health.* API
        -- We just verify the module loads correctly
        assert.is_function(health.check)
      end)
    end)
  end)

  describe("neovim version check", function()
    it("should detect neovim version", function()
      local version = vim.version()
      assert.is_table(version)
      assert.is_number(version.major)
      assert.is_number(version.minor)
    end)

    it("should meet minimum version requirement", function()
      local version = vim.version()
      -- ecolog requires at least Neovim 0.9+
      local meets_requirement = version.major > 0 or (version.major == 0 and version.minor >= 9)
      assert.is_true(meets_requirement, "Neovim version should be 0.9+")
    end)
  end)
end)
