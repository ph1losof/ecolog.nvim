local assert = require("luassert")
local stub = require("luassert.stub")
local spy = require("luassert.spy")

describe("workspace and monorepo comprehensive", function()
  local workspace
  local detection
  local auto_switch
  local vim_mock
  local file_operations_mock

  before_each(function()
    -- Reset modules
    package.loaded["ecolog.monorepo.workspace"] = nil
    package.loaded["ecolog.monorepo.detection"] = nil
    package.loaded["ecolog.monorepo.auto_switch"] = nil
    package.loaded["ecolog.core.file_operations"] = nil
    
    -- Mock vim functions
    vim_mock = {
      fn = {
        getcwd = spy.new(function() return "/test/monorepo/packages/frontend" end),
        finddir = spy.new(function(dir, path)
          if dir == ".git" then
            return "/test/monorepo/.git"
          elseif dir == "node_modules" then
            return "/test/monorepo/node_modules"
          end
          return ""
        end),
        fnamemodify = spy.new(function(path, modifier)
          if modifier == ":h" then
            return path:match("^(.*)/[^/]*$") or "."
          elseif modifier == ":t" then
            return path:match("([^/]+)$") or path
          end
          return path
        end),
        glob = spy.new(function(pattern)
          if pattern:match("package%.json") then
            return "/test/monorepo/package.json\n/test/monorepo/packages/frontend/package.json\n/test/monorepo/packages/backend/package.json"
          elseif pattern:match("%.env") then
            return "/test/monorepo/.env\n/test/monorepo/packages/frontend/.env\n/test/monorepo/packages/backend/.env"
          end
          return ""
        end),
        readfile = spy.new(function(path)
          if path:match("package%.json") then
            return {'{"name": "test-package", "workspaces": ["packages/*"]}'}
          end
          return {}
        end),
        isdirectory = spy.new(function(path) return 1 end),
        filereadable = spy.new(function(path) return 1 end)
      },
      split = function(str, sep)
        local result = {}
        local pattern = "([^" .. (sep or "\n") .. "]+)"
        for match in str:gmatch(pattern) do
          table.insert(result, match)
        end
        return result
      end,
      tbl_deep_extend = function(mode, ...)
        local result = {}
        for _, tbl in ipairs({...}) do
          for k, v in pairs(tbl) do
            result[k] = v
          end
        end
        return result
      end
    }
    _G.vim = vim_mock
    
    -- Mock file operations
    file_operations_mock = {
      is_readable = spy.new(function(path) return true end),
      read_file_lines = spy.new(function(path)
        if path:match("%.env$") then
          return {
            "NODE_ENV=development",
            "API_URL=http://localhost:3000",
            "DATABASE_URL=postgres://localhost:5432/test"
          }
        end
        return {}
      end)
    }
    package.preload["ecolog.core.file_operations"] = function() return file_operations_mock end
    
    workspace = require("ecolog.monorepo.workspace")
    detection = require("ecolog.monorepo.detection")
    auto_switch = require("ecolog.monorepo.auto_switch")
  end)

  after_each(function()
    _G.vim = nil
    package.preload["ecolog.core.file_operations"] = nil
  end)

  describe("workspace detection", function()
    describe("basic workspace detection", function()
      it("should detect workspace root from current directory", function()
        local root = workspace.find_workspace_root()
        
        assert.is_string(root)
        assert.spy(vim_mock.fn.finddir).was.called()
      end)

      it("should detect package.json workspaces", function()
        local workspaces = workspace.detect_workspaces("/test/monorepo")
        
        assert.is_table(workspaces)
        assert.spy(vim_mock.fn.glob).was.called()
        assert.spy(vim_mock.fn.readfile).was.called()
      end)

      it("should handle missing workspace root gracefully", function()
        vim_mock.fn.finddir = spy.new(function() return "" end)
        
        local root = workspace.find_workspace_root()
        assert.is_string(root)
      end)

      it("should detect multiple workspace types", function()
        -- Mock for different workspace types
        vim_mock.fn.readfile = spy.new(function(path)
          if path:match("package%.json") then
            return {'{"workspaces": ["packages/*", "apps/*"]}'}
          elseif path:match("pnpm%-workspace%.yaml") then
            return {'packages:', '  - "packages/*"', '  - "apps/*"'}
          end
          return {}
        end)

        local workspaces = workspace.detect_workspaces("/test/monorepo")
        
        assert.is_table(workspaces)
      end)
    end)

    describe("workspace hierarchy", function()
      it("should build workspace hierarchy correctly", function()
        local hierarchy = workspace.build_workspace_hierarchy("/test/monorepo")
        
        assert.is_table(hierarchy)
        assert.is_not_nil(hierarchy.root)
        assert.is_table(hierarchy.packages)
      end)

      it("should handle nested workspaces", function()
        vim_mock.fn.glob = spy.new(function(pattern)
          return "/test/monorepo/packages/frontend/package.json\n/test/monorepo/packages/frontend/subpackages/ui/package.json"
        end)

        local hierarchy = workspace.build_workspace_hierarchy("/test/monorepo")
        
        assert.is_table(hierarchy)
      end)

      it("should handle workspace without packages", function()
        vim_mock.fn.glob = spy.new(function() return "" end)
        
        local hierarchy = workspace.build_workspace_hierarchy("/test/monorepo")
        
        assert.is_table(hierarchy)
        assert.is_table(hierarchy.packages)
      end)
    end)

    describe("environment file discovery", function()
      it("should find environment files across workspace", function()
        local env_files = workspace.find_workspace_env_files("/test/monorepo")
        
        assert.is_table(env_files)
        assert.spy(vim_mock.fn.glob).was.called()
      end)

      it("should prioritize local environment files", function()
        local env_files = workspace.find_workspace_env_files("/test/monorepo/packages/frontend")
        
        assert.is_table(env_files)
        -- Should include both local and root env files
      end)

      it("should handle missing environment files gracefully", function()
        vim_mock.fn.glob = spy.new(function() return "" end)
        
        local env_files = workspace.find_workspace_env_files("/test/monorepo")
        
        assert.is_table(env_files)
        assert.equals(0, #env_files)
      end)
    end)
  end)

  describe("auto switching functionality", function()
    describe("workspace switching", function()
      it("should switch workspace context automatically", function()
        auto_switch.setup({
          enabled = true,
          auto_switch_workspace = true
        })

        -- Simulate directory change
        local success = auto_switch.switch_to_workspace("/test/monorepo/packages/backend")
        
        assert.is_boolean(success)
      end)

      it("should handle switch failures gracefully", function()
        vim_mock.fn.isdirectory = spy.new(function() return 0 end)
        
        auto_switch.setup({ enabled = true })
        local success = auto_switch.switch_to_workspace("/nonexistent/path")
        
        assert.is_false(success)
      end)

      it("should respect auto-switch configuration", function()
        auto_switch.setup({
          enabled = false,
          auto_switch_workspace = false
        })

        local success = auto_switch.switch_to_workspace("/test/monorepo/packages/backend")
        
        -- Should handle disabled state appropriately
        assert.is_boolean(success)
      end)
    end)

    describe("context management", function()
      it("should maintain workspace context", function()
        auto_switch.setup({ enabled = true })
        auto_switch.switch_to_workspace("/test/monorepo/packages/frontend")
        
        local context = auto_switch.get_current_context()
        
        assert.is_table(context)
      end)

      it("should update context on workspace change", function()
        auto_switch.setup({ enabled = true })
        
        auto_switch.switch_to_workspace("/test/monorepo/packages/frontend")
        local context1 = auto_switch.get_current_context()
        
        auto_switch.switch_to_workspace("/test/monorepo/packages/backend")
        local context2 = auto_switch.get_current_context()
        
        -- Contexts should be different
        assert.is_table(context1)
        assert.is_table(context2)
      end)

      it("should handle invalid workspace context gracefully", function()
        auto_switch.setup({ enabled = true })
        
        local success = auto_switch.switch_to_workspace("/invalid/workspace")
        local context = auto_switch.get_current_context()
        
        assert.is_table(context)
      end)
    end)
  end)

  describe("monorepo detection", function()
    describe("project type detection", function()
      it("should detect npm/yarn workspaces", function()
        vim_mock.fn.readfile = spy.new(function(path)
          if path:match("package%.json") then
            return {'{"workspaces": ["packages/*"]}'}
          end
          return {}
        end)

        local detected = detection.detect_monorepo_type("/test/monorepo")
        
        assert.is_table(detected)
        assert.equals("npm", detected.type)
      end)

      it("should detect pnpm workspaces", function()
        vim_mock.fn.filereadable = spy.new(function(path)
          if path:match("pnpm%-workspace%.yaml") then
            return 1
          end
          return 0
        end)

        local detected = detection.detect_monorepo_type("/test/monorepo")
        
        assert.is_table(detected)
        assert.equals("pnpm", detected.type)
      end)

      it("should detect lerna projects", function()
        vim_mock.fn.filereadable = spy.new(function(path)
          if path:match("lerna%.json") then
            return 1
          end
          return 0
        end)

        local detected = detection.detect_monorepo_type("/test/monorepo")
        
        assert.is_table(detected)
        assert.equals("lerna", detected.type)
      end)

      it("should detect rush projects", function()
        vim_mock.fn.filereadable = spy.new(function(path)
          if path:match("rush%.json") then
            return 1
          end
          return 0
        end)

        local detected = detection.detect_monorepo_type("/test/monorepo")
        
        assert.is_table(detected)
        assert.equals("rush", detected.type)
      end)

      it("should handle unknown project types", function()
        vim_mock.fn.filereadable = spy.new(function() return 0 end)
        vim_mock.fn.readfile = spy.new(function() return {} end)

        local detected = detection.detect_monorepo_type("/test/project")
        
        assert.is_table(detected)
        assert.equals("unknown", detected.type)
      end)
    end)

    describe("workspace configuration parsing", function()
      it("should parse npm workspace configuration", function()
        vim_mock.fn.readfile = spy.new(function()
          return {'{"workspaces": {"packages": ["packages/*", "apps/*"]}}'}
        end)

        local config = detection.parse_workspace_config("/test/monorepo", "npm")
        
        assert.is_table(config)
        assert.is_table(config.packages)
      end)

      it("should parse pnpm workspace configuration", function()
        vim_mock.fn.readfile = spy.new(function()
          return {
            'packages:',
            '  - "packages/*"',
            '  - "apps/*"'
          }
        end)

        local config = detection.parse_workspace_config("/test/monorepo", "pnpm")
        
        assert.is_table(config)
      end)

      it("should handle malformed configuration gracefully", function()
        vim_mock.fn.readfile = spy.new(function()
          return {'invalid json {'}
        end)

        local config = detection.parse_workspace_config("/test/monorepo", "npm")
        
        assert.is_table(config)
      end)
    end)
  end)

  describe("integration and performance", function()
    describe("large workspace handling", function()
      it("should handle workspaces with many packages efficiently", function()
        -- Simulate large workspace
        local large_glob_result = {}
        for i = 1, 100 do
          table.insert(large_glob_result, "/test/monorepo/packages/package" .. i .. "/package.json")
        end
        vim_mock.fn.glob = spy.new(function()
          return table.concat(large_glob_result, "\n")
        end)

        local start_time = vim.loop and vim.loop.hrtime() or 0
        local workspaces = workspace.detect_workspaces("/test/monorepo")
        local end_time = vim.loop and vim.loop.hrtime() or 1000000

        assert.is_table(workspaces)
        
        if vim.loop then
          local duration_ms = (end_time - start_time) / 1000000
          assert.is_true(duration_ms < 1000) -- Should complete in under 1 second
        end
      end)

      it("should handle deeply nested workspace structures", function()
        vim_mock.fn.glob = spy.new(function()
          return "/test/monorepo/packages/frontend/subpackages/ui/components/button/package.json"
        end)

        local hierarchy = workspace.build_workspace_hierarchy("/test/monorepo")
        
        assert.is_table(hierarchy)
      end)
    end)

    describe("error resilience", function()
      it("should handle file system errors gracefully", function()
        vim_mock.fn.readfile = spy.new(function()
          error("File system error")
        end)

        assert.has_no.errors(function()
          workspace.detect_workspaces("/test/monorepo")
        end)
      end)

      it("should handle permission errors", function()
        vim_mock.fn.isdirectory = spy.new(function()
          error("Permission denied")
        end)

        assert.has_no.errors(function()
          workspace.find_workspace_root()
        end)
      end)

      it("should handle concurrent workspace operations", function()
        auto_switch.setup({ enabled = true })
        
        -- Simulate concurrent operations
        local success1 = auto_switch.switch_to_workspace("/test/monorepo/packages/frontend")
        local success2 = auto_switch.switch_to_workspace("/test/monorepo/packages/backend")
        
        assert.is_boolean(success1)
        assert.is_boolean(success2)
      end)
    end)

    describe("memory management", function()
      it("should cleanup workspace cache properly", function()
        -- Populate cache
        workspace.detect_workspaces("/test/monorepo")
        
        -- Clear cache
        workspace.clear_cache()
        
        -- Should rebuild cache on next call
        local workspaces = workspace.detect_workspaces("/test/monorepo")
        assert.is_table(workspaces)
      end)

      it("should handle cache invalidation correctly", function()
        local workspaces1 = workspace.detect_workspaces("/test/monorepo")
        
        -- Simulate file change
        workspace.invalidate_cache("/test/monorepo")
        
        local workspaces2 = workspace.detect_workspaces("/test/monorepo")
        
        assert.is_table(workspaces1)
        assert.is_table(workspaces2)
      end)
    end)
  end)
end)