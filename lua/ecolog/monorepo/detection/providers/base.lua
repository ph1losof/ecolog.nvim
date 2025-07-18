---@class MonorepoBaseProvider
---@field name string Provider name
---@field priority number Priority for provider selection (lower = higher priority)
---@field cache_key_prefix string Prefix for cache keys
local BaseProvider = {}
BaseProvider.__index = BaseProvider

---@class ProviderDetectionConfig
---@field strategies string[] Detection strategies
---@field file_markers string[] Files that indicate workspace roots
---@field max_depth number Maximum depth to search for workspaces
---@field cache_duration number Cache duration in milliseconds

---@class ProviderWorkspaceConfig
---@field patterns string[] Workspace patterns to search for
---@field priority string[] Priority order for workspace types

---@class ProviderEnvConfig
---@field strategy string Resolution strategy
---@field inheritance boolean Whether workspace envs inherit from root
---@field override_order string[] Order of environment file precedence

---@class ProviderConfig
---@field name string Provider name
---@field detection ProviderDetectionConfig Detection configuration
---@field workspace ProviderWorkspaceConfig Workspace configuration
---@field env_resolution ProviderEnvConfig Environment resolution configuration
---@field priority number Provider selection priority

---Create a new provider instance
---@param config ProviderConfig Provider configuration
---@return MonorepoBaseProvider
function BaseProvider.new(config)
  local instance = setmetatable({}, BaseProvider)
  instance.name = config.name
  instance.priority = config.priority or 50
  instance.cache_key_prefix = "provider:" .. config.name .. ":"
  instance.config = config
  
  -- Add convenience properties for backward compatibility
  instance.workspace_patterns = config.workspace and config.workspace.patterns or {}
  instance.workspace_priority = config.workspace and config.workspace.priority or {}
  
  return instance
end

---Check if this provider can detect monorepo at given path
---@param path string Directory path to check
---@return boolean can_detect Whether provider can detect monorepo
---@return number confidence Detection confidence (0-100)
---@return table? metadata Additional detection metadata
function BaseProvider:detect(path)
  error("detect() must be implemented by subclass")
end

---Get workspace patterns for this provider
---@return string[] patterns Workspace patterns
function BaseProvider:get_workspace_patterns()
  return self.config.workspace.patterns or {}
end

---Get workspace priority for this provider
---@return string[] priority Workspace priority order
function BaseProvider:get_workspace_priority()
  return self.config.workspace.priority or {}
end

---Get environment resolution config for this provider
---@return ProviderEnvConfig env_config Environment resolution configuration
function BaseProvider:get_env_resolution()
  return self.config.env_resolution
    or {
      strategy = "workspace_first",
      inheritance = true,
      override_order = { "workspace", "root" },
    }
end

---Get package manager files for workspace validation
---@return string[] package_managers List of package manager files
function BaseProvider:get_package_managers()
  -- Default implementation uses detection file markers
  return self.config.detection.file_markers or {}
end

---Get cache duration for this provider
---@return number duration Cache duration in milliseconds
function BaseProvider:get_cache_duration()
  return self.config.detection.cache_duration or 300000 -- 5 minutes default
end

---Get quick detection markers for performance optimization
---@return string[] markers Quick detection markers
function BaseProvider:get_quick_markers()
  return self.config.detection.file_markers or {}
end

---Get maximum search depth for this provider
---@return number depth Maximum search depth
function BaseProvider:get_max_depth()
  return self.config.detection.max_depth or 4
end

---Generate cache key for given path
---@param path string Path to generate key for
---@param suffix? string Optional suffix for the key
---@return string cache_key Generated cache key
function BaseProvider:get_cache_key(path, suffix)
  local key = self.cache_key_prefix .. path
  if suffix then
    key = key .. ":" .. suffix
  end
  return key
end

---Validate provider configuration
---@param config table Configuration to validate
---@return boolean valid Whether configuration is valid
---@return string? error Error message if invalid
function BaseProvider.validate_config(config)
  if not config.name or type(config.name) ~= "string" then
    return false, "Provider name must be a string"
  end

  if not config.detection or type(config.detection) ~= "table" then
    return false, "Provider detection config must be a table"
  end

  if not config.detection.strategies or type(config.detection.strategies) ~= "table" then
    return false, "Detection strategies must be a table"
  end

  if not config.workspace or type(config.workspace) ~= "table" then
    return false, "Provider workspace config must be a table"
  end

  if not config.workspace.patterns or type(config.workspace.patterns) ~= "table" then
    return false, "Workspace patterns must be a table"
  end

  return true, nil
end

---Helper function to check if file exists and is readable
---@param file_path string Path to file to check
---@return boolean exists Whether file exists and is readable
function BaseProvider:file_exists(file_path)
  return vim.fn.filereadable(file_path) == 1
end

---Helper function to check if directory exists
---@param dir_path string Path to directory to check
---@return boolean exists Whether directory exists
function BaseProvider:dir_exists(dir_path)
  return vim.fn.isdirectory(dir_path) == 1
end

---Helper function to safely read and parse JSON file
---@param file_path string Path to JSON file
---@return table? content Parsed JSON content or nil if failed
function BaseProvider:read_json_file(file_path)
  if not self:file_exists(file_path) then
    return nil
  end

  local success, content = pcall(vim.fn.readfile, file_path)
  if not success or not content then
    return nil
  end

  local json_str = table.concat(content, "\n")
  local ok, parsed = pcall(vim.fn.json_decode, json_str)
  if not ok then
    return nil
  end

  return parsed
end

return BaseProvider

