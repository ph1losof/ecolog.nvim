local mock = require("luassert.mock")

describe("snacks previewer integration", function()
  local snacks_integration
  local state
  local previewer_utils

  before_each(function()
    package.loaded["ecolog.shelter.integrations.snacks"] = nil
    package.loaded["ecolog.shelter.state"] = nil
    package.loaded["ecolog.shelter.previewer_utils"] = nil
    package.loaded["snacks.picker.preview"] = nil

    snacks_integration = require("ecolog.shelter.integrations.snacks")
    state = require("ecolog.shelter.state")
    previewer_utils = require("ecolog.shelter.previewer_utils")
  end)

  describe("setup_snacks_shelter", function()
    local snacks_preview
    local original_preview_file

    before_each(function()
      original_preview_file = function() end
      snacks_preview = {
        file = original_preview_file,
      }
      package.loaded["snacks.picker.preview"] = snacks_preview

      local state_mock = mock(state, true)
      state_mock.is_enabled.returns(true)
      state_mock._original_snacks_preview = nil
    end)

    after_each(function()
      mock.revert(state)
    end)

    it("should not modify snacks when disabled", function()
      mock.revert(state)
      local state_mock = mock(state, true)
      state_mock.is_enabled.returns(false)

      snacks_integration.setup_snacks_shelter()

      assert.equals(original_preview_file, snacks_preview.file)
    end)

    it("should store original preview and set new one when enabled", function()
      snacks_integration.setup_snacks_shelter()

      assert.equals(original_preview_file, state._original_snacks_preview)

      assert.not_equals(original_preview_file, snacks_preview.file)
    end)
  end)

  describe("custom_file_previewer", function()
    local snacks_preview
    local original_preview_file
    local ctx = {
      buf = 1,
      item = {
        file = ".env",
      },
    }

    before_each(function()
      original_preview_file = function() end
      snacks_preview = {
        file = original_preview_file,
      }
      package.loaded["snacks.picker.preview"] = snacks_preview

      local fn_mock = mock(vim.fn, true)
      fn_mock.fnamemodify = function()
        return ".env"
      end

      mock(previewer_utils, true)

      local state_mock = mock(state, true)
      state_mock.is_enabled.returns(true)
      state_mock._original_snacks_preview = original_preview_file
    end)

    after_each(function()
      mock.revert(vim.fn)
      mock.revert(previewer_utils)
      mock.revert(state)
    end)

    it("should mask env file in preview", function()
      snacks_integration.setup_snacks_shelter()

      snacks_preview.file(ctx)

      assert.stub(previewer_utils.mask_preview_buffer).was_called_with(ctx.buf, ".env", "snacks")
    end)

    it("should handle missing file in item", function()
      ctx.item.file = nil

      snacks_integration.setup_snacks_shelter()

      snacks_preview.file(ctx)

      assert.stub(previewer_utils.mask_preview_buffer).was_not_called()
    end)

    it("should call original preview function", function()
      local original_called = false
      local original_fn = function()
        original_called = true
      end
      mock.revert(state)
      local state_mock = mock(state, true)
      state_mock.is_enabled.returns(true)
      state_mock._original_snacks_preview = original_fn

      snacks_integration.setup_snacks_shelter()

      snacks_preview.file(ctx)

      assert.is_true(original_called)
    end)
  end)
end)
