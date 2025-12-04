---@class WorkspaceManager
local WorkspaceManager = {}

local Cache = require("ecolog.monorepo.detection.cache")
local NotificationManager = require("ecolog.core.notification_manager")

-- Current workspace state
local _current_workspace = nil
local _workspace_change_listeners = {}

---@class Workspace
---@field path string Absolute path to workspace directory
---@field name string Workspace name (directory name)
---@field relative_path string Relative path from monorepo root
---@field type string Workspace type (apps, packages, etc.)
---@field provider MonorepoBaseProvider Provider that manages this workspace
---@field metadata table Additional workspace metadata

---Set current workspace
---@param workspace Workspace? New workspace to set as current
function WorkspaceManager.set_current(workspace)
  local previous_workspace = _current_workspace
  _current_workspace = workspace

  -- Only notify if workspace actually changed
  if previous_workspace ~= workspace then
    -- Notify all listeners about workspace change
    for _, listener in ipairs(_workspace_change_listeners) do
      local success, err = pcall(listener, workspace, previous_workspace)
      if not success then
        NotificationManager.error("Error in workspace change listener: " .. tostring(err))
      end
    end
  end
end

---Get current workspace
---@return Workspace? workspace Current workspace or nil
function WorkspaceManager.get_current()
  return _current_workspace
end

---Add workspace change listener
---@param listener function Callback function(new_workspace, previous_workspace)
function WorkspaceManager.add_change_listener(listener)
  if type(listener) == "function" then
    table.insert(_workspace_change_listeners, listener)
  end
end

---Remove workspace change listener
---@param listener function Callback function to remove
function WorkspaceManager.remove_change_listener(listener)
  for i, l in ipairs(_workspace_change_listeners) do
    if l == listener then
      table.remove(_workspace_change_listeners, i)
      break
    end
  end
end

---Clear all workspace change listeners
function WorkspaceManager.clear_listeners()
  _workspace_change_listeners = {}
end

---Find workspace containing given file path
---@param file_path string File path to search for
---@param workspaces Workspace[] List of workspaces to search
---@return Workspace? workspace Workspace containing the file or nil
function WorkspaceManager.find_workspace_for_file(file_path, workspaces)
  if not file_path or file_path == "" then
    return nil
  end

  file_path = vim.fn.fnamemodify(file_path, ":p")

  -- Find the workspace that contains this file (longest path match)
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

---Get workspace for current buffer
---@param workspaces Workspace[] List of workspaces to search
---@return Workspace? workspace Workspace containing current buffer or nil
function WorkspaceManager.get_current_buffer_workspace(workspaces)
  local current_file = vim.api.nvim_buf_get_name(0)
  return WorkspaceManager.find_workspace_for_file(current_file, workspaces)
end

---Filter workspaces by type
---@param workspaces Workspace[] List of workspaces to filter
---@param workspace_type string Type to filter by (e.g., "apps", "packages")
---@return Workspace[] filtered_workspaces Workspaces matching the type
function WorkspaceManager.filter_by_type(workspaces, workspace_type)
  local filtered = {}
  for _, workspace in ipairs(workspaces) do
    if workspace.type == workspace_type then
      table.insert(filtered, workspace)
    end
  end
  return filtered
end

---Sort workspaces by priority
---@param workspaces Workspace[] List of workspaces to sort
---@param priority_order string[] Priority order for workspace types
---@return Workspace[] sorted_workspaces Sorted workspaces
function WorkspaceManager.sort_by_priority(workspaces, priority_order)
  local sorted = vim.deepcopy(workspaces)

  table.sort(sorted, function(a, b)
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

  return sorted
end

---Get workspace statistics
---@param workspaces Workspace[] List of workspaces
---@return table stats Workspace statistics
function WorkspaceManager.get_stats(workspaces)
  local stats = {
    total = #workspaces,
    by_type = {},
    by_provider = {},
  }

  for _, workspace in ipairs(workspaces) do
    -- Count by type
    stats.by_type[workspace.type] = (stats.by_type[workspace.type] or 0) + 1

    -- Count by provider
    local provider_name = workspace.provider and workspace.provider.name or "unknown"
    stats.by_provider[provider_name] = (stats.by_provider[provider_name] or 0) + 1
  end

  return stats
end

---Create workspace display name with context
---@param workspace Workspace Workspace to create display name for
---@param monorepo_root string? Monorepo root path for context
---@return string display_name Formatted display name
function WorkspaceManager.get_display_name(workspace, monorepo_root)
  if not workspace then
    return "No workspace"
  end

  local display_name = workspace.name

  if monorepo_root then
    -- Show relative path from monorepo root
    local relative_path = workspace.path:sub(#monorepo_root + 2)
    display_name = relative_path
  end

  -- Add workspace type if available
  if workspace.type then
    display_name = display_name .. " (" .. workspace.type .. ")"
  end

  return display_name
end

---Validate workspace object
---@param workspace table Workspace object to validate
---@return boolean valid Whether workspace is valid
---@return string? error Error message if invalid
function WorkspaceManager.validate_workspace(workspace)
  if not workspace or type(workspace) ~= "table" then
    return false, "Workspace must be a table"
  end

  if not workspace.path or type(workspace.path) ~= "string" then
    return false, "Workspace path must be a string"
  end

  if not workspace.name or type(workspace.name) ~= "string" then
    return false, "Workspace name must be a string"
  end

  if not workspace.type or type(workspace.type) ~= "string" then
    return false, "Workspace type must be a string"
  end

  return true, nil
end

---Clear workspace state
function WorkspaceManager.clear_state()
  _current_workspace = nil
end

return WorkspaceManager

