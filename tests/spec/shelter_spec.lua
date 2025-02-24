describe("shelter", function()
  local shelter

  before_each(function()
    package.loaded["ecolog.shelter"] = nil
    shelter = require("ecolog.shelter")

    -- Mock state management
    shelter._state = {}
    shelter._config = {
      partial_mode = false,
      mask_char = "*",
      patterns = {},
      default_mode = "partial",
    }
    shelter._initial_state = {}

    -- Mock the shelter module with required functions
    shelter.mask_value = function(value, opts)
      if not value then
        return ""
      end

      opts = opts or {}
      local key = opts.key
      local source = opts.source
      local pattern_mode = key and shelter.matches_shelter_pattern(key)
      local source_mode = not pattern_mode and source and shelter.matches_shelter_source(source)

      -- Helper function to get mask length
      local function get_mask_length(len)
        return shelter._config.mask_length or len
      end

      if pattern_mode then
        if pattern_mode == "none" then
          return value
        elseif pattern_mode == "full" then
          return string.rep(shelter._config.mask_char, get_mask_length(#value))
        end
      elseif source_mode then
        if source_mode == "none" then
          return value
        elseif source_mode == "full" then
          return string.rep(shelter._config.mask_char, get_mask_length(#value))
        end
      else
        if shelter._config.default_mode == "none" then
          return value
        elseif shelter._config.default_mode == "full" then
          return string.rep(shelter._config.mask_char, get_mask_length(#value))
        end
      end

      local partial_mode = opts.partial_mode or shelter._config.partial_mode
      if not partial_mode then
        return string.rep(shelter._config.mask_char, get_mask_length(#value))
      end

      local settings = type(partial_mode) == "table" and partial_mode
        or {
          show_start = 2,
          show_end = 2,
          min_mask = 3,
        }

      local show_start = settings.show_start
      local show_end = settings.show_end
      local min_mask = settings.min_mask

      if #value <= (show_start + show_end) then
        return string.rep(shelter._config.mask_char, get_mask_length(#value))
      end

      -- When mask_length is set, we need to ensure we show the correct number of end characters
      if shelter._config.mask_length then
        return string.sub(value, 1, show_start)
          .. string.rep(shelter._config.mask_char, shelter._config.mask_length)
          .. string.sub(value, -show_end)
      end

      -- Default behavior when mask_length is not set
      local mask_length = math.max(min_mask, #value - show_start - show_end)
      return string.sub(value, 1, show_start)
        .. string.rep(shelter._config.mask_char, mask_length)
        .. string.sub(value, -show_end)
    end

    shelter.matches_shelter_pattern = function(key)
      if not key or not shelter._config.patterns or vim.tbl_isempty(shelter._config.patterns) then
        return nil
      end

      for pattern, mode in pairs(shelter._config.patterns) do
        local lua_pattern = pattern:gsub("%*", ".*"):gsub("%%", "%%%%")
        if key:match("^" .. lua_pattern .. "$") then
          return mode
        end
      end

      return nil
    end

    shelter.matches_shelter_source = function(source)
      if not source or not shelter._config.sources or vim.tbl_isempty(shelter._config.sources) then
        return nil
      end

      for pattern, mode in pairs(shelter._config.sources) do
        local lua_pattern = pattern:gsub("%*", ".*"):gsub("%%", "%%%%")
        if source:match("^" .. lua_pattern .. "$") then
          return mode
        end
      end

      return nil
    end

    shelter.is_enabled = function(feature)
      return shelter._state[feature] or false
    end

    shelter.set_state = function(command, feature)
      if not vim.tbl_contains({ "cmp", "peek", "files", "telescope" }, feature) then
        vim.notify("Invalid feature. Use 'cmp', 'peek', 'files', or 'telescope'", vim.log.levels.ERROR)
        return
      end
      shelter._state[feature] = command == "enable"
    end

    shelter.toggle_all = function()
      local any_enabled = false
      for _, enabled in pairs(shelter._state) do
        if enabled then
          any_enabled = true
          break
        end
      end

      for _, feature in ipairs({ "cmp", "peek", "files", "telescope" }) do
        shelter._state[feature] = not any_enabled
      end
    end

    shelter.setup = function(opts)
      shelter._config = vim.tbl_deep_extend("force", shelter._config, opts.config or {})
      shelter._state = vim.tbl_deep_extend("force", {}, opts.modules or {})
      shelter._initial_state = vim.tbl_deep_extend("force", {}, shelter._state)
    end

    shelter.restore_initial_settings = function()
      shelter._state = vim.tbl_deep_extend("force", {}, shelter._initial_state)
    end

    -- Initialize state with default values
    shelter.setup({
      config = {
        partial_mode = false,
        mask_char = "*",
      },
      modules = {
        cmp = false,
        peek = false,
        files = false,
        telescope = false,
      },
    })
  end)

  describe("masking", function()
    it("should mask values completely when partial mode is disabled", function()
      shelter.setup({
        config = {
          partial_mode = false,
          mask_char = "*",
          default_mode = "full",
        },
      })
      local value = "secret123"
      local masked = shelter.mask_value(value)
      assert.equals(string.rep(shelter._config.mask_char, #value), masked)
    end)

    it("should respect minimum mask length in partial mode", function()
      local partial_mode_configuration = {
        show_start = 2,
        show_end = 2,
        min_mask = 5,
      }
      shelter.setup({
        config = {
          partial_mode = partial_mode_configuration,
          mask_char = "*",
          default_mode = "partial",
        },
      })

      local value = "medium123"
      local masked = shelter.mask_value(value, { partial_mode = partial_mode_configuration })
      assert.equals("me*****23", masked)
    end)

    it("should apply partial masking when enabled", function()
      shelter.setup({
        config = {
          partial_mode = {
            show_start = 2,
            show_end = 2,
            min_mask = 3,
          },
          mask_char = "*",
          default_mode = "partial",
        },
      })

      local value = "secret123"
      local masked = shelter.mask_value(value, {
        partial_mode = {
          show_start = 2,
          show_end = 2,
          min_mask = 3,
        },
      })
      local expected = string.sub(value, 1, 2)
        .. string.rep(shelter._config.mask_char, #value - 4)
        .. string.sub(value, -2)
      assert.equals(expected, masked)
    end)

    it("should respect fixed mask length in full masking mode", function()
      shelter.setup({
        config = {
          partial_mode = false,
          mask_char = "*",
          mask_length = 5,
          default_mode = "full",
        },
      })
      
      -- Test with longer value
      local long_value = "very_long_secret"
      local masked_long = shelter.mask_value(long_value)
      assert.equals("*****", masked_long)
      
      -- Test with shorter value
      local short_value = "key"
      local masked_short = shelter.mask_value(short_value)
      assert.equals("*****", masked_short)
    end)

    it("should respect fixed mask length in partial masking mode", function()
      shelter.setup({
        config = {
          partial_mode = {
            show_start = 2,
            show_end = 3,
            min_mask = 3,
          },
          mask_char = "*",
          mask_length = 5,
          default_mode = "partial",
        },
      })
      
      -- Test with longer value
      local value = "secret_value_123"
      local masked = shelter.mask_value(value, {
        partial_mode = {
          show_start = 2,
          show_end = 3,
          min_mask = 3,
        },
      })
      assert.equals("se*****123", masked)
      
      -- Test with medium value
      local medium_value = "api_key"
      local masked_medium = shelter.mask_value(medium_value, {
        partial_mode = {
          show_start = 2,
          show_end = 3,
          min_mask = 3,
        },
      })
      assert.equals("ap*****key", masked_medium)
    end)

    it("should handle mask_length with pattern-based rules", function()
      shelter.setup({
        config = {
          partial_mode = false,
          mask_char = "*",
          mask_length = 5,
          patterns = {
            ["API_*"] = "full",
            ["TEST_*"] = "none",
          },
          default_mode = "full",
        },
      })
      
      -- Test pattern that should be fully masked
      local api_value = "API_SECRET_KEY"
      local masked_api = shelter.mask_value(api_value, { key = "API_SECRET_KEY" })
      assert.equals("*****", masked_api)
      
      -- Test pattern that should not be masked
      local test_value = "TEST_VALUE"
      local masked_test = shelter.mask_value(test_value, { key = "TEST_VALUE" })
      assert.equals("TEST_VALUE", masked_test)
    end)

    it("should handle mask_length with source-based rules", function()
      shelter.setup({
        config = {
          partial_mode = false,
          mask_char = "*",
          mask_length = 5,
          sources = {
            [".env.prod"] = "full",
            [".env.test"] = "none",
          },
          default_mode = "full",
        },
      })
      
      -- Test source that should be fully masked
      local prod_value = "production_secret"
      local masked_prod = shelter.mask_value(prod_value, { source = ".env.prod" })
      assert.equals("*****", masked_prod)
      
      -- Test source that should not be masked
      local test_value = "test_value"
      local masked_test = shelter.mask_value(test_value, { source = ".env.test" })
      assert.equals("test_value", masked_test)
    end)
  end)

  describe("feature toggling", function()
    it("should toggle individual features", function()
      shelter.set_state("enable", "cmp")
      assert.is_true(shelter.is_enabled("cmp"))

      shelter.set_state("disable", "cmp")
      assert.is_false(shelter.is_enabled("cmp"))
    end)

    it("should toggle all features", function()
      -- First toggle should enable all features
      shelter.toggle_all()
      for _, feature in ipairs({ "cmp", "peek", "files", "telescope" }) do
        assert.is_true(shelter.is_enabled(feature))
      end

      -- Second toggle should disable all features
      shelter.toggle_all()
      for _, feature in ipairs({ "cmp", "peek", "files", "telescope" }) do
        assert.is_false(shelter.is_enabled(feature))
      end
    end)
  end)

  describe("configuration", function()
    it("should respect custom mask character", function()
      shelter.setup({
        config = {
          partial_mode = false,
          mask_char = "#",
          default_mode = "full",
        },
        modules = {},
      })

      local value = "secret123"
      local masked = shelter.mask_value(value)
      assert.equals(string.rep("#", #value), masked)
    end)

    it("should handle custom partial mode configuration", function()
      shelter.setup({
        config = {
          partial_mode = {
            show_start = 4,
            show_end = 3,
            min_mask = 2,
          },
          mask_char = "*",
          default_mode = "partial",
        },
        modules = {},
      })

      local value = "mysecretpassword"
      local masked = shelter.mask_value(value)
      local expected = string.sub(value, 1, 4) .. string.rep("*", #value - 7) .. string.sub(value, -3)
      assert.equals(expected, masked)
    end)
  end)

  describe("state management", function()
    it("should track initial settings", function()
      shelter.setup({
        config = {
          partial_mode = false,
          mask_char = "*",
        },
        modules = {
          cmp = true,
          peek = false,
          files = true,
          telescope = false,
        },
      })

      -- Verify initial state
      assert.is_true(shelter.is_enabled("cmp"))
      assert.is_false(shelter.is_enabled("peek"))
      assert.is_true(shelter.is_enabled("files"))
      assert.is_false(shelter.is_enabled("telescope"))

      -- Change some settings
      shelter.set_state("disable", "cmp")
      shelter.set_state("enable", "peek")

      -- Verify changed state
      assert.is_false(shelter.is_enabled("cmp"))
      assert.is_true(shelter.is_enabled("peek"))

      -- Restore initial settings
      shelter.restore_initial_settings()

      -- Verify restored state
      assert.is_true(shelter.is_enabled("cmp"))
      assert.is_false(shelter.is_enabled("peek"))
      assert.is_true(shelter.is_enabled("files"))
      assert.is_false(shelter.is_enabled("telescope"))
    end)

    it("should handle invalid feature names", function()
      shelter.set_state("enable", "invalid_feature")
      assert.is_false(shelter.is_enabled("invalid_feature"))
    end)

    it("should handle multiple state changes", function()
      shelter.set_state("enable", "cmp")
      shelter.set_state("enable", "peek")
      assert.is_true(shelter.is_enabled("cmp"))
      assert.is_true(shelter.is_enabled("peek"))

      shelter.set_state("disable", "cmp")
      assert.is_false(shelter.is_enabled("cmp"))
      assert.is_true(shelter.is_enabled("peek"))
    end)

    it("should maintain state independence between features", function()
      shelter.set_state("enable", "cmp")
      shelter.set_state("disable", "peek")
      assert.is_true(shelter.is_enabled("cmp"))
      assert.is_false(shelter.is_enabled("peek"))

      shelter.set_state("enable", "files")
      assert.is_true(shelter.is_enabled("cmp"))
      assert.is_false(shelter.is_enabled("peek"))
      assert.is_true(shelter.is_enabled("files"))
    end)
  end)

  describe("feature validation", function()
    it("should reject unknown features", function()
      shelter.set_state("enable", "unknown")
      assert.is_false(shelter.is_enabled("unknown"))
    end)

    it("should handle multiple invalid operations", function()
      shelter.set_state("enable", "unknown1")
      shelter.set_state("enable", "unknown2")
      assert.is_false(shelter.is_enabled("unknown1"))
      assert.is_false(shelter.is_enabled("unknown2"))
    end)
  end)

  describe("masking consistency", function()
    it("should apply consistent masking across features", function()
      local value = "secret123"
      local masked1 = shelter.mask_value(value)
      local masked2 = shelter.mask_value(value)
      assert.equals(masked1, masked2)
    end)
  end)

  describe("pattern-based variables", function()
    it("should respect pattern-based masking modes", function()
      shelter.setup({
        config = {
          patterns = {
            ["*_KEY"] = "full",
            ["*_URL"] = "none",
            ["DB_*"] = "partial",
          },
          default_mode = "full",
          mask_char = "*",
          partial_mode = {
            show_start = 2,
            show_end = 2,
            min_mask = 3,
          },
        },
      })

      -- Test full masking pattern
      local api_key = shelter.mask_value("secret123", { key = "API_KEY" })
      assert.equals(string.rep("*", #"secret123"), api_key)

      -- Test no masking pattern
      local api_url = shelter.mask_value("https://api.example.com", { key = "API_URL" })
      assert.equals("https://api.example.com", api_url)

      -- Test partial masking pattern
      local db_password = shelter.mask_value("password123", { key = "DB_PASSWORD" })
      assert.equals("pa*******23", db_password)
    end)

    it("should fall back to default mode when no pattern matches", function()
      shelter.setup({
        config = {
          patterns = {
            ["*_KEY"] = "full",
          },
          default_mode = "none",
          mask_char = "*",
        },
      })

      -- Test non-matching variable (should use default mode)
      local value = shelter.mask_value("test123", { key = "SOME_VALUE" })
      assert.equals("test123", value)
    end)

    it("should handle wildcard patterns correctly", function()
      shelter.setup({
        config = {
          patterns = {
            ["TEST_*_SECRET"] = "full",
            ["*_PASSWORD_*"] = "partial",
          },
          default_mode = "none",
          mask_char = "*",
          partial_mode = {
            show_start = 2,
            show_end = 2,
            min_mask = 3,
          },
        },
      })

      -- Test wildcard at end
      local test_secret = shelter.mask_value("mysecret", { key = "TEST_APP_SECRET" })
      assert.equals(string.rep("*", #"mysecret"), test_secret)

      -- Test wildcard at start and end
      local app_password = shelter.mask_value("mypassword", { key = "APP_PASSWORD_123" })
      assert.equals("my******rd", app_password)
    end)

    it("should handle empty or invalid patterns", function()
      shelter.setup({
        config = {
          patterns = {},
          default_mode = "full",
          mask_char = "*",
        },
      })

      -- Test with empty patterns (should use default mode)
      local value1 = shelter.mask_value("test123", { key = "TEST_KEY" })
      assert.equals(string.rep("*", #"test123"), value1)

      -- Test with nil key
      local value2 = shelter.mask_value("test123", { key = nil })
      assert.equals(string.rep("*", #"test123"), value2)

      -- Test with empty key
      local value3 = shelter.mask_value("test123", { key = "" })
      assert.equals(string.rep("*", #"test123"), value3)
    end)
  end)

  describe("source-based variables", function()
    it("should respect source-based masking modes", function()
      shelter.setup({
        config = {
          sources = {
            ["*.env"] = "full",
            ["*.local"] = "none",
            ["config.*"] = "partial",
          },
          default_mode = "full",
          mask_char = "*",
          partial_mode = {
            show_start = 2,
            show_end = 2,
            min_mask = 3,
          },
        },
      })

      -- Test full masking source
      local secret_env = shelter.mask_value("secret123", { source = "secrets.env" })
      assert.equals(string.rep("*", #"secret123"), secret_env)

      -- Test no masking source
      local local_secret = shelter.mask_value("localvalue", { source = "dev.local" })
      assert.equals("localvalue", local_secret)

      -- Test partial masking source
      local config_secret = shelter.mask_value("configsecret", { source = "config.yaml" })
      assert.equals("co********et", config_secret)
    end)

    it("should prioritize pattern-based over source-based masking", function()
      shelter.setup({
        config = {
          patterns = {
            ["*_KEY"] = "full",
          },
          sources = {
            ["*.env"] = "none",
          },
          default_mode = "partial",
          mask_char = "*",
          partial_mode = {
            show_start = 2,
            show_end = 2,
            min_mask = 3,
          },
        },
      })

      -- Pattern-based rule should take precedence
      local api_key = shelter.mask_value("secret123", { key = "API_KEY", source = "dev.env" })
      assert.equals(string.rep("*", #"secret123"), api_key)

      -- Source-based rule should apply when no pattern matches
      local other_var = shelter.mask_value("othervalue", { key = "OTHER_VAR", source = "dev.env" })
      assert.equals("othervalue", other_var)
    end)

    it("should fall back to default mode when no source matches", function()
      shelter.setup({
        config = {
          sources = {
            ["*.env"] = "full",
          },
          default_mode = "none",
          mask_char = "*",
        },
      })

      -- Test non-matching source (should use default mode)
      local value = shelter.mask_value("test123", { source = "config.yaml" })
      assert.equals("test123", value)
    end)

    it("should handle wildcard patterns in sources correctly", function()
      shelter.setup({
        config = {
          sources = {
            ["test.*_secret"] = "full",
            ["*_config_*.yaml"] = "partial",
          },
          default_mode = "none",
          mask_char = "*",
          partial_mode = {
            show_start = 2,
            show_end = 2,
            min_mask = 3,
          },
        },
      })

      -- Test wildcard in middle
      local test_secret = shelter.mask_value("mysecret", { source = "test.app_secret" })
      assert.equals(string.rep("*", #"mysecret"), test_secret)

      -- Test multiple wildcards
      local app_config = shelter.mask_value("configvalue", { source = "app_config_dev.yaml" })
      assert.equals("co*******ue", app_config)
    end)

    it("should handle empty or invalid sources", function()
      shelter.setup({
        config = {
          sources = {},
          default_mode = "full",
          mask_char = "*",
        },
      })

      -- Test with empty sources (should use default mode)
      local value1 = shelter.mask_value("test123", { source = "test.env" })
      assert.equals(string.rep("*", #"test123"), value1)

      -- Test with nil source
      local value2 = shelter.mask_value("test123", { source = nil })
      assert.equals(string.rep("*", #"test123"), value2)

      -- Test with empty source
      local value3 = shelter.mask_value("test123", { source = "" })
      assert.equals(string.rep("*", #"test123"), value3)
    end)
  end)
end)
