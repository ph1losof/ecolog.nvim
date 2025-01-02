local assert = require("luassert")
local stub = require("luassert.stub")

describe("select window", function()
  local select
  local test_dir
  local api = vim.api
  local mock_lines

  before_each(function()
    package.loaded["ecolog.select"] = nil
    select = require("ecolog.select")
    test_dir = vim.fn.tempname()
    vim.fn.mkdir(test_dir, "p")
    mock_lines = {}

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
  end)

  it("should respect custom env file patterns", function()
    local test_dir = vim.fn.tempname()
    vim.fn.mkdir(test_dir)

    -- Create test files
    vim.fn.writefile({}, test_dir .. "/.env")
    vim.fn.writefile({}, test_dir .. "/config.env")
    vim.fn.writefile({}, test_dir .. "/test.env")

    local select = require("ecolog.select")
    local callback = function() end

    select.select_env_file({
      path = test_dir,
      env_file_pattern = "^.+/config%.env$",
    }, callback)

    -- Should only show config.env
    assert.equals(1, #mock_lines)
    assert.equals(" → 1. config.env", mock_lines[1])

    -- Cleanup
    vim.fn.delete(test_dir, "rf")
  end)

  it("should respect custom sort function", function()
    -- Create test files
    local files = {
      test_dir .. "/config.env",
      test_dir .. "/env.conf",
      test_dir .. "/.env",
    }

    for _, file in ipairs(files) do
      vim.fn.writefile({}, file)
    end

    local callback = function() end

    -- Test with custom sort function (sort by length)
    select.select_env_file({
      path = test_dir,
      env_file_pattern = {
        "^.+/config%.env[^.]*$",
        "^.+/env%.conf[^.]*$",
      },
      sort_fn = function(a, b)
        return #a < #b
      end,
    }, callback)

    -- Check that files are sorted by length
    assert.equals(2, #mock_lines)
    
    -- Extract filenames from the formatted lines
    local filenames = {}
    for _, line in ipairs(mock_lines) do
      local filename = line:match("%d%. (.+)$")
      table.insert(filenames, filename)
    end
    
    -- Check order (env.conf should come before config.env)
    assert.equals("env.conf", filenames[1])
    assert.equals("config.env", filenames[2])
  end)
end) 