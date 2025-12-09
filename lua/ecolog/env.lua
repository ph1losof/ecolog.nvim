local M = {}
local utils = require("ecolog.utils")

local added_vars = {}

function M.update_env_vars()
  local ecolog = require("ecolog")
  local env_vars = ecolog.get_env_vars()
  local config = ecolog.get_config()

  if config.vim_env == false then
    return
  end

  for key, _ in pairs(added_vars) do
    utils.unset_env_var(key)
  end

  added_vars = {}
  for key, var_info in pairs(env_vars) do
    utils.set_env_var(key, var_info.value)
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
  local config = ecolog.get_config()
  local types = require("ecolog.types")

  local type_name, transformed_value = types.detect_type(value)

  local source = "shell"

  if env_vars[key] and env_vars[key].source then
    source = env_vars[key].source
  end

  env_vars[key] = {
    value = transformed_value,
    type = type_name,
    raw_value = value,
    source = source,
  }

  if config.vim_env ~= false then
    utils.set_env_var(key, transformed_value)
    added_vars[key] = true
  end

  return env_vars[key]
end

function M.setup()
  M.update_env_vars()
end

return M
