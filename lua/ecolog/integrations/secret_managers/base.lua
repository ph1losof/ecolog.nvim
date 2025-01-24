local M = {}

local api = vim.api
local ecolog = require("ecolog")
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

M.BaseSecretManager = BaseSecretManager
return M
