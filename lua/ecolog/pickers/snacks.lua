---@class EcologSnacksPicker
---Snacks picker implementation
local M = {}

local lsp_commands = require("ecolog.lsp.commands")
local hooks = require("ecolog.hooks")
local keys = require("ecolog.pickers.keys")
local common = require("ecolog.pickers.common")
local notify = require("ecolog.notification_manager")

---Create a Snacks picker for variables
---@param opts? { on_select?: fun(var: EcologVariable) }
function M.pick_variables(opts)
  opts = opts or {}

  local ok, snacks = pcall(require, "snacks.picker")
  if not ok then
    notify.error("snacks.nvim picker is not installed")
    return
  end

  common.save_current_window()

  local current_file = vim.api.nvim_buf_get_name(0)
  lsp_commands.list_variables(current_file, function(vars)
    if #vars == 0 then
      notify.info("No environment variables found")
      return
    end

    -- Build items with proper fields
    local items = {}
    local longest_name = 0
    for _, var in ipairs(vars) do
      longest_name = math.max(longest_name, #var.name)
    end

    for i, var in ipairs(vars) do
      -- Transform through hooks
      local display = hooks.fire_filter("on_picker_entry", {
        name = var.name,
        value = var.value,
        source = var.source,
      })

      table.insert(items, {
        idx = i,
        text = display.name .. " " .. (display.value or ""),
        name = display.name,
        value = display.value or "",
        source = display.source or "",
        file = display.source, -- For go-to-file action
        _raw = var,
        _longest = longest_name,
      })
    end

    -- Define actions
    local actions = {
      copy_value = function(picker)
        local item = picker:current()
        if not item then
          return
        end
        -- Get unmasked value from _raw
        local value = item._raw and item._raw.value or item.value
        common.copy_to_clipboard(value, string.format("value of '%s'", item.name))
        picker:close()
      end,

      copy_name = function(picker)
        local item = picker:current()
        if not item then
          return
        end
        common.copy_to_clipboard(item.name, string.format("variable '%s' name", item.name))
        picker:close()
      end,

      append_value = function(picker)
        local item = picker:current()
        if not item then
          return
        end
        local value = item._raw and item._raw.value or item.value
        picker:close()
        vim.schedule(function()
          if common.append_at_cursor(value) then
            notify.info("Appended value")
          end
        end)
      end,

      append_name = function(picker)
        local item = picker:current()
        if not item then
          return
        end
        picker:close()
        vim.schedule(function()
          if common.append_at_cursor(item.name) then
            notify.info("Appended name")
          end
        end)
      end,

      goto_source = function(picker)
        local item = picker:current()
        if not item then
          return
        end
        local source = item._raw and item._raw.source or item.source
        picker:close()
        vim.schedule(function()
          common.goto_source(source)
        end)
      end,
    }

    snacks.pick({
      title = "Environment Variables",
      items = items,
      layout = {
        preset = "dropdown",
        preview = false,
        layout = {
          width = 0.9,
        },
      },
      sort = {
        fields = { "score:desc", "idx" },
      },
      format = function(item)
        local longest = item._longest or 20
        return {
          { ("%-" .. longest .. "s"):format(item.name), "@variable" },
          { " " },
          { item.value or "", "@string" },
          { "  " },
          { item.source or "", "@comment" },
        }
      end,
      win = {
        input = {
          keys = (function()
            local k = keys.get_snacks()
            local key_config = {}
            if k.copy_value and k.copy_value ~= "" then
              key_config[k.copy_value] = { "copy_value", mode = { "i", "n" } }
            end
            if k.copy_name and k.copy_name ~= "" then
              key_config[k.copy_name] = { "copy_name", mode = { "i", "n" } }
            end
            if k.append_value and k.append_value ~= "" then
              key_config[k.append_value] = { "append_value", mode = { "i", "n" } }
            end
            if k.goto_source and k.goto_source ~= "" then
              key_config[k.goto_source] = { "goto_source", mode = { "i", "n" } }
            end
            if k.append_name and k.append_name ~= "" then
              key_config[k.append_name] = { "append_name", mode = { "i", "n" } }
            end
            return key_config
          end)(),
        },
      },
      confirm = function(picker, item)
        if not item then
          return
        end
        if opts.on_select then
          picker:close()
          opts.on_select(item._raw)
        else
          -- Default: append name at cursor
          picker:close()
          vim.schedule(function()
            if common.append_at_cursor(item.name) then
              notify.info("Appended " .. item.name)
            end
          end)
        end
      end,
      actions = actions,
    })
  end)
end

---Create a Snacks picker for env files
---@param opts? { on_select?: fun(files: string[]) }
function M.pick_files(opts)
  opts = opts or {}

  local ok, snacks = pcall(require, "snacks.picker")
  if not ok then
    notify.error("snacks.nvim picker is not installed")
    return
  end

  local current_file = vim.api.nvim_buf_get_name(0)
  lsp_commands.list_files(current_file, { all = true }, function(files)
    if #files == 0 then
      notify.info("No env files found")
      return
    end

    local items = {}
    for i, file in ipairs(files) do
      local display_name = vim.fn.fnamemodify(file, ":t")
      table.insert(items, {
        idx = i,
        text = file,
        file = file,
        display_name = display_name,
      })
    end

    snacks.pick({
      title = "Select Environment File(s)",
      items = items,
      layout = {
        preset = "dropdown",
        preview = false,
      },
      format = function(item)
        return {
          { item.display_name, "Title" },
          { "  ", "Normal" },
          { item.file, "Comment" },
        }
      end,
      confirm = function(picker, item)
        if not item then
          return
        end
        picker:close()

        -- For now, snacks doesn't have built-in multi-select like telescope
        -- Just use single selection
        local selected_files = { item.file }

        if opts.on_select then
          opts.on_select(selected_files)
        else
          lsp_commands.set_active_file(selected_files, function(success)
            if success then
              notify.info("Active env file: " .. item.file)
            end
          end)
        end
      end,
    })
  end)
end

---Create a Snacks picker for active files
---@param files string[] List of active files to choose from
function M.pick_active_files(files)
  local ok, snacks = pcall(require, "snacks.picker")
  if not ok then
    notify.error("snacks.nvim picker is not installed")
    return
  end

  local items = {}
  for i, file in ipairs(files) do
    local display_name = vim.fn.fnamemodify(file, ":t")
    table.insert(items, {
      idx = i,
      text = file,
      file = file,
      display_name = display_name,
    })
  end

  snacks.pick({
    title = "Open Active Env File",
    items = items,
    layout = {
      preset = "dropdown",
      preview = false,
    },
    format = function(item)
      return {
        { item.display_name, "Title" },
        { "  ", "Normal" },
        { item.file, "Comment" },
      }
    end,
    confirm = function(picker, item)
      if item then
        picker:close()
        vim.cmd.edit(item.file)
      end
    end,
  })
end

---Create a Snacks picker for sources (Shell/File/Remote toggle)
---@param opts? { on_select?: fun(sources: string[]) }
function M.pick_sources(opts)
  opts = opts or {}

  local ok, snacks = pcall(require, "snacks.picker")
  if not ok then
    notify.error("snacks.nvim picker is not installed")
    return
  end

  lsp_commands.list_sources(function(sources)
    if #sources == 0 then
      notify.info("No sources available")
      return
    end

    local items = {}
    for i, source in ipairs(sources) do
      table.insert(items, {
        idx = i,
        text = source.name,
        name = source.name,
        enabled = source.enabled,
        priority = source.priority,
      })
    end

    snacks.pick({
      title = "Toggle Environment Sources",
      items = items,
      layout = {
        preset = "dropdown",
        preview = false,
      },
      format = function(item)
        local icon = item.enabled and "✓" or "○"
        local hl = item.enabled and "@string" or "@comment"
        return {
          { icon .. " ", hl },
          { item.name, hl },
          { "  ", "Normal" },
          { string.format("(priority: %d)", item.priority), "@comment" },
        }
      end,
      confirm = function(picker, item)
        if not item then
          return
        end
        -- Toggle single item
        local new_sources = {}
        for _, s in ipairs(sources) do
          if s.name == item.name then
            -- Toggle this one
            if not s.enabled then
              table.insert(new_sources, s.name)
            end
          elseif s.enabled then
            table.insert(new_sources, s.name)
          end
        end
        picker:close()
        if opts.on_select then
          opts.on_select(new_sources)
        else
          lsp_commands.set_sources(new_sources)
        end
      end,
    })
  end)
end

return M
