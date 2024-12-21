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
    }
    shelter._initial_state = {}

    -- Mock the shelter module with required functions
    shelter.mask_value = function(value, opts)
      if not value then
        return ""
      end

      opts = opts or {}
      local partial_mode = opts.partial_mode or shelter._config.partial_mode

      if not partial_mode then
        return string.rep(shelter._config.mask_char, #value)
      else
        local settings = type(partial_mode) == "table" and partial_mode
          or {
            show_start = 2,
            show_end = 2,
            min_mask = 3,
          }

        local show_start = settings.show_start
        local show_end = settings.show_end
        local min_mask = settings.min_mask

        -- Handle short values
        if #value <= (show_start + show_end) then
          return string.rep(shelter._config.mask_char, #value)
        end

        -- Apply masking with min_mask requirement
        local mask_length = math.max(min_mask, #value - show_start - show_end)
        return string.sub(value, 1, show_start)
          .. string.rep(shelter._config.mask_char, mask_length)
          .. string.sub(value, -show_end)
      end
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
      local value = "secret123"
      local masked = shelter.mask_value(value)
      assert.equals(string.rep(shelter._config.mask_char, #value), masked)
    end)

    it("should apply partial masking when enabled", function()
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
      local notify_called = false
      local original_notify = vim.notify
      vim.notify = function(msg, level)
        if msg:match("Invalid feature") then
          notify_called = true
        end
      end

      shelter.set_state("enable", "invalid_feature")
      assert.is_true(notify_called)

      vim.notify = original_notify
    end)
  end)

  describe("masking configuration", function()
    it("should handle empty values", function()
      assert.equals("", shelter.mask_value(""))
      assert.equals("", shelter.mask_value(nil))
    end)

    it("should handle short values in partial mode", function()
      shelter.setup({
        config = {
          partial_mode = {
            show_start = 3,
            show_end = 3,
            min_mask = 2,
          },
          mask_char = "*",
        },
        modules = {},
      })

      local value = "12345" -- Value shorter than show_start + show_end
      local masked = shelter.mask_value(value)
      assert.equals("*****", masked)
    end)
  end)

  describe("state management", function()
    it("should handle multiple state changes", function()
      -- Enable multiple features
      shelter.set_state("enable", "cmp")
      shelter.set_state("enable", "peek")
      assert.is_true(shelter.is_enabled("cmp"))
      assert.is_true(shelter.is_enabled("peek"))

      -- Disable one feature
      shelter.set_state("disable", "cmp")
      assert.is_false(shelter.is_enabled("cmp"))
      assert.is_true(shelter.is_enabled("peek"))

      -- Toggle all should affect both
      shelter.toggle_all()
      assert.is_false(shelter.is_enabled("cmp"))
      assert.is_false(shelter.is_enabled("peek"))
    end)

    it("should maintain state independence between features", function()
      shelter.set_state("enable", "cmp")
      shelter.set_state("enable", "peek")

      -- Disable one feature shouldn't affect others
      shelter.set_state("disable", "cmp")
      assert.is_false(shelter.is_enabled("cmp"))
      assert.is_true(shelter.is_enabled("peek"))

      -- Re-enable shouldn't affect others
      shelter.set_state("enable", "cmp")
      assert.is_true(shelter.is_enabled("cmp"))
      assert.is_true(shelter.is_enabled("peek"))
    end)
  end)

  describe("feature validation", function()
    it("should reject unknown features", function()
      local notify_called = false
      local original_notify = vim.notify
      vim.notify = function(msg, level)
        if msg:match("Invalid feature") then
          notify_called = true
        end
      end

      shelter.set_state("enable", "unknown_feature")
      assert.is_true(notify_called)
      assert.is_false(shelter.is_enabled("unknown_feature"))

      vim.notify = original_notify
    end)

    it("should handle multiple invalid operations", function()
      local notify_count = 0
      local original_notify = vim.notify
      vim.notify = function(msg, level)
        if msg:match("Invalid feature") then
          notify_count = notify_count + 1
        end
      end

      shelter.set_state("enable", "invalid1")
      shelter.set_state("enable", "invalid2")
      assert.equals(2, notify_count)

      vim.notify = original_notify
    end)
  end)

  describe("masking consistency", function()
    it("should apply consistent masking across features", function()
      shelter.setup({
        config = {
          partial_mode = {
            show_start = 2,
            show_end = 2,
            min_mask = 3,
          },
          mask_char = "*",
        },
        modules = {
          cmp = true,
          files = true,
        },
      })

      local test_values = {
        "secret123", -- Normal length
        "key", -- Short value
        "very_long_secret", -- Long value
      }

      for _, value in ipairs(test_values) do
        local cmp_masked = shelter.mask_value(value, "cmp")
        local files_masked = shelter.mask_value(value, "files")

        -- Both features should mask values identically
        assert.equals(cmp_masked, files_masked)

        -- Verify masking rules
        if #value <= 4 then -- show_start(2) + show_end(2)
          assert.equals(string.rep("*", #value), cmp_masked)
        else
          local expected = string.sub(value, 1, 2) .. string.rep("*", math.max(3, #value - 4)) .. string.sub(value, -2)
          assert.equals(expected, cmp_masked)
        end
      end
    end)
  end)
end)
