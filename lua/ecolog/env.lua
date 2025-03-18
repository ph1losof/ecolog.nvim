local M = {}

local added_vars = {}

function M.update_env_vars()
  local ecolog = require("ecolog")
  local env_vars = ecolog.get_env_vars()

  for key, _ in pairs(added_vars) do
    if not env_vars[key] then
      vim.env[key] = nil
    end
  end

  added_vars = {}
  for key, var_info in pairs(env_vars) do
    vim.env[key] = var_info.value
    added_vars[key] = true
  end
end

function M.get(key)
  local ecolog = require("ecolog")
  local env_vars = ecolog.get_env_vars()

  if not key then
    return env_vars
  end
  return env_vars[key]
end

function M.set(key, value)
  local ecolog = require("ecolog")
  local env_vars = ecolog.get_env_vars()
  local types = require("ecolog.types")
  
  local type_name, transformed_value = types.detect_type(value)
  
  env_vars[key] = {
    value = transformed_value,
    type = type_name,
    raw_value = value,
    source = "shell",
  }
  
  vim.env[key] = transformed_value
  added_vars[key] = true
  
  return env_vars[key]
end

function M.setup()
  M.update_env_vars()
end

return M
