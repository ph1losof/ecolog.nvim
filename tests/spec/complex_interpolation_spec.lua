local assert = require("luassert")

describe("complex interpolation scenarios", function()
  local interpolation
  local test_dir

  local function create_test_file(path, content)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local file = io.open(path, "w")
    if file then
      file:write(content)
      file:close()
    end
  end

  local function cleanup_test_files(path)
    vim.fn.delete(path, "rf")
  end

  before_each(function()
    package.loaded["ecolog.interpolation"] = nil
    interpolation = require("ecolog.interpolation")
    
    test_dir = vim.fn.tempname()
    vim.fn.mkdir(test_dir, "p")
  end)

  after_each(function()
    cleanup_test_files(test_dir)
  end)

  describe("deep nested interpolation", function()
    it("should handle multiple levels of nesting", function()
      local env_vars = {
        LEVEL1 = { value = "${LEVEL2}" },
        LEVEL2 = { value = "${LEVEL3}" },
        LEVEL3 = { value = "${LEVEL4}" },
        LEVEL4 = { value = "final_value" },
      }

      local result = interpolation.interpolate("${LEVEL1}", env_vars)
      assert.equals("final_value", result)
    end)

    it("should handle complex nested patterns", function()
      local env_vars = {
        PREFIX = { value = "app" },
        ENVIRONMENT = { value = "prod" },
        SERVICE_NAME = { value = "${PREFIX}_${ENVIRONMENT}_api" },
        BASE_URL = { value = "https://${SERVICE_NAME}.example.com" },
        API_ENDPOINT = { value = "${BASE_URL}/v1" },
        FULL_URL = { value = "${API_ENDPOINT}/users" },
      }

      local result = interpolation.interpolate("${FULL_URL}", env_vars)
      assert.equals("https://app_prod_api.example.com/v1/users", result)
    end)

    it("should handle recursive patterns with max_iterations", function()
      local env_vars = {
        A = { value = "${B}" },
        B = { value = "${C}" },
        C = { value = "${A}" }, -- Circular reference
      }

      local result = interpolation.interpolate("${A}", env_vars, { max_iterations = 5 })
      -- Should not hang and return some result after max iterations
      assert.is_string(result)
    end)

    it("should handle self-referencing variables", function()
      local env_vars = {
        RECURSIVE = { value = "start_${RECURSIVE}_end" },
      }

      local result = interpolation.interpolate("${RECURSIVE}", env_vars, { max_iterations = 3 })
      assert.is_string(result)
      -- Should not cause infinite recursion
    end)
  end)

  describe("complex default value scenarios", function()
    it("should handle nested default values", function()
      local env_vars = {
        HOST = { value = "localhost" },
        PORT = { value = "3000" },
      }

      local result = interpolation.interpolate("${URL:-https://${HOST:-example.com}:${PORT:-8080}/api}", env_vars)
      assert.equals("https://localhost:3000/api", result)
    end)

    it("should handle default values with commands", function()
      local env_vars = {}

      local result = interpolation.interpolate("${USER:-$(whoami)}", env_vars)
      assert.is_string(result)
      assert.is_true(#result > 0)
    end)

    it("should handle complex default patterns", function()
      local env_vars = {
        NODE_ENV = { value = "development" },
      }

      local complex_default = "${DATABASE_URL:-postgres://user:pass@${DB_HOST:-localhost}:${DB_PORT:-5432}/${DB_NAME:-myapp_${NODE_ENV}}}"
      local result = interpolation.interpolate(complex_default, env_vars)
      assert.equals("postgres://user:pass@localhost:5432/myapp_development", result)
    end)

    it("should handle alternate values correctly", function()
      local env_vars = {
        EMPTY_VAR = { value = "" },
        EXISTING_VAR = { value = "exists" },
      }

      -- Test - syntax (alternate)
      local result1 = interpolation.interpolate("${UNDEFINED_VAR-alternate}", env_vars)
      assert.equals("alternate", result1)

      local result2 = interpolation.interpolate("${EMPTY_VAR-alternate}", env_vars)
      assert.equals("", result2) -- Empty value exists, so no alternate

      local result3 = interpolation.interpolate("${EXISTING_VAR-alternate}", env_vars)
      assert.equals("exists", result3)
    end)
  end)

  describe("command substitution edge cases", function()
    it("should handle nested command substitution", function()
      local env_vars = {
        CMD = { value = "echo" },
        ARG = { value = "hello" },
      }

      local result = interpolation.interpolate("$(${CMD} ${ARG})", env_vars)
      assert.equals("hello", result:gsub("%s+$", "")) -- Remove trailing whitespace
    end)

    it("should handle command substitution with pipes", function()
      local result = interpolation.interpolate("$(echo 'hello world' | tr ' ' '_')", {}, { disable_security = true })
      assert.equals("hello_world", result:gsub("%s+$", ""))
    end)

    it("should handle command errors gracefully", function()
      local result = interpolation.interpolate("$(nonexistent_command_12345)", {}, { fail_on_cmd_error = false })
      assert.is_string(result)
      -- Should not crash, may return empty string or error message
    end)

    it("should handle commands with special characters", function()
      local result = interpolation.interpolate("$(echo 'special: !@#$%^&*()')", {}, { disable_security = true })
      assert.equals("special: !@#$%^&*()", result:gsub("%s+$", ""))
    end)

    it("should respect security settings for command substitution", function()
      local result = interpolation.interpolate("$(echo hello)", {}, { 
        disable_security = false,
        features = { commands = true }
      })
      assert.is_string(result)
    end)
  end)

  describe("mixed interpolation types", function()
    it("should handle variables and commands together", function()
      local env_vars = {
        PREFIX = { value = "app" },
        SUFFIX = { value = "prod" },
      }

      local result = interpolation.interpolate("${PREFIX}_$(echo middle)_${SUFFIX}", env_vars)
      assert.equals("app_middle_prod", result:gsub("%s+", ""))
    end)

    it("should handle defaults with command substitution", function()
      local env_vars = {}

      local result = interpolation.interpolate("${UNDEFINED:-$(echo default_value)}", env_vars)
      assert.equals("default_value", result:gsub("%s+$", ""))
    end)

    it("should handle complex mixed patterns", function()
      local env_vars = {
        ENV = { value = "test" },
        VERSION = { value = "1.0" },
      }

      local complex_pattern = "${APP_NAME:-myapp}_v${VERSION}_${ENV}_$(date +%Y%m%d)"
      local result = interpolation.interpolate(complex_pattern, env_vars)
      
      assert.is_true(result:match("^myapp_v1%.0_test_%d+$") ~= nil)
    end)

    it("should handle escape sequences in mixed context", function()
      local env_vars = {
        MESSAGE = { value = "hello\\nworld" },
      }

      local result = interpolation.interpolate("${MESSAGE}\\t$(echo test)", env_vars)
      assert.equals("hello\nworld\ttest", result:gsub("%s+$", ""))
    end)
  end)

  describe("interpolation with special patterns", function()
    it("should handle dollar signs in values", function()
      local env_vars = {
        PRICE = { value = "$19.99" },
        CURRENCY = { value = "$$" },
      }

      local result1 = interpolation.interpolate("Price: ${PRICE}", env_vars)
      assert.equals("Price: $19.99", result1)

      local result2 = interpolation.interpolate("Currency: ${CURRENCY}", env_vars)
      assert.equals("Currency: $$", result2)
    end)

    it("should handle variables with numbers and underscores", function()
      local env_vars = {
        VAR_1 = { value = "first" },
        VAR_2_3 = { value = "second" },
        VAR123 = { value = "third" },
        ["VAR_WITH_123_NUMBERS"] = { value = "fourth" },
      }

      local result = interpolation.interpolate("${VAR_1}_${VAR_2_3}_${VAR123}_${VAR_WITH_123_NUMBERS}", env_vars)
      assert.equals("first_second_third_fourth", result)
    end)

    it("should handle Unicode in variable names and values", function()
      local env_vars = {
        ["CAFÉ_URL"] = { value = "https://café.example.com" },
        MESSAGE_中文 = { value = "Hello 世界" },
      }

      local result1 = interpolation.interpolate("URL: ${CAFÉ_URL}", env_vars)
      assert.equals("URL: https://café.example.com", result1)

      local result2 = interpolation.interpolate("${MESSAGE_中文}!", env_vars)
      assert.equals("Hello 世界!", result2)
    end)

    it("should handle very long interpolation chains", function()
      local env_vars = {}
      local chain = "start"
      
      -- Create a long chain of variables
      for i = 1, 50 do
        env_vars["VAR_" .. i] = { value = "${VAR_" .. (i + 1) .. "}" }
        chain = chain .. "_${VAR_" .. i .. "}"
      end
      env_vars.VAR_51 = { value = "end" }

      local result = interpolation.interpolate(chain, env_vars, { max_iterations = 100 })
      assert.is_string(result)
      assert.is_true(result:find("end") ~= nil)
    end)
  end)

  describe("performance with complex interpolation", function()
    it("should handle many variables efficiently", function()
      local env_vars = {}
      for i = 1, 100 do
        env_vars["VAR_" .. i] = { value = "value_" .. i }
      end

      local pattern = ""
      for i = 1, 100 do
        pattern = pattern .. "${VAR_" .. i .. "}_"
      end

      local start_time = vim.loop.hrtime()
      local result = interpolation.interpolate(pattern, env_vars)
      local elapsed = (vim.loop.hrtime() - start_time) / 1e6

      assert.is_string(result)
      assert.is_true(result:find("value_1") ~= nil)
      assert.is_true(result:find("value_100") ~= nil)
      
      -- Should complete in reasonable time
      assert.is_true(elapsed < 100, "Complex interpolation should complete in under 100ms, took " .. elapsed .. "ms")
    end)

    it("should handle deeply nested structures efficiently", function()
      local env_vars = {}
      
      -- Create a deep nesting structure
      for i = 1, 20 do
        env_vars["NESTED_" .. i] = { value = "${NESTED_" .. (i + 1) .. "}" }
      end
      env_vars.NESTED_21 = { value = "deep_value" }

      local start_time = vim.loop.hrtime()
      local result = interpolation.interpolate("${NESTED_1}", env_vars, { max_iterations = 50 })
      local elapsed = (vim.loop.hrtime() - start_time) / 1e6

      assert.equals("deep_value", result)
      assert.is_true(elapsed < 50, "Deep nesting should complete in under 50ms, took " .. elapsed .. "ms")
    end)
  end)

  describe("error handling and edge cases", function()
    it("should handle malformed interpolation patterns", function()
      local env_vars = {
        VAR = { value = "test" },
      }

      -- Test various malformed patterns
      local patterns = {
        "${UNCLOSED",
        "${}",
        "${",
        "}VAR{$",
        "${VAR",
        "$VAR}",
        "$(unclosed command",
        "$(",
        "$()",
      }

      for _, pattern in ipairs(patterns) do
        local result = interpolation.interpolate(pattern, env_vars)
        assert.is_string(result) -- Should not crash
      end
    end)

    it("should handle empty interpolation context", function()
      local result = interpolation.interpolate("${UNDEFINED}", {})
      assert.equals("", result)
    end)

    it("should handle circular references gracefully", function()
      local env_vars = {
        A = { value = "${B}" },
        B = { value = "${C}" },
        C = { value = "${A}" },
      }

      local result = interpolation.interpolate("${A}", env_vars, { max_iterations = 10 })
      assert.is_string(result)
      -- Should not cause infinite loop
    end)

    it("should handle interpolation options correctly", function()
      local env_vars = {
        VAR = { value = "test" },
      }

      -- Test with disabled features
      local result1 = interpolation.interpolate("${VAR}", env_vars, { 
        features = { variables = false } 
      })
      assert.equals("${VAR}", result1)

      local result2 = interpolation.interpolate("$(echo test)", env_vars, { 
        features = { commands = false } 
      })
      assert.equals("$(echo test)", result2)
    end)
  end)
end)