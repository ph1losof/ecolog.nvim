local M = {}
local api = vim.api

local _shelter = nil

local function setup_completion(cmp, opts, providers)
  -- Validate inputs
  if not cmp then
    vim.notify("nvim-cmp is not available", vim.log.levels.ERROR)
    return
  end
  
  if not providers then
    vim.notify("Providers module is not available", vim.log.levels.ERROR)
    return
  end
  
  -- Set up highlights with error handling
  local highlight_groups = {
    "CmpItemKindEcolog",
    "CmpItemAbbrMatchEcolog", 
    "CmpItemAbbrMatchFuzzyEcolog",
    "CmpItemMenuEcolog"
  }
  
  local highlight_links = {
    "EcologVariable",
    "EcologVariable",
    "EcologVariable", 
    "EcologSource"
  }
  
  for i, group in ipairs(highlight_groups) do
    local success, err = pcall(api.nvim_set_hl, 0, group, { link = highlight_links[i] })
    if not success then
      vim.notify("Failed to set highlight group " .. group .. ": " .. tostring(err), vim.log.levels.WARN)
    end
  end

  -- Register completion source with error handling
  local success, err = pcall(cmp.register_source, "ecolog", {
    get_trigger_characters = function()
      local has_ecolog, ecolog = pcall(require, "ecolog")
      if not has_ecolog then
        return {}
      end

      local config_success, config = pcall(ecolog.get_config)
      if not config_success or not config then
        return {}
      end
      
      if not config.provider_patterns or not config.provider_patterns.cmp then
        return { "" }
      end

      local triggers = {}
      local filetype = vim.bo.filetype
      
      if not filetype or filetype == "" then
        return {}
      end
      
      local providers_success, available_providers = pcall(providers.get_providers, filetype)
      if not providers_success or not available_providers then
        return {}
      end

      for _, provider in ipairs(available_providers) do
        if provider and provider.get_completion_trigger then
          local trigger_success, trigger = pcall(provider.get_completion_trigger)
          if trigger_success and trigger and type(trigger) == "string" then
            for char in trigger:gmatch(".") do
              if not vim.tbl_contains(triggers, char) then
                table.insert(triggers, char)
              end
            end
          end
        end
      end

      return triggers
    end,

    complete = function(self, request, callback)
      -- Wrap entire completion logic in pcall for safety
      local success, err = pcall(function()
        -- Validate callback
        if not callback or type(callback) ~= "function" then
          return
        end
        
        local has_ecolog, ecolog = pcall(require, "ecolog")
        if not has_ecolog then
          callback({ items = {}, isIncomplete = false })
          return
        end

        local config_success, config = pcall(ecolog.get_config)
        if not config_success or not config then
          callback({ items = {}, isIncomplete = false })
          return
        end
        
        local env_vars_success, env_vars = pcall(ecolog.get_env_vars)
        if not env_vars_success or not env_vars then
          callback({ items = {}, isIncomplete = false })
          return
        end
        
        local filetype = vim.bo.filetype
        if not filetype or filetype == "" then
          callback({ items = {}, isIncomplete = false })
          return
        end
        
        local providers_success, available_providers = pcall(providers.get_providers, filetype)
        if not providers_success or not available_providers then
          callback({ items = {}, isIncomplete = false })
          return
        end

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

        -- Get workspace context for the source
        local utils = require("ecolog.utils")
        local source_display = utils.get_env_file_display_name(entry.source, config)
        
        local item = {
          label = entry.name,
          kind = cmp.lsp.CompletionItemKind.Variable,
          detail = source_display,
          documentation = {
            kind = "markdown",
            value = doc_value,
          },
          kind_hl_group = "CmpItemKindEcolog",
          menu_hl_group = "CmpItemMenuEcolog",
          abbr_hl_group = "CmpItemAbbrMatchEcolog",
          sortText = string.format("%05d", _),
          score = 100,
        }

        if matched_provider and matched_provider.format_completion then
          item = matched_provider.format_completion(item, entry.name, entry)
        end

        table.insert(items, item)
      end

        callback({ items = items, isIncomplete = false })
      end)
      
      if not success then
        vim.notify("nvim-cmp completion failed: " .. tostring(err), vim.log.levels.ERROR)
        if callback then
          callback({ items = {}, isIncomplete = false })
        end
      end
    end,
  })
  
  if not success then
    vim.notify("Failed to register nvim-cmp source: " .. tostring(err), vim.log.levels.ERROR)
  end
end

function M.setup(opts, env_vars, providers, shelter, types, selected_env_file)
  -- Validate required parameters
  if not providers then
    vim.notify("Providers module is required for nvim-cmp integration", vim.log.levels.ERROR)
    return
  end
  
  if not shelter then
    vim.notify("Shelter module is required for nvim-cmp integration", vim.log.levels.ERROR)
    return
  end
  
  _shelter = shelter

  local autocmd_success, autocmd_err = pcall(vim.api.nvim_create_autocmd, "InsertEnter", {
    callback = function()
      local success, err = pcall(function()
        local has_cmp, cmp = pcall(require, "cmp")
        if has_cmp and not M._cmp_loaded then
          setup_completion(cmp, opts, providers)
          M._cmp_loaded = true
        end
      end)
      
      if not success then
        vim.notify("nvim-cmp autocmd callback failed: " .. tostring(err), vim.log.levels.ERROR)
      end
    end,
    once = true,
  })
  
  if not autocmd_success then
    vim.notify("Failed to create nvim-cmp autocmd: " .. tostring(autocmd_err), vim.log.levels.ERROR)
  end
end

return M
