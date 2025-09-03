local types = require("ecolog.types")

---@class LoadShellConfig
---@field enabled boolean Enable loading shell variables into environment
---@field override boolean When true, shell variables take precedence over .env files
---@field filter? function Optional function to filter which shell variables to load
---@field transform? function Optional function to transform shell variable values

local M = {}

---@param config boolean|LoadShellConfig
---@return table<string, table>
function M.load_shell_vars(config)
  if config == nil then
    config = { enabled = false, override = false }
  end
  
  local shell_config = type(config) == "table" and config or { enabled = config, override = false }

  local shell_vars = {}
  local raw_vars = vim.fn.environ()

  if shell_config.filter then
    local filtered_vars = {}
    for key, value in pairs(raw_vars) do
      if shell_config.filter(key, value) then
        filtered_vars[key] = value
      end
    end
    raw_vars = filtered_vars
  end

  for key, value in pairs(raw_vars) do
    if shell_config.transform then
      value = shell_config.transform(key, value)
    end

    local type_name, transformed_value = types.detect_type(value)

    shell_vars[key] = {
      value = transformed_value or value,
      type = type_name,
      raw_value = value,
      source = "shell",
      comment = nil,
    }
  end

  return shell_vars
end

return M

