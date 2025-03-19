local M = {}

---Get sorted environment variables based on config.sort_var_fn
---@return table[] List of sorted environment variables
function M.get_sorted_vars()
  local ecolog = require("ecolog")
  local env_vars = ecolog.get_env_vars()
  local config = ecolog.get_config()

  local var_entries = {}
  for name, info in pairs(env_vars) do
    table.insert(var_entries, vim.tbl_extend("force", { name = name }, info))
  end

  if config.sort_var_fn and type(config.sort_var_fn) == "function" then
    table.sort(var_entries, function(a, b)
      return config.sort_var_fn(a, b)
    end)
  end

  return var_entries
end

---Format environment variables for display with masked values
---@param module_name string Name of the calling module (for shelter context)
---@param mask_on_copy boolean Whether to mask values when copying
---@return table[] Formatted environment variables
function M.format_env_vars_for_picker(module_name)
  local shelter = require("ecolog.shelter")
  local var_entries = M.get_sorted_vars()

  local result = {}
  for idx, entry in ipairs(var_entries) do
    local masked_value = shelter.mask_value(entry.value, module_name, entry.name, entry.source)

    table.insert(result, {
      name = entry.name,
      value = entry.value,
      masked_value = masked_value,
      source = entry.source,
      type = entry.type,
      display = string.format("%-30s = %s", entry.name, masked_value),
      idx = idx,
    })
  end

  return result
end

return M

