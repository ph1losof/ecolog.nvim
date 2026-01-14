-- Integration tests for statusline state updates
-- Tests source enable/disable, file switching, and file deletion scenarios
---@diagnostic disable: undefined-global

local state = require("ecolog.state")

describe("statusline state management", function()
  local original_execute_command

  before_each(function()
    -- Reset state before each test
    state.set_active_files({})
    state.set_var_count(0)
    state.set_enabled_sources({ shell = true, file = true })
    state.set_client_id(1) -- Mock client ID

    -- Store original function
    local lsp = require("ecolog.lsp")
    original_execute_command = lsp.execute_command
  end)

  after_each(function()
    -- Restore original function
    local lsp = require("ecolog.lsp")
    lsp.execute_command = original_execute_command
  end)

  describe("state initialization", function()
    it("should have default values", function()
      state.set_active_files({})
      state.set_var_count(0)
      state.set_enabled_sources({ shell = true, file = true })

      assert.are.same({}, state.get_active_files())
      assert.are.equal(0, state.get_var_count())
      assert.are.same({ shell = true, file = true }, state.get_enabled_sources())
    end)

    it("should persist values after setting", function()
      state.set_active_files({ "/path/to/.env", "/path/to/.env.local" })
      state.set_var_count(42)
      state.set_enabled_sources({ shell = false, file = true })

      assert.are.same({ "/path/to/.env", "/path/to/.env.local" }, state.get_active_files())
      assert.are.equal(42, state.get_var_count())
      assert.are.same({ shell = false, file = true }, state.get_enabled_sources())
    end)
  end)

  describe("set_sources command", function()
    it("should update enabled sources state", function()
      local commands = require("ecolog.lsp.commands")
      local lsp = require("ecolog.lsp")

      -- Mock LSP responses
      local call_count = 0
      lsp.execute_command = function(command, args, callback)
        call_count = call_count + 1
        if command == "ecolog.source.setPrecedence" then
          callback(nil, { success = true, precedence = args })
        elseif command == "ecolog.source.list" then
          callback(nil, {
            sources = {
              { name = "Shell", enabled = false, priority = 1 },
              { name = "File", enabled = true, priority = 2 },
              { name = "Remote", enabled = false, priority = 3 },
            },
          })
        elseif command == "ecolog.listEnvVariables" then
          -- Return 15 variables (File source still has variables)
          local vars = {}
          for i = 1, 15 do
            table.insert(vars, { name = "VAR_" .. i, value = "value" .. i, source = ".env" })
          end
          callback(nil, { variables = vars })
        end
      end

      -- Initial state: 25 vars
      state.set_var_count(25)
      state.set_enabled_sources({ shell = true, file = true })

      -- Disable shell source
      local callback_called = false
      commands.set_sources({ "File" }, function(success)
        callback_called = true
        assert.is_true(success)
      end)

      -- Allow async operations to complete
      vim.wait(100, function()
        return callback_called
      end)

      -- Verify state was updated
      local sources = state.get_enabled_sources()
      assert.is_false(sources.shell)
      assert.is_true(sources.file)

      -- Variable count should be updated (not 0, but 15 from File source)
      assert.are.equal(15, state.get_var_count())
    end)

    it("should preserve variable count when sources change but variables remain", function()
      local commands = require("ecolog.lsp.commands")
      local lsp = require("ecolog.lsp")

      -- Mock: After disabling shell, we still have 20 vars from file source
      lsp.execute_command = function(command, args, callback)
        if command == "ecolog.source.setPrecedence" then
          callback(nil, { success = true, precedence = args })
        elseif command == "ecolog.source.list" then
          callback(nil, {
            sources = {
              { name = "Shell", enabled = false, priority = 1 },
              { name = "File", enabled = true, priority = 2 },
            },
          })
        elseif command == "ecolog.listEnvVariables" then
          local vars = {}
          for i = 1, 20 do
            table.insert(vars, { name = "FILE_VAR_" .. i, value = "val" .. i, source = ".env" })
          end
          callback(nil, { variables = vars })
        end
      end

      state.set_var_count(30) -- Initial: 30 (10 from shell + 20 from file)

      commands.set_sources({ "File" }, function() end)

      vim.wait(100, function()
        return state.get_var_count() ~= 30
      end)

      -- Should now have 20 (only file source vars)
      assert.are.equal(20, state.get_var_count())
    end)

    it("should set count to 0 when all sources are disabled", function()
      local commands = require("ecolog.lsp.commands")
      local lsp = require("ecolog.lsp")

      -- Mock: All sources disabled
      lsp.execute_command = function(command, args, callback)
        if command == "ecolog.source.setPrecedence" then
          callback(nil, { success = true, precedence = args })
        elseif command == "ecolog.source.list" then
          callback(nil, {
            sources = {
              { name = "Shell", enabled = false, priority = 1 },
              { name = "File", enabled = false, priority = 2 },
              { name = "Remote", enabled = false, priority = 3 },
            },
          })
        elseif command == "ecolog.listEnvVariables" then
          -- LSP bug: returns all vars even when sources disabled
          local vars = {}
          for i = 1, 107 do
            table.insert(vars, { name = "VAR_" .. i, value = "val" .. i })
          end
          callback(nil, { variables = vars })
        end
      end

      state.set_var_count(107) -- Initial count

      -- Disable all sources
      commands.set_sources({}, function() end)

      vim.wait(100, function()
        return state.get_var_count() == 0
      end)

      -- Count should be 0 when all sources disabled (plugin workaround)
      assert.are.equal(0, state.get_var_count())

      local sources = state.get_enabled_sources()
      assert.is_false(sources.shell)
      assert.is_false(sources.file)
    end)

    it("should not set count to 0 when LSP returns error", function()
      local commands = require("ecolog.lsp.commands")
      local lsp = require("ecolog.lsp")

      -- Mock: setPrecedence succeeds, but listEnvVariables fails
      lsp.execute_command = function(command, args, callback)
        if command == "ecolog.source.setPrecedence" then
          callback(nil, { success = true, precedence = args })
        elseif command == "ecolog.source.list" then
          callback(nil, {
            sources = {
              { name = "Shell", enabled = false, priority = 1 },
              { name = "File", enabled = true, priority = 2 },
            },
          })
        elseif command == "ecolog.listEnvVariables" then
          -- Simulate error
          callback({ message = "Internal error" }, nil)
        end
      end

      state.set_var_count(25) -- Initial count

      commands.set_sources({ "File" }, function() end)

      vim.wait(100, function()
        return false -- Just wait
      end)

      -- Count should NOT be reset to 0 on error - should preserve previous
      assert.are.equal(25, state.get_var_count())
    end)
  end)

  describe("set_active_file command", function()
    it("should update active files and variable count", function()
      local commands = require("ecolog.lsp.commands")
      local lsp = require("ecolog.lsp")

      lsp.execute_command = function(command, args, callback)
        if command == "ecolog.file.setActive" then
          callback(nil, { success = true })
        elseif command == "ecolog.listEnvVariables" then
          local vars = {}
          for i = 1, 10 do
            table.insert(vars, { name = "VAR_" .. i, value = "val" .. i, source = ".env.local" })
          end
          callback(nil, { variables = vars })
        end
      end

      state.set_active_files({ ".env" })
      state.set_var_count(5)

      commands.set_active_file({ ".env.local" }, function(success)
        assert.is_true(success)
      end)

      vim.wait(100, function()
        return state.get_var_count() == 10
      end)

      assert.are.same({ ".env.local" }, state.get_active_files())
      assert.are.equal(10, state.get_var_count())
    end)
  end)

  describe("refresh_state command", function()
    it("should refresh all state data", function()
      local commands = require("ecolog.lsp.commands")
      local lsp = require("ecolog.lsp")

      -- Mock get_client to return a fake client
      lsp.get_client = function()
        return { id = 1, name = "ecolog" }
      end

      lsp.execute_command = function(command, args, callback)
        if command == "ecolog.file.list" then
          callback(nil, { files = { "/path/.env", "/path/.env.local" } })
        elseif command == "ecolog.listEnvVariables" then
          local vars = {}
          for i = 1, 8 do
            table.insert(vars, { name = "VAR_" .. i, value = "val" .. i })
          end
          callback(nil, { variables = vars })
        elseif command == "ecolog.source.list" then
          callback(nil, {
            sources = {
              { name = "Shell", enabled = true, priority = 1 },
              { name = "File", enabled = true, priority = 2 },
              { name = "Remote", enabled = false, priority = 3 },
            },
          })
        end
      end

      -- Set initial state
      state.set_active_files({})
      state.set_var_count(0)
      state.set_enabled_sources({ shell = false, file = false })

      local callback_called = false
      commands.refresh_state(nil, function()
        callback_called = true
      end)

      vim.wait(200, function()
        return callback_called
      end)

      -- Verify all state was refreshed
      assert.are.same({ "/path/.env", "/path/.env.local" }, state.get_active_files())
      assert.are.equal(8, state.get_var_count())
      assert.are.same({ shell = true, file = true }, state.get_enabled_sources())
    end)

    it("should clear state when no files found", function()
      local commands = require("ecolog.lsp.commands")
      local lsp = require("ecolog.lsp")

      lsp.get_client = function()
        return { id = 1, name = "ecolog" }
      end

      lsp.execute_command = function(command, args, callback)
        if command == "ecolog.file.list" then
          callback(nil, { files = {} }) -- No files
        elseif command == "ecolog.listEnvVariables" then
          callback(nil, { variables = {} }) -- No vars
        elseif command == "ecolog.source.list" then
          callback(nil, { sources = {} })
        end
      end

      -- Set initial state
      state.set_active_files({ ".env" })
      state.set_var_count(10)

      local callback_called = false
      commands.refresh_state(nil, function()
        callback_called = true
      end)

      vim.wait(200, function()
        return callback_called
      end)

      -- State should be cleared
      assert.are.same({}, state.get_active_files())
      assert.are.equal(0, state.get_var_count())
    end)
  end)

  describe("re-enabling sources", function()
    it("should restore variable count when re-enabling a source", function()
      local commands = require("ecolog.lsp.commands")
      local lsp = require("ecolog.lsp")

      local shell_enabled = true

      lsp.execute_command = function(command, args, callback)
        if command == "ecolog.source.setPrecedence" then
          shell_enabled = vim.tbl_contains(args, "Shell")
          callback(nil, { success = true, precedence = args })
        elseif command == "ecolog.source.list" then
          callback(nil, {
            sources = {
              { name = "Shell", enabled = shell_enabled, priority = 1 },
              { name = "File", enabled = true, priority = 2 },
            },
          })
        elseif command == "ecolog.listEnvVariables" then
          local vars = {}
          local count = shell_enabled and 25 or 15 -- More vars with shell enabled
          for i = 1, count do
            table.insert(vars, { name = "VAR_" .. i, value = "val" .. i })
          end
          callback(nil, { variables = vars })
        end
      end

      -- Initial state with shell enabled
      state.set_var_count(25)
      state.set_enabled_sources({ shell = true, file = true })

      -- Disable shell
      commands.set_sources({ "File" }, function() end)
      vim.wait(100, function()
        return state.get_var_count() == 15
      end)
      assert.are.equal(15, state.get_var_count())
      assert.is_false(state.get_enabled_sources().shell)

      -- Re-enable shell
      commands.set_sources({ "Shell", "File" }, function() end)
      vim.wait(100, function()
        return state.get_var_count() == 25
      end)
      assert.are.equal(25, state.get_var_count())
      assert.is_true(state.get_enabled_sources().shell)
    end)
  end)
end)
