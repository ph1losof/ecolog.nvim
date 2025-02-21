local M = {}

local _shelter = nil
local _providers = nil

local function get_env_completion(findstart, base)
  local ok, ecolog = pcall(require, "ecolog")
  if not ok then
    return findstart == 1 and -1 or {}
  end

  local config = ecolog.get_config()
  local env_vars = ecolog.get_env_vars()

  if vim.tbl_count(env_vars) == 0 then
    return findstart == 1 and -1 or {}
  end

  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local line_to_cursor = line:sub(1, col)

  local should_complete = not config.provider_patterns.cmp
  if config.provider_patterns.cmp then
    local filetype = vim.bo.filetype
    local available_providers = _providers.get_providers(filetype)

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

        local trigger_len = #trigger
        local text_before_cursor = line_to_cursor:sub(-trigger_len)

        if text_before_cursor == trigger or (provider.pattern and text_before_cursor:match("^" .. provider.pattern .. "$")) then
          should_complete = true
          break
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
  for var_name, var_info in pairs(env_vars) do
    if var_name:lower():find(base:lower(), 1, true) == 1 then
      local display_value = _shelter.is_enabled("cmp")
          and _shelter.mask_value(var_info.value, "cmp", var_name, var_info.source)
        or var_info.value

      local info = string.format("%s [%s] = %s", var_name, var_info.type, display_value)
      if var_info.comment then
        info = info .. " # " .. var_info.comment
      end

      table.insert(items, {
        word = var_name,
        kind = "v",
        menu = var_info.source,
        info = info,
      })
    end
  end

  return items
end

function M.setup(opts, _, providers, shelter)
  _shelter = shelter
  _providers = providers

  if opts == true or (type(opts) == "table" and opts.auto_setup ~= false) then
    if not vim.opt.completeopt:get()[1]:match("preview") then
      vim.opt.completeopt:append("preview")
    end
    
    local supported_filetypes = {}
    for _, filetypes in pairs(_providers.filetype_map) do
      vim.list_extend(supported_filetypes, filetypes)
    end
    
    local group = vim.api.nvim_create_augroup("EcologOmnifunc", { clear = true })
    
    vim.api.nvim_create_autocmd("FileType", {
      group = group,
      pattern = supported_filetypes,
      callback = function()
        if vim.bo.omnifunc == "" then
          vim.bo.omnifunc = "v:lua.require'ecolog.integrations.cmp.omnifunc'.complete"
        end
      end,
    })
    
    local function close_preview()
      vim.cmd('pclose')
    end
    
    vim.api.nvim_create_autocmd({"InsertLeave", "CompleteDone"}, {
      group = group,
      callback = close_preview,
    })
  end
end

function M.complete(findstart, base)
  return get_env_completion(findstart, base)
end

return M

