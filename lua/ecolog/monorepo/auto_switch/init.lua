---@class AutoSwitch
local AutoSwitch = {}

local Detection = require("ecolog.monorepo.detection")
local WorkspaceManager = require("ecolog.monorepo.workspace.manager")
local WorkspaceFinder = require("ecolog.monorepo.workspace.finder")
local Throttle = require("ecolog.monorepo.auto_switch.throttle")

-- Auto-switch state
local _auto_switch_state = {
  enabled = false,
  augroup = nil,
  current_monorepo = nil,
  config = nil,
}

---Setup auto-switching with given configuration
---@param config table Monorepo configuration
function AutoSwitch.setup(config)
  _auto_switch_state.config = config
  _auto_switch_state.enabled = config.auto_switch == true

  if not _auto_switch_state.enabled then
    AutoSwitch.disable()
    return
  end

  -- Configure throttling
  if config.auto_switch_throttle then
    Throttle.configure(config.auto_switch_throttle)
  end

  -- Setup autocmds
  AutoSwitch._setup_autocmds()

  -- Perform initial detection and switch
  vim.schedule(function()
    AutoSwitch._handle_buffer_change()
  end)
end

---Setup autocmds for auto-switching
function AutoSwitch._setup_autocmds()
  -- Clean up existing autocmds
  if _auto_switch_state.augroup then
    vim.api.nvim_del_augroup_by_id(_auto_switch_state.augroup)
  end

  _auto_switch_state.augroup = vim.api.nvim_create_augroup("EcologMonorepoAutoSwitch", { clear = true })

  -- Buffer change events - use more specific events for better performance
  vim.api.nvim_create_autocmd({ "BufEnter" }, {
    group = _auto_switch_state.augroup,
    callback = function()
      AutoSwitch._handle_buffer_change()
    end,
  })
  
  -- Only handle window events for non-temporary buffers
  vim.api.nvim_create_autocmd({ "BufWinEnter" }, {
    group = _auto_switch_state.augroup,
    callback = function()
      local bufname = vim.api.nvim_buf_get_name(0)
      if bufname ~= "" and not bufname:match("^%w+://") then
        AutoSwitch._handle_buffer_change()
      end
    end,
  })

  -- Directory change events
  vim.api.nvim_create_autocmd("DirChanged", {
    group = _auto_switch_state.augroup,
    callback = function()
      AutoSwitch._handle_directory_change()
    end,
  })
end

---Handle buffer change event
function AutoSwitch._handle_buffer_change()
  if not _auto_switch_state.enabled then
    return
  end

  local current_file = vim.api.nvim_buf_get_name(0)
  if not current_file or current_file == "" then
    return
  end

  -- Use throttled check
  Throttle.debounced_check(current_file, function()
    AutoSwitch._perform_workspace_check(current_file)
  end)
end

---Handle directory change event
function AutoSwitch._handle_directory_change()
  if not _auto_switch_state.enabled then
    return
  end

  -- Directory changes are less frequent, so we can be more aggressive
  local current_dir = vim.fn.getcwd()
  AutoSwitch._perform_workspace_check(current_dir, true)
end

---Perform the actual workspace detection and switching
---@param file_path string File path or directory to check
---@param force_check? boolean Whether to force check regardless of throttling
function AutoSwitch._perform_workspace_check(file_path, force_check)
  local success, err = pcall(function()
    -- Early exit if no providers are available
    local providers = Detection.get_providers()
    if not next(providers) then
      return
    end
    
    -- Detect monorepo
    local root_path, provider, detection_info = Detection.detect_monorepo(file_path)

    if not root_path or not provider then
      -- Not in a monorepo or no provider detected
      if _auto_switch_state.current_monorepo then
        AutoSwitch._clear_monorepo_state()
      end
      return
    end

    -- Check if we're in a different monorepo
    if _auto_switch_state.current_monorepo and _auto_switch_state.current_monorepo.root_path ~= root_path then
      AutoSwitch._clear_monorepo_state()
    end

    -- Update current monorepo state
    _auto_switch_state.current_monorepo = {
      root_path = root_path,
      provider = provider,
      detection_info = detection_info,
    }

    -- Find workspaces
    local workspaces = WorkspaceFinder.find_workspaces(root_path, provider)
    if #workspaces == 0 then
      return
    end

    -- Find current workspace for the file
    local current_workspace = WorkspaceManager.find_workspace_for_file(file_path, workspaces)
    local previous_workspace = WorkspaceManager.get_current()

    -- Only switch if workspace has actually changed
    if current_workspace and current_workspace ~= previous_workspace then
      WorkspaceManager.set_current(current_workspace)
      Throttle.update_workspace(current_workspace)
      
      -- Note: Notifications are now handled in the main ecolog module
      -- after environment reloading is complete
    end
  end)

  if not success then
    -- Silently handle errors to avoid disrupting user workflow
    vim.notify("Auto-switch error: " .. tostring(err), vim.log.levels.DEBUG)
  end
end

---Clear monorepo state when leaving monorepo
function AutoSwitch._clear_monorepo_state()
  _auto_switch_state.current_monorepo = nil
  WorkspaceManager.set_current(nil)
  Throttle.update_workspace(nil)
end

---Notify about workspace change
---@param current_workspace table Current workspace
---@param previous_workspace table? Previous workspace
function AutoSwitch._notify_workspace_change(current_workspace, previous_workspace)
  -- Get the selected environment file information
  local selected_env_file = AutoSwitch._get_selected_env_file_info(current_workspace)
  
  local message
  if selected_env_file then
    message = string.format("Selected environment file: %s (%s)", selected_env_file.name, selected_env_file.location)
  else
    -- Fallback to workspace name if no env file is found
    message = string.format("Entered workspace: %s", current_workspace.name)
  end

  vim.notify(message, vim.log.levels.INFO)
end

---Get selected environment file information for a workspace
---@param workspace table Workspace information
---@return table? env_file_info Information about the selected environment file
function AutoSwitch._get_selected_env_file_info(workspace)
  if not workspace then
    return nil
  end
  
  -- Get the current ecolog state to find the selected environment file
  local ecolog = require("ecolog")
  local state = ecolog.get_state()
  
  if not state.selected_env_file then
    return nil
  end
  
  -- Extract the filename from the full path
  local filename = vim.fn.fnamemodify(state.selected_env_file, ":t")
  
  -- Create a readable location string
  local location = string.format("%s/%s", workspace.type, workspace.name)
  
  return {
    name = filename,
    location = location,
    full_path = state.selected_env_file
  }
end

---Enable auto-switching
function AutoSwitch.enable()
  if not _auto_switch_state.config then
    vim.notify("Auto-switch not configured. Call setup() first.", vim.log.levels.WARN)
    return
  end

  _auto_switch_state.enabled = true
  AutoSwitch._setup_autocmds()

  -- Perform immediate check
  vim.schedule(function()
    AutoSwitch._handle_buffer_change()
  end)
end

---Disable auto-switching
function AutoSwitch.disable()
  _auto_switch_state.enabled = false

  if _auto_switch_state.augroup then
    vim.api.nvim_del_augroup_by_id(_auto_switch_state.augroup)
    _auto_switch_state.augroup = nil
  end

  Throttle.reset()
end

---Check if auto-switching is enabled
---@return boolean enabled Whether auto-switching is enabled
function AutoSwitch.is_enabled()
  return _auto_switch_state.enabled
end

---Get current monorepo state
---@return table? monorepo_state Current monorepo state or nil
function AutoSwitch.get_current_monorepo()
  return _auto_switch_state.current_monorepo
end

---Manually trigger workspace detection and switching
---@param file_path? string Optional file path to check (defaults to current buffer)
function AutoSwitch.manual_switch(file_path)
  file_path = file_path or vim.api.nvim_buf_get_name(0)
  if file_path and file_path ~= "" then
    AutoSwitch._perform_workspace_check(file_path, true)
  end
end

---Get auto-switch statistics
---@return table stats Auto-switch performance and throttle statistics
function AutoSwitch.get_stats()
  return {
    enabled = _auto_switch_state.enabled,
    current_monorepo = _auto_switch_state.current_monorepo,
    current_workspace = WorkspaceManager.get_current(),
    throttle = Throttle.get_stats(),
    detection = Detection.get_stats(),
  }
end

---Configure auto-switch settings
---@param config table Auto-switch configuration
function AutoSwitch.configure(config)
  if config.enabled ~= nil then
    if config.enabled then
      AutoSwitch.enable()
    else
      AutoSwitch.disable()
    end
  end

  if config.throttle then
    Throttle.configure(config.throttle)
  end

  if config.notify_on_switch ~= nil then
    _auto_switch_state.config = _auto_switch_state.config or {}
    _auto_switch_state.config.notify_on_switch = config.notify_on_switch
  end
end

return AutoSwitch

