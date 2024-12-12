local M = {}

-- Cache frequently used functions and modules
local api = vim.api
local cmd = vim.cmd
local notify = vim.notify
local ecolog

-- Helper function to check if word matches environment variable pattern
local function is_env_var(word)
  return ecolog.get_env_vars()[word] ~= nil
end

-- Helper function to get word under cursor
local function get_word_under_cursor()
  local line = api.nvim_get_current_line()
  local col = api.nvim_win_get_cursor(0)[2]
  local word_start, word_end = ecolog.find_word_boundaries(line, col)
  return line:sub(word_start, word_end)
end

-- Create command handler functions
local function handle_hover()
  local word = get_word_under_cursor()
  cmd(is_env_var(word) and ("EcologPeek " .. word) or "Lspsaga hover_doc")
end

local function handle_goto_definition()
  local word = get_word_under_cursor()
  cmd(is_env_var(word) and ("EcologGotoVar " .. word) or "Lspsaga goto_definition")
end

-- Find and replace existing Saga keymaps
local function replace_saga_keymaps()
  local modes = { "n", "v" }
  local saga_commands = {
    ["Lspsaga hover_doc"] = "EcologSagaHover",
    ["Lspsaga goto_definition"] = "EcologSagaGD"
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
  -- Cache ecolog module
  if not ecolog then
    ecolog = require("ecolog")
  end

  -- Check if lspsaga is available
  if not pcall(require, "lspsaga") then
    notify("LSP Saga not found. Skipping integration.", vim.log.levels.WARN)
    return
  end

  -- Create commands
  api.nvim_create_user_command("EcologSagaHover", handle_hover, {})
  api.nvim_create_user_command("EcologSagaGD", handle_goto_definition, {})

  -- Replace existing Saga keymaps
  replace_saga_keymaps()
end

return M


