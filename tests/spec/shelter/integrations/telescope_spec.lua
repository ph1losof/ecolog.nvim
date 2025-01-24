local mock = require("luassert.mock")

describe("telescope previewer integration", function()
  local telescope_integration
  local state
  local previewer_utils

  before_each(function()
    package.loaded["ecolog.shelter.integrations.telescope"] = nil
    package.loaded["ecolog.shelter.state"] = nil
    package.loaded["ecolog.shelter.previewer_utils"] = nil
    package.loaded["telescope.config"] = nil

    telescope_integration = require("ecolog.shelter.integrations.telescope")
    state = require("ecolog.shelter.state")
    previewer_utils = require("ecolog.shelter.previewer_utils")
  end)

  describe("setup_telescope_shelter", function()
    local telescope_config
    local original_file_previewer = function() end
    local original_grep_previewer = function() end

    before_each(function()
      telescope_config = {
        values = {
          file_previewer = original_file_previewer,
          grep_previewer = original_grep_previewer,
        },
      }
      package.loaded["telescope.config"] = telescope_config

      local state_mock = mock(state, true)
      state_mock._original_file_previewer = nil
      state_mock._original_grep_previewer = nil
      state_mock.is_enabled.returns(true)
    end)

    after_each(function()
      mock.revert(state)
    end)

    it("should store original previewers and set new ones when enabled", function()
      telescope_integration.setup_telescope_shelter()

      assert.equals(original_file_previewer, state._original_file_previewer)
      assert.equals(original_grep_previewer, state._original_grep_previewer)

      assert.not_equals(original_file_previewer, telescope_config.values.file_previewer)
      assert.not_equals(original_grep_previewer, telescope_config.values.grep_previewer)
    end)

    it("should restore original previewers when disabled", function()
      telescope_integration.setup_telescope_shelter()

      mock.revert(state)
      local state_mock = mock(state, true)
      state_mock.is_enabled.returns(false)
      state_mock._original_file_previewer = original_file_previewer
      state_mock._original_grep_previewer = original_grep_previewer

      telescope_integration.setup_telescope_shelter()

      assert.equals(original_file_previewer, telescope_config.values.file_previewer)
      assert.equals(original_grep_previewer, telescope_config.values.grep_previewer)
    end)
  end)

  describe("masked previewer", function()
    local telescope_from_entry
    local telescope_previewers
    local buffer_previewer_maker
    local telescope_config

    before_each(function()
      telescope_from_entry = {
        path = function(entry)
          return entry.path
        end,
      }
      telescope_previewers = {
        new_buffer_previewer = function(opts)
          local previewer = {
            state = {
              bufnr = opts.state and opts.state.bufnr or 1,
              bufname = opts.state and opts.state.bufname or ".env",
              winid = opts.state and opts.state.winid or 0,
            },
            define_preview = opts.define_preview,
          }
          return previewer
        end,
      }
      buffer_previewer_maker = function(path, bufnr, opts)
        if opts.callback then
          opts.callback(bufnr)
        end
      end

      telescope_config = {
        values = {
          buffer_previewer_maker = buffer_previewer_maker,
        },
      }

      package.loaded["telescope.from_entry"] = telescope_from_entry
      package.loaded["telescope.previewers"] = telescope_previewers
      package.loaded["telescope.config"] = telescope_config

      local state_mock = mock(state, true)
      state_mock.is_enabled.returns(true)

      mock(previewer_utils, true)
    end)

    after_each(function()
      mock.revert(previewer_utils)
      mock.revert(state)
    end)

    it("should create a masked file previewer", function()
      telescope_integration.setup_telescope_shelter()
      local previewer = telescope_integration.create_masked_previewer({}, "file")
      local entry = { path = ".env" }

      previewer.define_preview(previewer, entry)

      assert.stub(previewer_utils.mask_preview_buffer).was_called_with(1, ".env", "telescope")
    end)

    it("should create a masked grep previewer", function()
      telescope_integration.setup_telescope_shelter()
      local previewer = telescope_integration.create_masked_previewer({}, "grep")
      local entry = { filename = ".env", lnum = 1, col = 0 }

      previewer.define_preview(previewer, entry)

      assert.stub(previewer_utils.mask_preview_buffer).was_called_with(1, ".env", "telescope")

      mock.revert(vim.api)
      mock.revert(vim.cmd)
    end)
  end)
end)
