local assert = require("luassert")

describe("env pattern and sorting", function()
  local utils
  local test_dir

  before_each(function()
    package.loaded["ecolog.utils"] = nil
    utils = require("ecolog.utils")
    test_dir = vim.fn.tempname()
    vim.fn.mkdir(test_dir, "p")
  end)

  after_each(function()
    vim.fn.delete(test_dir, "rf")
  end)

  describe("custom env file pattern", function()
    it("should match default env files", function()
      local files = {
        test_dir .. "/.env",
        test_dir .. "/.env.local",
        test_dir .. "/.env.development",
        test_dir .. "/.env.test",
        test_dir .. "/not-env-file.txt",
        test_dir .. "/.environment",
      }

      -- Create test files
      for _, file in ipairs(files) do
        vim.fn.writefile({}, file)
      end

      local matched = utils.filter_env_files(files, nil) -- nil pattern should use default
      assert.equals(4, #matched)
      assert.truthy(vim.tbl_contains(matched, test_dir .. "/.env"))
      assert.truthy(vim.tbl_contains(matched, test_dir .. "/.env.local"))
      assert.truthy(vim.tbl_contains(matched, test_dir .. "/.env.development"))
      assert.truthy(vim.tbl_contains(matched, test_dir .. "/.env.test"))
    end)

    it("should match custom pattern", function()
      local files = {
        test_dir .. "/config.env",
        test_dir .. "/config.env.local",
        test_dir .. "/config.env.dev",
        test_dir .. "/.env",
        test_dir .. "/not-env-file.txt",
      }

      -- Create test files
      for _, file in ipairs(files) do
        vim.fn.writefile({}, file)
      end

      local pattern = "^.+/config%.env[^.]*$"
      local matched = utils.filter_env_files(files, pattern)
      assert.equals(1, #matched)
      assert.truthy(vim.tbl_contains(matched, test_dir .. "/config.env"))
    end)

    it("should match multiple custom patterns", function()
      local files = {
        test_dir .. "/config.env",
        test_dir .. "/config.env.local",
        test_dir .. "/env.conf",
        test_dir .. "/env.conf.local",
        test_dir .. "/.env",
        test_dir .. "/not-env-file.txt",
      }

      -- Create test files
      for _, file in ipairs(files) do
        vim.fn.writefile({}, file)
      end

      local patterns = {
        "^.+/config%.env[^.]*$",
        "^.+/env%.conf[^.]*$",
      }
      local matched = utils.filter_env_files(files, patterns)
      assert.equals(2, #matched)
      assert.truthy(vim.tbl_contains(matched, test_dir .. "/config.env"))
      assert.truthy(vim.tbl_contains(matched, test_dir .. "/env.conf"))
    end)
  end)

  describe("custom env file sorting", function()
    it("should use default sorting when no custom sort function provided", function()
      local files = {
        test_dir .. "/.env.test",
        test_dir .. "/.env",
        test_dir .. "/.env.local",
      }

      local sorted = utils.sort_env_files(files, { preferred_environment = "" })
      assert.equals(test_dir .. "/.env", sorted[1])
    end)

    it("should use custom sort function when provided", function()
      local files = {
        test_dir .. "/.env.test",
        test_dir .. "/.env",
        test_dir .. "/.env.local",
      }

      local sort_fn = function(a, b)
        -- Sort by string length (just as an example)
        return #a < #b
      end

      local sorted = utils.sort_env_files(files, { sort_fn = sort_fn })
      assert.equals(test_dir .. "/.env", sorted[1])
      assert.equals(test_dir .. "/.env.test", sorted[2])
      assert.equals(test_dir .. "/.env.local", sorted[3])
    end)

    it("should handle custom sort function with preferred environment", function()
      local files = {
        test_dir .. "/.env.test",
        test_dir .. "/.env",
        test_dir .. "/.env.local",
      }

      local sort_fn = function(a, b, opts)
        -- First prioritize preferred environment
        if opts.preferred_environment ~= "" then
          local pref_pattern = "%.env%." .. vim.pesc(opts.preferred_environment) .. "$"
          local a_is_preferred = a:match(pref_pattern) ~= nil
          local b_is_preferred = b:match(pref_pattern) ~= nil
          if a_is_preferred ~= b_is_preferred then
            return a_is_preferred
          end
        end
        -- Then sort alphabetically
        return a < b
      end

      local sorted = utils.sort_env_files(files, {
        sort_fn = sort_fn,
        preferred_environment = "test",
      })
      assert.equals(test_dir .. "/.env.test", sorted[1])
    end)
  end)
end) 