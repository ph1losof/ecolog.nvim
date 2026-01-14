-- Hooks system tests
-- Tests hook registration and firing
---@diagnostic disable: undefined-global

describe("hooks module", function()
  local hooks

  before_each(function()
    package.loaded["ecolog.hooks"] = nil
    hooks = require("ecolog.hooks")
  end)

  describe("register", function()
    it("should register a hook without error", function()
      assert.has_no.errors(function()
        hooks.register("on_variable_hover", function(data)
          return data
        end)
      end)
    end)

    it("should accept priority parameter", function()
      assert.has_no.errors(function()
        hooks.register("on_variable_hover", function(data)
          return data
        end, { priority = 100 })
      end)
    end)
  end)

  describe("fire", function()
    it("should fire registered hooks", function()
      local hook_called = false

      hooks.register("test_event", function(data)
        hook_called = true
        return data
      end)

      hooks.fire("test_event", { value = "test" })

      assert.is_true(hook_called)
    end)

    it("should pass data to hooks", function()
      local received_data = nil

      hooks.register("test_event", function(data)
        received_data = data
        return data
      end)

      hooks.fire("test_event", { value = "test_value" })

      assert.is_table(received_data)
      assert.equals("test_value", received_data.value)
    end)

    it("should allow hooks to modify data", function()
      hooks.register("test_event", function(data)
        data.modified = true
        return data
      end)

      local result = hooks.fire("test_event", { value = "original" })

      assert.is_true(result.modified)
    end)

    it("should call hooks in priority order", function()
      local call_order = {}

      hooks.register("test_event", function(data)
        table.insert(call_order, "low")
        return data
      end, { priority = 10 })

      hooks.register("test_event", function(data)
        table.insert(call_order, "high")
        return data
      end, { priority = 100 })

      hooks.fire("test_event", {})

      -- Higher priority should be called first
      assert.equals("high", call_order[1])
      assert.equals("low", call_order[2])
    end)

    it("should handle no registered hooks gracefully", function()
      assert.has_no.errors(function()
        hooks.fire("unregistered_event", { value = "test" })
      end)
    end)
  end)

  describe("unregister", function()
    it("should unregister a hook", function()
      local call_count = 0

      local hook_id = hooks.register("test_event", function(data)
        call_count = call_count + 1
        return data
      end)

      hooks.fire("test_event", {})
      assert.equals(1, call_count)

      hooks.unregister(hook_id)

      hooks.fire("test_event", {})
      -- Call count should not increase after unregister
      assert.equals(1, call_count)
    end)
  end)
end)
