local M = {}

local _shelter = nil
local _providers = nil

-- Track state for cleanup
local _initialized = false
local _cleanup_handlers = {}
local _augroup_id = nil

-- Safe wrapper for external calls
local function safe_call(fn, ...)
  local success, result = pcall(fn, ...)
  if not success then
    vim.notify("omnifunc error: " .. tostring(result), vim.log.levels.ERROR)
    return nil
  end
  return result
end

-- Input validation helper
local function validate_input(value, expected_type, name)
  if not value then
    vim.notify("omnifunc: " .. name .. " is nil", vim.log.levels.WARN)
    return false
  end
  
  if expected_type and type(value) ~= expected_type then
    vim.notify("omnifunc: " .. name .. " expected " .. expected_type .. ", got " .. type(value), vim.log.levels.WARN)
    return false
  end
  
  return true
end

local function get_env_completion(findstart, base)
  -- Input validation
  if not validate_input(_providers, "table", "providers") then
    return findstart == 1 and -1 or {}
  end
  
  if not validate_input(_shelter, "table", "shelter") then
    return findstart == 1 and -1 or {}
  end
  
  local ok, ecolog = pcall(require, "ecolog")
  if not ok then
    vim.notify("omnifunc: failed to load ecolog", vim.log.levels.WARN)
    return findstart == 1 and -1 or {}
  end

  local config = safe_call(ecolog.get_config)
  if not config then
    return findstart == 1 and -1 or {}
  end

  local env_vars = safe_call(ecolog.get_env_vars)
  if not env_vars or vim.tbl_count(env_vars) == 0 then
    return findstart == 1 and -1 or {}
  end

  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  if not validate_input(line, "string", "line") then
    return findstart == 1 and -1 or {}
  end
  
  local line_to_cursor = line:sub(1, col)

  local should_complete = not (config.provider_patterns and config.provider_patterns.cmp)
  if config.provider_patterns and config.provider_patterns.cmp then
    local filetype = vim.bo.filetype
    if not validate_input(filetype, "string", "filetype") then
      return findstart == 1 and -1 or {}
    end
    
    local available_providers = safe_call(_providers.get_providers, filetype)
    if not available_providers then
      available_providers = {}
    end

    for _, provider in ipairs(available_providers) do
      if provider and provider.get_completion_trigger then
        local trigger = safe_call(provider.get_completion_trigger)
        if trigger and type(trigger) == "string" then
          local parts = vim.split(trigger, ".", { plain = true })
          local pattern = table.concat(
            vim.tbl_map(function(part)
              return vim.pesc(part)
            end, parts),
            "%."
          )

          local trigger_len = #trigger
          local text_before_cursor = line_to_cursor:sub(-trigger_len)

          if text_before_cursor == trigger or 
             (provider.pattern and type(provider.pattern) == "string" and 
              safe_call(string.match, text_before_cursor, "^" .. provider.pattern .. "$")) then
            should_complete = true
            break
          end
        end
      end
    end
  end

  if findstart == 1 then
    if not should_complete then
      return -1
    end
    return col
  end

  if not should_complete then
    return {}
  end

  local items = {}

  local var_entries = {}
  for var_name, info in pairs(env_vars) do
    if validate_input(var_name, "string", "var_name") and info then
      if base and type(base) == "string" then
        local var_lower = var_name:lower()
        local base_lower = base:lower()
        if var_lower:find(base_lower, 1, true) == 1 then
          table.insert(var_entries, vim.tbl_extend("force", { name = var_name }, info))
        end
      else
        table.insert(var_entries, vim.tbl_extend("force", { name = var_name }, info))
      end
    end
  end

  if config.sort_var_fn and type(config.sort_var_fn) == "function" then
    local success, err = pcall(function()
      table.sort(var_entries, function(a, b)
        return config.sort_var_fn(a, b)
      end)
    end)
    if not success then
      vim.notify("omnifunc: sort function error: " .. tostring(err), vim.log.levels.WARN)
    end
  end

  for _, entry in ipairs(var_entries) do
    if entry and entry.name then
      local display_value = entry.value
      if _shelter and _shelter.is_enabled then
        local is_enabled = safe_call(_shelter.is_enabled, "cmp")
        if is_enabled then
          display_value = safe_call(_shelter.mask_value, entry.value, "cmp", entry.name, entry.source) or entry.value
        end
      end

      local info = string.format("%s [%s] = %s", entry.name, entry.type or "unknown", display_value or "")
      if entry.comment then
        local comment_value = entry.comment
        if _shelter and _shelter.is_enabled and _shelter.get_config then
          local is_enabled = safe_call(_shelter.is_enabled, "cmp")
          local shelter_config = safe_call(_shelter.get_config)
          if is_enabled and shelter_config and not shelter_config.skip_comments then
            local utils = safe_call(require, "ecolog.shelter.utils")
            if utils and utils.mask_comment then
              comment_value = safe_call(utils.mask_comment, comment_value, entry.source, _shelter, "cmp") or comment_value
            end
          end
        end
        info = info .. " # " .. comment_value
      end

      -- Get workspace context for the source
      local utils = safe_call(require, "ecolog.utils")
      local source_display = entry.source or "unknown"
      if utils and utils.get_env_file_display_name then
        source_display = safe_call(utils.get_env_file_display_name, entry.source, config) or source_display
      end
      
      table.insert(items, {
        word = entry.name,
        kind = entry.type or "unknown",
        menu = source_display,
        info = info,
        priority = 100 - _,
        user_data = { sort_index = string.format("%05d", _) },
      })
    end
  end

  return items
end

-- Cleanup function
function M.cleanup()
  if not _initialized then
    return
  end

  -- Clean up augroup
  if _augroup_id then
    local success, err = pcall(vim.api.nvim_del_augroup_by_id, _augroup_id)
    if not success then
      vim.notify("omnifunc: failed to delete augroup: " .. tostring(err), vim.log.levels.WARN)
    end
    _augroup_id = nil
  end
  
  -- Execute cleanup handlers
  for _, handler in ipairs(_cleanup_handlers) do
    local success, err = pcall(handler)
    if not success then
      vim.notify("omnifunc cleanup error: " .. tostring(err), vim.log.levels.WARN)
    end
  end
  
  -- Clear handlers
  _cleanup_handlers = {}
  
  -- Clear references
  _providers = nil
  _shelter = nil
  
  _initialized = false
end

-- Register cleanup handler
function M.register_cleanup_handler(handler)
  if type(handler) == "function" then
    table.insert(_cleanup_handlers, handler)
  end
end

function M.setup(opts, _, providers, shelter)
  -- Input validation
  if not providers then
    vim.notify("omnifunc: providers is required", vim.log.levels.ERROR)
    return
  end
  
  if not shelter then
    vim.notify("omnifunc: shelter is required", vim.log.levels.ERROR)
    return
  end

  -- Cleanup previous state
  if _initialized then
    M.cleanup()
  end

  _shelter = shelter
  _providers = providers
  _initialized = true

  if opts == true or (type(opts) == "table" and opts.auto_setup ~= false) then
    -- Safe option setting
    local success, err = pcall(function()
      local completeopt = vim.opt.completeopt:get()
      local has_preview = false
      for _, opt in ipairs(completeopt) do
        if opt:match("preview") then
          has_preview = true
          break
        end
      end
      if not has_preview then
        vim.opt.completeopt:append("preview")
      end
    end)
    if not success then
      vim.notify("omnifunc: failed to set completeopt: " .. tostring(err), vim.log.levels.WARN)
    end

    local supported_filetypes = {}
    if _providers.filetype_map then
      for _, filetypes in pairs(_providers.filetype_map) do
        if type(filetypes) == "table" then
          vim.list_extend(supported_filetypes, filetypes)
        end
      end
    end

    local group_success, group = pcall(vim.api.nvim_create_augroup, "EcologOmnifunc", { clear = true })
    if not group_success then
      vim.notify("omnifunc: failed to create augroup: " .. tostring(group), vim.log.levels.ERROR)
      return
    end
    _augroup_id = group

    if #supported_filetypes > 0 then
      local autocmd_success, autocmd_err = pcall(vim.api.nvim_create_autocmd, "FileType", {
        group = group,
        pattern = supported_filetypes,
        callback = function()
          if vim.bo.omnifunc == "" then
            vim.bo.omnifunc = "v:lua.require'ecolog.integrations.cmp.omnifunc'.complete"
          end
        end,
      })
      if not autocmd_success then
        vim.notify("omnifunc: failed to create FileType autocmd: " .. tostring(autocmd_err), vim.log.levels.ERROR)
      end
    end

    local function close_preview()
      local success, err = pcall(vim.cmd, "pclose")
      if not success then
        vim.notify("omnifunc: failed to close preview: " .. tostring(err), vim.log.levels.WARN)
      end
    end

    local close_success, close_err = pcall(vim.api.nvim_create_autocmd, { "InsertLeave", "CompleteDone" }, {
      group = group,
      callback = close_preview,
    })
    if not close_success then
      vim.notify("omnifunc: failed to create close preview autocmd: " .. tostring(close_err), vim.log.levels.ERROR)
    end
  end

  -- Register cleanup with ecolog if available
  local success, ecolog = pcall(require, "ecolog")
  if success and ecolog.register_cleanup_handler then
    ecolog.register_cleanup_handler(M.cleanup)
  end
end

function M.complete(findstart, base)
  return get_env_completion(findstart, base)
end

return M
