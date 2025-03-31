--- @type blink.cmp.Source
local M = {}

local _providers = nil
local _shelter = nil

local trigger_patterns = {}

function M.new()
  return setmetatable({}, { __index = M })
end

function M:get_trigger_characters()
  local ft = vim.bo.filetype
  if trigger_patterns[ft] then
    return trigger_patterns[ft]
  end

  local ok, ecolog = pcall(require, "ecolog")
  if not ok then
    return {}
  end

  local config = ecolog.get_config()
  if not config.provider_patterns.cmp then
    trigger_patterns[ft] = { "" }
    return trigger_patterns[ft]
  end

  local chars = {}
  local seen = {}
  for _, provider in ipairs(_providers.get_providers(ft)) do
    if provider.get_completion_trigger then
      local trigger = provider.get_completion_trigger()
      local parts = vim.split(trigger, ".", { plain = true })
      for _, part in ipairs(parts) do
        if not seen[part] then
          seen[part] = true
          table.insert(chars, ".")
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
  local ok, ecolog = pcall(require, "ecolog")
  if not ok then
    callback({
      context = ctx,
      items = {},
      is_incomplete_forward = true,
      is_incomplete_backward = true,
    })
    return function() end
  end

  local config = ecolog.get_config()
  local env_vars = ecolog.get_env_vars()
  if vim.tbl_count(env_vars) == 0 then
    callback({
      context = ctx,
      items = {},
      is_incomplete_forward = true,
      is_incomplete_backward = true,
    })
    return function() end
  end

  local filetype = vim.bo.filetype
  local available_providers = _providers.get_providers(filetype)
  local cursor = ctx.cursor[2]
  local line = ctx.line
  local before_line = string.sub(line, 1, cursor)

  local should_complete = false
  local matched_provider

  if config.provider_patterns.cmp then
    for _, provider in ipairs(available_providers) do
      if provider.pattern and before_line:match(provider.pattern) then
        should_complete = true
        matched_provider = provider
        break
      end

      if provider.get_completion_trigger then
        local trigger = provider.get_completion_trigger()
        local parts = vim.split(trigger, ".", { plain = true })
        local pattern = table.concat(
          vim.tbl_map(function(part)
            return vim.pesc(part)
          end, parts),
          "%."
        )
        if before_line:match(pattern .. "$") then
          should_complete = true
          matched_provider = provider
          break
        end
      end
    end
  else
    should_complete = true
  end

  if not should_complete then
    callback({
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
    table.insert(var_entries, vim.tbl_extend("force", { name = var_name }, info))
  end

  if config.sort_var_fn and type(config.sort_var_fn) == "function" then
    table.sort(var_entries, function(a, b)
      return config.sort_var_fn(a, b)
    end)
  end

  for _, entry in ipairs(var_entries) do
    local display_value = _shelter.is_enabled("cmp")
        and _shelter.mask_value(entry.value, "cmp", entry.name, entry.source)
      or entry.value

    local doc_value = string.format("**Type:** `%s`\n**Value:** `%s`", entry.type, display_value)
    if entry.comment then
      local comment_value = entry.comment
      if _shelter.is_enabled("cmp") and not _shelter.get_config().skip_comments then
        local utils = require("ecolog.shelter.utils")
        comment_value = utils.mask_comment(comment_value, entry.source, _shelter, "cmp")
      end
      doc_value = doc_value .. string.format("\n\n**Comment:** `%s`", comment_value)
    end

    local item = {
      label = entry.name,
      kind = vim.lsp.protocol.CompletionItemKind.Variable,
      insertTextFormat = vim.lsp.protocol.InsertTextFormat.PlainText,
      insertText = entry.name,
      detail = entry.source,
      documentation = {
        kind = vim.lsp.protocol.MarkupKind.Markdown,
        value = doc_value,
      },
      score = 100,
      source_name = "ecolog",
      sortText = string.format("%05d", _),
    }

    if matched_provider and matched_provider.format_completion then
      item = matched_provider.format_completion(item, entry.name, entry)
    end

    table.insert(items, item)
  end

  callback({
    context = ctx,
    items = items,
    is_incomplete_forward = true,
    is_incomplete_backward = true,
  })
  return function() end
end

M.setup = function(opts, _, providers, shelter)
  _providers = providers
  _shelter = shelter
end

return M
