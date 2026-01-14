-- State module tests
-- Tests state management for plugin runtime data
---@diagnostic disable: undefined-global

describe("state module", function()
  local state

  before_each(function()
    package.loaded["ecolog.state"] = nil
    state = require("ecolog.state")
  end)

  describe("client_id", function()
    it("should set and get client id", function()
      state.set_client_id(42)
      assert.equals(42, state.get_client_id())
    end)

    it("should default to nil", function()
      assert.is_nil(state.get_client_id())
    end)
  end)

  describe("var_count", function()
    it("should set and get variable count", function()
      state.set_var_count(100)
      assert.equals(100, state.get_var_count())
    end)

    it("should default to 0", function()
      assert.equals(0, state.get_var_count())
    end)

    it("should accept zero", function()
      state.set_var_count(0)
      assert.equals(0, state.get_var_count())
    end)
  end)

  describe("active_files", function()
    it("should set and get active files", function()
      local files = { ".env", ".env.local" }
      state.set_active_files(files)
      assert.are.same(files, state.get_active_files())
    end)

    it("should default to empty table", function()
      assert.are.same({}, state.get_active_files())
    end)

    it("should handle single file", function()
      state.set_active_files({ ".env" })
      assert.are.same({ ".env" }, state.get_active_files())
    end)

    it("should handle empty table", function()
      state.set_active_files({})
      assert.are.same({}, state.get_active_files())
    end)
  end)

  describe("enabled_sources", function()
    it("should set and get enabled sources", function()
      local sources = { shell = true, file = false }
      state.set_enabled_sources(sources)
      assert.are.same(sources, state.get_enabled_sources())
    end)

    it("should default to shell and file enabled", function()
      local sources = state.get_enabled_sources()
      assert.is_true(sources.shell)
      assert.is_true(sources.file)
    end)

    it("should handle all sources disabled", function()
      state.set_enabled_sources({ shell = false, file = false })
      local sources = state.get_enabled_sources()
      assert.is_false(sources.shell)
      assert.is_false(sources.file)
    end)
  end)

  describe("is_ready", function()
    it("should return false when client not set", function()
      assert.is_false(state.is_ready())
    end)

    it("should return true when client is set", function()
      state.set_client_id(1)
      assert.is_true(state.is_ready())
    end)
  end)

  describe("reset", function()
    it("should reset all state", function()
      state.set_client_id(1)
      state.set_var_count(100)
      state.set_active_files({ ".env" })

      state.reset()

      assert.is_nil(state.get_client_id())
      assert.equals(0, state.get_var_count())
      assert.are.same({}, state.get_active_files())
    end)
  end)
end)
