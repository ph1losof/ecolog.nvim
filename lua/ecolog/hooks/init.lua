---@class EcologHooks
---Hook system for shelter.nvim and other integrations
local M = {}

local notify = require("ecolog.notification_manager")

---@alias EcologHookName
---| "on_lsp_attach"          # (ctx: {client, bufnr}) - LSP attached
---| "on_variables_list"      # (vars: EcologVariable[]) -> EcologVariable[] - Filter/mask vars
---| "on_variable_hover"      # (var: EcologVariable) -> EcologVariable - Filter single var
---| "on_variable_peek"       # (var: EcologVariable) -> EcologVariable - Before showing peek
---| "on_active_file_changed" # (ctx: {patterns, result}) - Active file changed
---| "on_picker_entry"        # (entry: table) -> table - Transform picker entry

---@class EcologVariable
---@field name string Variable name
---@field value string Variable value (possibly masked)
---@field source string Source description (file path, "System Environment", etc.)
---@field type? string Variable type (string, number, boolean, url, etc.)
---@field comment? string Associated comment

---@class EcologHookEntry
---@field id string Unique hook ID
---@field priority number Higher = runs first (default: 100)
---@field callback function Hook callback

---@type table<EcologHookName, EcologHookEntry[]>
local hooks = {}

---Register a hook
---@param name EcologHookName Hook name
---@param callback function Hook callback
---@param opts? { id?: string, priority?: number }
---@return string id Hook ID for unregistering
function M.register(name, callback, opts)
  opts = opts or {}
  local id = opts.id or tostring(callback)
  local priority = opts.priority or 100

  hooks[name] = hooks[name] or {}

  -- Check if already registered with same ID
  for i, entry in ipairs(hooks[name]) do
    if entry.id == id then
      hooks[name][i] = { id = id, priority = priority, callback = callback }
      M._sort_hooks(name)
      return id
    end
  end

  table.insert(hooks[name], {
    id = id,
    priority = priority,
    callback = callback,
  })

  M._sort_hooks(name)
  return id
end

---Unregister a hook
---@param name EcologHookName Hook name
---@param id string Hook ID
function M.unregister(name, id)
  if not hooks[name] then
    return
  end

  for i, entry in ipairs(hooks[name]) do
    if entry.id == id then
      table.remove(hooks[name], i)
      return
    end
  end
end

---Fire hooks (no return value expected)
---@param name EcologHookName Hook name
---@param ctx any Context passed to hooks
function M.fire(name, ctx)
  if not hooks[name] then
    return
  end

  for _, entry in ipairs(hooks[name]) do
    local ok, err = pcall(entry.callback, ctx)
    if not ok then
      notify.warn(string.format("Hook '%s' (%s) error: %s", name, entry.id, err))
    end
  end
end

---Fire filter hooks (return transformed value)
---Each hook receives the result of the previous hook
---@param name EcologHookName Hook name
---@param value any Initial value
---@return any Transformed value
function M.fire_filter(name, value)
  if not hooks[name] then
    return value
  end

  local result = value
  for _, entry in ipairs(hooks[name]) do
    local ok, transformed = pcall(entry.callback, result)
    if ok and transformed ~= nil then
      result = transformed
    elseif not ok then
      notify.warn(string.format("Hook '%s' (%s) error: %s", name, entry.id, transformed))
    end
  end

  return result
end

---Check if any hooks are registered for a name
---@param name EcologHookName Hook name
---@return boolean
function M.has_hooks(name)
  return hooks[name] ~= nil and #hooks[name] > 0
end

---Get all registered hook names
---@return EcologHookName[]
function M.list()
  local names = {}
  for name in pairs(hooks) do
    table.insert(names, name)
  end
  return names
end

---Clear all hooks (for testing)
function M._clear()
  hooks = {}
end

---Sort hooks by priority (higher first)
---@param name EcologHookName
function M._sort_hooks(name)
  if hooks[name] then
    table.sort(hooks[name], function(a, b)
      return a.priority > b.priority
    end)
  end
end

return M
