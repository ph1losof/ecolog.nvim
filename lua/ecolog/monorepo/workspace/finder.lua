---@class WorkspaceFinder
local WorkspaceFinder = {}

local Cache = require("ecolog.monorepo.detection.cache")

-- Removed global package manager constants - now using provider-specific approaches

---Find all workspace directories in a monorepo
---@param root_path string Root path of the monorepo
---@param provider MonorepoBaseProvider Provider that detected this monorepo
---@return table[] workspaces List of found workspace directories
function WorkspaceFinder.find_workspaces(root_path, provider)
  if not root_path or not provider then
    return {}
  end

  -- Early exit if provider has no workspace patterns
  local patterns = provider:get_workspace_patterns()
  if not patterns or #patterns == 0 then
    return {}
  end

  -- Check cache first
  local cache_key = provider:get_cache_key(root_path, "workspaces")
  local cached_workspaces = Cache.get_workspaces(cache_key, provider:get_cache_duration())
  if cached_workspaces then
    return cached_workspaces
  end

  local max_depth = provider:get_max_depth()
  local workspaces = {}

  -- Search for workspaces using glob patterns
  for _, pattern in ipairs(patterns) do
    local found_workspaces = WorkspaceFinder._find_workspaces_for_pattern(root_path, pattern, max_depth, provider)
    vim.list_extend(workspaces, found_workspaces)
  end

  -- Remove duplicates and sort by priority
  workspaces = WorkspaceFinder._deduplicate_workspaces(workspaces)
  workspaces = WorkspaceFinder._sort_workspaces(workspaces, provider:get_workspace_priority())

  -- Cache the results
  Cache.set_workspaces(cache_key, workspaces, provider:get_cache_duration())

  return workspaces
end

-- Batch file system operations for better performance
local _file_check_cache = {}
local _file_check_cache_time = 0

---Check if file is readable with caching
---@param file_path string File path to check
---@return boolean readable Whether file is readable
local function is_file_readable_cached(file_path)
  local now = vim.loop.now()
  if (now - _file_check_cache_time) > 5000 then -- Clear cache every 5 seconds
    _file_check_cache = {}
    _file_check_cache_time = now
  end
  
  if _file_check_cache[file_path] ~= nil then
    return _file_check_cache[file_path]
  end
  
  local readable = vim.fn.filereadable(file_path) == 1
  _file_check_cache[file_path] = readable
  return readable
end

---Find workspaces for a specific pattern
---@param root_path string Root path of the monorepo
---@param pattern string Workspace pattern to search for
---@param max_depth number Maximum search depth
---@param provider MonorepoBaseProvider Provider instance
---@return table[] workspaces Found workspaces for this pattern
function WorkspaceFinder._find_workspaces_for_pattern(root_path, pattern, max_depth, provider)
  local workspaces = {}
  local search_pattern = root_path .. "/" .. pattern

  -- Use vim.fn.glob to find matching directories
  local found = vim.fn.glob(search_pattern, false, true)
  if type(found) == "string" then
    found = { found }
  end

  -- Batch directory checks
  local valid_dirs = {}
  for _, workspace_path in ipairs(found) do
    if vim.fn.isdirectory(workspace_path) == 1 then
      table.insert(valid_dirs, workspace_path)
    end
  end

  -- Process valid directories
  for _, workspace_path in ipairs(valid_dirs) do
    local workspace = WorkspaceFinder._create_workspace_info(workspace_path, root_path, provider)
    if workspace and WorkspaceFinder._is_valid_workspace(workspace, max_depth) then
      table.insert(workspaces, workspace)
    end
  end

  return workspaces
end

---Create workspace information object
---@param workspace_path string Absolute path to workspace
---@param root_path string Root path of monorepo
---@param provider MonorepoBaseProvider Provider instance
---@return table? workspace Workspace information or nil if invalid
function WorkspaceFinder._create_workspace_info(workspace_path, root_path, provider)
  local relative_path = workspace_path:sub(#root_path + 2) -- Remove root path + "/"
  local workspace_parts = vim.split(relative_path, "/")

  if #workspace_parts == 0 then
    return nil
  end

  return {
    path = workspace_path,
    name = vim.fn.fnamemodify(workspace_path, ":t"),
    relative_path = relative_path,
    type = workspace_parts[1], -- First part indicates type (apps, packages, etc.)
    provider = provider,
    metadata = {
      depth = #workspace_parts,
      has_package_manager = WorkspaceFinder._has_package_manager(workspace_path, provider),
    },
  }
end

---Check if workspace is valid
---@param workspace table Workspace information
---@param max_depth number Maximum allowed depth
---@return boolean valid Whether workspace is valid
function WorkspaceFinder._is_valid_workspace(workspace, max_depth)
  -- Check depth limit
  if workspace.metadata.depth > max_depth then
    return false
  end

  -- Must have a package manager file to be considered a valid workspace
  return workspace.metadata.has_package_manager
end

---Check if directory has package manager files using provider-specific detection
---@param dir_path string Directory path to check
---@param provider MonorepoBaseProvider Provider to use for detection
---@return boolean has_package_manager Whether directory has package manager files
function WorkspaceFinder._has_package_manager(dir_path, provider)
  -- Get provider-specific package manager files
  local package_managers = provider:get_package_managers()
  if not package_managers then
    -- Fallback to basic detection markers
    package_managers = provider.config.detection.file_markers or {}
  end

  -- Check all files in one batch to reduce system calls
  for _, pm_file in ipairs(package_managers) do
    if is_file_readable_cached(dir_path .. "/" .. pm_file) then
      return true
    end
  end
  return false
end

---Remove duplicate workspaces
---@param workspaces table[] List of workspaces that may contain duplicates
---@return table[] unique_workspaces List with duplicates removed
function WorkspaceFinder._deduplicate_workspaces(workspaces)
  local seen = {}
  local unique = {}

  for _, workspace in ipairs(workspaces) do
    if not seen[workspace.path] then
      seen[workspace.path] = true
      table.insert(unique, workspace)
    end
  end

  return unique
end

---Sort workspaces by priority
---@param workspaces table[] List of workspaces to sort
---@param priority_order string[] Priority order for workspace types
---@return table[] sorted_workspaces Sorted workspaces
function WorkspaceFinder._sort_workspaces(workspaces, priority_order)
  table.sort(workspaces, function(a, b)
    -- Priority by type first
    local a_priority = 999
    local b_priority = 999

    for i, type_name in ipairs(priority_order) do
      if a.type == type_name then
        a_priority = i
      end
      if b.type == type_name then
        b_priority = i
      end
    end

    if a_priority ~= b_priority then
      return a_priority < b_priority
    end

    -- Then by name
    return a.name < b.name
  end)

  return workspaces
end

---Find workspace by name
---@param workspaces table[] List of workspaces to search
---@param name string Workspace name to find
---@return table? workspace Found workspace or nil
function WorkspaceFinder.find_by_name(workspaces, name)
  for _, workspace in ipairs(workspaces) do
    if workspace.name == name then
      return workspace
    end
  end
  return nil
end

---Find workspaces by type
---@param workspaces table[] List of workspaces to search
---@param workspace_type string Type to filter by
---@return table[] filtered_workspaces Workspaces matching the type
function WorkspaceFinder.find_by_type(workspaces, workspace_type)
  local filtered = {}
  for _, workspace in ipairs(workspaces) do
    if workspace.type == workspace_type then
      table.insert(filtered, workspace)
    end
  end
  return filtered
end

---Clear workspace cache for specific root path
---@param root_path string Root path to clear cache for
---@param provider MonorepoBaseProvider? Provider to clear cache for (optional)
function WorkspaceFinder.clear_cache(root_path, provider)
  if provider then
    local cache_key = provider:get_cache_key(root_path, "workspaces")
    Cache.evict(cache_key)
  else
    -- Clear all workspace cache entries for this root path
    Cache.evict_pattern(".*:workspaces:" .. vim.pesc(root_path))
  end
end

return WorkspaceFinder

