-- Picker integration tests
-- Tests telescope, fzf-lua, and snacks picker integrations
---@diagnostic disable: undefined-global

describe("picker module", function()
  local pickers

  before_each(function()
    package.loaded["ecolog.pickers"] = nil
    pickers = require("ecolog.pickers")
  end)

  describe("get_default_picker", function()
    it("should return a picker name", function()
      local picker = pickers.get_default()
      assert.is_string(picker)
    end)
  end)

  describe("is_available", function()
    it("should check if telescope is available", function()
      local available = pickers.is_available("telescope")
      assert.equals(_G.ECOLOG_TEST_TELESCOPE, available)
    end)

    it("should check if fzf is available", function()
      local available = pickers.is_available("fzf")
      assert.equals(_G.ECOLOG_TEST_FZF, available)
    end)

    it("should check if snacks is available", function()
      local available = pickers.is_available("snacks")
      assert.equals(_G.ECOLOG_TEST_SNACKS, available)
    end)

    it("should return false for unknown picker", function()
      local available = pickers.is_available("nonexistent_picker")
      assert.is_false(available)
    end)
  end)
end)

-- Telescope-specific tests (only run if telescope is available)
if _G.ECOLOG_TEST_TELESCOPE then
  describe("telescope picker", function()
    local telescope_picker

    before_each(function()
      package.loaded["ecolog.pickers.telescope"] = nil
      telescope_picker = require("ecolog.pickers.telescope")
      _G.setup_mock_lsp(_G.DEFAULT_MOCK_RESULTS)
    end)

    after_each(function()
      _G.teardown_mock_lsp()
    end)

    describe("variables picker", function()
      it("should create variables picker without error", function()
        assert.has_no.errors(function()
          -- Just verify the function exists
          assert.is_function(telescope_picker.variables)
        end)
      end)
    end)

    describe("files picker", function()
      it("should create files picker without error", function()
        assert.has_no.errors(function()
          assert.is_function(telescope_picker.files)
        end)
      end)
    end)
  end)
end

-- FZF-specific tests (only run if fzf-lua is available)
if _G.ECOLOG_TEST_FZF then
  describe("fzf picker", function()
    local fzf_picker

    before_each(function()
      package.loaded["ecolog.pickers.fzf"] = nil
      fzf_picker = require("ecolog.pickers.fzf")
      _G.setup_mock_lsp(_G.DEFAULT_MOCK_RESULTS)
    end)

    after_each(function()
      _G.teardown_mock_lsp()
    end)

    describe("variables picker", function()
      it("should create variables picker without error", function()
        assert.has_no.errors(function()
          assert.is_function(fzf_picker.variables)
        end)
      end)
    end)

    describe("files picker", function()
      it("should create files picker without error", function()
        assert.has_no.errors(function()
          assert.is_function(fzf_picker.files)
        end)
      end)
    end)
  end)
end

-- Snacks-specific tests (only run if snacks is available)
if _G.ECOLOG_TEST_SNACKS then
  describe("snacks picker", function()
    local snacks_picker

    before_each(function()
      package.loaded["ecolog.pickers.snacks"] = nil
      snacks_picker = require("ecolog.pickers.snacks")
      _G.setup_mock_lsp(_G.DEFAULT_MOCK_RESULTS)
    end)

    after_each(function()
      _G.teardown_mock_lsp()
    end)

    describe("variables picker", function()
      it("should create variables picker without error", function()
        assert.has_no.errors(function()
          assert.is_function(snacks_picker.variables)
        end)
      end)
    end)

    describe("files picker", function()
      it("should create files picker without error", function()
        assert.has_no.errors(function()
          assert.is_function(snacks_picker.files)
        end)
      end)
    end)
  end)
end
