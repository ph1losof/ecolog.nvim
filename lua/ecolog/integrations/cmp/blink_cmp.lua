---@module 'ecolog.integrations.cmp.blink_cmp'

---@class ecolog.BlinkSource
---@field get_trigger_characters fun(): string[]
---@field enabled fun(): boolean
---@field get_completions fun(self: table, context: table, callback: function)
local Source = {}
Source.__index = Source

-- Store module references as class fields
Source._providers = nil
Source._shelter = nil

function Source.new()
  local self = setmetatable({}, Source)
  return self
end

function Source:get_trigger_characters()
  local triggers = {}
  if not Source._providers then
    return triggers
  end

  local available_providers = Source._providers.get_providers(vim.bo.filetype)
  
  -- Collect unique trigger characters from all providers
  for _, provider in ipairs(available_providers) do
    if provider.get_completion_trigger then
      local trigger = provider.get_completion_trigger()
      -- Split trigger into characters and add them
      for char in trigger:gmatch(".") do
        if not vim.tbl_contains(triggers, char) then
          table.insert(triggers, char)
        end
      end
    end
  end
  
  return triggers
end

function Source:enabled()
  return true
end

function Source:get_completions(context, callback)
  -- Get current env vars directly from ecolog
  local has_ecolog, ecolog = pcall(require, "ecolog")
  if not has_ecolog then
    callback({
      context = context,
      is_incomplete_forward = false,
      is_incomplete_backward = false,
      items = {},
    })
    return
  end

  local env_vars = ecolog.get_env_vars()
  if vim.tbl_count(env_vars) == 0 then
    callback({
      context = context,
      is_incomplete_forward = false,
      is_incomplete_backward = false,
      items = {},
    })
    return
  end

  local items = {}
  for var_name, var_info in pairs(env_vars) do
    -- Get masked value if shelter is enabled
    local display_value = Source._shelter and Source._shelter.is_enabled("cmp") 
      and Source._shelter.mask_value(var_info.value, "cmp")
      or var_info.value

    -- Create base completion item
    local item = {
      label = var_name,
      insertText = var_name,
      detail = vim.fn.fnamemodify(var_info.source, ":t"),
      documentation = {
        kind = "markdown",
        value = string.format("**Type:** `%s`\n**Value:** `%s`", var_info.type, display_value),
      },
    }

    table.insert(items, item)
  end

  callback({
    context = context,
    is_incomplete_forward = false,
    is_incomplete_backward = false,
    items = items,
  })
end

---@param opts table
---@param env_vars table
---@param providers table
---@param shelter table
---@param types table
---@param selected_env_file string
function Source.setup(opts, env_vars, providers, shelter, types, selected_env_file)
  -- Store module references
  Source._providers = providers
  Source._shelter = shelter

  -- Create highlight groups
  vim.api.nvim_set_hl(0, "CmpItemKindEcolog", { link = "EcologVariable" })
  vim.api.nvim_set_hl(0, "CmpItemAbbrMatchEcolog", { link = "EcologVariable" })
  vim.api.nvim_set_hl(0, "CmpItemAbbrMatchFuzzyEcolog", { link = "EcologVariable" })
  vim.api.nvim_set_hl(0, "CmpItemMenuEcolog", { link = "EcologSource" })
end

return Source 