local assert = require("luassert")

describe("env pattern and sorting", function()
  local utils = require("ecolog.utils")

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
    return files
  end

  local function cleanup_test_files(path)
    vim.fn.delete(path, "rf")
  end

  describe("custom env file pattern", function()
    it("should match default env files", function()
      local test_dir = vim.fn.tempname()
      local files = create_test_files(test_dir)

      local found = utils.find_env_files({
        path = test_dir,
      })

      -- Should find .env and .env.* files in root
      assert.equals(3, #found)
      cleanup_test_files(test_dir)
    end)

    it("should match custom pattern", function()
      local test_dir = vim.fn.tempname()
      local files = create_test_files(test_dir)

      local found = utils.find_env_files({
        path = test_dir,
        env_file_patterns = { "config/.env" },
      })

      -- Should find only config/.env
      assert.equals(1, #found)
      assert.equals(test_dir .. "/config/.env", found[1])
      cleanup_test_files(test_dir)
    end)

    it("should match multiple custom patterns", function()
      local test_dir = vim.fn.tempname()
      local files = create_test_files(test_dir)

      local found = utils.find_env_files({
        path = test_dir,
        env_file_patterns = { "config/.env", "config/.env.*" },
      })

      -- Should find both config/.env and config/.env.local
      assert.equals(2, #found)
      cleanup_test_files(test_dir)
    end)
  end)

  describe("custom env file sorting", function()
    it("should use default sorting when no custom sort function provided", function()
      local test_dir = vim.fn.tempname()
      local files = create_test_files(test_dir)

      local found = utils.find_env_files({
        path = test_dir,
      })

      -- Default sorting: .env comes first
      assert.equals(test_dir .. "/.env", found[1])
      cleanup_test_files(test_dir)
    end)

    it("should use custom sort function when provided", function()
      local test_dir = vim.fn.tempname()
      local files = create_test_files(test_dir)

      local custom_sort = function(a, b)
        -- Sort by length of filename (without path)
        local a_name = vim.fn.fnamemodify(a, ":t")
        local b_name = vim.fn.fnamemodify(b, ":t")
        return #a_name > #b_name
      end

      local found = utils.find_env_files({
        path = test_dir,
        sort_file_fn = custom_sort,
      })

      -- Longest filename should come first
      local first_name = vim.fn.fnamemodify(found[1], ":t")
      assert.equals(".env.development", first_name)
      cleanup_test_files(test_dir)
    end)

    it("should handle custom sort function with preferred environment", function()
      local test_dir = vim.fn.tempname()
      local files = create_test_files(test_dir)

      local found = utils.find_env_files({
        path = test_dir,
        preferred_environment = "test",
      })

      -- .env.test should come first due to preferred_environment
      assert.equals(test_dir .. "/.env.test", found[1])
      cleanup_test_files(test_dir)
    end)
  end)
end) 