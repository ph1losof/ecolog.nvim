describe("utils", function()
  local utils
  local api = vim.api
  local stub = require("luassert.stub")

  before_each(function()
    package.loaded["ecolog.utils"] = nil
    utils = require("ecolog.utils")

    -- Mock vim.api functions
    stub(api, "nvim_get_current_line")
    stub(api, "nvim_win_get_cursor")
  end)

  after_each(function()
    -- Restore stubs
    api.nvim_get_current_line:revert()
    api.nvim_win_get_cursor:revert()
  end)

  describe("find_word_boundaries", function()
    it("should find word boundaries correctly", function()
      local line = "const API_KEY = process.env.DATABASE_URL"
      local col = 29 -- Position at 'D' in DATABASE_URL
      local start, finish = utils.find_word_boundaries(line, col)
      assert.equals(29, start) -- Start of DATABASE_URL
      assert.equals(40, finish) -- End of DATABASE_URL
    end)

    it("should handle cursor at start of word", function()
      local line = "API_KEY=value"
      local col = 0
      local start, finish = utils.find_word_boundaries(line, col)
      assert.equals(1, start)
      assert.equals(7, finish)
    end)

    it("should handle cursor at end of word", function()
      local line = "API_KEY=value"
      local col = 7
      local start, finish = utils.find_word_boundaries(line, col)
      assert.equals(1, start)
      assert.equals(7, finish)
    end)

    it("should handle cursor at end of line", function()
      local line = "API_KEY"
      local col = 7 -- cursor after last character
      local start, finish = utils.find_word_boundaries(line, col)
      assert.equals(1, start)
      assert.equals(7, finish)
    end)

    it("should handle empty line", function()
      local line = ""
      local col = 0
      local start, finish = utils.find_word_boundaries(line, col)
      assert.is_nil(start)
      assert.is_nil(finish)
    end)

    it("should handle line with no word characters", function()
      local line = "    =   "
      local col = 3
      local start, finish = utils.find_word_boundaries(line, col)
      assert.is_nil(start)
      assert.is_nil(finish)
    end)
  end)

  describe("get_var_word_under_cursor", function()
    local mock_provider = {
      extract_var = function(line, col)
        if line:match("process%.env%.") then
          return line:match("process%.env%.([%w_]+)")
        end
        return nil
      end
    }

    it("should find word at cursor", function()
      local line = "TEST_VAR=value"
      stub(api, "nvim_get_current_line", function() return line end)
      stub(api, "nvim_win_get_cursor", function() return { 1, 4 } end)

      assert.equals("TEST_VAR", utils.get_var_word_under_cursor())
    end)

    it("should not find word at cursor start position", function()
      local line = "TEST_VAR=value"
      stub(api, "nvim_get_current_line", function() return line end)
      stub(api, "nvim_win_get_cursor", function() return { 1, 0 } end)

      assert.equals("", utils.get_var_word_under_cursor())
    end)

    it("should find word with provider match", function()
      local line = "process.env.TEST_VAR"
      stub(api, "nvim_get_current_line", function() return line end)
      stub(api, "nvim_win_get_cursor", function() return { 1, 15 } end)

      assert.equals("TEST_VAR", utils.get_var_word_under_cursor({ mock_provider }))
    end)

    it("should find word with underscore", function()
      local line = "TEST_VAR=value"
      stub(api, "nvim_get_current_line", function() return line end)
      stub(api, "nvim_win_get_cursor", function() return { 1, 5 } end)

      assert.equals("TEST_VAR", utils.get_var_word_under_cursor())
    end)

    it("should find word with multiple underscores", function()
      local line = "MY_TEST_VAR=value"
      stub(api, "nvim_get_current_line", function() return line end)
      stub(api, "nvim_win_get_cursor", function() return { 1, 5 } end)

      assert.equals("MY_TEST_VAR", utils.get_var_word_under_cursor())
    end)

    it("should return empty string for empty line", function()
      local line = ""
      stub(api, "nvim_get_current_line", function() return line end)
      stub(api, "nvim_win_get_cursor", function() return { 1, 0 } end)

      assert.equals("", utils.get_var_word_under_cursor())
    end)

    it("should return empty string for non-word", function()
      local line = "===="
      stub(api, "nvim_get_current_line", function() return line end)
      stub(api, "nvim_win_get_cursor", function() return { 1, 0 } end)

      assert.equals("", utils.get_var_word_under_cursor())
    end)

    it("should find word with provider match when hovering over variable", function()
      local line = "const url = process.env.DATABASE_URL;"
      stub(api, "nvim_get_current_line", function() return line end)
      stub(api, "nvim_win_get_cursor", function() return { 1, 33 } end)  -- cursor on DATABASE_URL

      assert.equals("DATABASE_URL", utils.get_var_word_under_cursor({ mock_provider }))
    end)

    it("should find word with provider match when cursor is at end of variable", function()
      local line = "const url = process.env.DATABASE_URL;"
      stub(api, "nvim_get_current_line", function() return line end)
      stub(api, "nvim_win_get_cursor", function() return { 1, 36 } end)  -- cursor right after DATABASE_URL

      assert.equals("DATABASE_URL", utils.get_var_word_under_cursor({ mock_provider }))
    end)
  end)

  describe("module loading", function()
    it("should cache required modules", function()
      local first = utils.require_on_demand("ecolog.types")
      local second = utils.require_on_demand("ecolog.types")
      assert.are.equal(first, second)
    end)

    it("should create lazy loaded module proxy", function()
      local module = utils.get_module("ecolog.types")
      assert.is_table(module)
      assert.is_function(getmetatable(module).__index)
    end)
  end)
end)

