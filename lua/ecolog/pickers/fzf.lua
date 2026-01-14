---@class EcologFzfPicker
---FZF-lua picker implementation
local M = {}

local lsp_commands = require("ecolog.lsp.commands")
local picker_keys = require("ecolog.pickers.keys")
local common = require("ecolog.pickers.common")
local notify = require("ecolog.notification_manager")

---Create an FZF picker for variables
---@param opts? { on_select?: fun(var: EcologVariable) }
function M.pick_variables(opts)
  opts = opts or {}

  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    notify.error("fzf-lua is not installed")
    return
  end

  common.save_current_window()

  local current_file = vim.api.nvim_buf_get_name(0)
  lsp_commands.list_variables(current_file, function(vars)
    if #vars == 0 then
      notify.info("No environment variables found")
      return
    end

    -- Build entries using common helper
    local data = common.build_entries(vars)

    -- Build display strings and map to raw variables
    local display_entries = {}
    local entry_map = {}

    for _, entry in ipairs(data.entries) do
      local format_str = "%-" .. data.longest_name .. "s │ %-40s │ %s"
      local display = string.format(format_str, entry.name, entry.value or "", entry.source or "")
      table.insert(display_entries, display)
      entry_map[display] = entry.raw
    end

    -- Get configured keymaps in fzf format
    local k = picker_keys.get_fzf()

    -- Build actions table with configured keys
    local fzf_actions = {
      -- Default: append name at cursor
      ["default"] = function(selected)
        if #selected > 0 then
          local var = entry_map[selected[1]]
          if opts.on_select then
            opts.on_select(var)
          else
            vim.schedule(function()
              common.append_name(var)
            end)
          end
        end
      end,
    }

    -- Copy value action
    if k.copy_value and k.copy_value ~= "" then
      fzf_actions[k.copy_value] = function(selected)
        if #selected > 0 then
          common.copy_value(entry_map[selected[1]])
        end
      end
    end

    -- Copy name action
    if k.copy_name and k.copy_name ~= "" then
      fzf_actions[k.copy_name] = function(selected)
        if #selected > 0 then
          common.copy_name(entry_map[selected[1]])
        end
      end
    end

    -- Go to source file action
    if k.goto_source and k.goto_source ~= "" then
      fzf_actions[k.goto_source] = function(selected)
        if #selected > 0 then
          vim.schedule(function()
            common.goto_var_source(entry_map[selected[1]])
          end)
        end
      end
    end

    -- Append value at cursor action
    if k.append_value and k.append_value ~= "" then
      fzf_actions[k.append_value] = function(selected)
        if #selected > 0 then
          vim.schedule(function()
            common.append_value(entry_map[selected[1]])
          end)
        end
      end
    end

    fzf.fzf_exec(display_entries, {
      prompt = "Env Variables> ",
      actions = fzf_actions,
      winopts = {
        height = 0.6,
        width = 0.9,
      },
    })
  end)
end

---Create an FZF picker for env files
---@param opts? { on_select?: fun(files: string[]), multi?: boolean }
function M.pick_files(opts)
  opts = opts or {}
  local multi = opts.multi ~= false -- Default to multi-select

  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    notify.error("fzf-lua is not installed")
    return
  end

  local current_file = vim.api.nvim_buf_get_name(0)
  lsp_commands.list_files(current_file, { all = true }, function(files)
    if #files == 0 then
      notify.info("No env files found")
      return
    end

    fzf.fzf_exec(files, {
      prompt = "Env Files> ",
      fzf_opts = multi and { ["--multi"] = true } or nil,
      actions = {
        ["default"] = function(selected)
          if #selected > 0 then
            if opts.on_select then
              opts.on_select(selected)
            else
              lsp_commands.set_active_file(selected, function(success)
                if success then
                  local msg = #selected == 1
                      and ("Active env file: " .. selected[1])
                      or ("Active env files: " .. #selected .. " files")
                  notify.info(msg)
                end
              end)
            end
          end
        end,
      },
    })
  end)
end

---Create an FZF picker for active files
---@param files string[] List of active files to choose from
function M.pick_active_files(files)
  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    notify.error("fzf-lua is not installed")
    return
  end

  fzf.fzf_exec(files, {
    prompt = "Open Active Env File> ",
    actions = {
      ["default"] = function(selected)
        if #selected > 0 then
          vim.cmd.edit(selected[1])
        end
      end,
    },
    winopts = {
      height = 0.4,
      width = 0.6,
    },
  })
end

---Create an FZF picker for sources (Shell/File/Remote toggle)
---@param opts? { on_select?: fun(sources: string[]) }
function M.pick_sources(opts)
  opts = opts or {}

  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    notify.error("fzf-lua is not installed")
    return
  end

  lsp_commands.list_sources(function(sources)
    if #sources == 0 then
      notify.info("No sources available")
      return
    end

    -- Build entries with visual indicators
    local entries = {}
    local entry_map = {}
    for _, source in ipairs(sources) do
      local icon = source.enabled and "✓" or "○"
      local entry = string.format("%s %s (priority: %d)", icon, source.name, source.priority)
      table.insert(entries, entry)
      entry_map[entry] = source
    end

    fzf.fzf_exec(entries, {
      prompt = "Toggle Sources> ",
      fzf_opts = { ["--multi"] = true },
      actions = {
        ["default"] = function(selected)
          if #selected == 0 then
            return
          end

          local new_sources = {}
          if #selected == 1 then
            -- Toggle single item
            local source = entry_map[selected[1]]
            for _, s in ipairs(sources) do
              if s.name == source.name then
                -- Toggle this one
                if not s.enabled then
                  table.insert(new_sources, s.name)
                end
              elseif s.enabled then
                table.insert(new_sources, s.name)
              end
            end
          else
            -- Use multi-selection as the new enabled set
            for _, entry in ipairs(selected) do
              local source = entry_map[entry]
              if source then
                table.insert(new_sources, source.name)
              end
            end
          end

          if opts.on_select then
            opts.on_select(new_sources)
          else
            lsp_commands.set_sources(new_sources)
          end
        end,
      },
    })
  end)
end

return M
