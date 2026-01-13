---@class EcologLspCommands
---Wrappers for ecolog-lsp executeCommand requests
local M = {}

local lsp = require("ecolog.lsp")
local hooks = require("ecolog.hooks")
local state = require("ecolog.state")
local notify = require("ecolog.notification_manager")

---Refresh all statusline state (files, variables, sources)
---Call this when env files change, are deleted, or need manual refresh
---@param file_path? string Optional file path for context
---@param callback? fun() Optional callback when refresh is complete
function M.refresh_state(file_path, callback)
  local client = lsp.get_client()
  if not client then
    if callback then
      callback()
    end
    return
  end

  local pending = 3
  local function done()
    pending = pending - 1
    if pending == 0 then
      -- Invalidate statusline cache
      local statusline_ok, statusline = pcall(require, "ecolog.statusline")
      if statusline_ok and statusline.invalidate_cache then
        statusline.invalidate_cache()
      end
      if callback then
        callback()
      end
    end
  end

  -- Refresh active files
  M.list_files(file_path, function(files)
    if files and #files > 0 then
      state.set_active_files(files)
    else
      state.set_active_files({})
    end
    done()
  end)

  -- Refresh variable count
  -- Note: list_variables updates state.var_count internally on success
  M.list_variables(file_path, function()
    done()
  end)

  -- Refresh enabled sources
  M.list_sources(function(sources)
    if sources and #sources > 0 then
      local enabled = { shell = false, file = false }
      for _, src in ipairs(sources) do
        local key = src.name:lower()
        if enabled[key] ~= nil then
          enabled[key] = src.enabled
        end
      end
      state.set_enabled_sources(enabled)
    end
    done()
  end)
end

---List all environment variables
---@param file_path? string Optional file path for package scoping
---@param callback fun(vars: EcologVariable[])
function M.list_variables(file_path, callback)
  -- Handle backwards compatibility: if first arg is a function, it's the callback
  if type(file_path) == "function" then
    callback = file_path
    file_path = nil
  end

  local args = {}
  if file_path then
    args = { file_path }
  end

  lsp.execute_command("ecolog.listEnvVariables", args, function(err, result)
    if err then
      notify.error(err.message or "Failed to list variables")
      -- Don't update state on error - preserve previous count
      callback({})
      return
    end

    local vars = {}
    if result and result.variables then
      vars = result.variables
    elseif result and type(result) == "table" and result[1] then
      -- Handle array response
      vars = result
    end

    -- Fire hook for masking before returning
    local processed_vars = hooks.fire_filter("on_variables_list", vars)

    -- Apply custom sorting if configured
    local config = require("ecolog.config")
    local sort_fn = config.get_sort_var_fn()
    if sort_fn and processed_vars and #processed_vars > 0 then
      table.sort(processed_vars, sort_fn)
    end

    callback(processed_vars or vars)

    -- Sync to vim.env if enabled (use raw vars, not masked)
    if config.get_vim_env() then
      local vim_env = require("ecolog.vim_env")
      vim_env.sync(vars)
    end

    -- Update state with count only on successful response
    state.set_var_count(#vars)
  end)
end

---List available env files
---@param file_path? string Optional file path for package scoping
---@param opts? { all?: boolean } Options: all=true returns all registered files (for pickers)
---@param callback fun(files: string[])
function M.list_files(file_path, opts, callback)
  -- Handle backwards compatibility for different call signatures:
  -- list_files(callback)
  -- list_files(file_path, callback)
  -- list_files(file_path, opts, callback)
  if type(file_path) == "function" then
    callback = file_path
    file_path = nil
    opts = nil
  elseif type(opts) == "function" then
    callback = opts
    opts = nil
  end

  local args = {}
  if file_path then
    table.insert(args, file_path)
  end

  -- Add 'all' flag as second argument if specified
  if opts and opts.all then
    if #args == 0 then
      table.insert(args, vim.NIL) -- placeholder for file_path
    end
    table.insert(args, true)
  end

  lsp.execute_command("ecolog.file.list", args, function(err, result)
    if err then
      notify.error(err.message or "Failed to list files")
      callback({})
      return
    end

    local files = {}
    if result and result.files then
      files = result.files
    elseif result and type(result) == "table" and type(result[1]) == "string" then
      files = result
    end

    callback(files)
  end)
end

---Set active env file(s)
---@param patterns string[] File patterns to activate
---@param callback? fun(success: boolean)
function M.set_active_file(patterns, callback)
  lsp.execute_command("ecolog.file.setActive", patterns, function(err, result)
    local success = not err and result and result.success

    if success then
      state.set_active_files(patterns)

      -- Re-query variable count for updated statusline
      -- Note: list_variables updates state.var_count internally on success
      local current_file = vim.api.nvim_buf_get_name(0)
      M.list_variables(current_file ~= "" and current_file or nil, function()
        -- Invalidate statusline cache to reflect changes
        local statusline_ok, statusline = pcall(require, "ecolog.statusline")
        if statusline_ok and statusline.invalidate_cache then
          statusline.invalidate_cache()
        end
      end)
    end

    if callback then
      callback(success)
    end

    -- Fire hook for file change
    hooks.fire("on_active_file_changed", { patterns = patterns, result = result, success = success })
  end)
end

---Generate .env.example content
---@param callback fun(content: string, count: number)
function M.generate_example(callback)
  lsp.execute_command("ecolog.generateEnvExample", {}, function(err, result)
    if err then
      notify.error(err.message or "Failed to generate example")
      callback("", 0)
      return
    end

    local content = ""
    local count = 0

    if result then
      content = result.content or result.example or ""
      count = result.count or 0
    end

    callback(content, count)
  end)
end

---Get variable at cursor position (uses hover internally)
---@param bufnr? number
---@param callback fun(var: EcologVariable|nil)
function M.get_variable_at_cursor(bufnr, callback)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local params = vim.lsp.util.make_position_params()
  local client = lsp.get_client()

  if not client then
    callback(nil)
    return
  end

  client:request("textDocument/hover", params, function(err, result)
    if err or not result then
      callback(nil)
      return
    end

    -- Parse hover result to extract variable info
    local var = M._parse_hover_result(result)
    if var then
      -- Fire hook for masking
      var = hooks.fire_filter("on_variable_hover", var) or var
    end
    callback(var)
  end, bufnr)
end

---Parse hover result to extract variable info
---@param result table LSP hover result
---@return EcologVariable|nil
function M._parse_hover_result(result)
  if not result or not result.contents then
    return nil
  end

  local content = result.contents
  if type(content) == "table" then
    if content.kind == "markdown" or content.kind == "plaintext" then
      content = content.value
    elseif content.value then
      content = content.value
    elseif type(content[1]) == "string" then
      content = content[1]
    elseif type(content[1]) == "table" and content[1].value then
      content = content[1].value
    else
      return nil
    end
  end

  if type(content) ~= "string" then
    return nil
  end

  -- Parse markdown format from ecolog-lsp:
  -- **`VAR_NAME`**
  --
  -- **Value**: `value`
  --
  -- **Source**: `source`
  local name = content:match("%*%*`([^`]+)`%*%*")
  if not name then
    -- Try alternative format: `VAR_NAME`
    name = content:match("^`([^`]+)`")
  end

  local value = content:match("%*%*Value%*%*:%s*`([^`]*)`")
  if not value then
    value = content:match("Value:%s*`([^`]*)`")
  end

  local source = content:match("%*%*Source%*%*:%s*`([^`]*)`")
  if not source then
    source = content:match("Source:%s*`([^`]*)`")
  end

  local var_type = content:match("%*%*Type%*%*:%s*`([^`]*)`")
  if not var_type then
    var_type = content:match("Type:%s*`([^`]*)`")
  end

  if name then
    return {
      name = name,
      value = value or "",
      source = source or "",
      type = var_type,
    }
  end

  return nil
end

---Get a specific variable by name
---@param name string Variable name
---@param callback fun(var: EcologVariable|nil)
function M.get_variable(name, callback)
  lsp.execute_command("ecolog.variable.get", { name }, function(err, result)
    if err or not result then
      callback(nil)
      return
    end

    local var = {
      name = result.name or name,
      value = result.value or "",
      source = result.source or "",
      type = result.type,
    }

    -- Fire hook for masking
    var = hooks.fire_filter("on_variable_hover", var) or var
    callback(var)
  end)
end

---@class EcologSource
---@field name string Source name (Shell, File, Remote)
---@field enabled boolean Whether the source is enabled
---@field priority number Source priority (higher = more precedence)

---List all available sources with their enabled status
---@param callback fun(sources: EcologSource[])
function M.list_sources(callback)
  lsp.execute_command("ecolog.source.list", {}, function(err, result)
    if err then
      notify.error(err.message or "Failed to list sources")
      callback({})
      return
    end

    local sources = {}
    if result and result.sources then
      sources = result.sources
    end

    callback(sources)
  end)
end

---Set the source precedence (enable/disable sources)
---@param sources string[] Array of source names to enable (e.g., {"Shell", "File"})
---@param callback? fun(success: boolean)
function M.set_sources(sources, callback)
  -- Capture current state before change for intuitive notifications
  local old_sources = state.get_enabled_sources()

  lsp.execute_command("ecolog.source.setPrecedence", sources, function(err, result)
    local success = not err and result and result.success

    if callback then
      callback(success)
    end

    if success then
      -- Update state with new sources and refresh statusline
      M.list_sources(function(updated_sources)
        local enabled = { shell = false, file = false }
        local any_enabled = false

        if updated_sources and #updated_sources > 0 then
          for _, src in ipairs(updated_sources) do
            local key = src.name:lower()
            if enabled[key] ~= nil then
              enabled[key] = src.enabled
              if src.enabled then
                any_enabled = true
              end
            end
          end
          state.set_enabled_sources(enabled)
        end

        -- Generate intuitive notification message
        local changes = {}
        local source_names = { shell = "Shell", file = "File" }
        for key, name in pairs(source_names) do
          local was_enabled = old_sources[key]
          local is_enabled = enabled[key]
          if was_enabled ~= is_enabled then
            table.insert(changes, name .. (is_enabled and " enabled" or " disabled"))
          end
        end

        if #changes > 0 then
          notify.info(table.concat(changes, ", "))
        end

        -- If no sources are enabled, set count to 0 (workaround for LSP bug)
        if not any_enabled then
          state.set_var_count(0)
          local statusline_ok, statusline = pcall(require, "ecolog.statusline")
          if statusline_ok and statusline.invalidate_cache then
            statusline.invalidate_cache()
          end
          return
        end

        -- Re-query variable count (sources affect which variables are available)
        -- Note: list_variables updates state.var_count internally on success
        local current_file = vim.api.nvim_buf_get_name(0)
        M.list_variables(current_file ~= "" and current_file or nil, function()
          -- Invalidate statusline cache to reflect changes
          local statusline_ok, statusline = pcall(require, "ecolog.statusline")
          if statusline_ok and statusline.invalidate_cache then
            statusline.invalidate_cache()
          end
        end)
      end)
    elseif result and result.error then
      notify.error(result.error)
    end
  end)
end

---List workspaces (for monorepo support)
---@param callback fun(workspaces: table[])
function M.list_workspaces(callback)
  lsp.execute_command("ecolog.workspace.list", {}, function(err, result)
    if err then
      notify.error(err.message or "Failed to list workspaces")
      callback({})
      return
    end

    local workspaces = {}
    if result and result.workspaces then
      workspaces = result.workspaces
    end

    callback(workspaces)
  end)
end

---Set workspace root
---Changes the workspace root at runtime, re-detecting monorepo provider
---@param path string New workspace root path
---@param callback? fun(success: boolean, root: string|nil)
function M.set_root(path, callback)
  lsp.execute_command("ecolog.workspace.setRoot", { path }, function(err, result)
    if err then
      notify.error(err.message or "Failed to set workspace root")
      if callback then
        callback(false, nil)
      end
      return
    end

    if result and result.error then
      notify.error(result.error)
      if callback then
        callback(false, nil)
      end
      return
    end

    local success = result and result.success
    local root = result and result.root

    if callback then
      callback(success, root)
    end

    if success then
      hooks.fire("on_workspace_root_changed", { root = root })
    end
  end)
end

---Set interpolation enabled state
---@param enabled boolean Whether to enable interpolation
---@param callback? fun(success: boolean, enabled: boolean)
function M.set_interpolation(enabled, callback)
  lsp.execute_command("ecolog.interpolation.set", { enabled }, function(err, result)
    if err then
      notify.error(err.message or "Failed to set interpolation")
      if callback then
        callback(false, false)
      end
      return
    end

    -- Handle nil result (should not happen, but be defensive)
    if not result then
      notify.error("Unexpected nil result from interpolation.set command")
      if callback then
        callback(false, false)
      end
      return
    end

    local success = result.success == true
    -- result.enabled is a boolean, could be true or false (both are valid)
    local new_state = type(result.enabled) == "boolean" and result.enabled or false

    if success then
      state.set_interpolation_enabled(new_state)
    end

    if callback then
      callback(success, new_state)
    end
  end)
end

---Get interpolation enabled state
---@param callback fun(enabled: boolean)
function M.get_interpolation(callback)
  lsp.execute_command("ecolog.interpolation.get", {}, function(err, result)
    if err then
      callback(false)
      return
    end
    callback(result and result.enabled or false)
  end)
end

return M
