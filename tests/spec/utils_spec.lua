describe("utils", function()
  local utils

  before_each(function()
    package.loaded["ecolog.utils"] = nil
    utils = require("ecolog.utils")
  end)

  describe("find_word_boundaries", function()
    it("should find word boundaries correctly", function()
      local line = "const API_KEY = process.env.DATABASE_URL"
      local col = 29  -- Position at 'D' in DATABASE_URL
      local start, finish = utils.find_word_boundaries(line, col)
      assert.equals(29, start)  -- Start of DATABASE_URL
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