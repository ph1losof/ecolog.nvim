local M = {}

local api = vim.api
local fn = vim.fn

---@class MonorepoConfig
---@field enabled boolean Enable monorepo support
---@field detection MonorepoDetectionConfig Workspace detection configuration
---@field workspace_patterns string[] Patterns to identify workspace roots
---@field env_resolution EnvResolutionConfig Environment file resolution strategy
---@field auto_switch boolean Automatically switch workspaces based on current file
---@field workspace_priority string[] Priority order for workspace selection

---@class MonorepoDetectionConfig
---@field strategies string[] Detection strategies: "file_markers", "package_managers", "git_submodules"
---@field file_markers string[] Files that indicate workspace roots
---@field package_managers string[] Package manager files to look for
---@field max_depth number Maximum depth to search for workspaces
---@field cache_duration number Cache duration in milliseconds

---@class EnvResolutionConfig
---@field strategy string Resolution strategy: "workspace_first", "root_first", "merge", "workspace_only"
---@field inheritance boolean Whether workspace envs inherit from root
---@field override_order string[] Order of environment file precedence

-- Common monorepo detection patterns
local MONOREPO_MARKERS = {
  -- Turborepo
  "turbo.json",
  -- Nx
  "nx.json", 
  "workspace.json",
  -- Lerna
  "lerna.json",
  -- Rush
  "rush.json",
  -- Yarn/npm workspaces
  "package.json", -- with workspaces field
  -- Bazel
  "WORKSPACE",
  "WORKSPACE.bazel",
  -- Cargo workspaces  
  "Cargo.toml", -- with workspace section
  -- Gradle
  "settings.gradle",
  "settings.gradle.kts",
  -- Maven
  "pom.xml", -- with modules
  -- Generic
  ".workspace",
  ".monorepo"
}

local WORKSPACE_PATTERNS = {
  -- Common workspace directory patterns
  "apps/*",
  "packages/*", 
  "libs/*",
  "services/*",
  "modules/*",
  "components/*",
  "tools/*",
  "internal/*",
  "external/*",
  "projects/*"
}

local PACKAGE_MANAGERS = {
  "package.json",
  "Cargo.toml", 
  "go.mod",
  "pyproject.toml",
  "requirements.txt",
  "pom.xml",
  "build.gradle",
  "composer.json",
  "pubspec.yaml",
  "mix.exs"
}

-- Cache for detected workspaces
local _workspace_cache = {}
local _cache_timestamps = {}
local _current_workspace = nil

-- Default configuration
local DEFAULT_MONOREPO_CONFIG = {
  enabled = true,
  detection = {
    strategies = { "file_markers", "package_managers" },
    file_markers = MONOREPO_MARKERS,
    package_managers = PACKAGE_MANAGERS,
    max_depth = 4,
    cache_duration = 300000, -- 5 minutes
  },
  workspace_patterns = WORKSPACE_PATTERNS,
  env_resolution = {
    strategy = "workspace_first", -- workspace_first, root_first, merge, workspace_only
    inheritance = true,
    override_order = { "workspace", "root" }
  },
  auto_switch = true,
  workspace_priority = { "apps", "packages", "services", "libs" }
}

---Check if cache is valid for a given path
---@param path string The path to check cache for
---@return boolean valid Whether cache is still valid
local function is_cache_valid(path, cache_duration)
  local timestamp = _cache_timestamps[path]
  if not timestamp then
    return false
  end
  
  local now = vim.loop.now()
  return (now - timestamp) < cache_duration
end

---Detect if a directory contains monorepo markers
---@param path string Directory path to check
---@param markers string[] List of marker files to look for
---@return boolean is_monorepo Whether directory contains monorepo markers
---@return string[] found_markers List of found marker files
local function detect_monorepo_markers(path, markers)
  local found_markers = {}
  
  for _, marker in ipairs(markers) do
    local marker_path = path .. "/" .. marker
    if fn.filereadable(marker_path) == 1 or fn.isdirectory(marker_path) == 1 then
      table.insert(found_markers, marker)
      
      -- Special handling for package.json - check for workspaces field
      if marker == "package.json" then
        local success, content = pcall(fn.readfile, marker_path)
        if success and content then
          local json_str = table.concat(content, "\n")
          if json_str:match('"workspaces"') then
            return true, found_markers
          end
        end
      else
        return true, found_markers
      end
    end
  end
  
  return #found_markers > 0, found_markers
end

---Find all workspace directories in a monorepo
---@param root_path string Root path of the monorepo
---@param patterns string[] Workspace patterns to search for
---@param max_depth number Maximum search depth
---@return table workspaces List of found workspace directories
local function find_workspaces(root_path, patterns, max_depth)
  local workspaces = {}
  
  -- Use recursive glob search with depth limit
  for _, pattern in ipairs(patterns) do
    local search_pattern = root_path .. "/" .. pattern
    local found = fn.glob(search_pattern, false, true)
    
    if type(found) == "string" then
      found = { found }
    end
    
    for _, workspace_path in ipairs(found) do
      if fn.isdirectory(workspace_path) == 1 then
        -- Check depth
        local relative_path = workspace_path:sub(#root_path + 2)
        local depth = select(2, relative_path:gsub("/", ""))
        
        if depth <= max_depth then
          -- Check if workspace has package manager files
          local has_package_file = false
          for _, pm_file in ipairs(PACKAGE_MANAGERS) do
            if fn.filereadable(workspace_path .. "/" .. pm_file) == 1 then
              has_package_file = true
              break
            end
          end
          
          if has_package_file then
            table.insert(workspaces, {
              path = workspace_path,
              name = fn.fnamemodify(workspace_path, ":t"),
              relative_path = relative_path,
              type = relative_path:match("^([^/]+)")
            })
          end
        end
      end
    end
  end
  
  return workspaces
end

---Detect monorepo root from current working directory
---@param start_path string? Starting path (defaults to cwd)
---@param config MonorepoDetectionConfig Detection configuration
---@return string|nil root_path Path to monorepo root if found
---@return table|nil info Additional information about detected monorepo
function M.detect_monorepo_root(start_path, config)
  start_path = start_path or fn.getcwd()
  config = config or DEFAULT_MONOREPO_CONFIG.detection
  
  -- Check cache first
  if is_cache_valid(start_path, config.cache_duration) then
    local cached_result = _workspace_cache[start_path]
    if cached_result then
      return cached_result.root, cached_result
    else
      return nil, nil
    end
  end
  
  local current_path = fn.fnamemodify(start_path, ":p:h")
  local max_iterations = 10 -- Prevent infinite loops
  local iteration = 0
  
  while current_path ~= "/" and iteration < max_iterations do
    iteration = iteration + 1
    
    -- Check for file markers
    if vim.tbl_contains(config.strategies, "file_markers") then
      local is_monorepo, markers = detect_monorepo_markers(current_path, config.file_markers)
      if is_monorepo then
        local result = {
          root = current_path,
          type = "file_markers",
          markers = markers
        }
        
        -- Cache result with root path
        result.root = current_path
        _workspace_cache[start_path] = result
        _cache_timestamps[start_path] = vim.loop.now()
        
        return current_path, result
      end
    end
    
    -- Move up one directory
    local parent = fn.fnamemodify(current_path, ":h")
    if parent == current_path then
      break
    end
    current_path = parent
  end
  
  -- Cache negative result too
  _workspace_cache[start_path] = nil
  _cache_timestamps[start_path] = vim.loop.now()
  
  return nil, nil
end

---Get all workspaces in a monorepo
---@param root_path string Root path of monorepo
---@param config table Monorepo configuration
---@return table workspaces List of workspace information
function M.get_workspaces(root_path, config)
  -- Validate inputs
  if not root_path or type(root_path) ~= "string" then
    vim.notify("Invalid root_path provided to get_workspaces. Type: " .. type(root_path) .. ", Value: " .. tostring(root_path), vim.log.levels.ERROR)
    if type(root_path) == "table" then
      vim.notify("Root path table contents: " .. vim.inspect(root_path), vim.log.levels.ERROR)
    end
    return {}
  end
  
  config = config or DEFAULT_MONOREPO_CONFIG
  
  local cache_key = root_path .. ":workspaces"
  if is_cache_valid(cache_key, config.detection.cache_duration) then
    return _workspace_cache[cache_key] or {}
  end
  
  local workspaces = find_workspaces(
    root_path, 
    config.workspace_patterns, 
    config.detection.max_depth
  )
  
  -- Sort workspaces by priority
  table.sort(workspaces, function(a, b)
    local a_priority = vim.tbl_contains(config.workspace_priority, a.type) and 
      vim.fn.index(config.workspace_priority, a.type) or 999
    local b_priority = vim.tbl_contains(config.workspace_priority, b.type) and 
      vim.fn.index(config.workspace_priority, b.type) or 999
      
    if a_priority ~= b_priority then
      return a_priority < b_priority
    end
    
    return a.name < b.name
  end)
  
  -- Cache workspaces
  _workspace_cache[cache_key] = workspaces
  _cache_timestamps[cache_key] = vim.loop.now()
  
  return workspaces
end

---Find workspace containing the current file
---@param file_path string? File path (defaults to current buffer)
---@param root_path string Root path of monorepo  
---@param workspaces table List of workspaces
---@return table|nil workspace Workspace containing the file
function M.find_current_workspace(file_path, root_path, workspaces)
  file_path = file_path or api.nvim_buf_get_name(0)
  
  if not file_path or file_path == "" then
    return nil
  end
  
  file_path = fn.fnamemodify(file_path, ":p")
  
  -- Find the workspace that contains this file
  local best_match = nil
  local longest_match = 0
  
  for _, workspace in ipairs(workspaces) do
    local workspace_path = workspace.path .. "/"
    if file_path:sub(1, #workspace_path) == workspace_path then
      if #workspace_path > longest_match then
        longest_match = #workspace_path
        best_match = workspace
      end
    end
  end
  
  return best_match
end

---Resolve environment files for a workspace
---@param workspace table|nil Workspace information
---@param root_path string Monorepo root path
---@param config table Environment resolution config
---@param env_file_patterns string[] Environment file patterns
---@param opts table|nil Additional options including preferred_environment and sorting functions
---@return string[] env_files List of environment files in resolution order
function M.resolve_env_files(workspace, root_path, config, env_file_patterns, opts)
  config = config or DEFAULT_MONOREPO_CONFIG.env_resolution
  env_file_patterns = env_file_patterns or { ".env", ".env.*" }
  
  local env_files = {}
  
  -- Helper function to find env files in a directory
  local function find_env_files_in_path(path)
    local files = {}
    if not path or path == "" then
      return files
    end
    
    for _, pattern in ipairs(env_file_patterns) do
      local search_pattern = path .. "/" .. pattern
      local found = fn.glob(search_pattern, false, true)
      if type(found) == "string" then
        found = { found }
      end
      if found and #found > 0 then
        vim.list_extend(files, found)
      end
    end
    return files
  end
  
  if config.strategy == "workspace_only" and workspace then
    -- Only workspace env files
    env_files = find_env_files_in_path(workspace.path)
  elseif config.strategy == "workspace_first" then
    -- Workspace files first, then root files
    if workspace then
      vim.list_extend(env_files, find_env_files_in_path(workspace.path))
    end
    if config.inheritance then
      vim.list_extend(env_files, find_env_files_in_path(root_path))
    end
  elseif config.strategy == "root_first" then
    -- Root files first, then workspace files
    vim.list_extend(env_files, find_env_files_in_path(root_path))
    if workspace then
      vim.list_extend(env_files, find_env_files_in_path(workspace.path))
    end
  elseif config.strategy == "merge" then
    -- Merge strategy - collect all and sort by override order
    local root_files = find_env_files_in_path(root_path)
    local workspace_files = workspace and find_env_files_in_path(workspace.path) or {}
    
    -- Apply override order
    for _, location in ipairs(config.override_order) do
      if location == "root" then
        vim.list_extend(env_files, root_files)
      elseif location == "workspace" then
        vim.list_extend(env_files, workspace_files)
      end
    end
  end
  
  -- Remove duplicates while preserving order
  local seen = {}
  local unique_files = {}
  for _, file in ipairs(env_files) do
    if not seen[file] then
      seen[file] = true
      table.insert(unique_files, file)
    end
  end
  
  -- Apply proper sorting with preferred environment if opts provided
  if opts then
    local utils = require("ecolog.utils")
    unique_files = utils.sort_env_files(unique_files, opts)
  end
  
  return unique_files
end

---Set current workspace
---@param workspace table|nil Workspace to set as current
function M.set_current_workspace(workspace)
  local previous_workspace = _current_workspace
  _current_workspace = workspace
  
  -- Only refresh if workspace actually changed
  if previous_workspace ~= workspace then
    -- Handle selected env file transition
    local has_ecolog, ecolog = pcall(require, "ecolog")
    if has_ecolog then
      vim.schedule(function()
        local selected_file = M.handle_env_file_transition(workspace, previous_workspace, ecolog)
        -- Force refresh to reload env files from new workspace
        -- Pass the selected file to preserve it during force reload
        ecolog.refresh_env_vars({ 
          _workspace_file_handled = true,
          _workspace_selected_file = selected_file
        })
        
        -- Refresh shelter configuration for new workspace context
        local has_shelter_buffer, shelter_buffer = pcall(require, "ecolog.shelter.buffer")
        if has_shelter_buffer and shelter_buffer.refresh_shelter_for_monorepo then
          shelter_buffer.refresh_shelter_for_monorepo()
        end
      end)
    end
  end
end

---Handle environment file selection when switching workspaces
---@param new_workspace table|nil New workspace
---@param previous_workspace table|nil Previous workspace  
---@param ecolog table Ecolog module
function M.handle_env_file_transition(new_workspace, previous_workspace, ecolog)
  if not ecolog.get_state then
    return
  end
  
  local state = ecolog.get_state()
  local current_selected_file = state.selected_env_file
  
  -- Get current config to determine resolution strategy
  local config = ecolog.get_config()
  local monorepo_config = config.monorepo or {}
  local env_resolution = monorepo_config.env_resolution or { strategy = "workspace_first" }
  
  if not new_workspace then
    -- Switching to non-workspace mode, clear selection
    state.selected_env_file = nil
    state.env_vars = {}
    state._env_line_cache = {}
    state.cached_env_files = nil
    vim.notify("Cleared environment file selection (no workspace)", vim.log.levels.INFO)
    return nil
  end
  
  -- Get available files in new workspace
  local root_path = config._monorepo_root
  if not root_path then
    -- Try to detect root_path if not available in config
    root_path, _ = M.detect_monorepo_root()
  end
  
  if not root_path then
    return nil
  end
  
  local available_files = M.resolve_env_files(
    new_workspace,
    root_path, 
    env_resolution,
    config.env_file_patterns,
    config
  )
  
  if #available_files == 0 then
    -- No files available in new workspace
    state.selected_env_file = nil
    state.env_vars = {}
    state._env_line_cache = {}
    state.cached_env_files = nil
    vim.notify(string.format("No environment files found in workspace: %s", new_workspace.name), vim.log.levels.WARN)
    return nil
  end
  
  -- Select appropriate file for the new workspace
  local selected_file = nil
  local message = ""
  
  if current_selected_file then
    -- Try to find equivalent file in new workspace
    local current_filename = fn.fnamemodify(current_selected_file, ":t")
    
    -- Look for exact filename match
    for _, file in ipairs(available_files) do
      if fn.fnamemodify(file, ":t") == current_filename then
        selected_file = file
        message = string.format("Switched to equivalent file: %s (%s)", current_filename, file)
        break
      end
    end
  end
  
  if not selected_file then
    -- No equivalent file or no previous file, select first available
    selected_file = available_files[1]
    local new_filename = fn.fnamemodify(selected_file, ":t")
    if current_selected_file then
      local old_filename = fn.fnamemodify(current_selected_file, ":t")
      message = string.format("Selected new file: %s (%s) (was: %s)", new_filename, selected_file, old_filename)
    else
      message = string.format("Selected workspace file: %s (%s)", new_filename, selected_file)
    end
  end
  
  -- Apply the selection
  state.selected_env_file = selected_file
  state.env_vars = {} -- Clear cache to force reload
  state._env_line_cache = {} -- Clear line cache too
  state.cached_env_files = nil -- Clear file cache
  vim.notify(message, vim.log.levels.INFO)
  
  -- Return the selected file so it can be passed to refresh_env_vars
  return selected_file
end

---Get current workspace
---@return table|nil workspace Current workspace
function M.get_current_workspace()
  return _current_workspace
end

---Clear workspace cache
function M.clear_cache()
  _workspace_cache = {}
  _cache_timestamps = {}
end

-- Store the setup config globally for autocmd access
local _setup_config = nil

---Setup monorepo detection and auto-switching
---@param config table Monorepo configuration
function M.setup(config)
  config = vim.tbl_deep_extend("force", DEFAULT_MONOREPO_CONFIG, config or {})
  _setup_config = config
  
  if not config.enabled then
    return
  end
  
  -- Set up auto-switching if enabled
  if config.auto_switch then
    local augroup = api.nvim_create_augroup("EcologMonorepo", { clear = true })
    
    api.nvim_create_autocmd({ "BufEnter", "DirChanged" }, {
      group = augroup,
      callback = function()
        -- Add error handling to prevent autocmd errors
        local success, err = pcall(function()
          local root_path, _ = M.detect_monorepo_root()
          if not root_path or type(root_path) ~= "string" then
            return
          end
          
          if not _setup_config then
            return
          end
          
          local workspaces = M.get_workspaces(root_path, _setup_config)
          local current_workspace = M.find_current_workspace(nil, root_path, workspaces)
          
          if current_workspace and current_workspace ~= _current_workspace then
            M.set_current_workspace(current_workspace)
            vim.notify(
              string.format("Switched to workspace: %s (%s)", current_workspace.name, current_workspace.path),
              vim.log.levels.INFO
            )
          end
        end)
        
        if not success then
          -- Silently ignore errors in autocmd to prevent noise
          -- vim.notify("Monorepo autocmd error: " .. tostring(err), vim.log.levels.DEBUG)
        end
      end,
    })
  end
end

---Integration with ecolog configuration
---@param ecolog_config table The main ecolog configuration
---@return table modified_config Modified configuration for monorepo support
function M.integrate_with_ecolog_config(ecolog_config)
  local root_path, _ = M.detect_monorepo_root()
  if not root_path then
    return ecolog_config
  end
  
  -- Ensure monorepo config exists
  local monorepo_config = ecolog_config.monorepo or DEFAULT_MONOREPO_CONFIG
  local workspaces = M.get_workspaces(root_path, monorepo_config)
  local current_workspace = M.find_current_workspace(nil, root_path, workspaces)
  
  
  -- Handle monorepo integration based on auto_switch setting
  if monorepo_config.auto_switch then
    -- Auto-switch mode: only activate if we can determine current workspace
    if current_workspace then
      M.set_current_workspace(current_workspace)
      
      -- Override path to workspace path so utils.find_env_files looks in the right place
      ecolog_config.path = current_workspace.path
      
      -- Add workspace information for auto-switching mode
      ecolog_config._is_monorepo_workspace = true
      ecolog_config._workspace_info = current_workspace
      ecolog_config._monorepo_root = root_path
    end
  else
    -- Manual mode: always provide workspace info for manual selection
    if #workspaces > 0 then
      ecolog_config._is_monorepo_manual_mode = true
      ecolog_config._all_workspaces = workspaces
      ecolog_config._monorepo_root = root_path
      ecolog_config._current_workspace_info = current_workspace -- For reference only
    end
  end
  
  return ecolog_config
end

return M