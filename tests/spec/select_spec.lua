local assert = require("luassert")
local stub = require("luassert.stub")
local mock = require("luassert.mock")
local match = require("luassert.match")

describe("select window", function()
  local select
  local test_dir
  local api = vim.api
  local mock_lines
  local utils
  local keymaps = {}

  local function create_test_files(path)
    vim.fn.mkdir(path, "p")
    local files = {
      [path .. "/.env"] = "KEY=value",
      [path .. "/.env.development"] = "KEY=dev",
      [path .. "/.env.test"] = "KEY=test",
      [path .. "/config/.env"] = "KEY=config",
      [path .. "/config/.env.local"] = "KEY=config_local",
    }
    for file, content in pairs(files) do
      local dir = vim.fn.fnamemodify(file, ":h")
      vim.fn.mkdir(dir, "p")
      local f = io.open(file, "w")
      f:write(content)
      f:close()
    end
  end

  local function cleanup_test_files(path)
    vim.fn.delete(path, "rf")
  end

  before_each(function()
    package.loaded["ecolog.select"] = nil
    package.loaded["ecolog.utils"] = nil
    utils = require("ecolog.utils")
    select = require("ecolog.select")
    test_dir = vim.fn.tempname()
    vim.fn.mkdir(test_dir, "p")
    mock_lines = {}
    keymaps = {}

    -- Mock window creation functions
    stub(api, "nvim_create_buf").returns(1)
    stub(api, "nvim_open_win").returns(1)
    stub(api, "nvim_buf_set_option")
    stub(api, "nvim_win_set_option")
    stub(api, "nvim_buf_set_lines", function(_, _, _, _, lines)
      mock_lines = lines
    end)
    stub(api, "nvim_win_set_cursor")
    stub(api, "nvim_buf_clear_namespace")
    stub(api, "nvim_buf_add_highlight")
    stub(api, "nvim_create_augroup").returns(1)
    stub(api, "nvim_create_autocmd")

    -- Mock keymap functions
    stub(vim.keymap, "set", function(mode, lhs, rhs, opts)
      keymaps[lhs] = rhs
    end)
  end)

  after_each(function()
    vim.fn.delete(test_dir, "rf")
    -- Restore stubs
    api.nvim_create_buf:revert()
    api.nvim_open_win:revert()
    api.nvim_buf_set_option:revert()
    api.nvim_win_set_option:revert()
    api.nvim_buf_set_lines:revert()
    api.nvim_win_set_cursor:revert()
    api.nvim_buf_clear_namespace:revert()
    api.nvim_buf_add_highlight:revert()
    api.nvim_create_augroup:revert()
    api.nvim_create_autocmd:revert()
    vim.keymap.set:revert()
  end)

  it("should respect custom env file patterns", function()
    local test_dir = vim.fn.tempname()
    create_test_files(test_dir)

    -- Mock utils.find_env_files to return only config/.env
    stub(utils, "find_env_files", function(opts)
      return { test_dir .. "/config/.env" }
    end)

    local opts = {
      path = test_dir,
      env_file_patterns = { "config/.env" },
    }

    local selected_file
    select.select_env_file(opts, function(file)
      selected_file = file
    end)

    -- Simulate pressing Enter to select the first file
    keymaps["<CR>"]()

    assert.equals(test_dir .. "/config/.env", selected_file)
    cleanup_test_files(test_dir)
    utils.find_env_files:revert()
  end)

  it("should respect custom sort function", function()
    local test_dir = vim.fn.tempname()
    create_test_files(test_dir)

    -- Mock utils.find_env_files to return sorted files
    stub(utils, "find_env_files", function(opts)
      return {
        test_dir .. "/.env.development",
        test_dir .. "/.env.test",
        test_dir .. "/.env",
      }
    end)

    local custom_sort = function(a, b)
      -- Sort by length of filename (without path)
      local a_name = vim.fn.fnamemodify(a, ":t")
      local b_name = vim.fn.fnamemodify(b, ":t")
      return #a_name > #b_name
    end

    local opts = {
      path = test_dir,
      sort_fn = custom_sort,
    }

    local selected_file
    select.select_env_file(opts, function(file)
      selected_file = file
    end)

    -- Simulate pressing Enter to select the first file
    keymaps["<CR>"]()

    -- The longest filename should be selected first
    local selected_name = vim.fn.fnamemodify(selected_file, ":t")
    assert.equals(".env.development", selected_name)
    cleanup_test_files(test_dir)
    utils.find_env_files:revert()
  end)
end) 