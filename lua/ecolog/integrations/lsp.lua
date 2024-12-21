---@class LspConfig
---@field on_hover? fun(result: table) Custom hover handler
---@field on_definition? fun(result: table) Custom definition handler

local M = {}

-- Cache vim functions and APIs
local api, lsp, cmd, bo = vim.api, vim.lsp, vim.cmd, vim.bo
local sub = string.sub
local utils = require("ecolog.utils")

-- Pre-compile patterns
local PATTERNS = {
  word = "[%w_]",
  env_var = "^[%w_]+$",
}

-- Cache original LSP handlers
local original_handlers = {
  hover = nil,
  definition = nil,
}

-- Check if a word matches an environment variable (optimized)
local function matches_env_var(word, line, col, available_providers, env_vars)
  if word:match(utils.PATTERNS.env_var) and env_vars[word] then
    return word
  end

  -- Then try providers
  for i = 1, #available_providers do
    local extracted = available_providers[i].extract_var(line, col)
    if extracted and env_vars[extracted] then
      return extracted
    end
  end

  return nil
end

-- Handle hover request (optimized)
local function handle_hover(err, result, ctx, config, providers, ecolog)
  if err then
    return original_handlers.hover(err, result, ctx, config)
  end

  -- Get cursor context (optimized)
  local line = api.nvim_get_current_line()
  local cursor = api.nvim_win_get_cursor(0)
  local word_start, word_end = utils.find_word_boundaries(line, cursor[2])

  -- Get available providers
  local available_providers = providers.get_providers(bo[0].filetype)

  -- Check for env var match
  local env_var =
    matches_env_var(sub(line, word_start, word_end), line, word_end, available_providers, ecolog.get_env_vars())

  if env_var then
    cmd("EcologPeek " .. env_var)
    return
  end

  return original_handlers.hover(err, result, ctx, config)
end

-- Handle definition request (optimized)
local function handle_definition(err, result, ctx, config, providers, ecolog)
  if err then
    return original_handlers.definition(err, result, ctx, config)
  end

  -- Get cursor context (optimized)
  local line = api.nvim_get_current_line()
  local cursor = api.nvim_win_get_cursor(0)
  local word_start, word_end = utils.find_word_boundaries(line, cursor[2])

  -- Get available providers
  local available_providers = providers.get_providers(bo[0].filetype)

  -- Check for env var match
  local env_var =
    matches_env_var(sub(line, word_start, word_end), line, word_end, available_providers, ecolog.get_env_vars())

  if env_var then
    cmd("EcologGotoVar " .. env_var)
    return
  end

  return original_handlers.definition(err, result, ctx, config)
end

-- Set up LSP integration (optimized)
function M.setup()
  local providers = require("ecolog.providers")
  local ecolog = require("ecolog")

  -- Load providers once
  providers.load_providers()

  -- Cache original handlers
  original_handlers.hover = lsp.handlers["textDocument/hover"]
  original_handlers.definition = lsp.handlers["textDocument/definition"]

  -- Set optimized handlers
  lsp.handlers["textDocument/hover"] = function(err, result, ctx, config)
    return handle_hover(err, result, ctx, config, providers, ecolog)
  end

  lsp.handlers["textDocument/definition"] = function(err, result, ctx, config)
    return handle_definition(err, result, ctx, config, providers, ecolog)
  end
end

-- Restore original LSP handlers (optimized)
function M.restore()
  if original_handlers.hover then
    lsp.handlers["textDocument/hover"] = original_handlers.hover
  end
  if original_handlers.definition then
    lsp.handlers["textDocument/definition"] = original_handlers.definition
  end
end

return M

