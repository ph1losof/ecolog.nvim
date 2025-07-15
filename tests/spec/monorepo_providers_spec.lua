local assert = require("luassert")

describe("monorepo provider system", function()
  local monorepo = require("ecolog.monorepo")
  
  local function create_test_monorepo(path, provider_type, files)
    vim.fn.mkdir(path, "p")
    
    -- Create marker files based on provider type
    if provider_type == "turborepo" then
      vim.fn.writefile({ '{"$schema": "https://turbo.build/schema.json"}' }, path .. "/turbo.json")
    elseif provider_type == "nx" then
      vim.fn.writefile({ '{"version": 2}' }, path .. "/nx.json")
    elseif provider_type == "lerna" then
      vim.fn.writefile({ '{"version": "0.0.0"}' }, path .. "/lerna.json")
    end
    
    -- Create workspace directories and files
    for workspace_path, content in pairs(files or {}) do
      local full_path = path .. "/" .. workspace_path
      vim.fn.mkdir(vim.fn.fnamemodify(full_path, ":h"), "p")
      vim.fn.writefile(content, full_path)
    end
  end
  
  local function cleanup_test_monorepo(path)
    vim.fn.delete(path, "rf")
  end
  
  describe("provider detection", function()
    it("should detect turborepo provider", function()
      local test_dir = vim.fn.tempname()
      create_test_monorepo(test_dir, "turborepo", {
        ["apps/web/package.json"] = { '{"name": "web"}' },
        ["packages/ui/package.json"] = { '{"name": "ui"}' }
      })
      
      -- Need to pass a config with enabled=true since it's disabled by default
      local config = { enabled = true, providers = monorepo.DEFAULT_MONOREPO_CONFIG.providers }
      local root_path, detected_info = monorepo.detect_monorepo_root(test_dir, config)
      
      assert.equals(test_dir, root_path)
      assert.equals("turborepo", detected_info.provider.name)
      assert.is_true(vim.tbl_contains(detected_info.provider.workspace_patterns, "apps/*"))
      assert.is_true(vim.tbl_contains(detected_info.provider.workspace_patterns, "packages/*"))
      
      cleanup_test_monorepo(test_dir)
    end)
    
    it("should detect nx provider", function()
      local test_dir = vim.fn.tempname()
      create_test_monorepo(test_dir, "nx", {
        ["apps/web/package.json"] = { '{"name": "web"}' },
        ["libs/shared/package.json"] = { '{"name": "shared"}' }
      })
      
      local config = { enabled = true, providers = monorepo.DEFAULT_MONOREPO_CONFIG.providers }
      local root_path, detected_info = monorepo.detect_monorepo_root(test_dir, config)
      
      assert.equals(test_dir, root_path)
      assert.equals("nx", detected_info.provider.name)
      assert.is_true(vim.tbl_contains(detected_info.provider.workspace_patterns, "apps/*"))
      assert.is_true(vim.tbl_contains(detected_info.provider.workspace_patterns, "libs/*"))
      
      cleanup_test_monorepo(test_dir)
    end)
    
    it("should detect lerna provider", function()
      local test_dir = vim.fn.tempname()
      create_test_monorepo(test_dir, "lerna", {
        ["packages/core/package.json"] = { '{"name": "core"}' },
        ["packages/utils/package.json"] = { '{"name": "utils"}' }
      })
      
      local config = { enabled = true, providers = monorepo.DEFAULT_MONOREPO_CONFIG.providers }
      local root_path, detected_info = monorepo.detect_monorepo_root(test_dir, config)
      
      assert.equals(test_dir, root_path)
      assert.equals("lerna", detected_info.provider.name)
      assert.is_true(vim.tbl_contains(detected_info.provider.workspace_patterns, "packages/*"))
      
      cleanup_test_monorepo(test_dir)
    end)
  end)
  
  describe("provider-specific workspace patterns", function()
    it("should use turborepo workspace patterns", function()
      local test_dir = vim.fn.tempname()
      create_test_monorepo(test_dir, "turborepo", {
        ["apps/web/package.json"] = { '{"name": "web"}' },
        ["packages/ui/package.json"] = { '{"name": "ui"}' },
        ["libs/shared/package.json"] = { '{"name": "shared"}' } -- This shouldn't be found for turborepo
      })
      
      local config = { enabled = true, providers = monorepo.DEFAULT_MONOREPO_CONFIG.providers }
      local root_path, detected_info = monorepo.detect_monorepo_root(test_dir, config)
      local workspaces = monorepo.get_workspaces(root_path, config, detected_info)
      
      -- Should find apps/web and packages/ui but not libs/shared
      assert.equals(2, #workspaces)
      local workspace_names = {}
      for _, workspace in ipairs(workspaces) do
        table.insert(workspace_names, workspace.name)
      end
      assert.is_true(vim.tbl_contains(workspace_names, "web"))
      assert.is_true(vim.tbl_contains(workspace_names, "ui"))
      assert.is_false(vim.tbl_contains(workspace_names, "shared"))
      
      cleanup_test_monorepo(test_dir)
    end)
    
    it("should use nx workspace patterns", function()
      local test_dir = vim.fn.tempname()
      create_test_monorepo(test_dir, "nx", {
        ["apps/web/package.json"] = { '{"name": "web"}' },
        ["libs/shared/package.json"] = { '{"name": "shared"}' },
        ["packages/ui/package.json"] = { '{"name": "ui"}' } -- This shouldn't be found for nx
      })
      
      local config = { enabled = true, providers = monorepo.DEFAULT_MONOREPO_CONFIG.providers }
      local root_path, detected_info = monorepo.detect_monorepo_root(test_dir, config)
      local workspaces = monorepo.get_workspaces(root_path, config, detected_info)
      
      -- Should find apps/web and libs/shared but not packages/ui
      assert.equals(2, #workspaces)
      local workspace_names = {}
      for _, workspace in ipairs(workspaces) do
        table.insert(workspace_names, workspace.name)
      end
      assert.is_true(vim.tbl_contains(workspace_names, "web"))
      assert.is_true(vim.tbl_contains(workspace_names, "shared"))
      assert.is_false(vim.tbl_contains(workspace_names, "ui"))
      
      cleanup_test_monorepo(test_dir)
    end)
  end)
  
  describe("provider-specific workspace priority", function()
    it("should use turborepo workspace priority", function()
      local test_dir = vim.fn.tempname()
      create_test_monorepo(test_dir, "turborepo", {
        ["apps/web/package.json"] = { '{"name": "web"}' },
        ["packages/ui/package.json"] = { '{"name": "ui"}' }
      })
      
      local config = { enabled = true, providers = monorepo.DEFAULT_MONOREPO_CONFIG.providers }
      local root_path, detected_info = monorepo.detect_monorepo_root(test_dir, config)
      local workspaces = monorepo.get_workspaces(root_path, config, detected_info)
      
      -- Apps should come before packages in turborepo
      assert.equals("apps", workspaces[1].type)
      assert.equals("packages", workspaces[2].type)
      
      cleanup_test_monorepo(test_dir)
    end)
    
    it("should use nx workspace priority", function()
      local test_dir = vim.fn.tempname()
      create_test_monorepo(test_dir, "nx", {
        ["libs/shared/package.json"] = { '{"name": "shared"}' },
        ["apps/web/package.json"] = { '{"name": "web"}' }
      })
      
      local config = { enabled = true, providers = monorepo.DEFAULT_MONOREPO_CONFIG.providers }
      local root_path, detected_info = monorepo.detect_monorepo_root(test_dir, config)
      local workspaces = monorepo.get_workspaces(root_path, config, detected_info)
      
      -- Apps should come before libs in nx
      assert.equals("apps", workspaces[1].type)
      assert.equals("libs", workspaces[2].type)
      
      cleanup_test_monorepo(test_dir)
    end)
  end)
  
  describe("custom provider configuration", function()
    it("should support custom provider configuration", function()
      local test_dir = vim.fn.tempname()
      
      -- Create a custom provider config
      local custom_config = {
        enabled = true,
        auto_switch = true,
        providers = {
          {
            name = "custom",
            detection = {
              strategies = { "file_markers" },
              file_markers = { "custom.json" },
              max_depth = 3,
              cache_duration = 60000,
            },
            workspace_patterns = { "modules/*", "services/*" },
            workspace_priority = { "services", "modules" },
            env_resolution = {
              strategy = "workspace_first",
              inheritance = true,
              override_order = { "workspace", "root" }
            },
            priority = 1,
          }
        }
      }
      
      -- Create test structure
      vim.fn.mkdir(test_dir, "p")
      vim.fn.writefile({ '{"custom": true}' }, test_dir .. "/custom.json")
      vim.fn.mkdir(test_dir .. "/modules/auth", "p")
      vim.fn.writefile({ '{"name": "auth"}' }, test_dir .. "/modules/auth/package.json")
      vim.fn.mkdir(test_dir .. "/services/api", "p")
      vim.fn.writefile({ '{"name": "api"}' }, test_dir .. "/services/api/package.json")
      
      local root_path, detected_info = monorepo.detect_monorepo_root(test_dir, custom_config)
      
      assert.equals(test_dir, root_path)
      assert.equals("custom", detected_info.provider.name)
      
      local workspaces = monorepo.get_workspaces(root_path, custom_config, detected_info)
      
      -- Should find both workspaces, with services prioritized over modules
      assert.equals(2, #workspaces)
      assert.equals("services", workspaces[1].type)
      assert.equals("modules", workspaces[2].type)
      
      cleanup_test_monorepo(test_dir)
    end)
  end)
  
  describe("boolean configuration", function()
    it("should return nil when monorepo is disabled by default", function()
      local test_dir = vim.fn.tempname()
      create_test_monorepo(test_dir, "turborepo", {
        ["apps/web/package.json"] = { '{"name": "web"}' }
      })
      
      -- Without config, should return nil (disabled by default)
      local root_path, detected_info = monorepo.detect_monorepo_root(test_dir)
      assert.is_nil(root_path)
      assert.is_nil(detected_info)
      
      cleanup_test_monorepo(test_dir)
    end)
    
    it("should work with monorepo = true", function()
      local test_dir = vim.fn.tempname()
      create_test_monorepo(test_dir, "turborepo", {
        ["apps/web/package.json"] = { '{"name": "web"}' }
      })
      
      -- Test the integration function with monorepo = true
      local ecolog_config = { monorepo = true }
      local modified_config = monorepo.integrate_with_ecolog_config(ecolog_config)
      
      -- Should not be modified if no monorepo detected in test environment
      -- But the function should handle the boolean correctly
      assert.is_not_nil(modified_config)
      
      cleanup_test_monorepo(test_dir)
    end)
    
    it("should work with monorepo = false", function()
      local test_dir = vim.fn.tempname()
      create_test_monorepo(test_dir, "turborepo", {
        ["apps/web/package.json"] = { '{"name": "web"}' }
      })
      
      -- Test the integration function with monorepo = false
      local ecolog_config = { monorepo = false }
      local modified_config = monorepo.integrate_with_ecolog_config(ecolog_config)
      
      -- Should return config unchanged when disabled
      assert.equals(ecolog_config, modified_config)
      
      cleanup_test_monorepo(test_dir)
    end)
  end)
end)