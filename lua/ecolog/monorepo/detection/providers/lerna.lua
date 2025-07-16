---@class LernaProvider : MonorepoBaseProvider
local LernaProvider = {}

local BaseProvider = require("ecolog.monorepo.detection.providers.base")

-- Inherit from BaseProvider
setmetatable(LernaProvider, { __index = BaseProvider })

---Create a new Lerna provider instance
---@param config? ProviderConfig Optional provider configuration
---@return LernaProvider provider New provider instance
function LernaProvider.new(config)
  -- Default configuration for Lerna
  local default_config = {
    name = "lerna",
    detection = {
      strategies = { "file_markers" },
      file_markers = { "lerna.json" },
      max_depth = 4,
      cache_duration = 300000, -- 5 minutes
    },
    workspace = {
      patterns = { "packages/*" },
      priority = { "packages" },
    },
    env_resolution = {
      strategy = "workspace_first",
      inheritance = true,
      override_order = { "workspace", "root" },
    },
    priority = 3, -- Medium priority for Lerna detection
  }

  -- Merge with provided config
  local merged_config = config and vim.tbl_deep_extend("force", default_config, config) or default_config

  -- Validate configuration
  local valid, error_msg = BaseProvider.validate_config(merged_config)
  if not valid then
    error("Invalid Lerna provider configuration: " .. error_msg)
  end

  local instance = BaseProvider.new(merged_config)
  setmetatable(instance, { __index = LernaProvider })
  return instance
end

---Check if this provider can detect Lerna at given path
---@param path string Directory path to check
---@return boolean can_detect Whether provider can detect Lerna
---@return number confidence Detection confidence (0-100)
---@return table? metadata Additional detection metadata
function LernaProvider:detect(path)
  local lerna_json_path = path .. "/lerna.json"

  if not self:file_exists(lerna_json_path) then
    return false, 0, nil
  end

  -- Parse lerna.json to get additional metadata
  local lerna_config = self:read_json_file(lerna_json_path)
  local metadata = {
    marker_file = "lerna.json",
    lerna_config = lerna_config,
  }

  local confidence = 95 -- High confidence for lerna.json presence

  -- Increase confidence if lerna.json has expected structure
  if lerna_config then
    if lerna_config.packages then
      confidence = 99
      metadata.has_packages = true
      metadata.package_patterns = lerna_config.packages
    end

    -- Extract Lerna version if available
    if lerna_config.version then
      metadata.lerna_version = lerna_config.version
    end

    -- Extract command configuration
    if lerna_config.command then
      metadata.command_config = lerna_config.command
    end

    -- Extract npmClient
    if lerna_config.npmClient then
      metadata.npm_client = lerna_config.npmClient
    end

    -- Check for independent versioning
    if lerna_config.independent then
      metadata.independent_versioning = true
    end
  end

  return true, confidence, metadata
end

---Get Lerna-specific workspace patterns
---@return string[] patterns Enhanced workspace patterns for Lerna
function LernaProvider:get_workspace_patterns()
  local base_patterns = BaseProvider.get_workspace_patterns(self)

  -- Lerna commonly uses these patterns
  local lerna_patterns = {
    "packages/*",
    "libs/*",
    "modules/*",
  }

  -- Merge and deduplicate
  local all_patterns = vim.deepcopy(base_patterns)
  for _, pattern in ipairs(lerna_patterns) do
    if not vim.tbl_contains(all_patterns, pattern) then
      table.insert(all_patterns, pattern)
    end
  end

  return all_patterns
end

---Get dynamic workspace patterns based on lerna.json configuration
---@param detection_metadata table? Metadata from detection phase
---@return string[] patterns Workspace patterns customized for this Lerna workspace
function LernaProvider:get_dynamic_workspace_patterns(detection_metadata)
  local patterns = self:get_workspace_patterns()

  if detection_metadata and detection_metadata.lerna_config and detection_metadata.lerna_config.packages then
    local custom_patterns = detection_metadata.lerna_config.packages

    -- Merge custom patterns with defaults
    for _, pattern in ipairs(custom_patterns) do
      if not vim.tbl_contains(patterns, pattern) then
        table.insert(patterns, pattern)
      end
    end
  end

  return patterns
end

---Get enhanced environment resolution for Lerna
---@return ProviderEnvConfig env_config Enhanced environment configuration
function LernaProvider:get_env_resolution()
  local base_config = BaseProvider.get_env_resolution(self)

  -- Lerna-specific enhancements
  return vim.tbl_deep_extend("force", base_config, {
    -- Lerna typically uses package-specific configurations
    strategy = "workspace_first",
    inheritance = true,
    override_order = { "workspace", "root" },
  })
end

---Validate Lerna-specific configuration
---@param config table Configuration to validate
---@return boolean valid Whether configuration is valid
---@return string? error Error message if invalid
function LernaProvider.validate_config(config)
  -- First run base validation
  local valid, error_msg = BaseProvider.validate_config(config)
  if not valid then
    return false, error_msg
  end

  -- Lerna-specific validation
  if config.name ~= "lerna" then
    return false, "Provider name must be 'lerna'"
  end

  if not vim.tbl_contains(config.detection.file_markers, "lerna.json") then
    return false, "Lerna provider must include 'lerna.json' in file_markers"
  end

  return true, nil
end

---Get provider-specific metadata
---@return table metadata Provider information and capabilities
function LernaProvider:get_metadata()
  return {
    name = "Lerna",
    description = "A tool for managing JavaScript projects with multiple packages",
    website = "https://lerna.js.org",
    supported_languages = { "javascript", "typescript" },
    features = {
      version_management = true,
      package_publishing = true,
      dependency_management = true,
      bootstrap = true,
    },
  }
end

return LernaProvider

