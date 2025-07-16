---@class YarnWorkspacesProvider : MonorepoBaseProvider
local YarnWorkspacesProvider = {}

local BaseProvider = require("ecolog.monorepo.detection.providers.base")

-- Inherit from BaseProvider
setmetatable(YarnWorkspacesProvider, { __index = BaseProvider })

---Create a new Yarn Workspaces provider instance
---@param config? ProviderConfig Optional provider configuration
---@return YarnWorkspacesProvider provider New provider instance
function YarnWorkspacesProvider.new(config)
  -- Default configuration for Yarn Workspaces
  local default_config = {
    name = "yarn_workspaces",
    detection = {
      strategies = { "file_markers" },
      file_markers = { "package.json" },
      max_depth = 4,
      cache_duration = 300000, -- 5 minutes
    },
    workspace = {
      patterns = { "packages/*", "apps/*", "services/*" },
      priority = { "apps", "packages", "services" },
    },
    env_resolution = {
      strategy = "workspace_first",
      inheritance = true,
      override_order = { "workspace", "root" },
    },
    priority = 5, -- Lower priority since package.json is common
  }

  -- Merge with provided config
  local merged_config = config and vim.tbl_deep_extend("force", default_config, config) or default_config

  -- Validate configuration
  local valid, error_msg = BaseProvider.validate_config(merged_config)
  if not valid then
    error("Invalid Yarn Workspaces provider configuration: " .. error_msg)
  end

  local instance = BaseProvider.new(merged_config)
  setmetatable(instance, { __index = YarnWorkspacesProvider })
  return instance
end

---Check if this provider can detect Yarn Workspaces at given path
---@param path string Directory path to check
---@return boolean can_detect Whether provider can detect Yarn Workspaces
---@return number confidence Detection confidence (0-100)
---@return table? metadata Additional detection metadata
function YarnWorkspacesProvider:detect(path)
  local package_json_path = path .. "/package.json"

  if not self:file_exists(package_json_path) then
    return false, 0, nil
  end

  -- Parse package.json to check for workspaces
  local package_config = self:read_json_file(package_json_path)
  if not package_config then
    return false, 0, nil
  end

  -- Check for workspaces field
  if not package_config.workspaces then
    return false, 0, nil
  end

  local metadata = {
    marker_file = "package.json",
    package_config = package_config,
  }

  local confidence = 85 -- Good confidence for workspaces field

  -- Analyze workspaces configuration
  if type(package_config.workspaces) == "table" then
    if package_config.workspaces.packages then
      -- Yarn/npm workspaces format
      metadata.workspace_patterns = package_config.workspaces.packages
      metadata.workspace_format = "yarn"
      confidence = 90
    elseif vim.islist(package_config.workspaces) then
      -- Simple array format
      metadata.workspace_patterns = package_config.workspaces
      metadata.workspace_format = "simple"
      confidence = 88
    end

    -- Check for nohoist configuration
    if package_config.workspaces.nohoist then
      metadata.nohoist = package_config.workspaces.nohoist
    end
  end

  -- Check for yarn.lock to increase confidence
  if self:file_exists(path .. "/yarn.lock") then
    metadata.has_yarn_lock = true
    metadata.package_manager = "yarn"
    confidence = confidence + 5
  end

  -- Check for npm-workspaces
  if self:file_exists(path .. "/package-lock.json") then
    metadata.has_package_lock = true
    metadata.package_manager = "npm"
    confidence = confidence + 3
  end

  -- Check for pnpm-workspace.yaml
  if self:file_exists(path .. "/pnpm-workspace.yaml") then
    metadata.has_pnpm_workspace = true
    metadata.package_manager = "pnpm"
    confidence = confidence + 5
  end

  -- Extract other relevant metadata
  if package_config.name then
    metadata.workspace_name = package_config.name
  end

  if package_config.private then
    metadata.is_private = true
    confidence = confidence + 2
  end

  return true, math.min(confidence, 99), metadata
end

---Get Yarn Workspaces-specific workspace patterns
---@return string[] patterns Enhanced workspace patterns for Yarn Workspaces
function YarnWorkspacesProvider:get_workspace_patterns()
  local base_patterns = BaseProvider.get_workspace_patterns(self)

  -- Yarn Workspaces commonly uses these patterns
  local yarn_patterns = {
    "packages/*",
    "apps/*",
    "services/*",
    "libs/*",
    "tools/*",
  }

  -- Merge and deduplicate
  local all_patterns = vim.deepcopy(base_patterns)
  for _, pattern in ipairs(yarn_patterns) do
    if not vim.tbl_contains(all_patterns, pattern) then
      table.insert(all_patterns, pattern)
    end
  end

  return all_patterns
end

---Get dynamic workspace patterns based on package.json configuration
---@param detection_metadata table? Metadata from detection phase
---@return string[] patterns Workspace patterns customized for this Yarn workspace
function YarnWorkspacesProvider:get_dynamic_workspace_patterns(detection_metadata)
  local patterns = self:get_workspace_patterns()

  if detection_metadata and detection_metadata.workspace_patterns then
    local custom_patterns = detection_metadata.workspace_patterns

    -- Merge custom patterns with defaults
    for _, pattern in ipairs(custom_patterns) do
      if not vim.tbl_contains(patterns, pattern) then
        table.insert(patterns, pattern)
      end
    end
  end

  return patterns
end

---Get enhanced environment resolution for Yarn Workspaces
---@return ProviderEnvConfig env_config Enhanced environment configuration
function YarnWorkspacesProvider:get_env_resolution()
  local base_config = BaseProvider.get_env_resolution(self)

  -- Yarn Workspaces-specific enhancements
  return vim.tbl_deep_extend("force", base_config, {
    -- Yarn workspaces typically use workspace-specific configurations
    strategy = "workspace_first",
    inheritance = true,
    override_order = { "workspace", "root" },
  })
end

---Validate Yarn Workspaces-specific configuration
---@param config table Configuration to validate
---@return boolean valid Whether configuration is valid
---@return string? error Error message if invalid
function YarnWorkspacesProvider.validate_config(config)
  -- First run base validation
  local valid, error_msg = BaseProvider.validate_config(config)
  if not valid then
    return false, error_msg
  end

  -- Yarn Workspaces-specific validation
  if config.name ~= "yarn_workspaces" then
    return false, "Provider name must be 'yarn_workspaces'"
  end

  if not vim.tbl_contains(config.detection.file_markers, "package.json") then
    return false, "Yarn Workspaces provider must include 'package.json' in file_markers"
  end

  return true, nil
end

---Get provider-specific metadata
---@return table metadata Provider information and capabilities
function YarnWorkspacesProvider:get_metadata()
  return {
    name = "Yarn Workspaces",
    description = "Yarn's built-in monorepo management system",
    website = "https://yarnpkg.com/features/workspaces",
    supported_languages = { "javascript", "typescript" },
    features = {
      dependency_hoisting = true,
      workspace_isolation = true,
      parallel_execution = true,
      version_constraints = true,
    },
  }
end

return YarnWorkspacesProvider

