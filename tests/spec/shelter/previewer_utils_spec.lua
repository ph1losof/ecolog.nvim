local api = vim.api
local mock = require("luassert.mock")

describe("previewer_utils", function()
  local previewer_utils
  local state
  local shelter_utils

  before_each(function()
    package.loaded["ecolog.shelter.previewer_utils"] = nil
    package.loaded["ecolog.shelter.state"] = nil
    package.loaded["ecolog.shelter.utils"] = nil

    previewer_utils = require("ecolog.shelter.previewer_utils")
    state = require("ecolog.shelter.state")
    shelter_utils = require("ecolog.shelter.utils")
  end)

  describe("mask_preview_buffer", function()
    local bufnr
    local filename = ".env"

    before_each(function()
      bufnr = api.nvim_create_buf(false, true)
      api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        "SECRET_KEY=abc123",
        "API_TOKEN=xyz789",
        "DEBUG=true",
      })
    end)

    after_each(function()
      pcall(api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("should mask env values in preview buffer when enabled", function()
      local state_mock = mock(state, true)
      state_mock.is_enabled.returns(true)
      state_mock.get_config.returns({ highlight_group = "Comment", partial_mode = false })

      local utils_mock = mock(shelter_utils, true)
      utils_mock.match_env_file.returns(true)
      utils_mock.determine_masked_value.returns("*****")

      local ns = 1
      local api_mock = mock(vim.api, true)
      api_mock.nvim_create_namespace.returns(ns)
      api_mock.nvim_buf_get_extmarks.returns({ { 1, 0, 1 }, { 2, 0, 1 }, { 3, 0, 1 } })

      previewer_utils.mask_preview_buffer(bufnr, filename, "telescope")

      local marks = api_mock.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })

      assert.equals(3, #marks)

      mock.revert(state)
      mock.revert(shelter_utils)
      mock.revert(vim.api)
    end)

    it("should not mask values when previewer is disabled", function()
      local state_mock = mock(state, true)
      state_mock.is_enabled.returns(false)

      previewer_utils.mask_preview_buffer(bufnr, filename, "telescope")

      local ns = api.nvim_create_namespace("ecolog_shelter")
      local marks = api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })

      assert.equals(0, #marks)

      mock.revert(state)
    end)

    it("should not mask non-env files", function()
      local state_mock = mock(state, true)
      state_mock.is_enabled.returns(true)

      local utils_mock = mock(shelter_utils, true)
      utils_mock.match_env_file.returns(false)

      previewer_utils.mask_preview_buffer(bufnr, "regular.txt", "telescope")

      local ns = api.nvim_create_namespace("ecolog_shelter")
      local marks = api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })

      assert.equals(0, #marks)

      mock.revert(state)
      mock.revert(shelter_utils)
    end)
  end)

  describe("process_buffer", function()
    local bufnr

    before_each(function()
      bufnr = api.nvim_create_buf(false, true)
      api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        "SECRET_KEY=abc123",
        "API_TOKEN=xyz789",
        "DEBUG=true",
      })
    end)

    after_each(function()
      pcall(api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("should process buffer in chunks", function()
      local utils_mock = mock(shelter_utils, true)
      utils_mock.determine_masked_value.returns("*****")

      local state_mock = mock(state, true)
      state_mock.get_config.returns({ highlight_group = "Comment", partial_mode = false })

      local ns = 1
      local api_mock = mock(vim.api, true)
      api_mock.nvim_create_namespace.returns(ns)
      api_mock.nvim_buf_get_extmarks.returns({ { 1, 0, 1 }, { 2, 0, 1 }, { 3, 0, 1 } })

      previewer_utils.process_buffer(bufnr)

      local marks = api_mock.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })

      assert.equals(3, #marks)

      mock.revert(shelter_utils)
      mock.revert(state)
      mock.revert(vim.api)
    end)
  end)
end)

