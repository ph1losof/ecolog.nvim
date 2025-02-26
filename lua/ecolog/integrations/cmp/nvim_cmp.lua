local M = {}
local api = vim.api

local _shelter = nil

local function setup_completion(cmp, opts, providers)
  api.nvim_set_hl(0, "CmpItemKindEcolog", { link = "EcologVariable" })
  api.nvim_set_hl(0, "CmpItemAbbrMatchEcolog", { link = "EcologVariable" })
  api.nvim_set_hl(0, "CmpItemAbbrMatchFuzzyEcolog", { link = "EcologVariable" })
  api.nvim_set_hl(0, "CmpItemMenuEcolog", { link = "EcologSource" })

  cmp.register_source("ecolog", {
    get_trigger_characters = function()
      local has_ecolog, ecolog = pcall(require, "ecolog")
      if not has_ecolog then
        return {}
      end

      local config = ecolog.get_config()
      if not config.provider_patterns.cmp then
        return { "" }
      end

      local triggers = {}
      local available_providers = providers.get_providers(vim.bo.filetype)

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
    end,

    complete = function(self, request, callback)
      local has_ecolog, ecolog = pcall(require, "ecolog")
      if not has_ecolog then
        callback({ items = {}, isIncomplete = false })
        return
      end

      local config = ecolog.get_config()
      local env_vars = ecolog.get_env_vars()
      local filetype = vim.bo.filetype
      local available_providers = providers.get_providers(filetype)

      if vim.tbl_count(env_vars) == 0 then
        callback({ items = {}, isIncomplete = false })
        return
      end

      local should_complete = false
      local line = request.context.cursor_before_line
      local matched_provider

      if config.provider_patterns.cmp then
        for _, provider in ipairs(available_providers) do
          if provider.get_completion_trigger then
            local trigger = provider.get_completion_trigger()
            local parts = vim.split(trigger, ".", { plain = true })
            local pattern = table.concat(
              vim.tbl_map(function(part)
                return vim.pesc(part)
              end, parts),
              "%."
            )

            if line:match(pattern .. "$") or (provider.pattern and line:match(provider.pattern)) then
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
        callback({ items = {}, isIncomplete = false })
        return
      end

      local items = {}
     local var_names = {}
     for var_name in pairs(env_vars) do
       table.insert(var_names, var_name)
     end
     
     if config.sort_var_fn and type(config.sort_var_fn) == "function" then
       table.sort(var_names, config.sort_var_fn)
     end
     
     for _, var_name in ipairs(var_names) do
       local var_info = env_vars[var_name]
        local display_value = _shelter.is_enabled("cmp")
            and _shelter.mask_value(var_info.value, "cmp", var_name, var_info.source)
          or var_info.value

        local doc_value = string.format("**Type:** `%s`\n**Value:** `%s`", var_info.type, display_value)
        if var_info.comment then
          doc_value = doc_value .. string.format("\n\n**Comment:** %s", var_info.comment)
        end

        local item = {
          label = var_name,
          kind = cmp.lsp.CompletionItemKind.Variable,
          detail = var_info.source,
          documentation = {
            kind = "markdown",
            value = doc_value,
          },
          kind_hl_group = "CmpItemKindEcolog",
          menu_hl_group = "CmpItemMenuEcolog",
          abbr_hl_group = "CmpItemAbbrMatchEcolog",
          sortText = string.format("%05d", _),
          score = 100
        }

        if matched_provider and matched_provider.format_completion then
          item = matched_provider.format_completion(item, var_name, var_info)
        end

        table.insert(items, item)
      end

      callback({ items = items, isIncomplete = false })
    end,
  })
end

function M.setup(opts, env_vars, providers, shelter, types, selected_env_file)
  _shelter = shelter

  vim.api.nvim_create_autocmd("InsertEnter", {
    callback = function()
      local has_cmp, cmp = pcall(require, "cmp")
      if has_cmp and not M._cmp_loaded then
        setup_completion(cmp, opts, providers)
        M._cmp_loaded = true
      end
    end,
    once = true,
  })
end

return M
