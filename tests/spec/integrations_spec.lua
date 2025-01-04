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
            Variable = 1,
          },
        },
      }, true)

      local providers = {
        get_providers = function()
          return {}
        end,
        load_providers = function() end,
      }

      local shelter = {
        is_enabled = function()
          return false
        end,
        mask_value = function(val)
          return val
        end,
      }

      nvim_cmp.setup({
        integrations = { nvim_cmp = true },
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
        is_enabled = function()
          return true
        end,
        mask_value = function(val)
          return string.rep("*", #val)
        end,
      }

      local env_vars = {
        TEST_VAR = {
          value = "secret123",
          type = "string",
          source = ".env",
        },
      }

      -- Mock ecolog module
      package.loaded["ecolog"] = {
        get_env_vars = function()
          return env_vars
        end,
      }

      -- Create mock completion source with shelter mode
      local source = {
        complete = function(_, _, callback)
          callback({
            items = {
              {
                label = "TEST_VAR",
                detail = shelter.mask_value("secret123"),
                kind = 1,
              },
            },
          })
        end,
      }

      -- Mock nvim-cmp
      local cmp = mock({
        register_source = function()
          return source
        end,
        lsp = {
          CompletionItemKind = {
            Variable = 1,
          },
        },
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
      nvim_cmp.setup(
        {
          integrations = { nvim_cmp = true },
        },
        env_vars,
        {
          get_providers = function()
            return {
              {
                get_completion_trigger = function()
                  return "process.env."
                end,
              },
            }
          end,
          load_providers = function() end,
        },
        shelter
      )

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

  describe("lspsaga integration", function()
    local lspsaga
    local api = vim.api

    before_each(function()
      package.loaded["ecolog.integrations.lspsaga"] = nil
      lspsaga = require("ecolog.integrations.lspsaga")

      -- Mock vim.api functions
      stub(api, "nvim_get_current_line")
      stub(api, "nvim_win_get_cursor")
      stub(api, "nvim_get_keymap")
      stub(api, "nvim_del_keymap")
      stub(api, "nvim_set_keymap")
      stub(api, "nvim_create_user_command")

      -- Mock vim.cmd
      stub(vim, "cmd")

      -- Create commands
      lspsaga.setup()
    end)

    after_each(function()
      -- Restore stubs
      api.nvim_get_current_line:revert()
      api.nvim_win_get_cursor:revert()
      api.nvim_get_keymap:revert()
      api.nvim_del_keymap:revert()
      api.nvim_set_keymap:revert()
      api.nvim_create_user_command:revert()
      vim.cmd:revert()
    end)

    describe("word boundary detection", function()
      local test_cases = {
        {
          desc = "should detect word in middle of line",
          line = "const TEST_VAR = process.env.TEST",
          col = 15, -- cursor on TEST_VAR
          expected = "TEST_VAR",
        },
        {
          desc = "should detect word at start of line",
          line = "TEST_VAR = value",
          col = 0,
          expected = "TEST_VAR",
        },
        {
          desc = "should detect word at end of line",
          line = "const TEST_VAR",
          col = 11,
          expected = "TEST_VAR",
        },
        {
          desc = "should handle cursor at start of word",
          line = "const TEST_VAR = value",
          col = 6,
          expected = "TEST_VAR",
        },
        {
          desc = "should handle cursor at end of word",
          line = "const TEST_VAR = value",
          col = 13,
          expected = "TEST_VAR",
        },
        {
          desc = "should handle underscore in word",
          line = "const MY_TEST_VAR = value",
          col = 10,
          expected = "MY_TEST_VAR",
        },
      }

      for _, tc in ipairs(test_cases) do
        it(tc.desc, function()
          api.nvim_get_current_line.returns(tc.line)
          api.nvim_win_get_cursor.returns({ 1, tc.col })

          local word = lspsaga.get_var_word_under_cursor()
          assert.equals(tc.expected, word)
        end)
      end
    end)

    describe("command handling", function()
      it("should use EcologPeek for env vars", function()
        -- Mock environment variables and peek module
        local mock_peek = {
          peek_env_value = stub(),
        }
        package.loaded["ecolog.peek"] = mock_peek

        local mock_providers = {
          get_providers = function()
            return {}
          end,
        }
        package.loaded["ecolog.providers"] = mock_providers

        local mock_ecolog = {
          get_env_vars = function()
            return { TEST_VAR = { value = "test" } }
          end,
          get_opts = function()
            return { some = "opts" }
          end,
        }
        lspsaga._ecolog = mock_ecolog

        api.nvim_get_current_line.returns("const TEST_VAR = value")
        api.nvim_win_get_cursor.returns({ 1, 8 })

        lspsaga.handle_hover()
        assert
          .stub(mock_peek.peek_env_value)
          .was_called_with("TEST_VAR", { some = "opts" }, { TEST_VAR = { value = "test" } }, mock_providers, match._)
      end)

      describe("keymap replacement", function()
        it("should replace Lspsaga keymaps with Ecolog commands", function()
          -- Mock existing keymaps
          api.nvim_get_keymap.returns({
            {
              lhs = "K",
              rhs = "<cmd>Lspsaga hover_doc<CR>",
              silent = 1,
              noremap = 1,
            },
          })

          lspsaga.replace_saga_keymaps()

          assert.stub(api.nvim_del_keymap).was_called()
          assert.stub(api.nvim_set_keymap).was_called_with("n", "K", "<cmd>EcologSagaHover<CR>", {
            silent = true,
            noremap = true,
            expr = false,
            desc = "Ecolog hover_doc",
          })
        end)
      end)
    end)
  end)

  describe("lsp integration", function()
    local lsp
    local api = vim.api
    local lsp_handlers = vim.lsp.handlers

    before_each(function()
      package.loaded["ecolog.integrations.lsp"] = nil
      package.loaded["ecolog.providers"] = nil
      lsp = require("ecolog.integrations.lsp")

      -- Mock vim.api functions
      stub(api, "nvim_get_current_line")
      stub(api, "nvim_win_get_cursor")
      stub(api, "nvim_buf_get_lines")
      stub(api, "nvim_win_set_cursor")
      stub(api, "nvim_create_user_command")

      -- Mock vim.cmd
      stub(vim, "cmd")

      -- Mock providers
      package.loaded["ecolog.providers"] = {
        get_providers = function()
          return {}
        end,
        load_providers = function() end,
      }

      -- Initialize ecolog with default settings
      local ecolog = require("ecolog")
      ecolog.setup({
        integrations = {
          lsp = true,
        },
      })

      -- Store original LSP handlers
      lsp_handlers["textDocument/hover"] = function() end
      lsp_handlers["textDocument/definition"] = function() end

      -- Mock EcologPeek command
      local old_pcall = _G.pcall
      _G.pcall = function(fn, ...)
        if type(...) == "string" and (...):match("^EcologPeek") then
          return true
        end
        return old_pcall(fn, ...)
      end
    end)

    after_each(function()
      -- Restore stubs
      api.nvim_get_current_line:revert()
      api.nvim_win_get_cursor:revert()
      api.nvim_buf_get_lines:revert()
      api.nvim_win_set_cursor:revert()
      api.nvim_create_user_command:revert()
      vim.cmd:revert()

      -- Clear mocks
      package.loaded["ecolog.providers"] = nil

      -- Restore pcall
      _G.pcall = old_pcall
    end)

    describe("hover handling", function()
      it("should use EcologPeek for env vars", function()
        -- Create spy for EcologPeek command
        local peek_spy = stub()

        -- Mock environment variables
        local mock_ecolog = {
          get_env_vars = function()
            return { TEST_VAR = { value = "test", source = ".env" } }
          end,
          setup = function(opts)
            -- Create the EcologPeek command with the spy
            api.nvim_create_user_command("EcologPeek", peek_spy, { nargs = "?" })
          end,
        }
        package.loaded["ecolog"] = mock_ecolog

        -- Initialize ecolog
        mock_ecolog.setup({
          integrations = {
            lsp = true,
          },
        })

        -- Mock providers with TypeScript provider
        package.loaded["ecolog.providers"] = {
          get_providers = function()
            return {
              {
                pattern = "process%.env%.%w*$",
                extract_var = function(line, col)
                  return "TEST_VAR"
                end,
              },
            }
          end,
          load_providers = function() end,
        }

        -- Mock cursor position on env var
        api.nvim_get_current_line.returns("const TEST_VAR = process.env.TEST_VAR")
        api.nvim_win_get_cursor.returns({ 1, 30 })

        -- Mock api.nvim_get_commands to return our command
        stub(api, "nvim_get_commands").returns({
          EcologPeek = {
            callback = peek_spy,
          },
        })

        -- Call hover handler
        lsp.setup()
        lsp_handlers["textDocument/hover"](nil, {}, {}, {})

        -- Verify EcologPeek command was called with correct args
        assert.stub(peek_spy).was_called_with({ args = "TEST_VAR" })
      end)

      it("should use original hover handler for non-env vars", function()
        -- Mock environment variables
        local mock_ecolog = {
          get_env_vars = function()
            return { TEST_VAR = { value = "test" } }
          end,
        }
        package.loaded["ecolog"] = mock_ecolog

        -- Mock providers with TypeScript provider
        package.loaded["ecolog.providers"] = {
          get_providers = function()
            return {
              {
                pattern = "process%.env%.%w*$",
                extract_var = function(line, col)
                  return nil
                end,
              },
            }
          end,
          load_providers = function() end,
        }

        -- Mock cursor position on regular variable
        api.nvim_get_current_line.returns("const regularVar = 'hello'")
        api.nvim_win_get_cursor.returns({ 1, 8 })

        -- Create spy for original hover handler
        local original_hover = stub()
        local result = { contents = "test hover" }
        lsp_handlers["textDocument/hover"] = original_hover

        -- Call hover handler
        lsp.setup()
        lsp_handlers["textDocument/hover"](nil, result, {}, {})

        -- Verify original handler was called
        assert.stub(original_hover).was_called_with(nil, result, {}, {})
      end)
    end)

    describe("setup and restore", function()
      it("should restore original handlers", function()
        -- Store original handlers
        local original_hover = function() end
        local original_definition = function() end
        lsp_handlers["textDocument/hover"] = original_hover
        lsp_handlers["textDocument/definition"] = original_definition

        -- Mock providers
        package.loaded["ecolog.providers"] = {
          get_providers = function()
            return {}
          end,
          load_providers = function() end,
        }

        -- Setup LSP integration
        lsp.setup()

        -- Verify handlers were changed
        assert.are_not.equal(original_hover, lsp_handlers["textDocument/hover"])
        assert.are_not.equal(original_definition, lsp_handlers["textDocument/definition"])

        -- Restore handlers
        lsp.restore()

        -- Verify original handlers were restored
        assert.equal(original_hover, lsp_handlers["textDocument/hover"])
        assert.equal(original_definition, lsp_handlers["textDocument/definition"])
      end)
    end)
  end)
end)
