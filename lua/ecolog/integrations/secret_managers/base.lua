local M = {}

local api = vim.api
local ecolog = require("ecolog")
local utils = require("ecolog.utils")
local secret_utils = require("ecolog.integrations.secret_managers.utils")

---@class BaseSecretManagerConfig
---@field enabled boolean Enable loading secrets into environment
---@field override boolean When true, secrets take precedence over .env files and shell variables
---@field filter? fun(key: string, value: any): boolean Optional function to filter which secrets to load
---@field transform? fun(key: string, value: any): any Optional function to transform secret values

---@class SecretManagerState
---@field selected_secrets string[] List of currently selected secret names
---@field config BaseSecretManagerConfig|nil
---@field loading boolean
---@field loaded_secrets table<string, table>
---@field active_jobs table<number, boolean>
---@field is_refreshing boolean
---@field skip_load boolean
---@field loading_lock table|nil
---@field timeout_timer number|nil
---@field initialized boolean
---@field pending_env_updates function[]

---@class BaseSecretManager
---@field state SecretManagerState
---@field config BaseSecretManagerConfig|nil
---@field source_prefix string
---@field manager_name string
local BaseSecretManager = {}

function BaseSecretManager:new(source_prefix, manager_name)
  local instance = {
    state = {
      selected_secrets = {},
      config = nil,
      loading = false,
      loaded_secrets = {},
      active_jobs = {},
      is_refreshing = false,
      skip_load = false,
      loading_lock = nil,
      timeout_timer = nil,
      initialized = false,
      pending_env_updates = {},
    },
    config = nil,
    source_prefix = source_prefix,
    manager_name = manager_name,
  }
  setmetatable(instance, { __index = self })
  return instance
end

---Initialize the secret manager with configuration
---@param config BaseSecretManagerConfig
function BaseSecretManager:init(config)
  self.config = config
  self.state.config = config
  self:load_secrets(config)
end

---Load secrets from the manager
---@param config BaseSecretManagerConfig
function BaseSecretManager:load_secrets(config)
  if self.state.loading_lock then
    return self.state.loaded_secrets or {}
  end

  if self.state.skip_load then
    return self.state.loaded_secrets or {}
  end

  if self.state.initialized and not self.state.is_refreshing then
    return self.state.loaded_secrets or {}
  end

  self.state.loading_lock = {}
  self.state.loading = true
  self.state.pending_env_updates = {}

  self.config = config
  self.state.config = config

  if not config.enabled then
    local current_env = ecolog.get_env_vars() or {}
    local final_vars = {}

    for key, value in pairs(current_env) do
      if not (value.source and value.source:match("^" .. self.source_prefix)) then
        final_vars[key] = value
      end
    end

    self.state.selected_secrets = {}
    self.state.loaded_secrets = {}
    self.state.initialized = true

    secret_utils.update_environment(final_vars, false, self.source_prefix)
    secret_utils.cleanup_state(self.state)
    return {}
  end

  return self:_load_secrets_impl(config)
end

---Implementation specific loading of secrets
---@protected
---@param config BaseSecretManagerConfig
function BaseSecretManager:_load_secrets_impl(config)
  error("_load_secrets_impl must be implemented by the derived class")
end

---Select secrets from the manager
function BaseSecretManager:select()
  if not self.state.config or not self.state.config.enabled then
    return
  end

  self:_select_impl()
end

---Implementation specific selection of secrets
---@protected
function BaseSecretManager:_select_impl()
  error("_select_impl must be implemented by the derived class")
end

---Process a batch of secrets in parallel
---@param secrets table<string, table> Table to store loaded secrets
---@param start_job fun(index: number) Function to start a job for a specific index
function BaseSecretManager:process_secrets_parallel(secrets, start_job)
  return secret_utils.process_secrets_parallel(self.config, self.state, secrets, {
    source_prefix = self.source_prefix,
    manager_name = self.manager_name,
  }, start_job)
end

---Process a secret value
---@param secret_value string
---@param source_path string
---@param secrets table<string, table>
function BaseSecretManager:process_secret_value(secret_value, source_path, secrets)
  return secret_utils.process_secret_value(secret_value, {
    filter = self.config.filter,
    transform = self.config.transform,
    source_prefix = self.source_prefix,
    source_path = source_path,
  }, secrets)
end

---Handle cleanup on vim exit
function BaseSecretManager:setup_cleanup()
  api.nvim_create_autocmd("VimLeavePre", {
    group = api.nvim_create_augroup("Ecolog" .. self.manager_name .. "Cleanup", { clear = true }),
    callback = function()
      secret_utils.cleanup_jobs(self.state.active_jobs)
    end,
  })
end

---Get available configuration options for the manager
---@protected
---@return table<string, { name: string, current: string|nil, options: string[]|nil, type: "multi-select"|"single-select"|"input" }>
function BaseSecretManager:_get_config_options()
  return {}
end

---Handle configuration change
---@protected
---@param option string The configuration option being changed
---@param value any The new value
function BaseSecretManager:_handle_config_change(option, value)
  -- To be implemented by derived classes
end

---Handle single select option
---@private
---@param option table The option configuration
---@param option_name string The name of the option
function BaseSecretManager:_handle_single_select(option, option_name)
  local current_value = option.current
  local select_idx = 1

  for i, value in ipairs(option.options) do
    if value == current_value then
      select_idx = i
      break
    end
  end

  local select_bufnr = api.nvim_create_buf(false, true)
  local select_winid = api.nvim_open_win(select_bufnr, true, utils.create_minimal_win_opts(30, #option.options))

  local function update_select_buffer()
    local content = {}
    for i, value in ipairs(option.options) do
      local prefix = i == select_idx and " → " or "   "
      table.insert(content, string.format("%s%s", prefix, value))
    end

    api.nvim_buf_set_option(select_bufnr, "modifiable", true)
    api.nvim_buf_set_lines(select_bufnr, 0, -1, false, content)
    api.nvim_buf_set_option(select_bufnr, "modifiable", false)

    api.nvim_buf_clear_namespace(select_bufnr, -1, 0, -1)
    for i = 1, #content do
      local hl_group = i == select_idx and "EcologCursor" or "EcologVariable"
      api.nvim_buf_add_highlight(select_bufnr, -1, hl_group, i - 1, 0, -1)
    end

    api.nvim_win_set_cursor(select_winid, { select_idx, 4 })
  end

  local function close_select_window()
    if api.nvim_win_is_valid(select_winid) then
      api.nvim_win_close(select_winid, true)
    end
  end

  api.nvim_buf_set_option(select_bufnr, "buftype", "nofile")
  api.nvim_buf_set_option(select_bufnr, "bufhidden", "wipe")
  api.nvim_buf_set_option(select_bufnr, "modifiable", true)
  api.nvim_buf_set_option(select_bufnr, "filetype", "ecolog")

  api.nvim_win_set_option(select_winid, "conceallevel", 2)
  api.nvim_win_set_option(select_winid, "concealcursor", "niv")
  api.nvim_win_set_option(select_winid, "cursorline", true)
  api.nvim_win_set_option(select_winid, "winhl", "Normal:EcologNormal,FloatBorder:EcologBorder")

  vim.keymap.set("n", "j", function()
    if select_idx < #option.options then
      select_idx = select_idx + 1
      update_select_buffer()
    end
  end, { buffer = select_bufnr, nowait = true })

  vim.keymap.set("n", "k", function()
    if select_idx > 1 then
      select_idx = select_idx - 1
      update_select_buffer()
    end
  end, { buffer = select_bufnr, nowait = true })

  vim.keymap.set("n", "<CR>", function()
    local selected_value = option.options[select_idx]
    close_select_window()
    self:_handle_config_change(option_name, selected_value)
  end, { buffer = select_bufnr, nowait = true })

  vim.keymap.set("n", "q", close_select_window, { buffer = select_bufnr, nowait = true })
  vim.keymap.set("n", "<ESC>", close_select_window, { buffer = select_bufnr, nowait = true })

  api.nvim_create_autocmd("BufLeave", {
    buffer = select_bufnr,
    once = true,
    callback = close_select_window,
  })

  update_select_buffer()
end

---Handle multi select option
---@private
---@param option table The option configuration
---@param option_name string The name of the option
function BaseSecretManager:_handle_multi_select(option, option_name)
  local function show_selection_ui(options_list)
    local selected = {}
    local current_value = option.current
    if current_value and current_value ~= "none" then
      local current_values = vim.split(current_value, ",")
      for _, value in ipairs(current_values) do
        local trimmed = vim.trim(value)
        if trimmed ~= "" then
          selected[trimmed] = true
        end
      end
    end

    local filtered_options = vim.tbl_filter(function(opt)
      return type(opt) == "string" and opt ~= ""
    end, options_list)

    if #filtered_options == 0 then
      vim.notify("No valid options available", vim.log.levels.WARN)
      return
    end

    secret_utils.create_secret_selection_ui(filtered_options, selected, function(selected_options)
      local valid_selections = {}
      for opt, is_selected in pairs(selected_options) do
        if type(opt) == "string" and opt ~= "" then
          valid_selections[opt] = is_selected
        end
      end
      self:_handle_config_change(option_name, valid_selections)
    end, self.source_prefix)
  end

  if option.dynamic_options then
    vim.notify("Loading options...", vim.log.levels.INFO)
    option.dynamic_options(function(options_list)
      if not options_list or #options_list == 0 then
        vim.notify("No options available", vim.log.levels.WARN)
        return
      end
      show_selection_ui(options_list)
    end)
  else
    show_selection_ui(option.options or {})
  end
end

---Show configuration selection UI
---@param direct_option? string Optional configuration option to select directly
function BaseSecretManager:select_config(direct_option)
  local options = self:_get_config_options()
  if vim.tbl_isempty(options) then
    vim.notify("No configurable options available for " .. self.manager_name, vim.log.levels.WARN)
    return
  end

  if direct_option then
    local option_name, matched_option

    if options[direct_option] then
      option_name = direct_option
      matched_option = options[direct_option]
    else
      local direct_lower = direct_option:lower()
      for name, option in pairs(options) do
        if name:lower() == direct_lower or (option.name and option.name:lower() == direct_lower) then
          option_name = name
          matched_option = option
          break
        end
      end
    end

    if not option_name or not matched_option then
      vim.notify("Invalid configuration option: " .. direct_option, vim.log.levels.ERROR)
      return
    end

    if matched_option.type == "multi-select" then
      self:_handle_multi_select(matched_option, option_name)
      return
    elseif matched_option.type == "single-select" and matched_option.options then
      self:_handle_single_select(matched_option, option_name)
      return
    elseif matched_option.type == "input" then
      vim.ui.input({
        prompt = string.format("Enter %s: ", matched_option.name),
        default = matched_option.current or "",
      }, function(value)
        if value then
          self:_handle_config_change(option_name, value)
        end
      end)
      return
    end
  end

  local option_names = vim.tbl_keys(options)
  table.sort(option_names)

  local cursor_idx = 1
  local function get_content()
    local content = {}
    for i, option_name in ipairs(option_names) do
      local option = options[option_name]
      local current = option.current or "not set"
      local prefix = i == cursor_idx and " → " or "   "
      table.insert(content, string.format("%s%s: %s", prefix, option.name, current))
    end
    return content
  end

  local float_opts = utils.create_minimal_win_opts(60, #option_names)
  local bufnr = api.nvim_create_buf(false, true)

  api.nvim_buf_set_option(bufnr, "buftype", "nofile")
  api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
  api.nvim_buf_set_option(bufnr, "modifiable", true)
  api.nvim_buf_set_option(bufnr, "filetype", "ecolog")

  local winid = api.nvim_open_win(bufnr, true, float_opts)

  api.nvim_win_set_option(winid, "conceallevel", 2)
  api.nvim_win_set_option(winid, "concealcursor", "niv")
  api.nvim_win_set_option(winid, "cursorline", true)
  api.nvim_win_set_option(winid, "winhl", "Normal:EcologNormal,FloatBorder:EcologBorder")

  local function update_buffer()
    local content = get_content()
    api.nvim_buf_set_option(bufnr, "modifiable", true)
    api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
    api.nvim_buf_set_option(bufnr, "modifiable", false)

    api.nvim_buf_clear_namespace(bufnr, -1, 0, -1)
    for i = 1, #content do
      local hl_group = i == cursor_idx and "EcologCursor" or "EcologVariable"
      api.nvim_buf_add_highlight(bufnr, -1, hl_group, i - 1, 0, -1)
    end

    api.nvim_win_set_cursor(winid, { cursor_idx, 4 })
  end

  local function close_window()
    if api.nvim_win_is_valid(winid) then
      api.nvim_win_close(winid, true)
    end
  end

  local function handle_option_selection()
    local option_name = option_names[cursor_idx]
    local option = options[option_name]

    if option.type == "multi-select" then
      self:_handle_multi_select(option, option_name)
    elseif option.type == "single-select" and option.options then
      close_window()
      self:_handle_single_select(option, option_name)
    elseif option.type == "input" then
      close_window()
      vim.ui.input({
        prompt = string.format("Enter %s: ", option.name),
        default = option.current or "",
      }, function(value)
        if value then
          self:_handle_config_change(option_name, value)
        end
      end)
    end
  end

  vim.keymap.set("n", "j", function()
    if cursor_idx < #option_names then
      cursor_idx = cursor_idx + 1
      update_buffer()
    end
  end, { buffer = bufnr, nowait = true })

  vim.keymap.set("n", "k", function()
    if cursor_idx > 1 then
      cursor_idx = cursor_idx - 1
      update_buffer()
    end
  end, { buffer = bufnr, nowait = true })

  vim.keymap.set("n", "<CR>", handle_option_selection, { buffer = bufnr, nowait = true })
  vim.keymap.set("n", "q", close_window, { buffer = bufnr, nowait = true })
  vim.keymap.set("n", "<ESC>", close_window, { buffer = bufnr, nowait = true })

  api.nvim_create_autocmd("BufLeave", {
    buffer = bufnr,
    once = true,
    callback = close_window,
  })

  update_buffer()
end

M.BaseSecretManager = BaseSecretManager
return M
