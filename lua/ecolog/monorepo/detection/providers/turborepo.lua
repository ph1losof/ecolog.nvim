---@class TurborepoProvider : MonorepoBaseProvider
local TurborepoProvider = {}

local BaseProvider = require("ecolog.monorepo.detection.providers.base")

-- Inherit from BaseProvider
setmetatable(TurborepoProvider, { __index = BaseProvider })

---Create a new Turborepo provider instance
---@param config? ProviderConfig Optional provider configuration
---@return TurborepoProvider provider New provider instance
function TurborepoProvider.new(config)
  -- Default configuration for Turborepo
  local default_config = {
    name = "turborepo",
    detection = {
      strategies = { "file_markers" },
      file_markers = { "turbo.json" },
      max_depth = 4,
      cache_duration = 300000, -- 5 minutes
    },
    workspace = {
      patterns = { "apps/*", "packages/*" },
      priority = { "apps", "packages" },
    },
    env_resolution = {
      strategy = "workspace_first",
      inheritance = true,
      override_order = { "workspace", "root" },
    },
    priority = 1, -- High priority for Turborepo detection
  }

  -- Merge with provided config
  local merged_config = config and vim.tbl_deep_extend("force", default_config, config) or default_config

  -- Validate configuration
  local valid, error_msg = BaseProvider.validate_config(merged_config)
  if not valid then
    error("Invalid Turborepo provider configuration: " .. error_msg)
  end

  local instance = BaseProvider.new(merged_config)
  setmetatable(instance, { __index = TurborepoProvider })
  return instance
end

---Check if this provider can detect Turborepo at given path
---@param path string Directory path to check
---@return boolean can_detect Whether provider can detect Turborepo
---@return number confidence Detection confidence (0-100)
---@return table? metadata Additional detection metadata
function TurborepoProvider:detect(path)
  local turbo_json_path = path .. "/turbo.json"

  if not self:file_exists(turbo_json_path) then
    return false, 0, nil
  end

  -- Parse turbo.json to get additional metadata
  local turbo_config = self:read_json_file(turbo_json_path)
  local metadata = {
    marker_file = "turbo.json",
    turbo_config = turbo_config,
  }

  local confidence = 95 -- High confidence for turbo.json presence

  -- Increase confidence if turbo.json has expected structure
  if turbo_config then
    if turbo_config.pipeline or turbo_config.tasks then
      confidence = 99
      metadata.has_pipeline = turbo_config.pipeline ~= nil
      metadata.has_tasks = turbo_config.tasks ~= nil
    end

    -- Extract remote cache info if available
    if turbo_config.remoteCache then
      metadata.remote_cache = turbo_config.remoteCache
    end

    -- Extract package manager info
    if turbo_config.packageManager then
      metadata.package_manager = turbo_config.packageManager
    end
  end

  return true, confidence, metadata
end

---Get Turborepo-specific workspace patterns
---@return string[] patterns Enhanced workspace patterns for Turborepo
function TurborepoProvider:get_workspace_patterns()
  local base_patterns = BaseProvider.get_workspace_patterns(self)

  -- Turborepo commonly uses these patterns
  local turborepo_patterns = {
    "apps/*",
    "packages/*",
    "tools/*",
    "examples/*",
  }

  -- Merge and deduplicate
  local all_patterns = vim.deepcopy(base_patterns)
  for _, pattern in ipairs(turborepo_patterns) do
    if not vim.tbl_contains(all_patterns, pattern) then
      table.insert(all_patterns, pattern)
    end
  end

  return all_patterns
end

---Get package manager files for workspace validation
---@return string[] package_managers List of package manager files
function TurborepoProvider:get_package_managers()
  -- For Turborepo, workspaces should have package.json files
  -- The turbo.json file is only at the root level
  return { "package.json" }
end

---Get enhanced environment resolution for Turborepo
---@return ProviderEnvConfig env_config Enhanced environment configuration
function TurborepoProvider:get_env_resolution()
  local base_config = BaseProvider.get_env_resolution(self)

  -- Turborepo-specific enhancements
  return vim.tbl_deep_extend("force", base_config, {
    -- Turborepo typically prioritizes workspace-specific configs
    strategy = "workspace_first",
    inheritance = true,
    override_order = { "workspace", "root" },
  })
end

---Validate Turborepo-specific configuration
---@param config table Configuration to validate
---@return boolean valid Whether configuration is valid
---@return string? error Error message if invalid
function TurborepoProvider.validate_config(config)
  -- First run base validation
  local valid, error_msg = BaseProvider.validate_config(config)
  if not valid then
    return false, error_msg
  end

  -- Turborepo-specific validation
  if config.name ~= "turborepo" then
    return false, "Provider name must be 'turborepo'"
  end

  if not vim.tbl_contains(config.detection.file_markers, "turbo.json") then
    return false, "Turborepo provider must include 'turbo.json' in file_markers"
  end

  return true, nil
end

---Get package manager files for workspace detection
---@return string[] package_managers List of package manager files
function TurborepoProvider:get_package_managers()
  -- For workspace detection, look for package.json files
  return { "package.json" }
end

---Get provider-specific metadata
---@return table metadata Provider information and capabilities
function TurborepoProvider:get_metadata()
  return {
    name = "Turborepo",
    description = "Vercel's build system for JavaScript/TypeScript monorepos",
    website = "https://turbo.build/repo",
    supported_languages = { "javascript", "typescript" },
    features = {
      remote_caching = true,
      task_scheduling = true,
      dependency_graph = true,
    },
  }
end

return TurborepoProvider

