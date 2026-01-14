-- LSP module tests
-- Tests LSP backend detection, client management, and command execution
---@diagnostic disable: undefined-global

describe("lsp module", function()
  local lsp

  before_each(function()
    -- Reset modules
    package.loaded["ecolog.lsp"] = nil
    package.loaded["ecolog.lsp.commands"] = nil

    lsp = require("ecolog.lsp")

    -- Setup mock LSP
    _G.setup_mock_lsp(_G.DEFAULT_MOCK_RESULTS)
  end)

  after_each(function()
    _G.teardown_mock_lsp()
  end)

  describe("get_client", function()
    it("should return mock client when available", function()
      local client = lsp.get_client()
      assert.is_not_nil(client)
      assert.equals("ecolog", client.name)
    end)
  end)

  describe("is_attached", function()
    it("should return true when client is attached", function()
      local attached = lsp.is_attached()
      assert.is_true(attached)
    end)
  end)

  describe("execute_command", function()
    it("should execute LSP command", function()
      local callback_called = false
      local result_data = nil

      lsp.execute_command("ecolog.listEnvVariables", {}, function(err, result)
        callback_called = true
        result_data = result
      end)

      _G.wait_for(function()
        return callback_called
      end)

      assert.is_true(callback_called)
      assert.is_table(result_data)
      assert.is_table(result_data.variables)
    end)

    it("should pass arguments to command", function()
      local callback_called = false
      local result_data = nil

      lsp.execute_command("ecolog.variable.get", { "TEST_VAR" }, function(err, result)
        callback_called = true
        result_data = result
      end)

      _G.wait_for(function()
        return callback_called
      end)

      assert.is_true(callback_called)
      assert.is_table(result_data)
      assert.equals("TEST_VAR", result_data.name)
    end)
  end)
end)

describe("lsp.commands module", function()
  local lsp_commands
  local state

  before_each(function()
    package.loaded["ecolog.lsp.commands"] = nil
    package.loaded["ecolog.state"] = nil

    lsp_commands = require("ecolog.lsp.commands")
    state = require("ecolog.state")

    _G.setup_mock_lsp(_G.DEFAULT_MOCK_RESULTS)
    state.set_client_id(1)
  end)

  after_each(function()
    _G.teardown_mock_lsp()
  end)

  describe("set_sources", function()
    it("should update enabled sources state", function()
      state.set_enabled_sources({ shell = true, file = true })

      local callback_called = false
      lsp_commands.set_sources({ "File" }, function(success)
        callback_called = true
      end)

      _G.wait_for(function()
        return callback_called
      end)

      local sources = state.get_enabled_sources()
      assert.is_false(sources.shell)
      assert.is_true(sources.file)
    end)

    it("should set count to 0 when all sources disabled", function()
      state.set_var_count(10)

      lsp_commands.set_sources({}, function() end)

      _G.wait_for(function()
        return state.get_var_count() == 0
      end, 200)

      assert.equals(0, state.get_var_count())
    end)
  end)

  describe("set_active_file", function()
    it("should update active files state", function()
      state.set_active_files({})

      local callback_called = false
      lsp_commands.set_active_file({ ".env.local" }, function(success)
        callback_called = true
      end)

      _G.wait_for(function()
        return callback_called
      end)

      assert.are.same({ ".env.local" }, state.get_active_files())
    end)
  end)

  describe("refresh_state", function()
    it("should refresh all state data", function()
      local callback_called = false

      lsp_commands.refresh_state(nil, function()
        callback_called = true
      end)

      _G.wait_for(function()
        return callback_called
      end)

      assert.is_true(callback_called)
    end)
  end)
end)
