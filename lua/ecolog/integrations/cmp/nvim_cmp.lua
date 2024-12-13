local M = {}
local api = vim.api
local fn = vim.fn

-- Store providers reference
local _providers = nil

-- Create completion source
local function setup_completion(cmp, opts, providers)
  -- Create highlight groups for cmp
  api.nvim_set_hl(0, "CmpItemKindEcolog", { link = "EcologVariable" })
  api.nvim_set_hl(0, "CmpItemAbbrMatchEcolog", { link = "EcologVariable" })
  api.nvim_set_hl(0, "CmpItemAbbrMatchFuzzyEcolog", { link = "EcologVariable" })
  api.nvim_set_hl(0, "CmpItemMenuEcolog", { link = "EcologSource" })

  vim.notify("Setting up ecolog completion source", vim.log.levels.INFO)

  -- Register completion source
  cmp.register_source("ecolog", {
    get_trigger_characters = function()
      local triggers = {}
      local available_providers = providers.get_providers(vim.bo.filetype)
      
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
      
      vim.notify("Trigger characters: " .. vim.inspect(triggers), vim.log.levels.INFO)
      return triggers
    end,

    complete = function(self, request, callback)
      vim.notify("Complete function called", vim.log.levels.INFO)
      
      -- Get current env vars directly from ecolog
      local has_ecolog, ecolog = pcall(require, "ecolog")
      if not has_ecolog then
        vim.notify("Failed to require ecolog module", vim.log.levels.ERROR)
        callback({ items = {}, isIncomplete = false })
        return
      end

      local env_vars = ecolog.get_env_vars()
      
      vim.notify(string.format("Current env vars count: %d", vim.tbl_count(env_vars)), vim.log.levels.INFO)
      
      local filetype = vim.bo.filetype
      local available_providers = providers.get_providers(filetype)

      if vim.tbl_count(env_vars) == 0 then
        vim.notify("No environment variables available", vim.log.levels.WARN)
        callback({ items = {}, isIncomplete = false })
        return
      end

      local should_complete = false
      local line = request.context.cursor_before_line
      local matched_provider

      vim.notify("Checking line: " .. line, vim.log.levels.INFO)

      -- Check completion triggers from all providers
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

          if line:match(pattern .. "$") then
            should_complete = true
            matched_provider = provider
            vim.notify("Matched provider with trigger: " .. trigger, vim.log.levels.INFO)
            break
          end
        end
      end

      if not should_complete then
        vim.notify("No matching trigger found", vim.log.levels.INFO)
        callback({ items = {}, isIncomplete = false })
        return
      end

      local items = {}
      for var_name, var_info in pairs(env_vars) do
        -- Create base completion item
        local item = {
          label = var_name,
          kind = cmp.lsp.CompletionItemKind.Variable,
          detail = fn.fnamemodify(var_info.source, ":t"),
          documentation = {
            kind = "markdown",
            value = string.format("**Type:** `%s`\n**Value:** `%s`", var_info.type, var_info.value),
          },
          kind_hl_group = "CmpItemKindEcolog",
          menu_hl_group = "CmpItemMenuEcolog",
          abbr_hl_group = "CmpItemAbbrMatchEcolog",
        }

        -- Add provider-specific customizations if available
        if matched_provider and matched_provider.format_completion then
          item = matched_provider.format_completion(item, var_name, var_info)
        end

        table.insert(items, item)
      end

      vim.notify("Returning " .. #items .. " completion items", vim.log.levels.INFO)
      callback({ items = items, isIncomplete = false })
    end,
  })
end

function M.setup(opts, env_vars, providers, shelter, types, selected_env_file)
  vim.notify("Setting up nvim-cmp integration", vim.log.levels.INFO)
  
  -- Store providers reference
  _providers = providers
  
  -- Set up lazy loading for cmp
  vim.api.nvim_create_autocmd("InsertEnter", {
    callback = function()
      local has_cmp, cmp = pcall(require, "cmp")
      if has_cmp and not M._cmp_loaded then
        vim.notify("Loading nvim-cmp integration", vim.log.levels.INFO)
        -- Load providers first
        providers.load_providers()
        -- Then set up completion
        setup_completion(cmp, opts, providers)
        M._cmp_loaded = true
      end
    end,
    once = true,
  })
end

return M 