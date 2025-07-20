local utils = require("ecolog.utils")
local env_loader = require("ecolog.env_loader")
local shelter_utils = require("ecolog.shelter.utils")

describe("Multi-line environment variable support", function()
  describe("utils.extract_line_parts with multi-line state", function()
    it("should parse single-line values correctly", function()
      local line = "KEY=value"
      local key, value, comment, quote_char, state = utils.extract_line_parts(line)
      
      assert.are.equal("KEY", key)
      assert.are.equal("value", value)
      assert.is_nil(comment)
      assert.is_nil(quote_char)
      assert.is_false(state.in_multi_line or false)
    end)

    it("should parse quoted single-line values correctly", function()
      local line = 'KEY="quoted value"'
      local key, value, comment, quote_char, state = utils.extract_line_parts(line)
      
      assert.are.equal("KEY", key)
      assert.are.equal("quoted value", value)
      assert.is_nil(comment)
      assert.are.equal('"', quote_char)
      assert.is_false(state.in_multi_line or false)
    end)

    it("should detect start of quoted multi-line value", function()
      local line = 'KEY="start of multi-line'
      local key, value, comment, quote_char, state = utils.extract_line_parts(line)
      
      assert.is_nil(key)
      assert.is_nil(value)
      assert.is_nil(comment)
      assert.is_nil(quote_char)
      assert.is_true(state.in_multi_line)
      assert.are.equal("KEY", state.key)
      assert.are.equal("quoted", state.continuation_type)
      assert.are.equal('"', state.quote_char)
    end)

    it("should handle quoted multi-line continuation", function()
      local state = {
        in_multi_line = true,
        key = "KEY",
        value_lines = {"start of multi-line"},
        quote_char = '"',
        continuation_type = "quoted"
      }
      
      local line = 'middle line'
      local key, value, comment, quote_char, updated_state = utils.extract_line_parts(line, state)
      
      assert.is_nil(key)
      assert.is_nil(value)
      assert.is_nil(comment)
      assert.is_nil(quote_char)
      assert.is_true(updated_state.in_multi_line)
      assert.are.equal(2, #updated_state.value_lines)
      assert.are.equal("middle line", updated_state.value_lines[2])
    end)

    it("should complete quoted multi-line value", function()
      local state = {
        in_multi_line = true,
        key = "KEY",
        value_lines = {"start of multi-line", "middle line"},
        quote_char = '"',
        continuation_type = "quoted"
      }
      
      local line = 'end of multi-line"'
      local key, value, comment, quote_char, updated_state = utils.extract_line_parts(line, state)
      
      assert.are.equal("KEY", key)
      assert.are.equal("start of multi-line\nmiddle line\nend of multi-line", value)
      assert.is_nil(comment)
      assert.are.equal('"', quote_char)
      assert.is_false(updated_state.in_multi_line)
    end)


    it("should handle backslash continuation", function()
      local line = 'KEY=start of value\\'
      local key, value, comment, quote_char, state = utils.extract_line_parts(line)
      
      assert.is_nil(key)
      assert.is_nil(value)
      assert.is_nil(comment)
      assert.is_nil(quote_char)
      assert.is_true(state.in_multi_line)
      assert.are.equal("KEY", state.key)
      assert.are.equal("backslash", state.continuation_type)
      assert.are.equal("start of value", state.value_lines[1])
    end)

    it("should complete backslash continuation", function()
      local state = {
        in_multi_line = true,
        key = "KEY",
        value_lines = {"start of value", "continued value"},
        continuation_type = "backslash"
      }
      
      local line = 'final part'
      local key, value, comment, quote_char, updated_state = utils.extract_line_parts(line, state)
      
      assert.are.equal("KEY", key)
      assert.are.equal("start of valuecontinued valuefinal part", value)
      assert.is_nil(comment)
      assert.is_nil(quote_char)
      assert.is_false(updated_state.in_multi_line)
    end)
  end)

  describe("shelter multi-line masking", function()
    it("should mask multi-line values correctly", function()
      local value = "line1\nline2\nline3"
      local settings = {
        key = "TEST_KEY",
        source = "test.env"
      }
      
      local masked = shelter_utils.determine_masked_value(value, settings)
      
      -- Should contain newlines to preserve structure
      assert.is_true(masked:find("\n") ~= nil)
      
      -- Should have masked content
      assert.is_true(masked:find("*") ~= nil)
    end)

    it("should handle partial masking for multi-line values", function()
      -- Mock shelter config to enable partial mode
      local shelter_state = require("ecolog.shelter.state")
      local original_get_config = shelter_state.get_config
      shelter_state.get_config = function()
        return {
          partial_mode = {
            show_start = 3,
            show_end = 3,
            min_mask = 3,
          },
          mask_char = "*",
          default_mode = "partial",
          patterns = {},
          sources = {}
        }
      end
      
      -- Test partial masking directly
      local value = "start123\nmiddle456\nend789"
      local settings = {
        key = "TEST_KEY",
        source = "test.env",
        show_start = 3,
        show_end = 3,
        default_mode = "partial",
        patterns = {},
        sources = {}
      }
      
      local masked = shelter_utils.mask_multi_line_value(value, settings, {
        partial_mode = {
          show_start = 3,
          show_end = 3,
          min_mask = 3,
        },
        mask_char = "*"
      }, "partial")
      
      local lines = vim.split(masked, "\n", { plain = true })
      
      -- First line should show start (first 3 chars of "start123")
      assert.are.equal("sta", lines[1]:sub(1, 3))
      
      -- Last line should show end (last 3 chars of "end789")
      assert.are.equal("789", lines[#lines]:sub(-3))
      
      -- Restore original config
      shelter_state.get_config = original_get_config
    end)
  end)
end)