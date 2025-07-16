---@class EnvironmentResolver
local EnvironmentResolver = {}

local Cache = require("ecolog.monorepo.detection.cache")
local BulkResolver = require("ecolog.monorepo.workspace.bulk_resolver")

-- Default environment file patterns
local DEFAULT_ENV_PATTERNS = {
  ".env",
  ".envrc",
  ".env.*",
}

---Resolve environment files for a workspace (optimized)
---@param workspace table? Workspace information
---@param root_path string Monorepo root path
---@param provider MonorepoBaseProvider Provider that manages this workspace
---@param env_file_patterns string[]? Custom environment file patterns
---@param opts table? Additional options including preferred_environment and sorting functions
---@return string[] env_files List of environment files in resolution order
function EnvironmentResolver.resolve_env_files(workspace, root_path, provider, env_file_patterns, opts)
  opts = opts or {}
  env_file_patterns = env_file_patterns or DEFAULT_ENV_PATTERNS

  -- Generate cache key based on workspace and options
  local cache_key = EnvironmentResolver._generate_cache_key(workspace, root_path, provider, env_file_patterns, opts)

  -- Check cache first
  local cached_files = Cache.get_env_files(cache_key, provider:get_cache_duration())
  if cached_files then
    return cached_files
  end

  local env_resolution = provider:get_env_resolution()
  local paths_to_resolve = {}
  
  -- Collect paths based on resolution strategy
  if env_resolution.strategy == "workspace_only" and workspace then
    table.insert(paths_to_resolve, {path = workspace.path, workspace_info = workspace})
  elseif env_resolution.strategy == "workspace_first" then
    if workspace then
      table.insert(paths_to_resolve, {path = workspace.path, workspace_info = workspace})
    end
    if env_resolution.inheritance then
      table.insert(paths_to_resolve, {path = root_path, workspace_info = nil})
    end
  elseif env_resolution.strategy == "root_first" then
    table.insert(paths_to_resolve, {path = root_path, workspace_info = nil})
    if workspace then
      table.insert(paths_to_resolve, {path = workspace.path, workspace_info = workspace})
    end
  elseif env_resolution.strategy == "merge" then
    -- Collect all paths for merge strategy
    table.insert(paths_to_resolve, {path = root_path, workspace_info = nil})
    if workspace then
      table.insert(paths_to_resolve, {path = workspace.path, workspace_info = workspace})
    end
  end
  
  -- Use bulk resolver for high performance
  local bulk_results = BulkResolver.bulk_resolve_env_files(paths_to_resolve, env_file_patterns, provider, opts)
  
  -- Merge results according to strategy
  local env_files = {}
  
  if env_resolution.strategy == "merge" then
    -- Apply override order for merge strategy
    for _, location in ipairs(env_resolution.override_order) do
      if location == "root" and bulk_results[root_path] then
        vim.list_extend(env_files, bulk_results[root_path])
      elseif location == "workspace" and workspace and bulk_results[workspace.path] then
        vim.list_extend(env_files, bulk_results[workspace.path])
      end
    end
  else
    -- Sequential strategy
    for _, path_info in ipairs(paths_to_resolve) do
      local path = path_info.path
      if bulk_results[path] then
        vim.list_extend(env_files, bulk_results[path])
      end
    end
  end

  -- Remove duplicates while preserving order
  env_files = EnvironmentResolver._remove_duplicates(env_files)

  -- Apply sorting if options provided
  if opts.preferred_environment or opts.sort_file_fn then
    env_files = EnvironmentResolver._sort_env_files(env_files, opts, root_path)
  end

  -- Cache the result
  Cache.set_env_files(cache_key, env_files, provider:get_cache_duration())

  return env_files
end

---Find environment files in a specific directory
---@param path string Directory path to search
---@param patterns string[] Environment file patterns
---@return string[] files Found environment files
function EnvironmentResolver._find_env_files_in_path(path, patterns)
  local files = {}

  if not path or path == "" then
    return files
  end

  for _, pattern in ipairs(patterns) do
    local search_pattern = path .. "/" .. pattern
    local found = vim.fn.glob(search_pattern, false, true)
    if type(found) == "string" then
      found = { found }
    end
    if found and #found > 0 then
      vim.list_extend(files, found)
    end
  end

  return files
end

---Remove duplicate files while preserving order
---@param files string[] List of files that may contain duplicates
---@return string[] unique_files List with duplicates removed
function EnvironmentResolver._remove_duplicates(files)
  local seen = {}
  local unique = {}

  for _, file in ipairs(files) do
    if not seen[file] then
      seen[file] = true
      table.insert(unique, file)
    end
  end

  return unique
end

---Sort environment files based on preferences
---@param files string[] Files to sort
---@param opts table Sort options including preferred_environment and sort_file_fn
---@param root_path string Monorepo root path for context
---@return string[] sorted_files Sorted files
function EnvironmentResolver._sort_env_files(files, opts, root_path)
  if not files or #files == 0 then
    return {}
  end

  -- Create enhanced options for sorting that includes monorepo context
  local sort_opts = vim.tbl_deep_extend("force", opts, {
    _monorepo_root = root_path,
  })

  -- Use utils.sort_env_files if available, otherwise use simple sorting
  local utils_ok, utils = pcall(require, "ecolog.utils")
  if utils_ok and utils.sort_env_files then
    return utils.sort_env_files(files, sort_opts)
  end

  -- Fallback to simple sorting
  local sorted = vim.deepcopy(files)
  table.sort(sorted, function(a, b)
    -- Preferred environment sorting
    if opts.preferred_environment and opts.preferred_environment ~= "" then
      local pref_pattern = "%." .. vim.pesc(opts.preferred_environment) .. "$"
      local a_is_preferred = a:match(pref_pattern) ~= nil
      local b_is_preferred = b:match(pref_pattern) ~= nil
      if a_is_preferred ~= b_is_preferred then
        return a_is_preferred
      end
    end

    -- Default .env file priority
    local a_is_env = a:match("%.env[^.]*$") ~= nil
    local b_is_env = b:match("%.env[^.]*$") ~= nil
    if a_is_env ~= b_is_env then
      return a_is_env
    end

    return a < b
  end)

  return sorted
end

---Generate cache key for environment file resolution
---@param workspace table? Workspace information
---@param root_path string Monorepo root path
---@param provider MonorepoBaseProvider Provider instance
---@param env_file_patterns string[] Environment file patterns
---@param opts table Additional options
---@return string cache_key Generated cache key
function EnvironmentResolver._generate_cache_key(workspace, root_path, provider, env_file_patterns, opts)
  local key_parts = {
    "env_files",
    provider.name,
    root_path,
    workspace and workspace.path or "no_workspace",
    env_file_patterns and table.concat(env_file_patterns, ",") or "default_patterns",
    opts.preferred_environment or "no_pref",
  }

  return table.concat(key_parts, ":")
end

---Resolve environment files for all workspaces in manual mode (optimized)
---@param workspaces table[] List of all workspaces
---@param root_path string Monorepo root path
---@param provider MonorepoBaseProvider Provider that manages these workspaces
---@param env_file_patterns string[]? Custom environment file patterns
---@param opts table? Additional options
---@return string[] env_files Merged list of environment files from all workspaces
function EnvironmentResolver.resolve_all_workspace_files(workspaces, root_path, provider, env_file_patterns, opts)
  env_file_patterns = env_file_patterns or DEFAULT_ENV_PATTERNS
  
  -- Collect all workspace paths for bulk resolution
  local all_paths = {}
  
  -- Add root path
  table.insert(all_paths, {path = root_path, workspace_info = nil})
  
  -- Add all workspace paths
  for _, workspace in ipairs(workspaces) do
    table.insert(all_paths, {path = workspace.path, workspace_info = workspace})
  end
  
  -- Use bulk resolver for maximum performance
  local bulk_results = BulkResolver.bulk_resolve_env_files(all_paths, env_file_patterns, provider, opts)
  
  -- Merge all results
  local all_files = {}
  
  -- Add root files first
  if bulk_results[root_path] then
    vim.list_extend(all_files, bulk_results[root_path])
  end
  
  -- Add workspace files
  for _, workspace in ipairs(workspaces) do
    if bulk_results[workspace.path] then
      vim.list_extend(all_files, bulk_results[workspace.path])
    end
  end

  -- Remove duplicates and sort
  all_files = EnvironmentResolver._remove_duplicates(all_files)

  if opts and (opts.preferred_environment or opts.sort_file_fn) then
    all_files = EnvironmentResolver._sort_env_files(all_files, opts, root_path)
  end

  return all_files
end

---Clear environment file cache for specific workspace
---@param workspace table? Workspace to clear cache for
---@param root_path string Monorepo root path
---@param provider MonorepoBaseProvider Provider instance
function EnvironmentResolver.clear_cache(workspace, root_path, provider)
  local workspace_path = workspace and workspace.path or "no_workspace"
  local pattern = "env_files:" .. provider.name .. ":" .. vim.pesc(root_path) .. ":" .. vim.pesc(workspace_path)
  Cache.evict_pattern(pattern)
end

return EnvironmentResolver

