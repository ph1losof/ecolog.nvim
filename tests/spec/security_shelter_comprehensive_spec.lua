local assert = require("luassert")

describe("security features and shelter mode", function()
  local shelter
  local test_dir

  local function cleanup_test_files(path)
    vim.fn.delete(path, "rf")
  end

  before_each(function()
    package.loaded["ecolog.shelter"] = nil
    shelter = require("ecolog.shelter")
    
    test_dir = vim.fn.tempname()
    vim.fn.mkdir(test_dir, "p")

    -- Reset shelter state for each test
    shelter.setup({
      config = {
        partial_mode = false,
        mask_char = "*",
        default_mode = "full",
      },
      modules = {
        cmp = false,
        peek = false,
        files = false,
        telescope = false,
      },
    })
  end)

  after_each(function()
    cleanup_test_files(test_dir)
    -- Reset shelter state
    shelter.restore_initial_settings()
  end)

  describe("pattern-based masking rules", function()
    it("should apply different masking modes based on patterns", function()
      shelter.setup({
        config = {
          patterns = {
            ["*_KEY"] = "full",
            ["*_TOKEN"] = "full", 
            ["*_PASSWORD"] = "full",
            ["*_URL"] = "partial",
            ["DEBUG*"] = "none",
          },
          partial_mode = {
            show_start = 3,
            show_end = 3,
            min_mask = 4,
          },
          mask_char = "*",
        },
      })

      -- Test full masking for sensitive patterns
      local api_key_masked = shelter.mask_value("secret123456", "API_KEY")
      assert.equals("************", api_key_masked)

      local token_masked = shelter.mask_value("token789", "ACCESS_TOKEN")
      assert.equals("********", token_masked)

      -- Test partial masking for URLs
      local url_masked = shelter.mask_value("https://api.example.com/v1/users", "DATABASE_URL")
      assert.equals("htt****ers", url_masked)

      -- Test no masking for debug vars
      local debug_masked = shelter.mask_value("verbose", "DEBUG_MODE")
      assert.equals("verbose", debug_masked)
    end)

    it("should handle wildcard patterns correctly", function()
      shelter.setup({
        config = {
          patterns = {
            ["AWS_*"] = "full",
            ["*_SECRET_*"] = "full",
            ["DEV_*_URL"] = "partial",
          },
          mask_char = "#",
        },
      })

      local aws_masked = shelter.mask_value("AKIAIOSFODNN7EXAMPLE", "AWS_ACCESS_KEY_ID")
      assert.equals("####################", aws_masked)

      local secret_masked = shelter.mask_value("supersecret", "APP_SECRET_KEY")
      assert.equals("###########", secret_masked)

      local dev_url_masked = shelter.mask_value("http://localhost:3000", "DEV_API_URL")
      assert.is_true(dev_url_masked:find("#") ~= nil)
    end)

    it("should handle overlapping patterns with priority", function()
      shelter.setup({
        config = {
          patterns = {
            ["*"] = "partial", -- Default for all
            ["*_KEY"] = "full", -- More specific
            ["API_*"] = "none", -- Most specific for API vars
          },
        },
      })

      -- Most specific should win
      local api_key = shelter.mask_value("secret", "API_KEY")
      assert.equals("secret", api_key) -- API_* pattern wins over *_KEY

      -- Fall back to less specific
      local other_key = shelter.mask_value("secret", "OTHER_KEY")
      assert.is_true(other_key:find("*") ~= nil) -- *_KEY pattern applies
    end)

    it("should handle case sensitivity in patterns", function()
      shelter.setup({
        config = {
          patterns = {
            ["*_key"] = "full", -- lowercase
            ["*_KEY"] = "partial", -- uppercase
          },
        },
      })

      local lower_masked = shelter.mask_value("secret", "api_key")
      assert.is_true(lower_masked:find("*") ~= nil)

      local upper_masked = shelter.mask_value("secret", "API_KEY")
      assert.is_true(upper_masked:find("*") ~= nil)
    end)
  end)

  describe("different masking configurations", function()
    it("should handle various partial mode configurations", function()
      local test_cases = {
        {
          config = { show_start = 2, show_end = 2, min_mask = 3 },
          input = "secret123",
          expected_pattern = "se***23"
        },
        {
          config = { show_start = 4, show_end = 1, min_mask = 2 },
          input = "verylongsecret",
          expected_pattern = "very*********t"
        },
        {
          config = { show_start = 0, show_end = 3, min_mask = 5 },
          input = "password",
          expected_pattern = "*****ord"
        },
        {
          config = { show_start = 3, show_end = 0, min_mask = 4 },
          input = "token123",
          expected_pattern = "tok*****"
        },
      }

      for _, case in ipairs(test_cases) do
        shelter.setup({
          config = {
            partial_mode = case.config,
            mask_char = "*",
            default_mode = "partial",
          },
        })

        local masked = shelter.mask_value(case.input)
        assert.equals(case.expected_pattern, masked)
      end
    end)

    it("should handle minimum mask length correctly", function()
      shelter.setup({
        config = {
          partial_mode = {
            show_start = 2,
            show_end = 2,
            min_mask = 8, -- Force at least 8 masked characters
          },
          mask_char = "#",
          default_mode = "partial",
        },
      })

      local short_value = shelter.mask_value("abc") -- Too short for partial
      assert.equals("###########", short_value) -- Should be fully masked

      local medium_value = shelter.mask_value("medium123") -- Just right
      assert.equals("me########23", medium_value)
    end)

    it("should handle different mask characters", function()
      local mask_chars = { "*", "#", "•", "X", "█" }

      for _, char in ipairs(mask_chars) do
        shelter.setup({
          config = {
            mask_char = char,
            default_mode = "full",
          },
        })

        local masked = shelter.mask_value("secret")
        assert.equals(string.rep(char, 6), masked)
      end
    end)

    it("should handle mask length configurations", function()
      shelter.setup({
        config = {
          mask_length = 10, -- Fixed mask length
          mask_char = "*",
          default_mode = "full",
        },
      })

      local short_masked = shelter.mask_value("abc")
      assert.equals("**********", short_masked)

      local long_masked = shelter.mask_value("verylongpassword123")
      assert.equals("**********", long_masked)
    end)
  end)

  describe("context-specific masking", function()
    it("should apply different masking in different contexts", function()
      shelter.setup({
        config = {
          default_mode = "partial",
        },
        modules = {
          cmp = true,
          peek = false,
          files = true,
          telescope = true,
        },
      })

      local value = "secret123"

      -- Should be masked in completion context
      assert.is_true(shelter.is_enabled("cmp"))
      
      -- Should not be masked in peek context
      assert.is_false(shelter.is_enabled("peek"))

      -- Should be masked in file context
      assert.is_true(shelter.is_enabled("files"))
    end)

    it("should handle module-specific configurations", function()
      shelter.setup({
        modules = {
          cmp = true,
          peek = false,
          files = {
            enabled = true,
            mode = "full",
          },
          telescope = {
            enabled = true,
            mode = "partial",
          },
        },
      })

      assert.is_true(shelter.is_enabled("cmp"))
      assert.is_false(shelter.is_enabled("peek"))
      assert.is_true(shelter.is_enabled("files"))
      assert.is_true(shelter.is_enabled("telescope"))
    end)

    it("should handle source-based masking rules", function()
      shelter.setup({
        config = {
          sources = {
            [".env"] = "partial",
            [".env.local"] = "full",
            ["shell"] = "none",
          },
          default_mode = "partial",
        },
      })

      local env_masked = shelter.mask_value("secret", "VAR", ".env")
      assert.is_true(env_masked:find("*") ~= nil) -- Should be partially masked

      local local_masked = shelter.mask_value("secret", "VAR", ".env.local")
      assert.equals("******", local_masked) -- Should be fully masked

      local shell_masked = shelter.mask_value("secret", "VAR", "shell")
      assert.equals("secret", shell_masked) -- Should not be masked
    end)
  end)

  describe("toggle functionality", function()
    it("should toggle individual features correctly", function()
      shelter.setup({
        modules = {
          cmp = false,
          peek = true,
          files = false,
        },
      })

      -- Initial state
      assert.is_false(shelter.is_enabled("cmp"))
      assert.is_true(shelter.is_enabled("peek"))
      assert.is_false(shelter.is_enabled("files"))

      -- Toggle individual features
      shelter.set_state("enable", "cmp")
      assert.is_true(shelter.is_enabled("cmp"))

      shelter.set_state("disable", "peek")
      assert.is_false(shelter.is_enabled("peek"))

      shelter.set_state("toggle", "files")
      assert.is_true(shelter.is_enabled("files"))

      shelter.set_state("toggle", "files")
      assert.is_false(shelter.is_enabled("files"))
    end)

    it("should handle toggle all functionality", function()
      shelter.setup({
        modules = {
          cmp = true,
          peek = false,
          files = true,
          telescope = false,
        },
      })

      -- Toggle all off
      shelter.set_state("disable")
      assert.is_false(shelter.is_enabled("cmp"))
      assert.is_false(shelter.is_enabled("peek"))
      assert.is_false(shelter.is_enabled("files"))
      assert.is_false(shelter.is_enabled("telescope"))

      -- Toggle all on
      shelter.set_state("enable")
      assert.is_true(shelter.is_enabled("cmp"))
      assert.is_true(shelter.is_enabled("peek"))
      assert.is_true(shelter.is_enabled("files"))
      assert.is_true(shelter.is_enabled("telescope"))
    end)

    it("should restore initial settings correctly", function()
      local initial_config = {
        modules = {
          cmp = true,
          peek = false,
          files = true,
        },
      }

      shelter.setup(initial_config)

      -- Verify initial state
      assert.is_true(shelter.is_enabled("cmp"))
      assert.is_false(shelter.is_enabled("peek"))
      assert.is_true(shelter.is_enabled("files"))

      -- Modify state
      shelter.set_state("disable", "cmp")
      shelter.set_state("enable", "peek")
      shelter.set_state("disable", "files")

      -- Verify modified state
      assert.is_false(shelter.is_enabled("cmp"))
      assert.is_true(shelter.is_enabled("peek"))
      assert.is_false(shelter.is_enabled("files"))

      -- Restore initial settings
      shelter.restore_initial_settings()

      -- Verify restored state
      assert.is_true(shelter.is_enabled("cmp"))
      assert.is_false(shelter.is_enabled("peek"))
      assert.is_true(shelter.is_enabled("files"))
    end)
  end)

  describe("line peek functionality", function()
    it("should handle line reveal correctly", function()
      local line_num = 5
      local bufname = "test.env"

      -- Initially not revealed
      assert.is_false(shelter.is_line_revealed(line_num))

      -- Reveal line
      shelter.set_revealed_line(line_num, true)
      assert.is_true(shelter.is_line_revealed(line_num))

      -- Hide line again
      shelter.set_revealed_line(line_num, false)
      assert.is_false(shelter.is_line_revealed(line_num))
    end)

    it("should handle multiple revealed lines", function()
      local lines = { 1, 5, 10, 15 }

      -- Reveal multiple lines
      for _, line in ipairs(lines) do
        shelter.set_revealed_line(line, true)
      end

      -- Verify all are revealed
      for _, line in ipairs(lines) do
        assert.is_true(shelter.is_line_revealed(line))
      end

      -- Hide some lines
      shelter.set_revealed_line(5, false)
      shelter.set_revealed_line(15, false)

      -- Verify state
      assert.is_true(shelter.is_line_revealed(1))
      assert.is_false(shelter.is_line_revealed(5))
      assert.is_true(shelter.is_line_revealed(10))
      assert.is_false(shelter.is_line_revealed(15))
    end)
  end)

  describe("integration with different modules", function()
    it("should mask values in completion context", function()
      shelter.setup({
        config = {
          default_mode = "partial",
          partial_mode = {
            show_start = 2,
            show_end = 2,
            min_mask = 3,
          },
        },
        modules = {
          cmp = true,
        },
      })

      local value = "secret123"
      local masked = shelter.mask_value_for_context(value, "cmp")
      assert.equals("se****23", masked)
    end)

    it("should respect disabled modules", function()
      shelter.setup({
        modules = {
          cmp = false,
          peek = false,
        },
      })

      local value = "secret123"
      
      local cmp_result = shelter.mask_value_for_context(value, "cmp")
      assert.equals("secret123", cmp_result) -- Should not mask when disabled

      local peek_result = shelter.mask_value_for_context(value, "peek")
      assert.equals("secret123", peek_result) -- Should not mask when disabled
    end)
  end)

  describe("error handling and edge cases", function()
    it("should handle invalid configuration gracefully", function()
      local success = pcall(function()
        shelter.setup({
          config = {
            invalid_option = "test",
            mask_char = 123, -- Invalid type
          },
        })
      end)
      assert.is_true(success) -- Should not crash on invalid config
    end)

    it("should handle empty and nil values", function()
      local empty_masked = shelter.mask_value("")
      assert.equals("", empty_masked)

      local nil_masked = shelter.mask_value(nil)
      assert.is_string(nil_masked)
    end)

    it("should handle very long values", function()
      local long_value = string.rep("a", 10000)
      local masked = shelter.mask_value(long_value)
      assert.is_string(masked)
      assert.is_true(#masked > 0)
    end)

    it("should handle unicode in values", function()
      local unicode_value = "🔐 secret 世界"
      local masked = shelter.mask_value(unicode_value)
      assert.is_string(masked)
      assert.is_true(#masked > 0)
    end)

    it("should handle invalid feature names", function()
      shelter.set_state("enable", "invalid_feature")
      assert.is_false(shelter.is_enabled("invalid_feature"))

      shelter.set_state("disable", "another_invalid")
      -- Should not crash
    end)
  end)

  describe("performance with security features", function()
    it("should mask many values efficiently", function()
      local values = {}
      for i = 1, 1000 do
        values[i] = "secret_value_" .. i .. "_with_some_length"
      end

      local start_time = vim.loop.hrtime()
      
      for _, value in ipairs(values) do
        shelter.mask_value(value)
      end
      
      local elapsed = (vim.loop.hrtime() - start_time) / 1e6

      assert.is_true(elapsed < 100, "Masking 1000 values should complete in under 100ms, took " .. elapsed .. "ms")
    end)

    it("should handle pattern matching efficiently", function()
      shelter.setup({
        config = {
          patterns = {},
        },
      })

      -- Add many patterns
      local patterns = {}
      for i = 1, 100 do
        patterns["PATTERN_" .. i .. "_*"] = "full"
      end
      
      shelter.setup({
        config = {
          patterns = patterns,
        },
      })

      local start_time = vim.loop.hrtime()
      
      for i = 1, 100 do
        shelter.mask_value("test_value", "PATTERN_50_TEST")
      end
      
      local elapsed = (vim.loop.hrtime() - start_time) / 1e6

      assert.is_true(elapsed < 50, "Pattern matching should be efficient, took " .. elapsed .. "ms")
    end)
  end)
end)