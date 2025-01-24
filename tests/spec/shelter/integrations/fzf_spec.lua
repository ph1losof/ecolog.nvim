local mock = require("luassert.mock")

describe("fzf previewer integration", function()
  local fzf_integration
  local state
  local shelter_utils
  local utils

  before_each(function()
    package.loaded["ecolog.shelter.integrations.fzf"] = nil
    package.loaded["ecolog.shelter.state"] = nil
    package.loaded["ecolog.shelter.utils"] = nil
    package.loaded["ecolog.utils"] = nil
    package.loaded["fzf-lua"] = nil
    package.loaded["fzf-lua.previewer.builtin"] = nil
    package.loaded["ecolog"] = nil

    fzf_integration = require("ecolog.shelter.integrations.fzf")
    state = require("ecolog.shelter.state")
    shelter_utils = require("ecolog.shelter.utils")
    utils = require("ecolog.utils")
  end)

  describe("setup_fzf_shelter", function()
    local fzf_lua
    local original_preview_buf_post

    before_each(function()
      original_preview_buf_post = function() end
      fzf_lua = {
        previewer = {
          builtin = {
            buffer_or_file = {
              preview_buf_post = original_preview_buf_post,
            },
          },
        },
      }
      package.loaded["fzf-lua"] = fzf_lua
      package.loaded["fzf-lua.previewer.builtin"] = fzf_lua.previewer.builtin

      local state_mock = mock(state, true)
      state_mock.is_enabled.returns(true)
      state_mock.get_config.returns({ highlight_group = "Comment" })
    end)

    after_each(function()
      mock.revert(state)
    end)

    it("should not modify fzf when disabled", function()
      mock.revert(state)
      local state_mock = mock(state, true)
      state_mock.is_enabled.returns(false)

      fzf_integration.setup_fzf_shelter()

      assert.equals(original_preview_buf_post, fzf_lua.previewer.builtin.buffer_or_file.preview_buf_post)
    end)

    it("should modify preview_buf_post when enabled", function()
      fzf_integration.setup_fzf_shelter()

      assert.not_equals(original_preview_buf_post, fzf_lua.previewer.builtin.buffer_or_file.preview_buf_post)
    end)
  end)

  describe("modified preview functionality", function()
    local fzf_lua
    local bufnr = 1
    local entry = { path = ".env" }
    local min_winopts = {}

    before_each(function()
      fzf_lua = {
        previewer = {
          builtin = {
            buffer_or_file = {
              preview_buf_post = function() end,
              preview_bufnr = bufnr,
            },
          },
        },
      }
      package.loaded["fzf-lua"] = fzf_lua
      package.loaded["fzf-lua.previewer.builtin"] = fzf_lua.previewer.builtin

      package.loaded["ecolog"] = {
        get_config = function()
          return { env_pattern = "%.env$" }
        end,
      }

      vim.schedule = function(fn)
        fn()
      end

      vim.api = vim.api or {}
      local api_mock = mock(vim.api, true)
      api_mock.nvim_buf_is_valid.returns(true)
      api_mock.nvim_buf_get_lines.returns({ "KEY=value" })
      api_mock.nvim_buf_set_extmark.returns(true)
      api_mock.nvim_create_namespace.returns(1)

      vim.fn = vim.fn or {}
      vim.fn.sha256 = function()
        return "hash"
      end

      vim.loop = vim.loop or {}
      vim.loop.now = function()
        return 1234567890
      end

      local utils_mock = mock(utils, true)
      utils_mock.parse_env_line.returns("KEY", "value", 3)

      local state_mock = mock(state, true)
      state_mock.is_enabled.returns(true)
      state_mock.get_config.returns({ highlight_group = "Comment", partial_mode = false })

      local shelter_utils_mock = mock(shelter_utils, true)
      shelter_utils_mock.match_env_file.returns(true)
      shelter_utils_mock.determine_masked_value.returns("****")
    end)

    after_each(function()
      mock.revert(vim.api)
      mock.revert(vim.fn)
      mock.revert(state)
      mock.revert(shelter_utils)
      mock.revert(utils)
    end)

    it("should mask env file in preview", function()
      fzf_integration.setup_fzf_shelter()

      local self = fzf_lua.previewer.builtin.buffer_or_file
      self.preview_buf_post(self, entry, min_winopts)

      assert.stub(vim.api.nvim_buf_get_lines).was_called()
      assert.stub(shelter_utils.determine_masked_value).was_called()
      assert.stub(vim.api.nvim_buf_set_extmark).was_called()
    end)

    it("should not mask non-env files", function()
      mock.revert(shelter_utils)
      local shelter_utils_mock = mock(shelter_utils, true)
      shelter_utils_mock.match_env_file.returns(false)

      fzf_integration.setup_fzf_shelter()

      entry.path = "regular.txt"
      local self = fzf_lua.previewer.builtin.buffer_or_file
      self.preview_buf_post(self, entry, min_winopts)

      assert.stub(vim.api.nvim_buf_get_lines).was_not_called()
    end)

    it("should handle invalid buffers", function()
      mock.revert(vim.api)
      local api_mock = mock(vim.api, true)
      api_mock.nvim_buf_is_valid.returns(false)

      fzf_integration.setup_fzf_shelter()

      local self = fzf_lua.previewer.builtin.buffer_or_file
      self.preview_buf_post(self, entry, min_winopts)

      assert.stub(vim.api.nvim_buf_get_lines).was_not_called()
    end)

    it("should not mask preview when disabled", function()
      mock.revert(state)
      local state_mock = mock(state, true)
      state_mock.is_enabled.returns(false)

      fzf_integration.setup_fzf_shelter()

      local self = fzf_lua.previewer.builtin.buffer_or_file
      self.preview_buf_post(self, entry, min_winopts)

      assert.stub(vim.api.nvim_buf_get_lines).was_not_called()
    end)
  end)
end)

