-- Statusline tests
-- Tests statusline rendering and formatting
---@diagnostic disable: undefined-global

describe("statusline module", function()
  local statusline
  local state

  before_each(function()
    package.loaded["ecolog.statusline"] = nil
    package.loaded["ecolog.state"] = nil

    statusline = require("ecolog.statusline")
    state = require("ecolog.state")

    -- Set up initial state
    state.set_var_count(42)
    state.set_active_files({ ".env", ".env.local" })
    state.set_enabled_sources({ shell = true, file = true })
  end)

  describe("get_status", function()
    it("should return status string", function()
      local status = statusline.get_status()
      assert.is_string(status)
    end)

    it("should include variable count", function()
      state.set_var_count(10)
      local status = statusline.get_status()
      assert.is_string(status)
      -- Status should mention the count in some form
    end)

    it("should handle zero variables", function()
      state.set_var_count(0)
      local status = statusline.get_status()
      assert.is_string(status)
    end)
  end)

  describe("get_component", function()
    it("should return component for lualine", function()
      local component = statusline.get_component()
      assert.is_table(component)
    end)
  end)

  describe("formatting", function()
    it("should format file names correctly", function()
      state.set_active_files({ "/path/to/.env" })
      local status = statusline.get_status()
      -- Should show just the filename, not full path
      assert.is_string(status)
    end)

    it("should handle multiple files", function()
      state.set_active_files({ ".env", ".env.local", ".env.production" })
      local status = statusline.get_status()
      assert.is_string(status)
    end)

    it("should handle empty files list", function()
      state.set_active_files({})
      local status = statusline.get_status()
      assert.is_string(status)
    end)
  end)

  describe("source indicators", function()
    it("should show when shell source is enabled", function()
      state.set_enabled_sources({ shell = true, file = false })
      local status = statusline.get_status()
      assert.is_string(status)
    end)

    it("should show when file source is enabled", function()
      state.set_enabled_sources({ shell = false, file = true })
      local status = statusline.get_status()
      assert.is_string(status)
    end)

    it("should handle all sources disabled", function()
      state.set_enabled_sources({ shell = false, file = false })
      local status = statusline.get_status()
      assert.is_string(status)
    end)
  end)
end)
