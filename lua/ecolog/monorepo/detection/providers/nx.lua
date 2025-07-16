---@class NxProvider : MonorepoBaseProvider
local NxProvider = {}

local BaseProvider = require("ecolog.monorepo.detection.providers.base")

-- Inherit from BaseProvider
setmetatable(NxProvider, { __index = BaseProvider })

---Create a new NX provider instance
---@param config? ProviderConfig Optional provider configuration
---@return NxProvider provider New provider instance
function NxProvider.new(config)
  -- Default configuration for NX
  local default_config = {
    name = "nx",
    detection = {
      strategies = { "file_markers" },
      file_markers = { "nx.json", "workspace.json" },
      max_depth = 4,
      cache_duration = 300000, -- 5 minutes
    },
    workspace = {
      patterns = { "apps/*", "libs/*", "tools/*", "e2e/*" },
      priority = { "apps", "libs", "tools", "e2e" },
    },
    env_resolution = {
      strategy = "workspace_first",
      inheritance = true,
      override_order = { "workspace", "root" },
    },
    priority = 2, -- High priority for NX detection
  }

  -- Merge with provided config
  local merged_config = config and vim.tbl_deep_extend("force", default_config, config) or default_config

  -- Validate configuration
  local valid, error_msg = BaseProvider.validate_config(merged_config)
  if not valid then
    error("Invalid NX provider configuration: " .. error_msg)
  end

  local instance = BaseProvider.new(merged_config)
  setmetatable(instance, { __index = NxProvider })
  return instance
end

---Check if this provider can detect NX at given path
---@param path string Directory path to check
---@return boolean can_detect Whether provider can detect NX
---@return number confidence Detection confidence (0-100)
---@return table? metadata Additional detection metadata
function NxProvider:detect(path)
  local nx_json_path = path .. "/nx.json"
  local workspace_json_path = path .. "/workspace.json"

  local has_nx_json = self:file_exists(nx_json_path)
  local has_workspace_json = self:file_exists(workspace_json_path)

  if not has_nx_json and not has_workspace_json then
    return false, 0, nil
  end

  local metadata = {
    marker_files = {},
  }
  local confidence = 80 -- Base confidence for NX detection

  -- Parse nx.json for additional metadata
  if has_nx_json then
    table.insert(metadata.marker_files, "nx.json")
    local nx_config = self:read_json_file(nx_json_path)
    if nx_config then
      metadata.nx_config = nx_config
      confidence = confidence + 10

      -- Extract NX version and features
      if nx_config.extends then
        metadata.extends = nx_config.extends
      end

      if nx_config.tasksRunnerOptions then
        metadata.has_task_runner = true
        confidence = confidence + 5
      end

      if nx_config.implicitDependencies then
        metadata.has_implicit_deps = true
      end

      if nx_config.workspaceLayout then
        metadata.workspace_layout = nx_config.workspaceLayout
        -- Use custom layout for workspace patterns if available
        if nx_config.workspaceLayout.appsDir then
          metadata.custom_apps_dir = nx_config.workspaceLayout.appsDir
        end
        if nx_config.workspaceLayout.libsDir then
          metadata.custom_libs_dir = nx_config.workspaceLayout.libsDir
        end
      end
    end
  end

  -- Parse workspace.json for project information
  if has_workspace_json then
    table.insert(metadata.marker_files, "workspace.json")
    local workspace_config = self:read_json_file(workspace_json_path)
    if workspace_config then
      metadata.workspace_config = workspace_config
      confidence = confidence + 5

      if workspace_config.projects then
        metadata.project_count = 0
        for _ in pairs(workspace_config.projects) do
          metadata.project_count = metadata.project_count + 1
        end
        if metadata.project_count > 0 then
          confidence = confidence + 5
        end
      end
    end
  end

  return true, math.min(confidence, 99), metadata
end

---Get NX-specific workspace patterns
---@return string[] patterns Enhanced workspace patterns for NX
function NxProvider:get_workspace_patterns()
  local base_patterns = BaseProvider.get_workspace_patterns(self)

  -- NX commonly uses these patterns
  local nx_patterns = {
    "apps/*",
    "libs/*",
    "tools/*",
    "e2e/*",
  }

  -- Check if we have custom workspace layout from detection metadata
  -- This would require access to detection results, for now use defaults

  -- Merge and deduplicate
  local all_patterns = vim.deepcopy(base_patterns)
  for _, pattern in ipairs(nx_patterns) do
    if not vim.tbl_contains(all_patterns, pattern) then
      table.insert(all_patterns, pattern)
    end
  end

  return all_patterns
end

---Get enhanced workspace patterns based on NX configuration
---@param detection_metadata table? Metadata from detection phase
---@return string[] patterns Workspace patterns customized for this NX workspace
function NxProvider:get_dynamic_workspace_patterns(detection_metadata)
  local patterns = self:get_workspace_patterns()

  if detection_metadata and detection_metadata.workspace_layout then
    local layout = detection_metadata.workspace_layout
    local custom_patterns = {}

    if layout.appsDir then
      table.insert(custom_patterns, layout.appsDir .. "/*")
    end

    if layout.libsDir then
      table.insert(custom_patterns, layout.libsDir .. "/*")
    end

    -- Merge custom patterns with defaults
    for _, pattern in ipairs(custom_patterns) do
      if not vim.tbl_contains(patterns, pattern) then
        table.insert(patterns, pattern)
      end
    end
  end

  return patterns
end

---Get enhanced environment resolution for NX
---@return ProviderEnvConfig env_config Enhanced environment configuration
function NxProvider:get_env_resolution()
  local base_config = BaseProvider.get_env_resolution(self)

  -- NX-specific enhancements
  return vim.tbl_deep_extend("force", base_config, {
    -- NX typically uses project-specific configurations
    strategy = "workspace_first",
    inheritance = true,
    override_order = { "workspace", "root" },
  })
end

---Validate NX-specific configuration
---@param config table Configuration to validate
---@return boolean valid Whether configuration is valid
---@return string? error Error message if invalid
function NxProvider.validate_config(config)
  -- First run base validation
  local valid, error_msg = BaseProvider.validate_config(config)
  if not valid then
    return false, error_msg
  end

  -- NX-specific validation
  if config.name ~= "nx" then
    return false, "Provider name must be 'nx'"
  end

  local has_nx_marker = vim.tbl_contains(config.detection.file_markers, "nx.json")
  local has_workspace_marker = vim.tbl_contains(config.detection.file_markers, "workspace.json")

  if not has_nx_marker and not has_workspace_marker then
    return false, "NX provider must include 'nx.json' or 'workspace.json' in file_markers"
  end

  return true, nil
end

---Get package manager files for workspace detection
---@return string[] package_managers List of package manager files
function NxProvider:get_package_managers()
  -- For workspace detection, look for package.json files
  return { "package.json" }
end

---Get provider-specific metadata
---@return table metadata Provider information and capabilities
function NxProvider:get_metadata()
  return {
    name = "NX",
    description = "Smart, fast and extensible build system",
    website = "https://nx.dev",
    supported_languages = { "javascript", "typescript", "angular", "react", "vue", "node" },
    features = {
      smart_rebuilds = true,
      distributed_caching = true,
      code_generation = true,
      dependency_graph = true,
      affected_commands = true,
    },
  }
end

return NxProvider

