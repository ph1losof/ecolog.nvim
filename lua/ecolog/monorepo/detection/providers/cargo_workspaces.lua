---@class CargoWorkspacesProvider : MonorepoBaseProvider
local CargoWorkspacesProvider = {}

local BaseProvider = require("ecolog.monorepo.detection.providers.base")

-- Inherit from BaseProvider
setmetatable(CargoWorkspacesProvider, { __index = BaseProvider })

---Create a new Cargo Workspaces provider instance
---@param config? ProviderConfig Optional provider configuration
---@return CargoWorkspacesProvider provider New provider instance
function CargoWorkspacesProvider.new(config)
  -- Default configuration for Cargo Workspaces
  local default_config = {
    name = "cargo_workspaces",
    detection = {
      strategies = { "file_markers" },
      file_markers = { "Cargo.toml" },
      max_depth = 4,
      cache_duration = 300000, -- 5 minutes
    },
    workspace = {
      patterns = { "crates/*", "libs/*", "bins/*" },
      priority = { "bins", "crates", "libs" },
    },
    env_resolution = {
      strategy = "workspace_first",
      inheritance = true,
      override_order = { "workspace", "root" },
    },
    priority = 6, -- Lower priority since Cargo.toml is common
  }

  -- Merge with provided config
  local merged_config = config and vim.tbl_deep_extend("force", default_config, config) or default_config

  -- Validate configuration
  local valid, error_msg = BaseProvider.validate_config(merged_config)
  if not valid then
    error("Invalid Cargo Workspaces provider configuration: " .. error_msg)
  end

  local instance = BaseProvider.new(merged_config)
  setmetatable(instance, { __index = CargoWorkspacesProvider })
  return instance
end

---Parse TOML file contents
---@param file_path string Path to TOML file
---@return table? content Parsed TOML content or nil if failed
function CargoWorkspacesProvider:read_toml_file(file_path)
  if not self:file_exists(file_path) then
    return nil
  end

  local success, content = pcall(vim.fn.readfile, file_path)
  if not success or not content then
    return nil
  end

  local toml_str = table.concat(content, "\n")

  -- Simple TOML parsing for workspace detection
  -- This is a basic implementation - in practice, you might want to use a proper TOML parser
  local parsed = {}
  local current_section = nil

  for line in toml_str:gmatch("[^\r\n]+") do
    line = line:match("^%s*(.-)%s*$") -- trim whitespace

    if line == "" or line:match("^#") then
      -- Skip empty lines and comments
    elseif line:match("^%[(.+)%]$") then
      -- Section header
      current_section = line:match("^%[(.+)%]$")
      if not parsed[current_section] then
        parsed[current_section] = {}
      end
    elseif line:match("^(%w+)%s*=%s*(.+)$") then
      -- Key-value pair
      local key, value = line:match("^(%w+)%s*=%s*(.+)$")

      -- Simple value parsing
      if value:match('^"(.*)"$') then
        value = value:match('^"(.*)"$')
      elseif value:match("^%[(.*)%]$") then
        -- Array value - simple parsing
        local array_content = value:match("^%[(.*)%]$")
        value = {}
        for item in array_content:gmatch('"([^"]*)"') do
          table.insert(value, item)
        end
      end

      if current_section then
        parsed[current_section][key] = value
      else
        parsed[key] = value
      end
    end
  end

  return parsed
end

---Check if this provider can detect Cargo Workspaces at given path
---@param path string Directory path to check
---@return boolean can_detect Whether provider can detect Cargo Workspaces
---@return number confidence Detection confidence (0-100)
---@return table? metadata Additional detection metadata
function CargoWorkspacesProvider:detect(path)
  local cargo_toml_path = path .. "/Cargo.toml"

  if not self:file_exists(cargo_toml_path) then
    return false, 0, nil
  end

  -- Parse Cargo.toml to check for workspace
  local cargo_config = self:read_toml_file(cargo_toml_path)
  if not cargo_config then
    return false, 0, nil
  end

  -- Check for workspace section
  if not cargo_config.workspace then
    return false, 0, nil
  end

  local metadata = {
    marker_file = "Cargo.toml",
    cargo_config = cargo_config,
  }

  local confidence = 90 -- High confidence for workspace section

  -- Analyze workspace configuration
  if cargo_config.workspace.members then
    metadata.workspace_members = cargo_config.workspace.members
    confidence = 95
  end

  if cargo_config.workspace.exclude then
    metadata.workspace_exclude = cargo_config.workspace.exclude
  end

  if cargo_config.workspace.dependencies then
    metadata.has_workspace_dependencies = true
    confidence = confidence + 2
  end

  -- Check for Cargo.lock
  if self:file_exists(path .. "/Cargo.lock") then
    metadata.has_cargo_lock = true
    confidence = confidence + 2
  end

  -- Extract package information if available
  if cargo_config.package then
    if cargo_config.package.name then
      metadata.workspace_name = cargo_config.package.name
    end
    if cargo_config.package.version then
      metadata.workspace_version = cargo_config.package.version
    end
  end

  return true, math.min(confidence, 99), metadata
end

---Get Cargo Workspaces-specific workspace patterns
---@return string[] patterns Enhanced workspace patterns for Cargo Workspaces
function CargoWorkspacesProvider:get_workspace_patterns()
  local base_patterns = BaseProvider.get_workspace_patterns(self)

  -- Cargo Workspaces commonly uses these patterns
  local cargo_patterns = {
    "crates/*",
    "libs/*",
    "bins/*",
    "examples/*",
    "tools/*",
  }

  -- Merge and deduplicate
  local all_patterns = vim.deepcopy(base_patterns)
  for _, pattern in ipairs(cargo_patterns) do
    if not vim.tbl_contains(all_patterns, pattern) then
      table.insert(all_patterns, pattern)
    end
  end

  return all_patterns
end

---Get dynamic workspace patterns based on Cargo.toml configuration
---@param detection_metadata table? Metadata from detection phase
---@return string[] patterns Workspace patterns customized for this Cargo workspace
function CargoWorkspacesProvider:get_dynamic_workspace_patterns(detection_metadata)
  local patterns = self:get_workspace_patterns()

  if detection_metadata and detection_metadata.workspace_members then
    local custom_patterns = {}

    -- Convert workspace members to patterns
    for _, member in ipairs(detection_metadata.workspace_members) do
      -- Handle both direct paths and glob patterns
      if member:match("%*") then
        table.insert(custom_patterns, member)
      else
        -- Convert direct path to pattern
        local parent = member:match("(.+)/[^/]+$")
        if parent then
          table.insert(custom_patterns, parent .. "/*")
        end
      end
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

---Get enhanced environment resolution for Cargo Workspaces
---@return ProviderEnvConfig env_config Enhanced environment configuration
function CargoWorkspacesProvider:get_env_resolution()
  local base_config = BaseProvider.get_env_resolution(self)

  -- Cargo Workspaces-specific enhancements
  return vim.tbl_deep_extend("force", base_config, {
    -- Cargo workspaces typically use crate-specific configurations
    strategy = "workspace_first",
    inheritance = true,
    override_order = { "workspace", "root" },
  })
end

---Validate Cargo Workspaces-specific configuration
---@param config table Configuration to validate
---@return boolean valid Whether configuration is valid
---@return string? error Error message if invalid
function CargoWorkspacesProvider.validate_config(config)
  -- First run base validation
  local valid, error_msg = BaseProvider.validate_config(config)
  if not valid then
    return false, error_msg
  end

  -- Cargo Workspaces-specific validation
  if config.name ~= "cargo_workspaces" then
    return false, "Provider name must be 'cargo_workspaces'"
  end

  if not vim.tbl_contains(config.detection.file_markers, "Cargo.toml") then
    return false, "Cargo Workspaces provider must include 'Cargo.toml' in file_markers"
  end

  return true, nil
end

---Get provider-specific metadata
---@return table metadata Provider information and capabilities
function CargoWorkspacesProvider:get_metadata()
  return {
    name = "Cargo Workspaces",
    description = "Rust's built-in workspace management system",
    website = "https://doc.rust-lang.org/book/ch14-03-cargo-workspaces.html",
    supported_languages = { "rust" },
    features = {
      dependency_management = true,
      shared_dependencies = true,
      unified_builds = true,
      workspace_inheritance = true,
    },
  }
end

return CargoWorkspacesProvider

