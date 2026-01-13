---@class EcologVimEnv
---Sync environment variables to vim.env
local M = {}

local added_vars = {} -- Track synced vars for cleanup

---Check if vim.uv API is available
local has_uv_setenv = vim.uv and vim.uv.os_setenv ~= nil
local has_uv_unsetenv = vim.uv and vim.uv.os_unsetenv ~= nil

---Set an environment variable
---@param key string
---@param value string
local function set_env_var(key, value)
  if has_uv_setenv then
    vim.uv.os_setenv(key, tostring(value))
  else
    vim.env[key] = value
  end
end

---Unset an environment variable
---@param key string
local function unset_env_var(key)
  if has_uv_unsetenv then
    vim.uv.os_unsetenv(key)
  else
    vim.env[key] = nil
  end
end

---Sync variables to vim.env
---@param vars EcologVariable[]
function M.sync(vars)
  -- Cleanup: remove previously synced vars
  for key, _ in pairs(added_vars) do
    unset_env_var(key)
  end
  added_vars = {}

  -- Sync new vars
  for _, var in ipairs(vars) do
    if var.name and var.value then
      set_env_var(var.name, var.value)
      added_vars[var.name] = true
    end
  end
end

---Clear all synced variables
function M.clear()
  for key, _ in pairs(added_vars) do
    unset_env_var(key)
  end
  added_vars = {}
end

---Get count of synced variables
---@return number
function M.count()
  local n = 0
  for _ in pairs(added_vars) do
    n = n + 1
  end
  return n
end

return M
