---Centralized lazy-loading utilities for ecolog modules
---@module ecolog.core.lazy_loader
local M = {}

-- Module cache for lazy-loaded modules
local _module_cache = {}

---Require a module on demand (with caching)
---@param module_name string The module path to require
---@return table module The loaded module
function M.require_on_demand(module_name)
  if not _module_cache[module_name] then
    _module_cache[module_name] = require(module_name)
  end
  return _module_cache[module_name]
end

---Create a lazy proxy for a module
---Access to any key triggers the require
---@param module_name string The module path to require
---@return table proxy A proxy table that lazy-loads the module
function M.lazy(module_name)
  return setmetatable({}, {
    __index = function(_, key)
      return M.require_on_demand(module_name)[key]
    end,
    __call = function(_, ...)
      local mod = M.require_on_demand(module_name)
      if type(mod) == "function" then
        return mod(...)
      end
      return mod
    end,
  })
end

---Create a lazy getter function for a module
---Useful for replacing `local function get_X()` patterns
---@param module_name string The module path to require
---@return function getter A function that returns the module when called
function M.getter(module_name)
  return function()
    return M.require_on_demand(module_name)
  end
end

---Clear the module cache (useful for testing)
function M.clear_cache()
  _module_cache = {}
end

---Check if a module is loaded
---@param module_name string The module path to check
---@return boolean is_loaded Whether the module is cached
function M.is_loaded(module_name)
  return _module_cache[module_name] ~= nil
end

return M
