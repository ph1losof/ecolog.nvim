---@class EcologCommands
---User command implementations
local M = {}

local lsp = require("ecolog.lsp")
local lsp_commands = require("ecolog.lsp.commands")
local hooks = require("ecolog.hooks")
local state = require("ecolog.state")
local notify = require("ecolog.notification_manager")

---@alias EcologSourceName "File"|"Shell"|"Remote"

---Toggle a source on/off
---@param source_name EcologSourceName
local function toggle_source(source_name)
  lsp_commands.list_sources(function(sources)
    local enabled_sources = {}
    local is_currently_enabled = false

    for _, s in ipairs(sources) do
      if s.name == source_name then
        is_currently_enabled = s.enabled
      elseif s.enabled then
        table.insert(enabled_sources, s.name)
      end
    end

    -- Toggle: if enabled, remove it; if disabled, add it
    if not is_currently_enabled then
      table.insert(enabled_sources, source_name)
    end

    lsp_commands.set_sources(enabled_sources)
  end)
end

---Enable a specific source
---@param source_name EcologSourceName
local function enable_source(source_name)
  lsp_commands.list_sources(function(sources)
    local enabled_sources = {}
    local already_enabled = false

    for _, s in ipairs(sources) do
      if s.enabled then
        table.insert(enabled_sources, s.name)
        if s.name == source_name then
          already_enabled = true
        end
      end
    end

    if already_enabled then
      notify.info(source_name .. " source is already enabled")
      return
    end

    table.insert(enabled_sources, source_name)
    lsp_commands.set_sources(enabled_sources)
  end)
end

---Disable a specific source
---@param source_name EcologSourceName
local function disable_source(source_name)
  lsp_commands.list_sources(function(sources)
    local enabled_sources = {}
    local was_enabled = false

    for _, s in ipairs(sources) do
      if s.enabled then
        if s.name == source_name then
          was_enabled = true
        else
          table.insert(enabled_sources, s.name)
        end
      end
    end

    if not was_enabled then
      notify.info(source_name .. " source is already disabled")
      return
    end

    lsp_commands.set_sources(enabled_sources)
  end)
end

---Copy variable name/value at cursor
---@param what "name"|"value"
function M.copy(what)
  lsp_commands.get_variable_at_cursor(nil, function(var)
    if not var then
      notify.info("No environment variable at cursor")
      return
    end

    local text
    if what == "value" then
      -- For value, fire peek hook to get unmasked value
      var = hooks.fire_filter("on_variable_peek", var) or var
      text = var.value
    else
      text = var.name
    end

    vim.fn.setreg("+", text)
    vim.fn.setreg('"', text)
    notify.info(string.format("Copied %s: %s", what, text))
  end)
end

---Refresh LSP (reload env files)
function M.refresh()
  lsp.restart()
  notify.info("LSP restarted")
end

---Open variable picker
function M.list()
  local pickers = require("ecolog.pickers")
  pickers.pick_variables()
end

---Handle files source commands
---@param action? string "select"|"enable"|"disable"|"open_active"|nil (toggle)
function M.files_cmd(action)
  if action == "select" then
    local pickers = require("ecolog.pickers")
    pickers.pick_files()
  elseif action == "open_active" then
    local active_files = state.get_active_files()
    if #active_files == 0 then
      notify.info("No active env file")
    elseif #active_files == 1 then
      vim.cmd.edit(active_files[1])
    else
      local pickers = require("ecolog.pickers")
      pickers.pick_active_files(active_files)
    end
  elseif action == "enable" then
    enable_source("File")
  elseif action == "disable" then
    disable_source("File")
  else
    -- Default: toggle
    toggle_source("File")
  end
end

---Handle shell source commands
---@param action? string "enable"|"disable"|nil (toggle)
function M.shell_cmd(action)
  if action == "enable" then
    enable_source("Shell")
  elseif action == "disable" then
    disable_source("Shell")
  else
    -- Default: toggle
    toggle_source("Shell")
  end
end

---Handle remote source commands (stub for future)
---@param action? string "enable"|"disable"|nil (toggle)
function M.remote_cmd(action)
  if action == "enable" then
    enable_source("Remote")
  elseif action == "disable" then
    disable_source("Remote")
  else
    -- Default: toggle
    toggle_source("Remote")
  end
end

---Handle interpolation commands
---@param action? string "on"|"off"|"toggle"|nil
function M.interpolation_cmd(action)
  if action == "on" or action == "enable" then
    lsp_commands.set_interpolation(true, function(success, enabled)
      if success then
        notify.info("Interpolation enabled")
      else
        notify.error("Failed to enable interpolation")
      end
    end)
  elseif action == "off" or action == "disable" then
    lsp_commands.set_interpolation(false, function(success, enabled)
      if success then
        notify.info("Interpolation disabled")
      else
        notify.error("Failed to disable interpolation")
      end
    end)
  else
    -- Default: toggle
    local current = state.get_interpolation_enabled()
    lsp_commands.set_interpolation(not current, function(success, enabled)
      if success then
        notify.info("Interpolation " .. (enabled and "enabled" or "disabled"))
      else
        notify.error("Failed to toggle interpolation")
      end
    end)
  end
end

---List workspaces
function M.workspaces()
  lsp_commands.list_workspaces(function(workspaces)
    if #workspaces == 0 then
      notify.info("No workspaces found")
      return
    end

    local lines = { "Workspaces:" }
    for _, ws in ipairs(workspaces) do
      local marker = ws.isActive and "* " or "  "
      table.insert(lines, string.format("%s%s (%s)", marker, ws.name, ws.path))
    end

    notify.info(table.concat(lines, "\n"))
  end)
end

---Set workspace root
---@param path? string Path to set as workspace root (defaults to cwd)
function M.root(path)
  path = path or vim.fn.getcwd()

  -- Expand path if it's relative
  if not vim.startswith(path, "/") then
    path = vim.fn.fnamemodify(path, ":p")
  end

  lsp_commands.set_root(path, function(success, root)
    if success and root then
      notify.info("Workspace root set to: " .. root)
    else
      notify.error("Failed to set workspace root")
    end
  end)
end

---Generate .env.example file
---@param opts? { output?: string }
function M.generate_example(opts)
  opts = opts or {}

  lsp_commands.generate_example(function(content, count)
    if count == 0 or content == "" then
      notify.info("No environment variables found in workspace")
      return
    end

    local output = opts.output or ".env.example"

    -- Open in new buffer or write to file
    if output == "-" then
      -- Open in scratch buffer
      vim.cmd("new")
      vim.bo.buftype = "nofile"
      vim.bo.bufhidden = "wipe"
      vim.bo.filetype = "dotenv"
      vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(content, "\n"))
      notify.info(string.format("Generated example with %d variables", count))
    else
      -- Write to file
      local file = io.open(output, "w")
      if file then
        file:write(content)
        file:close()
        notify.info(string.format("Generated %s with %d variables", output, count))
      else
        notify.error("Failed to write " .. output)
      end
    end
  end)
end

---Show ecolog info
function M.info()
  local client = lsp.get_client()
  local lines = { "ecolog.nvim" }

  if client then
    table.insert(lines, string.format("  LSP: Running (id: %d)", client.id))
    if client.config and client.config.root_dir then
      table.insert(lines, string.format("  Root: %s", client.config.root_dir))
    end
  else
    table.insert(lines, "  LSP: Not running")
  end

  local active_files = state.get_active_files()
  if #active_files > 0 then
    if #active_files == 1 then
      table.insert(lines, string.format("  Active file: %s", active_files[1]))
    else
      table.insert(lines, string.format("  Active files: %d", #active_files))
      for _, f in ipairs(active_files) do
        table.insert(lines, string.format("    - %s", f))
      end
    end
  end

  local var_count = state.get_var_count()
  if var_count > 0 then
    table.insert(lines, string.format("  Variables: %d", var_count))
  end

  local hook_names = hooks.list()
  if #hook_names > 0 then
    table.insert(lines, "  Hooks: " .. table.concat(hook_names, ", "))
  end

  notify.info(table.concat(lines, "\n"))
end

---Register user commands
function M._register_commands()
  vim.api.nvim_create_user_command("Ecolog", function(opts)
    local args = vim.split(opts.args, "%s+", { trimempty = true })
    local subcommand = args[1]
    local action = args[2]

    if subcommand == "copy" then
      M.copy(action or "name")
    elseif subcommand == "refresh" then
      M.refresh()
    elseif subcommand == "list" or subcommand == "vars" then
      M.list()
    elseif subcommand == "files" then
      M.files_cmd(action)
    elseif subcommand == "shell" then
      M.shell_cmd(action)
    elseif subcommand == "remote" then
      M.remote_cmd(action)
    elseif subcommand == "workspaces" then
      M.workspaces()
    elseif subcommand == "root" then
      M.root(action)
    elseif subcommand == "generate" then
      M.generate_example({ output = action })
    elseif subcommand == "info" then
      M.info()
    elseif subcommand == "interpolation" then
      M.interpolation_cmd(action)
    else
      notify.error(
        "Unknown subcommand. Available: copy, refresh, list, files, shell, remote, workspaces, root, generate, info, interpolation"
      )
    end
  end, {
    nargs = "+",
    complete = function(arglead, cmdline, _)
      local args = vim.split(cmdline, "%s+", { trimempty = true })

      if #args <= 2 then
        -- First level: subcommands
        local subcommands = {
          "copy", "refresh", "list", "files", "shell",
          "remote", "interpolation", "workspaces", "root",
          "generate", "info",
        }
        return vim.tbl_filter(function(c)
          return c:find(arglead, 1, true) == 1
        end, subcommands)
      elseif #args == 3 then
        -- Second level: depends on subcommand
        local sub = args[2]
        if sub == "copy" then
          return vim.tbl_filter(function(c)
            return c:find(arglead, 1, true) == 1
          end, { "name", "value" })
        elseif sub == "files" then
          return vim.tbl_filter(function(c)
            return c:find(arglead, 1, true) == 1
          end, { "select", "enable", "disable", "open_active" })
        elseif sub == "shell" or sub == "remote" then
          return vim.tbl_filter(function(c)
            return c:find(arglead, 1, true) == 1
          end, { "enable", "disable" })
        elseif sub == "interpolation" then
          return vim.tbl_filter(function(c)
            return c:find(arglead, 1, true) == 1
          end, { "on", "off", "toggle" })
        end
      end

      return {}
    end,
    desc = "Ecolog environment variable management",
  })
end

return M
