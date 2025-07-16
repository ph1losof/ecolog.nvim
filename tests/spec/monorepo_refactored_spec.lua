local assert = require("luassert")
local stub = require("luassert.stub")
local match = require("luassert.match")

-- Mock vim.fn and vim.loop
vim.fn = vim.fn or {}
vim.loop = vim.loop or {}

describe("refactored monorepo system", function()
  local MonorepoNew, Detection, Cache, TurborepoProvider, Factory

  before_each(function()
    -- Clear any existing modules from cache
    package.loaded["ecolog.monorepo"] = nil
    package.loaded["ecolog.monorepo.detection"] = nil
    package.loaded["ecolog.monorepo.detection.cache"] = nil
    package.loaded["ecolog.monorepo.detection.providers.turborepo"] = nil
    package.loaded["ecolog.monorepo.detection.providers.factory"] = nil

    -- Load modules
    MonorepoNew = require("ecolog.monorepo")
    Detection = require("ecolog.monorepo.detection")
    Cache = require("ecolog.monorepo.detection.cache")
    TurborepoProvider = require("ecolog.monorepo.detection.providers.turborepo")
    Factory = require("ecolog.monorepo.detection.providers.factory")

    -- Mock vim functions
    vim.fn.getcwd = function()
      return "/test/project"
    end
    vim.fn.fnamemodify = function(path, modifier)
      if modifier == ":p:h" then
        return path:gsub("/[^/]*$", "")
      elseif modifier == ":t" then
        return path:match("([^/]+)$")
      end
      return path
    end
    vim.fn.filereadable = function()
      return 0
    end
    vim.fn.isdirectory = function()
      return 0
    end
    vim.fn.glob = function()
      return {}
    end
    vim.loop.now = function()
      return 1000000
    end

    -- Clear caches
    Cache.clear_all()
  end)

  after_each(function()
    -- Clear state if possible
    if MonorepoNew.shutdown then
      MonorepoNew.shutdown()
    end
  end)

  describe("new modular architecture", function()
    it("should initialize with default configuration", function()
      local config = {
        enabled = true,
        auto_switch = false,
        providers = {
          builtin = { "turborepo" },
        },
      }

      assert.has_no.errors(function()
        MonorepoNew.setup(config)
      end)

      assert.is_true(MonorepoNew.is_enabled())
    end)

    it("should register providers correctly", function()
      MonorepoNew.setup({
        enabled = true,
        providers = {
          builtin = { "turborepo" },
        },
      })

      local providers = MonorepoNew.get_providers()
      assert.is_not_nil(providers.turborepo)
    end)

    it("should validate configuration", function()
      -- Valid configuration should work
      assert.has_no.errors(function()
        MonorepoNew.setup({
          enabled = true,
          providers = {
            builtin = { "turborepo" },
          },
        })
      end)

      -- Boolean configuration should work
      assert.has_no.errors(function()
        MonorepoNew.setup(true)
      end)
    end)
  end)

  describe("provider system", function()
    it("should create turborepo provider correctly", function()
      local provider = TurborepoProvider.new()

      assert.is_not_nil(provider)
      assert.equals("turborepo", provider.name)
      assert.equals(1, provider.priority)
    end)

    it("should detect turborepo correctly", function()
      vim.fn.filereadable = function(path)
        return path:match("turbo%.json$") and 1 or 0
      end

      local provider = TurborepoProvider.new()
      local can_detect, confidence, metadata = provider:detect("/test/project")

      assert.is_true(can_detect)
      assert.is_true(confidence > 90)
      assert.equals("turbo.json", metadata.marker_file)
    end)

    it("should create providers using factory", function()
      local provider = Factory.create_simple_provider({
        name = "test_provider",
        detection = {
          strategies = { "file_markers" },
          file_markers = { "test.json" },
          max_depth = 4,
          cache_duration = 300000,
        },
        workspace = {
          patterns = { "test/*" },
          priority = { "test" },
        },
        env_resolution = {
          strategy = "workspace_first",
          inheritance = true,
          override_order = { "workspace", "root" },
        },
        priority = 50,
      })

      assert.is_not_nil(provider)
      local instance = provider.new()
      assert.equals("test_provider", instance.name)
    end)
  end)

  describe("caching system", function()
    it("should cache detection results", function()
      local test_result = { root_path = "/test", provider = "test" }

      Cache.set_detection("test_key", test_result)
      local cached = Cache.get_detection("test_key")

      assert.same(test_result, cached)
    end)

    it("should respect cache TTL", function()
      local test_result = { root_path = "/test", provider = "test" }

      -- Mock time progression
      local current_time = 1000000
      vim.loop.now = function()
        return current_time
      end

      Cache.set_detection("test_key", test_result, 5000) -- 5 second TTL

      -- Should be cached initially
      assert.same(test_result, Cache.get_detection("test_key", 5000))

      -- Advance time beyond TTL
      current_time = current_time + 6000

      -- Should be expired
      assert.is_nil(Cache.get_detection("test_key", 5000))
    end)

    it("should provide cache statistics", function()
      Cache.set_detection("key1", { test = 1 })
      Cache.set_workspaces("key2", { workspace1 = true })

      -- Access one item to generate hit
      Cache.get_detection("key1")

      -- Try to access non-existent item to generate miss
      Cache.get_detection("nonexistent")

      local stats = Cache.get_stats()
      assert.is_number(stats.hits)
      assert.is_number(stats.misses)
      assert.is_number(stats.total_entries)
    end)
  end)

  describe("integration compatibility", function()
    it("should maintain backward compatibility", function()
      -- Test the compatibility function
      local ecolog_config = {
        monorepo = {
          enabled = true,
          providers = {
            builtin = { "turborepo" },
          },
        },
      }

      -- Mock successful detection
      vim.fn.filereadable = function(path)
        return path:match("turbo%.json$") and 1 or 0
      end

      local modified_config = MonorepoNew.integrate_with_ecolog_config(ecolog_config)

      -- Should have monorepo information added
      assert.is_not_nil(modified_config._monorepo_root)
      assert.is_not_nil(modified_config._detected_info)
    end)

    it("should handle boolean configuration", function()
      assert.has_no.errors(function()
        MonorepoNew.setup(true)
      end)

      assert.has_no.errors(function()
        MonorepoNew.setup(false)
      end)
    end)
  end)

  describe("statistics and monitoring", function()
    it("should provide comprehensive statistics", function()
      MonorepoNew.setup({
        enabled = true,
        providers = {
          builtin = { "turborepo" },
        },
      })

      local stats = MonorepoNew.get_stats()

      assert.is_true(stats.enabled)
      assert.is_true(stats.initialized)
      assert.is_not_nil(stats.config)
      assert.is_not_nil(stats.detection)
    end)
  end)
end)

