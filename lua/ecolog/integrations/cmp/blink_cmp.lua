--- @type blink.cmp.Source
local M = {}

local _providers = nil
local _shelter = nil

local trigger_patterns = {}

-- Track state for cleanup
local _initialized = false
local _cleanup_handlers = {}

-- Safe wrapper for external calls
local function safe_call(fn, ...)
  local success, result = pcall(fn, ...)
  if not success then
    vim.notify("blink_cmp error: " .. tostring(result), vim.log.levels.ERROR)
    return nil
  end
  return result
end

-- Input validation helper
local function validate_input(value, expected_type, name)
  if not value then
    vim.notify("blink_cmp: " .. name .. " is nil", vim.log.levels.WARN)
    return false
  end
  
  if expected_type and type(value) ~= expected_type then
    vim.notify("blink_cmp: " .. name .. " expected " .. expected_type .. ", got " .. type(value), vim.log.levels.WARN)
    return false
  end
  
  return true
end

function M.new()
  return setmetatable({}, { __index = M })
end

function M:get_trigger_characters()
  -- Input validation
  if not _providers then
    vim.notify("blink_cmp: providers not initialized", vim.log.levels.WARN)
    return {}
  end
  
  local ft = vim.bo.filetype
  if not validate_input(ft, "string", "filetype") then
    return {}
  end
  
  if trigger_patterns[ft] then
    return trigger_patterns[ft]
  end

  local ok, ecolog = pcall(require, "ecolog")
  if not ok then
    vim.notify("blink_cmp: failed to load ecolog", vim.log.levels.WARN)
    return {}
  end

  local config = safe_call(ecolog.get_config)
  if not config or not config.provider_patterns then
    trigger_patterns[ft] = { "" }
    return trigger_patterns[ft]
  end
  
  if not config.provider_patterns.cmp then
    trigger_patterns[ft] = { "" }
    return trigger_patterns[ft]
  end

  local chars = {}
  local seen = {}
  
  local providers = safe_call(_providers.get_providers, ft)
  if not providers then
    trigger_patterns[ft] = {}
    return trigger_patterns[ft]
  end
  
  for _, provider in ipairs(providers) do
    if provider and provider.get_completion_trigger then
      local trigger = safe_call(provider.get_completion_trigger)
      if trigger and type(trigger) == "string" then
        local parts = vim.split(trigger, ".", { plain = true })
        for _, part in ipairs(parts) do
          if part and not seen[part] then
            seen[part] = true
            table.insert(chars, ".")
          end
        end
      end
    end
  end

  trigger_patterns[ft] = chars
  return chars
end

function M:enabled()
  return true
end

function M:get_completions(ctx, callback)
  -- Input validation
  if not callback or type(callback) ~= "function" then
    vim.notify("blink_cmp: callback must be a function", vim.log.levels.ERROR)
    return function() end
  end
  
  if not ctx or not ctx.cursor or not ctx.line then
    vim.notify("blink_cmp: invalid context provided", vim.log.levels.ERROR)
    callback({
      context = ctx,
      items = {},
      is_incomplete_forward = true,
      is_incomplete_backward = true,
    })
    return function() end
  end

  -- Safe callback wrapper
  local safe_callback = function(result)
    local success, err = pcall(callback, result)
    if not success then
      vim.notify("blink_cmp: callback error: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
  
  local ok, ecolog = pcall(require, "ecolog")
  if not ok then
    vim.notify("blink_cmp: failed to load ecolog", vim.log.levels.WARN)
    safe_callback({
      context = ctx,
      items = {},
      is_incomplete_forward = true,
      is_incomplete_backward = true,
    })
    return function() end
  end

  local config = safe_call(ecolog.get_config)
  if not config then
    safe_callback({
      context = ctx,
      items = {},
      is_incomplete_forward = true,
      is_incomplete_backward = true,
    })
    return function() end
  end

  local env_vars = safe_call(ecolog.get_env_vars)
  if not env_vars or vim.tbl_count(env_vars) == 0 then
    safe_callback({
      context = ctx,
      items = {},
      is_incomplete_forward = true,
      is_incomplete_backward = true,
    })
    return function() end
  end

  local filetype = vim.bo.filetype
  if not validate_input(filetype, "string", "filetype") then
    safe_callback({
      context = ctx,
      items = {},
      is_incomplete_forward = true,
      is_incomplete_backward = true,
    })
    return function() end
  end

  local available_providers = safe_call(_providers.get_providers, filetype)
  if not available_providers then
    available_providers = {}
  end

  local cursor = ctx.cursor[2]
  local line = ctx.line
  if not validate_input(line, "string", "line") then
    safe_callback({
      context = ctx,
      items = {},
      is_incomplete_forward = true,
      is_incomplete_backward = true,
    })
    return function() end
  end
  
  local before_line = string.sub(line, 1, cursor)

  local should_complete = false
  local matched_provider

  if config.provider_patterns and config.provider_patterns.cmp then
    for _, provider in ipairs(available_providers) do
      if provider and provider.pattern and type(provider.pattern) == "string" then
        local pattern_match = safe_call(string.match, before_line, provider.pattern)
        if pattern_match then
          should_complete = true
          matched_provider = provider
          break
        end
      end

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
          local pattern_match = safe_call(string.match, before_line, pattern .. "$")
          if pattern_match then
            should_complete = true
            matched_provider = provider
            break
          end
        end
      end
    end
  else
    should_complete = true
  end

  if not should_complete then
    safe_callback({
      context = ctx,
      items = {},
      is_incomplete_forward = true,
      is_incomplete_backward = true,
    })
    return function() end
  end

  local items = {}

  local var_entries = {}
  for var_name, info in pairs(env_vars) do
    if validate_input(var_name, "string", "var_name") and info then
      table.insert(var_entries, vim.tbl_extend("force", { name = var_name }, info))
    end
  end

  if config.sort_var_fn and type(config.sort_var_fn) == "function" then
    local success, err = pcall(function()
      table.sort(var_entries, function(a, b)
        return config.sort_var_fn(a, b)
      end)
    end)
    if not success then
      vim.notify("blink_cmp: sort function error: " .. tostring(err), vim.log.levels.WARN)
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

      local doc_value = string.format("**Type:** `%s`\n**Value:** `%s`", entry.type or "unknown", display_value or "")
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
        doc_value = doc_value .. string.format("\n\n**Comment:** `%s`", comment_value)
      end

      local item = {
        label = entry.name,
        kind = vim.lsp.protocol.CompletionItemKind.Variable,
        insertTextFormat = vim.lsp.protocol.InsertTextFormat.PlainText,
        insertText = entry.name,
        detail = entry.source or "unknown",
        documentation = {
          kind = vim.lsp.protocol.MarkupKind.Markdown,
          value = doc_value,
        },
        score = 100,
        source_name = "ecolog",
        sortText = string.format("%05d", _),
      }

      if matched_provider and matched_provider.format_completion then
        local formatted_item = safe_call(matched_provider.format_completion, item, entry.name, entry)
        if formatted_item then
          item = formatted_item
        end
      end

      table.insert(items, item)
    end
  end

  safe_callback({
    context = ctx,
    items = items,
    is_incomplete_forward = true,
    is_incomplete_backward = true,
  })
  return function() end
end

-- Cleanup function
function M.cleanup()
  if not _initialized then
    return
  end

  -- Clear caches
  trigger_patterns = {}
  
  -- Execute cleanup handlers
  for _, handler in ipairs(_cleanup_handlers) do
    local success, err = pcall(handler)
    if not success then
      vim.notify("blink_cmp cleanup error: " .. tostring(err), vim.log.levels.WARN)
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

M.setup = function(opts, _, providers, shelter)
  -- Input validation
  if not providers then
    vim.notify("blink_cmp: providers is required", vim.log.levels.ERROR)
    return
  end
  
  if not shelter then
    vim.notify("blink_cmp: shelter is required", vim.log.levels.ERROR)
    return
  end

  -- Cleanup previous state
  if _initialized then
    M.cleanup()
  end

  -- Set up new state
  _providers = providers
  _shelter = shelter
  _initialized = true

  -- Register cleanup with ecolog if available
  local success, ecolog = pcall(require, "ecolog")
  if success and ecolog.register_cleanup_handler then
    ecolog.register_cleanup_handler(M.cleanup)
  end
end

return M
