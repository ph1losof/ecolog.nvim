local M = {}

-- Cache vim functions and APIs
local api = vim.api
local lsp = vim.lsp
local cmd = vim.cmd
local bo = vim.bo
local match = string.match
local sub = string.sub

-- Cache original LSP handlers
local original_handlers = {
  hover = nil,
  definition = nil,
}

-- Pattern for word boundaries (cached)
local WORD_PATTERN = "[%w_]"

-- Find word boundaries around cursor position (optimized)
local function find_word_boundaries(line, col)
  local len = #line
  local word_start = col
  local word_end = col
  
  -- Find start (unrolled loop)
  while word_start > 0 do
    if not match(sub(line, word_start, word_start), WORD_PATTERN) then
      break
    end
    word_start = word_start - 1
  end

  -- Find end (unrolled loop)
  while word_end <= len do
    local next_char = sub(line, word_end + 1, word_end + 1)
    if not next_char or not match(next_char, WORD_PATTERN) then
      break
    end
    word_end = word_end + 1
  end

  return word_start + 1, word_end
end

-- Check if a word matches an environment variable (optimized)
local function matches_env_var(word, line, col, available_providers, env_vars)
  -- First check if the word itself is an env var (faster check first)
  if env_vars[word] then
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
  if err then return original_handlers.hover(err, result, ctx, config) end

  -- Get cursor context (optimized)
  local line = api.nvim_get_current_line()
  local cursor = api.nvim_win_get_cursor(0)
  local word_start, word_end = find_word_boundaries(line, cursor[2])
  
  -- Get available providers
  local available_providers = providers.get_providers(bo[0].filetype)
  
  -- Check for env var match
  local env_var = matches_env_var(
    sub(line, word_start, word_end),
    line,
    word_end,
    available_providers,
    ecolog.get_env_vars()
  )

  if env_var then
    cmd("EcologPeek " .. env_var)
    return
  end

  return original_handlers.hover(err, result, ctx, config)
end

-- Handle definition request (optimized)
local function handle_definition(err, result, ctx, config, providers, ecolog)
  if err then return original_handlers.definition(err, result, ctx, config) end

  -- Get cursor context (optimized)
  local line = api.nvim_get_current_line()
  local cursor = api.nvim_win_get_cursor(0)
  local word_start, word_end = find_word_boundaries(line, cursor[2])
  
  -- Get available providers
  local available_providers = providers.get_providers(bo[0].filetype)
  
  -- Check for env var match
  local env_var = matches_env_var(
    sub(line, word_start, word_end),
    line,
    word_end,
    available_providers,
    ecolog.get_env_vars()
  )

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