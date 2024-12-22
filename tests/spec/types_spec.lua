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
      assert.equals("number", types.detect_type("-123"))
      assert.equals("number", types.detect_type("123.456"))
      assert.equals("boolean", types.detect_type("true"))
      assert.equals("boolean", types.detect_type("false"))
      assert.equals("boolean", types.detect_type("yes"))
      assert.equals("boolean", types.detect_type("no"))
      assert.equals("boolean", types.detect_type("1"))
      assert.equals("boolean", types.detect_type("0"))
      assert.equals("string", types.detect_type("regular string"))
    end)

    it("should detect URLs", function()
      assert.equals("url", types.detect_type("https://example.com"))
      assert.equals("url", types.detect_type("http://subdomain.example.com/path"))
      assert.equals("url", types.detect_type("https://example.com/path?query=value"))
      assert.equals("localhost", types.detect_type("http://localhost:3000"))
      assert.equals("localhost", types.detect_type("http://127.0.0.1:8080"))
      assert.equals("localhost", types.detect_type("http://localhost"))
      assert.equals("string", types.detect_type("http://invalid:port")) -- Invalid port
    end)

    it("should detect database URLs", function()
      assert.equals("database_url", types.detect_type("postgresql://user:pass@localhost:5432/db"))
      assert.equals("database_url", types.detect_type("mysql://admin:secret@db.host:3306/mydb"))
      assert.equals("database_url", types.detect_type("mongodb://user:pass@mongo.host:27017/db"))
      assert.equals("string", types.detect_type("invalid://user:pass@host:port/db")) -- Invalid protocol
      assert.equals("string", types.detect_type("postgresql://user:pass@host:invalid/db")) -- Invalid port
    end)

    it("should detect and validate dates and times", function()
      assert.equals("iso_date", types.detect_type("2024-03-15"))
      assert.equals("string", types.detect_type("2024-13-15")) -- Invalid month
      assert.equals("string", types.detect_type("2024-04-31")) -- Invalid day
      assert.equals("string", types.detect_type("2024-02-30")) -- Invalid leap year date
      assert.equals("iso_time", types.detect_type("13:45:30"))
      assert.equals("string", types.detect_type("24:00:00")) -- Invalid hour
      assert.equals("string", types.detect_type("12:60:00")) -- Invalid minute
    end)

    it("should detect JSON and hex colors", function()
      assert.equals("json", types.detect_type('{"key": "value"}'))
      assert.equals("json", types.detect_type("[1, 2, 3]"))
      assert.equals("string", types.detect_type("{invalid json}"))
      assert.equals("hex_color", types.detect_type("#fff"))
      assert.equals("hex_color", types.detect_type("#FF00FF"))
      assert.equals("string", types.detect_type("#GGG")) -- Invalid hex
    end)

    it("should detect IPv4 addresses", function()
      assert.equals("ipv4", types.detect_type("192.168.1.1"))
      assert.equals("ipv4", types.detect_type("10.0.0.0"))
      assert.equals("string", types.detect_type("256.1.2.3")) -- Invalid octet
      assert.equals("string", types.detect_type("1.2.3.4.5")) -- Too many octets
    end)
  end)

  describe("custom types", function()
    before_each(function()
      -- Initialize with custom types
      types.setup({
        types = false, -- Disable built-in types
        custom_types = {
          semver = {
            pattern = "^v?%d+%.%d+%.%d+%-?[%w]*$",
            validate = function(value)
              local major, minor, patch = value:match("^v?(%d+)%.(%d+)%.(%d+)")
              return major and minor and patch
            end,
          },
          aws_region = {
            pattern = "^[a-z][a-z]%-[a-z]+%-[0-9]+$",
            validate = function(value)
              local valid_regions = {
                ["us-east-1"] = true,
                ["us-west-2"] = true,
                ["eu-west-1"] = true,
              }
              return valid_regions[value] == true
            end,
          },
          jwt = {
            pattern = "^eyJ[A-Za-z0-9_-]+%.[A-Za-z0-9_-]+%.[A-Za-z0-9_-]+$",
            validate = function(value)
              local parts = vim.split(value, ".", { plain = true })
              -- Check if it has 3 parts and starts with proper JWT header
              return #parts == 3 and parts[1]:match("^eyJ")
            end,
          },
        },
      })
    end)

    it("should register and detect custom types", function()
      -- Semver tests
      assert.equals("semver", types.detect_type("v1.2.3"))
      assert.equals("semver", types.detect_type("2.0.0"))
      assert.equals("semver", types.detect_type("1.0.0-alpha"))
      assert.equals("string", types.detect_type("v1.2")) -- Invalid semver
      assert.equals("string", types.detect_type("1.2.3.4")) -- Too many parts

      -- AWS region tests
      assert.equals("aws_region", types.detect_type("us-east-1"))
      assert.equals("aws_region", types.detect_type("eu-west-1"))
      assert.equals("string", types.detect_type("us-invalid-1")) -- Invalid region
      assert.equals("string", types.detect_type("invalid")) -- Wrong format

      -- JWT tests
      assert.equals(
        "jwt",
        types.detect_type(
          "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        )
      )
      assert.equals("string", types.detect_type("invalid.token")) -- Not enough parts
    end)

    it("should handle type conflicts correctly", function()
      -- Add a built-in type to test priority
      types.setup({
        types = {
          number = true, -- Enable built-in number type
        },
        custom_types = {
          custom_number = {
            pattern = "^%d+$",
            validate = function(value)
              return tonumber(value) ~= nil
            end,
          },
        },
      })

      -- Custom types should take precedence
      assert.equals("custom_number", types.detect_type("123"))
    end)
  end)

  describe("type transformation", function()
    it("should transform boolean values consistently", function()
      types.setup({ types = { boolean = true } })

      local test_cases = {
        { input = "yes", expected = "true" },
        { input = "1", expected = "true" },
        { input = "true", expected = "true" },
        { input = "no", expected = "false" },
        { input = "0", expected = "false" },
        { input = "false", expected = "false" },
      }

      for _, case in ipairs(test_cases) do
        local type_name, transformed = types.detect_type(case.input)
        assert.equals("boolean", type_name)
        assert.equals(case.expected, transformed)
      end
    end)

    it("should handle complex database URLs", function()
      types.setup({ types = { database_url = true } })

      local valid_urls = {
        "postgresql://user:pass@localhost:5432/db",
        "mysql://admin:secret@db.host:3306/mydb",
        "mongodb://user:pass@cluster:27017/db",
      }

      local invalid_urls = {
        "postgresql://localhost:5432/db", -- Missing credentials
        "invalid://user:pass@host:3306/db", -- Invalid protocol
        "postgresql://user@localhost:5432/db", -- Missing password
        "postgresql://user:pass@localhost/db", -- Missing port
      }

      for _, url in ipairs(valid_urls) do
        local type_name = types.detect_type(url)
        assert.equals("database_url", type_name, "Failed for URL: " .. url)
      end

      for _, url in ipairs(invalid_urls) do
        local type_name = types.detect_type(url)
        assert.equals("string", type_name, "Failed for invalid URL: " .. url)
      end
    end)

    it("should validate IPv4 address ranges", function()
      types.setup({ types = { ipv4 = true } })

      local test_cases = {
        { input = "192.168.1.1", expected = "ipv4" },
        { input = "10.0.0.0", expected = "ipv4" },
        { input = "172.16.254.1", expected = "ipv4" },
        { input = "256.1.2.3", expected = "string" },
        { input = "1.2.3.4.5", expected = "string" },
      }

      for _, case in ipairs(test_cases) do
        local type_name = types.detect_type(case.input)
        assert.equals(case.expected, type_name, string.format("Failed for input: %s", case.input))
      end
    end)
  end)

  describe("custom type validation", function()
    it("should handle custom type priority correctly", function()
      types.setup({
        types = { url = true },
        custom_types = {
          custom_url = {
            pattern = "^https?://[%w%-%.]+%.[%w%-%.]+",
            validate = function(value)
              return value:match("^https?://api%.")
            end,
          },
        },
      })

      -- Should match custom_url
      local type1 = types.detect_type("https://api.example.com")
      assert.equals("custom_url", type1)

      -- Should fall back to built-in url
      local type2 = types.detect_type("https://regular.example.com")
      assert.equals("url", type2)
    end)

    it("should validate custom type with transform", function()
      types.setup({
        custom_types = {
          normalized_path = {
            pattern = "^/[%w/%-%.]+$",
            validate = function(value)
              return not value:match("%.%.")
            end,
            transform = function(value)
              return value:gsub("//+", "/")
            end,
          },
        },
      })

      local type_name, transformed = types.detect_type("/path//to///file")
      assert.equals("normalized_path", type_name)
      assert.equals("/path/to/file", transformed)
    end)
  end)
end)
