describe("providers", function()
  local providers
  local typescript_provider
  local javascript_provider

  before_each(function()
    -- Reset module cache
    package.loaded["ecolog.providers"] = nil
    package.loaded["ecolog.providers.python"] = nil
    package.loaded["ecolog.providers.javascript"] = nil
    
    -- Mock providers
    typescript_provider = {
      providers = {
        {
          pattern = "process%.env%.[%w_]*$",
          filetype = { "typescript", "typescriptreact" },
          extract_var = function(line, col)
            local before_cursor = line:sub(1, col)
            return before_cursor:match("process%.env%.([%w_]+)$")
          end
        },
        {
          pattern = 'process%.env%["[%w_]*$',
          filetype = { "typescript", "typescriptreact" },
          extract_var = function(line, col)
            local before_cursor = line:sub(1, col)
            return before_cursor:match('process%.env%["([%w_]*)$')
          end
        },
        {
          pattern = "process%.env%['[%w_]*$",
          filetype = { "typescript", "typescriptreact" },
          extract_var = function(line, col)
            local before_cursor = line:sub(1, col)
            return before_cursor:match("process%.env%['([%w_]*)$")
          end
        },
        {
          pattern = "import%.meta%.env%.[%w_]*$",
          filetype = { "typescript", "typescriptreact" },
          extract_var = function(line, col)
            local before_cursor = line:sub(1, col + 1)
            return before_cursor:match("import%.meta%.env%.([%w_]+)$")
          end
        },
        {
          pattern = 'Deno%.env%.get%("[%w_]*$',
          filetype = "typescript",
          extract_var = function(line, col)
            local before_cursor = line:sub(1, col)
            return before_cursor:match('Deno%.env%.get%("([%w_]*)$')
          end
        },
        {
          pattern = 'Deno%.env%.get%("[%w_]+"%)?$',
          filetype = "typescript",
          extract_var = function(line, col)
            local before_cursor = line:sub(1, col)
            return before_cursor:match('Deno%.env%.get%("([%w_]+)"%)?$')
          end
        }
      }
    }

    javascript_provider = {
      providers = {
        {
          pattern = "process%.env%.[%w_]*$",
          filetype = { "javascript", "javascriptreact" },
          extract_var = function(line, col)
            local before_cursor = line:sub(1, col)
            return before_cursor:match("process%.env%.([%w_]+)$")
          end
        },
        {
          pattern = "process%.env%['[%w_]*$",
          filetype = { "javascript", "javascriptreact" },
          extract_var = function(line, col)
            local before_cursor = line:sub(1, col)
            return before_cursor:match("process%.env%['([%w_]*)$")
          end
        }
      }
    }

    -- Mock providers
    package.loaded["ecolog.providers.typescript"] = typescript_provider
    package.loaded["ecolog.providers.javascript"] = javascript_provider
    
    providers = require("ecolog.providers")
  end)

  describe("typescript provider", function()
    describe("process.env dot notation", function()
      local test_cases = {
        {
          desc = "extracts variable at end of line",
          line = "const apiKey = process.env.API_KEY",
          col = #"const apiKey = process.env.API_KEY",
          expected = "API_KEY"
        },
        {
          desc = "extracts variable when cursor is on variable",
          line = "const apiKey = process.env.API_KEY;",
          col = #"const apiKey = process.env.API_KEY",
          expected = "API_KEY"
        },
        {
          desc = "extracts variable with single underscore",
          line = "const url = process.env.DATABASE_URL;",
          col = #"const url = process.env.DATABASE_URL",
          expected = "DATABASE_URL"
        },
        {
          desc = "extracts variable with multiple underscores",
          line = "const key = process.env.MY_API_KEY_HERE;",
          col = #"const key = process.env.MY_API_KEY_HERE",
          expected = "MY_API_KEY_HERE"
        }
      }

      for _, tc in ipairs(test_cases) do
        it(tc.desc, function()
          local var = typescript_provider.providers[1].extract_var(tc.line, tc.col)
          assert.equals(tc.expected, var)
        end)
      end
    end)

    describe("process.env bracket notation", function()
      local test_cases = {
        {
          desc = "extracts variable with double quotes",
          line = 'const key = process.env["DATABASE_URL"]',
          col = #'const key = process.env["DATABASE_URL',
          provider_index = 2,
          expected = "DATABASE_URL"
        },
        {
          desc = "extracts variable with single quotes",
          line = "const key = process.env['DATABASE_URL']",
          col = #"const key = process.env['DATABASE_URL",
          provider_index = 3,
          expected = "DATABASE_URL"
        }
      }

      for _, tc in ipairs(test_cases) do
        it(tc.desc, function()
          local var = typescript_provider.providers[tc.provider_index].extract_var(tc.line, tc.col)
          assert.equals(tc.expected, var)
        end)
      end
    end)

    describe("import.meta.env", function()
      it("extracts Vite environment variables", function()
        local line = "const url = import.meta.env.VITE_API_URL"
        local var = typescript_provider.providers[4].extract_var(line, #line)
        assert.equals("VITE_API_URL", var)
      end)
    end)

    describe("Deno.env", function()
      it("extracts Deno environment variables", function()
        local line = 'const key = Deno.env.get("DATABASE_URL")'
        local var = typescript_provider.providers[6].extract_var(line, #line)
        assert.equals("DATABASE_URL", var)
      end)
    end)
  end)

  describe("javascript provider", function()
    describe("process.env", function()
      local test_cases = {
        {
          desc = "extracts dot notation variables",
          line = "const apiKey = process.env.API_KEY",
          col = #"const apiKey = process.env.API_KEY",
          provider_index = 1,
          expected = "API_KEY"
        },
        {
          desc = "extracts bracket notation variables with single quotes",
          line = "const key = process.env['DATABASE_URL']",
          col = #"const key = process.env['DATABASE_URL",
          provider_index = 2,
          expected = "DATABASE_URL"
        }
      }

      for _, tc in ipairs(test_cases) do
        it(tc.desc, function()
          local var = javascript_provider.providers[tc.provider_index].extract_var(tc.line, tc.col)
          assert.equals(tc.expected, var)
        end)
      end
    end)
  end)

  describe("lazy loading", function()
    it("only loads providers when they are accessed", function()
      -- Reset module cache
      package.loaded["ecolog.providers"] = nil
      package.loaded["ecolog.providers.python"] = nil
      package.loaded["ecolog.providers.javascript"] = nil

      local load_count = 0
      -- Mock the require function to track provider loading
      local original_require = _G.require
      _G.require = function(module)
        if module:match("^ecolog.providers.[^.]+$") then
          load_count = load_count + 1
        end
        return original_require(module)
      end

      -- Load the main providers module
      local providers = require("ecolog.providers")
      
      -- Initially, no specific providers should be loaded
      assert.equals(0, load_count)

      -- Access python provider, should trigger lazy load
      local py_providers = providers.get_providers("python")
      assert.equals(1, load_count)
      assert.is_not_nil(py_providers)
      assert.is_true(#py_providers > 0)

      -- Accessing python again should not increase load count since it's cached
      providers.get_providers("python")
      assert.equals(1, load_count)

      -- Accessing javascript should trigger another lazy load
      local js_providers = providers.get_providers("javascript")
      assert.equals(2, load_count)
      assert.is_not_nil(js_providers)
      assert.is_true(#js_providers > 0)

      -- Restore original require
      _G.require = original_require
    end)

    it("does not load other providers when accessing one provider", function()
      -- Reset module cache
      package.loaded["ecolog.providers"] = nil
      package.loaded["ecolog.providers.python"] = nil
      package.loaded["ecolog.providers.javascript"] = nil

      local loaded_modules = {}
      -- Mock the require function to track which specific modules are loaded
      local original_require = _G.require
      _G.require = function(module)
        if module:match("^ecolog.providers.[^.]+$") then
          loaded_modules[module] = true
        end
        return original_require(module)
      end

      -- Load the main providers module
      local providers = require("ecolog.providers")
      
      -- Initially, no specific providers should be loaded
      assert.is_nil(loaded_modules["ecolog.providers.python"])
      assert.is_nil(loaded_modules["ecolog.providers.javascript"])

      -- Access only python provider
      local py_providers = providers.get_providers("python")
      assert.is_not_nil(py_providers)
      assert.is_true(#py_providers > 0)
      
      -- Verify python is loaded but javascript remains unloaded
      assert.is_true(loaded_modules["ecolog.providers.python"])
      assert.is_nil(loaded_modules["ecolog.providers.javascript"])

      -- Restore original require
      _G.require = original_require
    end)
  end)
end) 