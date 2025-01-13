describe("providers", function()
  local providers
  local typescript_provider
  local javascript_provider

  before_each(function()
    -- Reset module cache
    package.loaded["ecolog.providers"] = nil
    package.loaded["ecolog.providers.typescript"] = nil
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
end) 