---@class EcologState
---Runtime state management for ecolog.nvim
local M = {}

---@class EcologEnabledSources
---@field shell boolean Whether Shell source is enabled
---@field file boolean Whether File source is enabled

---@class EcologStateData
---@field active_files string[] Currently active env files
---@field var_count number Number of loaded variables
---@field client_id? number LSP client ID
---@field initialized boolean Whether the plugin is initialized
---@field enabled_sources EcologEnabledSources Which sources are enabled
---@field interpolation_enabled boolean Whether interpolation is enabled

---@type EcologStateData
local state = {
  active_files = {},
  var_count = 0,
  client_id = nil,
  initialized = false,
  enabled_sources = { shell = true, file = true },
  interpolation_enabled = true,
}

---Get active env files
---@return string[]
function M.get_active_files()
  return state.active_files
end

---Get first active env file (for backward compatibility)
---@return string|nil
function M.get_active_file()
  return state.active_files[1]
end

---Set active env files
---@param files string[]
function M.set_active_files(files)
  state.active_files = files or {}
end

---Set active env file (for backward compatibility, wraps single file in array)
---@param file string|nil
function M.set_active_file(file)
  if file then
    state.active_files = { file }
  else
    state.active_files = {}
  end
end

---Get variable count
---@return number
function M.get_var_count()
  return state.var_count
end

---Set variable count
---@param count number
function M.set_var_count(count)
  state.var_count = count
end

---Get LSP client ID
---@return number|nil
function M.get_client_id()
  return state.client_id
end

---Set LSP client ID
---@param id number|nil
function M.set_client_id(id)
  state.client_id = id
end

---Check if plugin is initialized
---@return boolean
function M.is_initialized()
  return state.initialized
end

---Set initialized state
---@param initialized boolean
function M.set_initialized(initialized)
  state.initialized = initialized
end

---Get enabled sources
---@return EcologEnabledSources
function M.get_enabled_sources()
  return state.enabled_sources
end

---Set enabled sources
---@param sources EcologEnabledSources
function M.set_enabled_sources(sources)
  state.enabled_sources = sources or { shell = true, file = true }
end

---Initialize enabled sources from config defaults
---@param defaults? EcologSourceDefaults
function M.init_from_config(defaults)
  if defaults then
    state.enabled_sources = {
      shell = defaults.shell ~= false,
      file = defaults.file ~= false,
    }
  end
end

---Get interpolation enabled state
---@return boolean
function M.get_interpolation_enabled()
  return state.interpolation_enabled
end

---Set interpolation enabled state
---@param enabled boolean
function M.set_interpolation_enabled(enabled)
  state.interpolation_enabled = enabled
end

---Reset all state
function M.reset()
  state = {
    active_files = {},
    var_count = 0,
    client_id = nil,
    initialized = false,
    enabled_sources = { shell = true, file = true },
    interpolation_enabled = true,
  }
end

return M
