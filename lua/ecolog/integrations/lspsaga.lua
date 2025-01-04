local M = {}

local api = vim.api
local cmd = vim.cmd
local notify = vim.notify
local utils = require("ecolog.utils")

function M.is_env_var(word)
  if not M._ecolog then
    M._ecolog = require("ecolog")
  end
  return M._ecolog.get_env_vars()[word] ~= nil
end

function M.handle_hover(args)
  local word = utils.get_var_word_under_cursor(nil, M._ecolog.get_config().provider_patterns)
  if M.is_env_var(word) then
    if M._ecolog.get_opts then
      local peek = require("ecolog.peek")
      local opts = M._ecolog.get_opts()
      local env_vars = M._ecolog.get_env_vars()
      local providers = require("ecolog.providers")
      local ok, err = pcall(peek.peek_env_value, word, opts, env_vars, providers, function() end)
      if not ok then
        require("lspsaga.hover"):render_hover_doc(args)
      end
    else
      cmd("EcologPeek " .. word)
    end
  else
    require("lspsaga.hover"):render_hover_doc(args)
  end
end

function M.handle_goto_definition(args)
  local word = utils.get_var_word_under_cursor(nil, M._ecolog.get_config().provider_patterns)
  if M.is_env_var(word) then
    local env_vars = M._ecolog.get_env_vars()
    local var = env_vars[word]
    if not var then
      notify(string.format("Environment variable '%s' not found", word), vim.log.levels.WARN)
      return
    end

    -- Open the file
    vim.cmd("edit " .. vim.fn.fnameescape(var.source))

    -- Find the line with the variable
    local lines = api.nvim_buf_get_lines(0, 0, -1, false)
    for i, line in ipairs(lines) do
      if line:match("^" .. vim.pesc(word) .. "=") then
        -- Move cursor to the line
        api.nvim_win_set_cursor(0, { i, 0 })
        -- Center the screen on the line
        vim.cmd("normal! zz")
        break
      end
    end
  else
    local ok, _ = pcall(function()
      require("lspsaga.definition"):init(1, 2, args)
    end)
    if not ok then
      notify("Lspsaga goto_definition not available", vim.log.levels.WARN)
    end
  end
end

function M.replace_saga_keymaps()
  local modes = { "n", "v" }
  local saga_commands = {
    ["Lspsaga hover_doc"] = "EcologSagaHover",
    ["Lspsaga goto_definition"] = "EcologSagaGD",
  }

  for _, mode in ipairs(modes) do
    local keymaps = api.nvim_get_keymap(mode)
    for _, keymap in ipairs(keymaps) do
      for saga_cmd, ecolog_cmd in pairs(saga_commands) do
        if keymap.rhs and keymap.rhs:match(saga_cmd) then
          -- Store original keymap attributes
          local opts = {
            silent = keymap.silent == 1,
            noremap = keymap.noremap == 1,
            expr = keymap.expr == 1,
            desc = keymap.desc or ("Ecolog " .. saga_cmd:gsub("Lspsaga ", "")),
          }

          -- Delete existing keymap
          pcall(api.nvim_del_keymap, mode, keymap.lhs)

          -- Create new keymap with ecolog command
          api.nvim_set_keymap(mode, keymap.lhs, "<cmd>" .. ecolog_cmd .. "<CR>", opts)
        end
      end
    end
  end
end

function M.setup()
  if not M._ecolog then
    M._ecolog = require("ecolog")
  end

  if not pcall(require, "lspsaga") then
    notify("LSP Saga not found. Skipping integration.", vim.log.levels.WARN)
    return
  end

  -- Create our commands
  api.nvim_create_user_command("EcologSagaHover", M.handle_hover, {})
  api.nvim_create_user_command("EcologSagaGD", M.handle_goto_definition, {})

  api.nvim_create_user_command("Lspsaga", function(opts)
    local subcmd = opts.args:match("^(%S+)")
    if subcmd == "hover_doc" then
      M.handle_hover(opts)
    elseif subcmd == "goto_definition" then
      M.handle_goto_definition(opts)
    else
      local ok, err = pcall(function()
        local command = require("lspsaga.command")
        if not command.load_command then
          error("Lspsaga command loader not found")
        end

        local args = opts.args:match("^%S+%s+(.+)$") or ""

        command.load_command(subcmd, { args = args })
      end)

      if not ok then
        notify("Failed to execute Lspsaga command: " .. err, vim.log.levels.ERROR)
      end
    end
  end, {
    nargs = "*",
    complete = function(arglead, _cmdline, _cursorpos)
      local command = require("lspsaga.command")
      if command.command_list then
        local commands = command.command_list()
        if not arglead or arglead == "" then
          return commands
        end
        return vim.tbl_filter(function(cmd)
          return cmd:find(arglead, 1, true) == 1
        end, commands)
      end
      return {}
    end,
  })

  M.replace_saga_keymaps()
end

M.get_word_under_cursor = function(providers)
  return utils.get_var_word_under_cursor(providers, M._ecolog.get_config().provider_patterns)
end

return M
