local interpolation = require("ecolog.interpolation")


describe("interpolation", function()
  local env_vars = {
    NAME = { value = "John" },
    GREETING = { value = "Hello" },
    EMPTY = { value = "" },
    NESTED = { value = "${NAME}" },
    PATH = { value = "/usr/local/bin" },
  }

  describe("basic interpolation", function()
    it("should interpolate simple variables", function()
      assert.equals("Hello John", interpolation.interpolate("${GREETING} ${NAME}", env_vars))
      assert.equals("Hello John", interpolation.interpolate("$GREETING $NAME", env_vars))
    end)

    it("should handle undefined variables", function()
      assert.equals("Hello ", interpolation.interpolate("${GREETING} ${UNDEFINED}", env_vars))
    end)

    it("should handle empty variables", function()
      assert.equals("Empty:", interpolation.interpolate("Empty:${EMPTY}", env_vars))
    end)

    it("should handle nested interpolation", function()
      assert.equals("John", interpolation.interpolate("${NESTED}", env_vars))
    end)
  end)

  describe("default and alternate values", function()
    it("should handle default values", function()
      assert.equals("guest", interpolation.interpolate("${UNDEFINED:-guest}", env_vars))
      assert.equals("John", interpolation.interpolate("${NAME:-guest}", env_vars))
      assert.equals("guest", interpolation.interpolate("${EMPTY:-guest}", env_vars))
    end)

    it("should handle alternate values", function()
      assert.equals("guest", interpolation.interpolate("${UNDEFINED-guest}", env_vars))
      assert.equals("John", interpolation.interpolate("${NAME-guest}", env_vars))
      assert.equals("", interpolation.interpolate("${EMPTY-guest}", env_vars))
    end)
  end)

  describe("quoted strings", function()
    it("should handle single quoted strings", function()
      assert.equals("raw ${NAME}", interpolation.interpolate("'raw ${NAME}'", env_vars))
      assert.equals("new\nline", interpolation.interpolate("'new\\nline'", env_vars))
    end)

    it("should handle double quoted strings", function()
      assert.equals("Hello John", interpolation.interpolate('"${GREETING} ${NAME}"', env_vars))
      assert.equals("new\nline", interpolation.interpolate('"new\\nline"', env_vars))
    end)
  end)

  describe("escape sequences", function()
    it("should handle basic escape sequences", function()
      assert.equals("new\nline", interpolation.interpolate("new\\nline", env_vars))
      assert.equals("tab\there", interpolation.interpolate("tab\\there", env_vars))
      assert.equals("quote\"here", interpolation.interpolate("quote\\\"here", env_vars))
    end)
  end)

  describe("command substitution", function()
    it("should handle basic command substitution", function()
      assert.equals("test", interpolation.interpolate("$(echo test)", env_vars))
    end)

    it("should handle failed commands", function()
      local result = interpolation.interpolate("$(nonexistent_command)", env_vars, { fail_on_cmd_error = false })
      assert.equals("", result)
    end)

    it("should fail on command errors when configured", function()
      assert.has_error(function()
        interpolation.interpolate("$(nonexistent_command)", env_vars, { fail_on_cmd_error = true })
      end)
    end)
  end)

  describe("options", function()
    it("should respect max_iterations", function()
      local recursive_vars = {
        A = { value = "${B}" },
        B = { value = "${A}" },
      }
      local result = interpolation.interpolate("${A}", recursive_vars, { max_iterations = 2 })
      -- Should not hang and return some value after max iterations
      assert.is_string(result)
    end)

    it("should handle warn_on_undefined option", function()
      local notify_called = false
      local old_notify = vim.notify
      vim.notify = function() notify_called = true end

      interpolation.interpolate("${UNDEFINED}", env_vars, { warn_on_undefined = true })
      assert.is_true(notify_called)

      notify_called = false
      interpolation.interpolate("${UNDEFINED}", env_vars, { warn_on_undefined = false })
      assert.is_false(notify_called)

      vim.notify = old_notify
    end)
  end)

  describe("complex interpolation scenarios", function()
    it("should handle nested interpolations", function()
      local nested_vars = {
        APP_URL = { value = "https://${HOST}:${PORT}" },
        HOST = { value = "localhost" },
        PORT = { value = "3000" },
      }
      local result = interpolation.interpolate("${APP_URL}", nested_vars)
      assert.equals("https://localhost:3000", result)
    end)

    it("should handle multiple levels of nesting", function()
      local multi_nested_vars = {
        DATABASE_URL = { value = "${DB_TYPE}://${DB_USER}:${DB_PASS}@${DB_HOST}/${DB_NAME}" },
        DB_TYPE = { value = "postgres" },
        DB_USER = { value = "user" },
        DB_PASS = { value = "pass" },
        DB_HOST = { value = "${DB_HOSTNAME}:${DB_PORT}" },
        DB_HOSTNAME = { value = "localhost" },
        DB_PORT = { value = "5432" },
        DB_NAME = { value = "myapp" },
      }
      local result = interpolation.interpolate("${DATABASE_URL}", multi_nested_vars)
      assert.equals("postgres://user:pass@localhost:5432/myapp", result)
    end)

    it("should handle shell command interpolation with pipes", function()
      local result = interpolation.interpolate("$(echo 'hello' | tr 'a-z' 'A-Z')", env_vars)
      assert.equals("HELLO", result)
    end)

    it("should handle shell commands with environment variables", function()
      local shell_vars = {
        GREETING = { value = "hello" },
        NAME = { value = "world" },
      }
      local result = interpolation.interpolate("$(echo $GREETING $NAME)", shell_vars)
      assert.equals("hello world", result)
    end)

    it("should handle mixed interpolation types", function()
      local mixed_vars = {
        MESSAGE = { value = "Hello" },
        TRANSFORMED = { value = "$(echo ${MESSAGE} | tr 'a-z' 'A-Z')" },
      }
      local result = interpolation.interpolate("${TRANSFORMED}", mixed_vars)
      assert.equals("HELLO", result)
    end)
  end)

  describe("error handling", function()
    it("should handle circular references gracefully", function()
      local circular_vars = {
        A = { value = "${B}" },
        B = { value = "${C}" },
        C = { value = "${A}" },
      }
      local result = interpolation.interpolate("${A}", circular_vars)
      assert.is_string(result)  -- Should not hang and return some value
    end)

    it("should handle invalid shell commands gracefully", function()
      local result = interpolation.interpolate("$(invalid_command 2>/dev/null)", env_vars, { fail_on_cmd_error = false })
      assert.equals("", result)  -- Should return empty string for failed commands when fail_on_cmd_error is false
    end)

    it("should handle empty interpolation expressions", function()
      local result = interpolation.interpolate("${}", env_vars)
      assert.equals("${}", result)
    end)

    it("should handle malformed interpolation expressions", function()
      local result = interpolation.interpolate("${incomplete", env_vars)
      assert.equals("${incomplete", result)
    end)

    it("should handle unclosed command substitutions", function()
      local result = interpolation.interpolate("$(echo test", env_vars)
      assert.equals("$(echo test", result)
    end)
  end)

  describe("feature control", function()
    it("should respect disabled variable interpolation", function()
      local opts = { features = { variables = false } }
      assert.equals("${NAME}", interpolation.interpolate("${NAME}", env_vars, opts))
      assert.equals("$NAME", interpolation.interpolate("$NAME", env_vars, opts))
    end)

    it("should respect disabled command substitution", function()
      local opts = { features = { commands = false } }
      assert.equals("$(echo test)", interpolation.interpolate("$(echo test)", env_vars, opts))
    end)

    it("should respect disabled escape sequences", function()
      local opts = { features = { escapes = false } }
      assert.equals("\\n", interpolation.interpolate("\\n", env_vars, opts))
      assert.equals("\\t", interpolation.interpolate("\\t", env_vars, opts))
    end)

    it("should respect disabled default values", function()
      local opts = { features = { defaults = false, variables = true } }
      assert.equals("", interpolation.interpolate("${UNDEFINED:-default}", env_vars, opts))
    end)

    it("should respect disabled alternate values", function()
      local opts = { features = { alternates = false, variables = true } }
      assert.equals("John", interpolation.interpolate("${NAME:+alternate}", env_vars, opts))
    end)
  end)

  describe("advanced variable operations", function()
    it("should handle alternate value if set and non-empty", function()
      assert.equals("has-value", interpolation.interpolate("${NAME:+has-value}", env_vars))
      assert.equals("", interpolation.interpolate("${EMPTY:+has-value}", env_vars))
      assert.equals("", interpolation.interpolate("${UNDEFINED:+has-value}", env_vars))
    end)

    it("should handle alternate value if set", function()
      assert.equals("has-value", interpolation.interpolate("${NAME+has-value}", env_vars))
      assert.equals("has-value", interpolation.interpolate("${EMPTY+has-value}", env_vars))
      assert.equals("", interpolation.interpolate("${UNDEFINED+has-value}", env_vars))
    end)

    it("should handle mixed quotes and escapes", function()
      assert.equals('Hello "John"', interpolation.interpolate('${GREETING} \\"${NAME}\\"', env_vars))
      assert.equals("Hello 'John'", interpolation.interpolate("${GREETING} '${NAME}'", env_vars))
    end)
  end)

  describe("shell environment integration", function()
    before_each(function()
      vim.fn.setenv("TEST_VAR", "test_value")
      vim.fn.setenv("TEST_EMPTY", "")
    end)

    after_each(function()
      vim.env.TEST_VAR = nil
      vim.env.TEST_EMPTY = nil
    end)

    it("should read from shell environment when not in env_vars", function()
      assert.equals("test_value", interpolation.interpolate("${TEST_VAR}", env_vars))
    end)

    it("should prefer env_vars over shell environment", function()
      local local_vars = {
        TEST_VAR = { value = "local_value" }
      }
      assert.equals("local_value", interpolation.interpolate("${TEST_VAR}", local_vars))
    end)
  end)
end) 