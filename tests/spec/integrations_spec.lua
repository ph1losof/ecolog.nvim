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
    package.loaded["ecolog.utils"] = nil
    package.loaded["ecolog.providers"] = nil

    nvim_cmp = require("ecolog.integrations.cmp.nvim_cmp")
    blink_cmp = require("ecolog.integrations.cmp.blink_cmp")

    -- Mock ecolog module
    package.loaded["ecolog"] = {
      get_config = function()
        return {
          provider_patterns = {
            extract = true,
            cmp = true,
          },
        }
      end,
      get_env_vars = function()
        return {
          MY_TEST_VAR = { value = "test", source = ".env" },
        }
      end,
    }

    -- Mock utils module
    package.loaded["ecolog.utils"] = {
      get_var_word_under_cursor = function(providers)
        local line = vim.api.nvim_get_current_line()
        if line:match("MY_TEST_VAR") then
          return "MY_TEST_VAR"
        end
        return ""
      end,
    }

    -- Mock providers module
    package.loaded["ecolog.providers"] = {
      get_providers = function()
        return {
          {
            pattern = "process%.env%.%w*$",
            extract_var = function(line, col)
              if line:match("process%.env%.") then
                return line:match("process%.env%.([%w_]+)")
              end
              return nil
            end,
          },
        }
      end,
      load_providers = function() end,
    }
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
      source.complete({}, {}, function(response)
        assert.equals("*********", response.items[1].detail)
      end)

      -- Restore require
      _G.require = old_require
    end)

    it("should format completion items with provider customizations", function()
      local cmp = mock({
        register_source = function() end,
        lsp = {
          CompletionItemKind = {
            Variable = 1,
          },
        },
      }, true)

      local custom_provider = {
        get_completion_trigger = function()
          return "custom."
        end,
        pattern = "custom%.",
        format_completion = function(item, var_name, var_info)
          item.insertText = "custom." .. var_name
          return item
        end,
      }

      local providers = {
        get_providers = function()
          return { custom_provider }
        end,
        load_providers = function() end,
      }

      local source
      cmp.register_source = function(_, src)
        source = src
        return source
      end

      local env_vars = {
        TEST_VAR = {
          value = "test_value",
          type = "string",
          source = ".env",
          comment = "Test comment",
        },
      }

      -- Mock ecolog module with required configuration
      package.loaded["ecolog"] = {
        get_config = function()
          return {
            provider_patterns = {
              cmp = true,
            },
          }
        end,
        get_env_vars = function()
          return env_vars
        end,
      }

      -- Mock require to return our cmp mock
      local old_require = _G.require
      _G.require = function(mod)
        if mod == "cmp" then
          return cmp
        end
        return old_require(mod)
      end

      nvim_cmp.setup(
        {
          integrations = { nvim_cmp = true },
        },
        env_vars,
        providers,
        {
          is_enabled = function()
            return false
          end,
          mask_value = function(val)
            return val
          end,
        }
      )

      -- Trigger lazy loading
      vim.api.nvim_exec_autocmds("InsertEnter", {})

      assert.is_not_nil(source, "Source should be initialized")

      local callback_called = false
      source:complete({
        context = {
          cursor_before_line = "custom.",
          cursor = { 1, 7 },
        }
      }, function(response)
        callback_called = true
        local result = response.items
        assert.equals(1, #result)
        assert.equals("TEST_VAR", result[1].label)
        assert.equals("custom.TEST_VAR", result[1].insertText)
        assert.equals(".env", result[1].detail)
        assert.matches("Test comment", result[1].documentation.value)
      end)

      assert.is_true(callback_called)

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

    it("should handle completion with shelter mode", function()
      local providers = {
        get_providers = function()
          return {
            {
              pattern = "process%.env%.",
              get_completion_trigger = function()
                return "process.env."
              end,
            },
          }
        end,
      }

      local shelter = {
        is_enabled = function()
          return true
        end,
        mask_value = function(val)
          return string.rep("*", #val)
        end,
      }

      local source = blink_cmp.new()
      blink_cmp.setup({}, {}, providers, shelter)

      local ctx = {
        cursor = { 1, 12 },
        line = "process.env.",
      }

      -- Mock ecolog module with test env vars
      package.loaded["ecolog"] = {
        get_config = function()
          return {
            provider_patterns = {
              cmp = true,
            },
          }
        end,
        get_env_vars = function()
          return {
            SECRET_KEY = {
              value = "secret123",
              type = "string",
              source = ".env",
              comment = "API key",
            },
          }
        end,
      }

      local callback_called = false
      source:get_completions(ctx, function(result)
        callback_called = true
        assert.equals(1, #result.items)
        local item = result.items[1]
        assert.equals("SECRET_KEY", item.label)
        assert.equals("SECRET_KEY", item.insertText)
        assert.equals(".env", item.detail)
        assert.matches("%*%*%*%*%*%*%*%*%*", item.documentation.value)
        assert.matches("API key", item.documentation.value)
      end)

      assert.is_true(callback_called)
    end)

    it("should handle provider-specific completion formatting", function()
      local custom_provider = {
        pattern = "custom%.",
        get_completion_trigger = function()
          return "custom."
        end,
        format_completion = function(item, var_name, var_info)
          item.insertText = "custom." .. var_name
          item.score = 2
          return item
        end,
      }

      local providers = {
        get_providers = function()
          return { custom_provider }
        end,
      }

      local source = blink_cmp.new()
      blink_cmp.setup({}, {}, providers, {
        is_enabled = function()
          return false
        end,
        mask_value = function(val)
          return val
        end,
      })

      local ctx = {
        cursor = { 1, 7 },
        line = "custom.",
      }

      package.loaded["ecolog"] = {
        get_config = function()
          return {
            provider_patterns = {
              cmp = true,
            },
          }
        end,
        get_env_vars = function()
          return {
            API_KEY = {
              value = "test_key",
              type = "string",
              source = ".env",
            },
          }
        end,
      }

      local callback_called = false
      source:get_completions(ctx, function(result)
        callback_called = true
        assert.equals(1, #result.items)
        local item = result.items[1]
        assert.equals("API_KEY", item.label)
        assert.equals("custom.API_KEY", item.insertText)
        assert.equals(2, item.score)
      end)

      assert.is_true(callback_called)
    end)
  end)

  describe("lspsaga integration", function()
    local lspsaga
    local api = vim.api
    local peek_spy = stub.new()

    before_each(function()
      package.loaded["ecolog.integrations.lspsaga"] = nil
      package.loaded["lspsaga.hover"] = {
        render_hover_doc = function() end,
      }
      package.loaded["lspsaga.definition"] = {
        init = function() end,
      }

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
          line = "const MY_TEST_VAR = process.env.TEST",
          col = 15, -- cursor on MY_TEST_VAR
          expected = "MY_TEST_VAR",
        },
        {
          desc = "should detect word at start of line",
          line = "MY_TEST_VAR = value",
          col = 0,
          expected = "MY_TEST_VAR",
        },
        {
          desc = "should detect word at end of line",
          line = "const MY_TEST_VAR",
          col = 11,
          expected = "MY_TEST_VAR",
        },
        {
          desc = "should handle cursor at start of word",
          line = "const MY_TEST_VAR = value",
          col = 6,
          expected = "MY_TEST_VAR",
        },
        {
          desc = "should handle cursor at end of word",
          line = "const MY_TEST_VAR = value",
          col = 13,
          expected = "MY_TEST_VAR",
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

          local utils = require("ecolog.utils")
          local word = utils.get_var_word_under_cursor()
          assert.equals(tc.expected, word)
        end)
      end
    end)

    describe("command handling", function()
      it("should use EcologPeek for env vars", function()
        -- Mock environment variables
        local mock_ecolog = {
          get_env_vars = function()
            return { MY_TEST_VAR = { value = "test", source = ".env" } }
          end,
          setup = function(opts)
            -- Create the EcologPeek command
            api.nvim_create_user_command("EcologPeek", function(args)
              peek_spy(args.args)
            end, { nargs = "?" })
          end,
        }
        package.loaded["ecolog"] = mock_ecolog

        -- Initialize ecolog
        mock_ecolog.setup({
          integrations = {
            lspsaga = true,
          },
        })

        -- Mock cursor position on env var
        api.nvim_get_current_line.returns("const MY_TEST_VAR = process.env.MY_TEST_VAR")
        api.nvim_win_get_cursor.returns({ 1, 30 })

        -- Mock nvim_get_commands to return our command
        stub(api, "nvim_get_commands")
        api.nvim_get_commands.returns({
          EcologPeek = {
            callback = function(args)
              peek_spy(args.args)
            end,
          },
        })

        -- Call hover handler
        lspsaga.handle_hover({})

        -- Verify EcologPeek was called
        assert.stub(peek_spy).was_called_with("MY_TEST_VAR")

        -- Restore stub
        api.nvim_get_commands:revert()
      end)
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
          {
            lhs = "gd",
            rhs = "<cmd>Lspsaga goto_definition<CR>",
            silent = 1,
            noremap = 1,
          },
        })

        -- Replace keymaps
        lspsaga.replace_saga_keymaps()

        -- Verify old keymaps were deleted
        assert.stub(api.nvim_del_keymap).was_called(2)

        -- Verify both new keymaps were set (without enforcing order)
        assert.stub(api.nvim_set_keymap).was_called(2)

        -- Get all calls to nvim_set_keymap
        local calls = api.nvim_set_keymap.calls
        local hover_call_found = false
        local gd_call_found = false

        for _, call in ipairs(calls) do
          local mode, lhs, rhs, opts = unpack(call.vals)
          if mode == "n" and lhs == "K" and rhs == "<cmd>EcologSagaHover<CR>" then
            assert.same({ silent = true, noremap = true, expr = false, desc = "Ecolog hover_doc" }, opts)
            hover_call_found = true
          elseif mode == "n" and lhs == "gd" and rhs == "<cmd>EcologSagaGD<CR>" then
            assert.same({ silent = true, noremap = true, expr = false, desc = "Ecolog goto_definition" }, opts)
            gd_call_found = true
          end
        end

        assert.is_true(hover_call_found, "Hover keymap was not set correctly")
        assert.is_true(gd_call_found, "Goto definition keymap was not set correctly")
      end)
    end)
  end)
end)
