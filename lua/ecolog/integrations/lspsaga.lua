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
end

return M


