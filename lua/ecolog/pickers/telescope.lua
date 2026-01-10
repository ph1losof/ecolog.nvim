---@class EcologTelescopePicker
---Telescope picker implementation
local M = {}

local lsp_commands = require("ecolog.lsp.commands")
local hooks = require("ecolog.hooks")
local picker_keys = require("ecolog.pickers.keys")
local common = require("ecolog.pickers.common")
local notify = require("ecolog.notification_manager")

---Create a telescope picker for variables
---@param opts? { on_select?: fun(var: EcologVariable) }
function M.pick_variables(opts)
  opts = opts or {}

  local ok, _ = pcall(require, "telescope")
  if not ok then
    notify.error("telescope.nvim is not installed")
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local entry_display = require("telescope.pickers.entry_display")

  common.save_current_window()

  local current_file = vim.api.nvim_buf_get_name(0)
  lsp_commands.list_variables(current_file, function(vars)
    if #vars == 0 then
      notify.info("No environment variables found")
      return
    end

    -- Find longest name for alignment
    local longest_name = 0
    for _, var in ipairs(vars) do
      longest_name = math.max(longest_name, #var.name)
    end

    -- Create entry displayer
    local displayer = entry_display.create({
      separator = " ",
      items = {
        { width = longest_name + 2 }, -- name
        { width = 40 }, -- value
        { remaining = true }, -- source
      },
    })

    local make_display = function(entry)
      -- Transform through hooks
      local display_entry = hooks.fire_filter("on_picker_entry", {
        name = entry.name,
        value = entry.value,
        source = entry.source,
      })

      return displayer({
        { display_entry.name, "Identifier" },
        { display_entry.value or "", "String" },
        { display_entry.source or "", "Comment" },
      })
    end

    pickers
      .new({
        layout_config = {
          width = 0.9,
        },
      }, {
        prompt_title = "Environment Variables",
        finder = finders.new_table({
          results = vars,
          entry_maker = function(var)
            return {
              value = var,
              display = make_display,
              ordinal = var.name .. " " .. (var.value or "") .. " " .. (var.source or ""),
              name = var.name,
              source = var.source,
              _raw = var,
            }
          end,
        }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr, map)
          -- Default: append name at cursor
          actions.select_default:replace(function()
            local selection = action_state.get_selected_entry()
            actions.close(prompt_bufnr)

            if opts.on_select then
              opts.on_select(selection.value)
            else
              vim.schedule(function()
                if common.append_at_cursor(selection.name) then
                  notify.info("Appended " .. selection.name)
                end
              end)
            end
          end)

          -- Get configured keymaps
          local k = picker_keys.get_telescope()

          -- Copy value
          local function copy_value_action()
            local selection = action_state.get_selected_entry()
            -- Get unmasked value via peek hook
            local var = hooks.fire_filter("on_variable_peek", selection.value) or selection.value
            common.copy_to_clipboard(var.value, "value of '" .. selection.name .. "'")
          end
          if k.copy_value and k.copy_value ~= "" then
            map("i", k.copy_value, copy_value_action)
            map("n", k.copy_value, copy_value_action)
          end

          -- Copy name
          local function copy_name_action()
            local selection = action_state.get_selected_entry()
            common.copy_to_clipboard(selection.name, "variable '" .. selection.name .. "' name")
          end
          if k.copy_name and k.copy_name ~= "" then
            map("i", k.copy_name, copy_name_action)
            map("n", k.copy_name, copy_name_action)
          end

          -- Go to source file
          local function go_to_source_action()
            local selection = action_state.get_selected_entry()
            actions.close(prompt_bufnr)
            vim.schedule(function()
              common.goto_source(selection.source)
            end)
          end
          if k.goto_source and k.goto_source ~= "" then
            map("i", k.goto_source, go_to_source_action)
            map("n", k.goto_source, go_to_source_action)
          end

          -- Append value at cursor
          local function append_value_action()
            local selection = action_state.get_selected_entry()
            local var = hooks.fire_filter("on_variable_peek", selection.value) or selection.value
            actions.close(prompt_bufnr)
            vim.schedule(function()
              if common.append_at_cursor(var.value) then
                notify.info("Appended value")
              end
            end)
          end
          if k.append_value and k.append_value ~= "" then
            map("i", k.append_value, append_value_action)
            map("n", k.append_value, append_value_action)
          end

          return true
        end,
      })
      :find()
  end)
end

---Create a telescope picker for env files
---@param opts? { on_select?: fun(files: string[]), multi?: boolean }
function M.pick_files(opts)
  opts = opts or {}
  local multi = opts.multi ~= false -- Default to multi-select

  local ok, _ = pcall(require, "telescope")
  if not ok then
    notify.error("telescope.nvim is not installed")
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local current_file = vim.api.nvim_buf_get_name(0)
  lsp_commands.list_files(current_file, { all = true }, function(files)
    if #files == 0 then
      notify.info("No env files found")
      return
    end

    pickers
      .new({}, {
        prompt_title = "Select Environment File(s)",
        finder = finders.new_table({
          results = files,
          entry_maker = function(file)
            -- Extract just the filename for display
            local display_name = vim.fn.fnamemodify(file, ":t")
            return {
              value = file,
              display = display_name .. "  " .. file,
              ordinal = file,
            }
          end,
        }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr, map)
          -- Add multi-select toggle on Tab
          if multi then
            map("i", "<Tab>", actions.toggle_selection + actions.move_selection_worse)
            map("n", "<Tab>", actions.toggle_selection + actions.move_selection_worse)
            map("i", "<S-Tab>", actions.toggle_selection + actions.move_selection_better)
            map("n", "<S-Tab>", actions.toggle_selection + actions.move_selection_better)
          end

          actions.select_default:replace(function()
            local picker = action_state.get_current_picker(prompt_bufnr)
            local multi_selection = picker:get_multi_selection()

            local selected_files = {}
            if #multi_selection > 0 then
              -- Use multi-selection
              for _, entry in ipairs(multi_selection) do
                table.insert(selected_files, entry.value)
              end
            else
              -- Fall back to current selection
              local selection = action_state.get_selected_entry()
              if selection then
                table.insert(selected_files, selection.value)
              end
            end

            actions.close(prompt_bufnr)

            if #selected_files == 0 then
              return
            end

            if opts.on_select then
              opts.on_select(selected_files)
            else
              lsp_commands.set_active_file(selected_files, function(success)
                if success then
                  local msg = #selected_files == 1
                      and ("Active env file: " .. selected_files[1])
                      or ("Active env files: " .. #selected_files .. " files")
                  notify.info(msg)
                end
              end)
            end
          end)

          return true
        end,
      })
      :find()
  end)
end

---Create a telescope picker for active files
---@param files string[] List of active files to choose from
function M.pick_active_files(files)
  local ok, _ = pcall(require, "telescope")
  if not ok then
    notify.error("telescope.nvim is not installed")
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers
    .new({}, {
      prompt_title = "Open Active Env File",
      finder = finders.new_table({
        results = files,
        entry_maker = function(file)
          local display_name = vim.fn.fnamemodify(file, ":t")
          return {
            value = file,
            display = display_name .. "  " .. file,
            ordinal = file,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, _)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if selection then
            vim.cmd.edit(selection.value)
          end
        end)
        return true
      end,
    })
    :find()
end

---Create a telescope picker for sources (Shell/File/Remote toggle)
---@param opts? { on_select?: fun(sources: string[]) }
function M.pick_sources(opts)
  opts = opts or {}

  local ok, _ = pcall(require, "telescope")
  if not ok then
    notify.error("telescope.nvim is not installed")
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  lsp_commands.list_sources(function(sources)
    if #sources == 0 then
      notify.info("No sources available")
      return
    end

    pickers
      .new({}, {
        prompt_title = "Toggle Environment Sources",
        finder = finders.new_table({
          results = sources,
          entry_maker = function(source)
            local icon = source.enabled and "✓" or "○"
            return {
              value = source,
              display = string.format("%s %s (priority: %d)", icon, source.name, source.priority),
              ordinal = source.name,
              name = source.name,
              enabled = source.enabled,
            }
          end,
        }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr, map)
          -- Add multi-select toggle on Tab
          map("i", "<Tab>", actions.toggle_selection + actions.move_selection_worse)
          map("n", "<Tab>", actions.toggle_selection + actions.move_selection_worse)
          map("i", "<S-Tab>", actions.toggle_selection + actions.move_selection_better)
          map("n", "<S-Tab>", actions.toggle_selection + actions.move_selection_better)

          actions.select_default:replace(function()
            local picker = action_state.get_current_picker(prompt_bufnr)
            local multi_selection = picker:get_multi_selection()

            local new_sources = {}
            if #multi_selection > 0 then
              -- Use multi-selection as the new enabled set
              for _, entry in ipairs(multi_selection) do
                table.insert(new_sources, entry.name)
              end
            else
              -- Toggle single item
              local selection = action_state.get_selected_entry()
              if selection then
                for _, s in ipairs(sources) do
                  if s.name == selection.name then
                    -- Toggle this one
                    if not s.enabled then
                      table.insert(new_sources, s.name)
                    end
                  elseif s.enabled then
                    table.insert(new_sources, s.name)
                  end
                end
              end
            end

            actions.close(prompt_bufnr)

            if opts.on_select then
              opts.on_select(new_sources)
            else
              lsp_commands.set_sources(new_sources)
            end
          end)

          return true
        end,
      })
      :find()
  end)
end

return M
