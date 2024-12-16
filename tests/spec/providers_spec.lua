describe("providers", function()
  local providers
  local typescript_provider
  local javascript_provider

  before_each(function()
    package.loaded["ecolog.providers"] = nil
    package.loaded["ecolog.providers.typescript"] = nil
    package.loaded["ecolog.providers.javascript"] = nil
    
    -- Mock the providers
    typescript_provider = {
      providers = {
        {
          pattern = "process%.env%.%w*$",
          filetype = { "typescript", "typescriptreact" },
          extract_var = function(line, col)
            local before_cursor = line:sub(1, col)
            return before_cursor:match("process%.env%.([%w_]+)")
          end
        },
        {
          pattern = "process%.env%['%w*$",
          filetype = { "typescript", "typescriptreact" },
          extract_var = function(line, col)
            local before_cursor = line:sub(1, col)
            return before_cursor:match("process%.env%['([%w_]*)")
          end
        },
        {
          pattern = "import%.meta%.env%.%w*$",
          filetype = { "typescript", "typescriptreact" },
          extract_var = function(line, col)
            local before_cursor = line:sub(1, col)
            return before_cursor:match("import%.meta%.env%.([%w_]+)")
          end
        }
      }
    }

    javascript_provider = {
      providers = {
        {
          pattern = "process%.env%.%w*$",
          filetype = { "javascript", "javascriptreact" },
          extract_var = function(line, col)
            local before_cursor = line:sub(1, col)
            return before_cursor:match("process%.env%.([%w_]+)")
          end
        },
        {
          pattern = "process%.env%['%w*$",
          filetype = { "javascript", "javascriptreact" },
          extract_var = function(line, col)
            local before_cursor = line:sub(1, col)
            return before_cursor:match("process%.env%['([%w_]*)")
          end
        }
      }
    }

    -- Mock require to return our mock providers
    package.loaded["ecolog.providers.typescript"] = typescript_provider
    package.loaded["ecolog.providers.javascript"] = javascript_provider
    
    providers = require("ecolog.providers")
  end)

  describe("typescript provider", function()
    it("should extract process.env variables", function()
      local line = "const apiKey = process.env.API_KEY"
      local col = #line
      local var = typescript_provider.providers[1].extract_var(line, col)
      assert.equals("API_KEY", var)
    end)

    it("should extract import.meta.env variables", function()
      local line = "const url = import.meta.env.VITE_API_URL"
      local col = #line
      local var = typescript_provider.providers[3].extract_var(line, col)
      assert.equals("VITE_API_URL", var)
    end)
  end)

  describe("javascript provider", function()
    it("should extract process.env variables", function()
      local line = "const apiKey = process.env.API_KEY"
      local col = #line
      local var = javascript_provider.providers[1].extract_var(line, col)
      assert.equals("API_KEY", var)
    end)

    it("should handle single quote bracket notation", function()
      local line = "const key = process.env['DATABASE_URL"
      local col = #line
      local var = javascript_provider.providers[2].extract_var(line, col)
      assert.equals("DATABASE_URL", var)
    end)
  end)
end) 