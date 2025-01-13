local assert = require("luassert")
local stub = require("luassert.stub")
local match = require("luassert.match")

describe("peek window", function()
  local peek
  local api = vim.api
  local mock_lines
  local mock_highlights
  local mock_shelter
  local mock_types
  local mock_providers
  local mock_env_vars
  local notify_stub

  before_each(function()
    package.loaded["ecolog.peek"] = nil
    package.loaded["ecolog.shelter"] = nil
    package.loaded["ecolog.types"] = nil
    package.loaded["ecolog.providers"] = nil

    -- Mock vim API functions
    stub(api, "nvim_create_buf").returns(1)
    stub(api, "nvim_open_win").returns(1)
    stub(api, "nvim_buf_set_option")
    stub(api, "nvim_win_set_option")
    stub(api, "nvim_buf_set_lines", function(_, _, _, _, lines)
      mock_lines = lines
    end)
    stub(api, "nvim_buf_add_highlight", function(_, _, group, line, start_col, end_col)
      mock_highlights = mock_highlights or {}
      table.insert(mock_highlights, { group = group, line = line, start_col = start_col, end_col = end_col })
    end)
    stub(api, "nvim_create_autocmd")
    stub(api, "nvim_buf_set_keymap")
    stub(api, "nvim_get_current_buf").returns(1)
    stub(api, "nvim_win_is_valid").returns(false)

    -- Mock shelter module
    mock_shelter = {
      is_enabled = function() return false end,
      mask_value = function(value) return value end,
      get_config = function() return { highlight_group = "Comment" } end,
    }
    package.loaded["ecolog.shelter"] = mock_shelter

    -- Mock types module
    mock_types = {
      detect_type = function(value) return "string", value end,
    }
    package.loaded["ecolog.types"] = mock_types

    -- Mock providers
    mock_providers = {
      get_providers = function() return { { extract_var = function() return "TEST_VAR" end } } end,
    }

    -- Mock environment variables
    mock_env_vars = {
      TEST_VAR = {
        value = "test_value",
        type = "string",
        source = ".env",
      },
      COMMENTED_VAR = {
        value = "test_value",
        type = "string",
        source = ".env",
        comment = "This is a comment",
      },
    }

    -- Set filetype
    vim.bo.filetype = "typescript"

    -- Mock notify
    notify_stub = stub(vim, "notify")

    peek = require("ecolog.peek")
  end)

  after_each(function()
    mock_lines = nil
    mock_highlights = nil
    notify_stub:revert()
  end)

  describe("window creation", function()
    it("should create peek window with correct options", function()
      peek.peek_env_value("TEST_VAR", {}, mock_env_vars, mock_providers, function() end)

      -- Verify buffer creation and options
      assert.stub(api.nvim_create_buf).was_called_with(false, true)
      assert.stub(api.nvim_buf_set_option).was_called_with(1, "buftype", "nofile")
      assert.stub(api.nvim_buf_set_option).was_called_with(1, "filetype", "ecolog")

      -- Verify window creation with correct options
      assert.stub(api.nvim_open_win).was_called_with(1, false, match._)

      -- Verify window options
      assert.stub(api.nvim_win_set_option).was_called_with(1, "conceallevel", 2)
      assert.stub(api.nvim_win_set_option).was_called_with(1, "concealcursor", "niv")
      assert.stub(api.nvim_win_set_option).was_called_with(1, "cursorline", true)
    end)

    it("should set up autocommands for auto-closing", function()
      peek.peek_env_value("TEST_VAR", {}, mock_env_vars, mock_providers, function() end)

      assert.stub(api.nvim_create_autocmd).was_called_with(
        match._,
        match._
      )
    end)

    it("should set up close keymapping", function()
      peek.peek_env_value("TEST_VAR", {}, mock_env_vars, mock_providers, function() end)

      assert.stub(api.nvim_buf_set_keymap).was_called_with(1, "n", "q", "", match._)
    end)
  end)

  describe("content display", function()
    it("should display variable information correctly", function()
      peek.peek_env_value("TEST_VAR", {}, mock_env_vars, mock_providers, function() end)

      assert.are.same({
        "Name    : TEST_VAR",
        "Type    : string",
        "Source  : .env",
        "Value   : test_value",
      }, mock_lines)
    end)

    it("should include comment when available", function()
      peek.peek_env_value("COMMENTED_VAR", {}, mock_env_vars, mock_providers, function() end)

      assert.are.same({
        "Name    : COMMENTED_VAR",
        "Type    : string",
        "Source  : .env",
        "Value   : test_value",
        "Comment : This is a comment",
      }, mock_lines)
    end)

    it("should apply correct highlights", function()
      peek.peek_env_value("TEST_VAR", {}, mock_env_vars, mock_providers, function() end)

      -- Verify highlights were applied for each line
      assert.equals("EcologVariable", mock_highlights[1].group)
      assert.equals("EcologType", mock_highlights[2].group)
      assert.equals("EcologSource", mock_highlights[3].group)
      assert.equals("EcologValue", mock_highlights[4].group)
    end)
  end)

  describe("shelter mode integration", function()
    it("should mask values when shelter mode is enabled", function()
      -- Enable shelter mode
      mock_shelter.is_enabled = function() return true end
      mock_shelter.mask_value = function() return "********" end

      peek.peek_env_value("TEST_VAR", {}, mock_env_vars, mock_providers, function() end)

      -- Check if value is masked
      assert.equals("Value   : ********", mock_lines[4])
    end)

    it("should use shelter highlight group when enabled", function()
      mock_shelter.is_enabled = function() return true end
      mock_shelter.get_config = function() return { highlight_group = "Comment" } end

      peek.peek_env_value("TEST_VAR", {}, mock_env_vars, mock_providers, function() end)

      -- Verify shelter highlight group is used for value
      assert.equals("Comment", mock_highlights[4].group)
    end)
  end)

  describe("error handling", function()
    it("should handle unsupported filetypes", function()
      mock_providers.get_providers = function() return {} end

      peek.peek_env_value("TEST_VAR", {}, mock_env_vars, mock_providers, function() end)

      assert.stub(notify_stub).was_called_with(
        "EcologPeek is not available for typescript files",
        vim.log.levels.WARN
      )
    end)

    it("should handle non-existent variables", function()
      peek.peek_env_value("NON_EXISTENT", {}, mock_env_vars, mock_providers, function() end)

      assert.stub(notify_stub).was_called_with(
        "Environment variable 'NON_EXISTENT' not found",
        vim.log.levels.WARN
      )
    end)

    it("should handle no variable at cursor", function()
      mock_providers.get_providers = function()
        return {
          { extract_var = function() return nil end }
        }
      end

      peek.peek_env_value(nil, {}, mock_env_vars, mock_providers, function() end)

      assert.stub(notify_stub).was_called_with(
        "No environment variable pattern matched at cursor",
        vim.log.levels.WARN
      )
    end)
  end)
end) 