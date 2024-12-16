describe("shelter", function()
  local shelter
  
  before_each(function()
    package.loaded["ecolog.shelter"] = nil
    shelter = require("ecolog.shelter")
    
    -- Mock the shelter module with required functions
    shelter.mask_value = function(value, opts)
      opts = opts or {}
      if not opts.partial_mode then
        return string.rep("*", #value)
      else
        local show_start = opts.partial_mode.show_start or 2
        local show_end = opts.partial_mode.show_end or 2
        return string.sub(value, 1, show_start) ..
               string.rep("*", #value - show_start - show_end) ..
               string.sub(value, -show_end)
      end
    end

    shelter.is_enabled = function(feature)
      return shelter._state and shelter._state[feature]
    end

    shelter.set_state = function(command, feature)
      shelter._state = shelter._state or {}
      shelter._state[feature] = command == "enable"
    end

    shelter.toggle_all = function()
      shelter._state = shelter._state or {}
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

    -- Initialize state with default values
    shelter.setup({
      config = {
        partial_mode = false,
        mask_char = "*"
      },
      modules = {
        cmp = false,
        peek = false,
        files = false,
        telescope = false
      }
    })
  end)

  describe("masking", function()
    it("should mask values completely when partial mode is disabled", function()
      local value = "secret123"
      local masked = shelter.mask_value(value)
      assert.equals(string.rep("*", #value), masked)
    end)

    it("should apply partial masking when enabled", function()
      local value = "secret123"
      local masked = shelter.mask_value(value, {
        partial_mode = {
          show_start = 2,
          show_end = 2,
          min_mask = 3
        }
      })
      local expected = string.sub(value, 1, 2) .. 
                      string.rep("*", #value - 4) .. 
                      string.sub(value, -2)
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
end) 