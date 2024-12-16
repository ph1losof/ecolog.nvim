describe("types", function()
  local types

  before_each(function()
    package.loaded["ecolog.types"] = nil
    types = require("ecolog.types")
  end)

  describe("type detection", function()
    before_each(function()
      -- Initialize with all built-in types enabled
      types.setup({
        types = true,
      })
    end)

    it("should detect basic types", function()
      assert.equals("number", types.detect_type("123"))
      assert.equals("boolean", types.detect_type("true"))
      assert.equals("boolean", types.detect_type("false"))
      assert.equals("string", types.detect_type("regular string"))
    end)

    it("should detect URLs", function()
      assert.equals("url", types.detect_type("https://example.com"))
      assert.equals("url", types.detect_type("http://localhost:3000"))
    end)

    it("should detect database URLs", function()
      local value = "postgresql://user:pass@localhost:5432/db"
      assert.equals("database_url", types.detect_type(value))
    end)

    it("should detect and validate dates", function()
      assert.equals("iso_date", types.detect_type("2024-03-15"))
      assert.equals("string", types.detect_type("2024-13-15")) -- Invalid month
    end)
  end)

  describe("custom types", function()
    before_each(function()
      -- Initialize with custom types
      types.setup({
        types = false, -- Disable built-in types
        custom_types = {
          semver = {
            pattern = "^v?(%d+)%.(%d+)%.(%d+)([%-+].+)?$",
            validate = function(value)
              local major, minor, patch = value:match("^v?(%d+)%.(%d+)%.(%d+)")
              return major and minor and patch
            end,
          },
        },
      })
    end)

    it("should register and detect custom types", function()
      assert.equals("semver", types.detect_type("v1.2.3"))
      assert.equals("semver", types.detect_type("2.0.0"))
      assert.equals("string", types.detect_type("v1.2")) -- Invalid semver
    end)
  end)
end)
