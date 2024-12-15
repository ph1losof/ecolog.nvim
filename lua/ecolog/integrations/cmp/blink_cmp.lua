--- @type blink.cmp.Source
local M = {}

-- Store module references
local _providers = nil
local _shelter = nil
local _env_vars = nil
local _ecolog = nil

function M.new()
  return setmetatable({}, { __index = M })
end

function M:get_trigger_characters()
  local triggers = {}
  local available_providers = _providers.get_providers(vim.bo.filetype)
  
  for _, provider in ipairs(available_providers) do
    if provider.get_completion_trigger then
      local trigger = provider.get_completion_trigger()
      for char in trigger:gmatch(".") do
        if not vim.tbl_contains(triggers, char) then
          table.insert(triggers, char)
        end
      end
    end
  end
  
  return triggers
end

function M:enabled()
  return true
end

function M:get_completions(ctx, callback)
  -- Get fresh env vars on each completion request
  if not _ecolog then
    local ok
    ok, _ecolog = pcall(require, "ecolog")
    if not ok then
      callback({
        context = ctx,
        is_incomplete_forward = false,
        is_incomplete_backward = false,
        items = {},
      })
      return function() end
    end
  end
  
  _env_vars = _ecolog.get_env_vars()
  
  if vim.tbl_count(_env_vars) == 0 then
    callback({
      context = ctx,
      is_incomplete_forward = false,
      is_incomplete_backward = false,
      items = {},
    })
    return function() end
  end

  local filetype = vim.bo.filetype
  local available_providers = _providers.get_providers(filetype)
  local line = ctx.line
  local should_complete = false
  local matched_provider

  -- Check completion triggers from all providers
  for _, provider in ipairs(available_providers) do
    if provider.pattern and line:match(provider.pattern) then
      should_complete = true
      matched_provider = provider
      break
    end
    
    if provider.get_completion_trigger then
      local trigger = provider.get_completion_trigger()
      if line:match(vim.pesc(trigger) .. "$") then
        should_complete = true
        matched_provider = provider
        break
      end
    end
  end

  if not should_complete then
    callback({
      context = ctx,
      is_incomplete_forward = false,
      is_incomplete_backward = false,
      items = {},
    })
    return function() end
  end

  local items = {}
  for var_name, var_info in pairs(_env_vars) do
    local display_value = _shelter.is_enabled("cmp") 
      and _shelter.mask_value(var_info.value, "cmp")
      or var_info.value

    local item = {
      label = var_name,
      kind = vim.lsp.protocol.CompletionItemKind.Variable,
      insertTextFormat = vim.lsp.protocol.InsertTextFormat.PlainText,
      insertText = var_name,
      detail = vim.fn.fnamemodify(var_info.source, ":t"),
      documentation = {
        kind = vim.lsp.protocol.MarkupKind.Markdown,
        value = string.format("**Type:** `%s`\n**Value:** `%s`", var_info.type, display_value),
      },
      score = 1,
      source_name = "ecolog",
    }

    if matched_provider and matched_provider.format_completion then
      item = matched_provider.format_completion(item, var_name, var_info)
    end

    table.insert(items, item)
  end

  callback({
    context = ctx,
    is_incomplete_forward = false,
    is_incomplete_backward = false,
    items = items,
  })
  return function() end
end

-- Setup function to initialize module references
M.setup = function(opts, env_vars, providers, shelter)
  _providers = providers
  _shelter = shelter
  _env_vars = env_vars
  providers.load_providers()
end

return M
