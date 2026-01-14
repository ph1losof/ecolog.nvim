-- User commands tests
-- Tests the main user-facing commands
---@diagnostic disable: undefined-global

describe("commands module", function()
  local commands
  local state

  before_each(function()
    -- Reset modules
    package.loaded["ecolog.commands"] = nil
    package.loaded["ecolog.state"] = nil
    package.loaded["ecolog.lsp.commands"] = nil

    commands = require("ecolog.commands")
    state = require("ecolog.state")

    -- Setup mock LSP
    _G.setup_mock_lsp(_G.DEFAULT_MOCK_RESULTS)

    -- Initialize state
    state.set_client_id(1)
    state.set_var_count(4)
    state.set_active_files({ ".env" })
    state.set_enabled_sources({ shell = true, file = true })
  end)

  after_each(function()
    _G.teardown_mock_lsp()
  end)

  describe("list", function()
    it("should return list of variables", function()
      local callback_called = false
      local result_vars = nil

      commands.list(function(vars)
        callback_called = true
        result_vars = vars
      end)

      _G.wait_for(function()
        return callback_called
      end)

      assert.is_true(callback_called)
      assert.is_table(result_vars)
    end)
  end)

  describe("files", function()
    it("should return list of env files", function()
      local callback_called = false
      local result_files = nil

      commands.files(function(files)
        callback_called = true
        result_files = files
      end)

      _G.wait_for(function()
        return callback_called
      end)

      assert.is_true(callback_called)
      assert.is_table(result_files)
    end)
  end)

  describe("info", function()
    it("should return plugin info without error", function()
      assert.has_no.errors(function()
        commands.info()
      end)
    end)
  end)

  describe("refresh", function()
    it("should refresh state without error", function()
      local callback_called = false

      commands.refresh(function()
        callback_called = true
      end)

      _G.wait_for(function()
        return callback_called
      end, 500)

      -- Should complete without error
      assert.is_true(true)
    end)
  end)
end)
