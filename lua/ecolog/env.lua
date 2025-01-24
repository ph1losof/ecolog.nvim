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

function M.setup()
  vim.api.nvim_create_user_command("EcologEnvGet", function(cmd_opts)
    local var = cmd_opts.args
    local value = M.get(var)
    if value then
      print(value.value)
    else
      print("Variable not found: " .. var)
    end
  end, {
    nargs = 1,
    desc = "Get environment variable value",
  })

  M.update_env_vars()
end

return M
