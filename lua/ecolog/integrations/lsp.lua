---@class LspConfig
---@field on_hover? fun(result: table) Custom hover handler
---@field on_definition? fun(result: table) Custom definition handler

local M = {}

-- Cache vim functions and APIs
local api, lsp, cmd, bo = vim.api, vim.lsp, vim.cmd, vim.bo
local utils = require("ecolog.utils")

-- Cache original LSP handlers
local original_handlers = {
  hover = nil,
  definition = nil,
}

-- Handle hover request (optimized)
local function handle_hover(err, result, ctx, config, providers, ecolog)
  if err then
    return original_handlers.hover(err, result, ctx, config)
  end

  -- Get available providers
  local available_providers = providers.get_providers(bo[0].filetype)

  -- Try to get env var at cursor
  local env_var = utils.get_var_word_under_cursor(available_providers, ecolog.get_config())
  if env_var and ecolog.get_env_vars()[env_var] then
    -- Get the command callback
    local commands = api.nvim_get_commands({})
    if commands.EcologPeek and commands.EcologPeek.callback then
      commands.EcologPeek.callback({ args = env_var })
    else
      -- Fallback to using vim.cmd
      cmd("EcologPeek " .. env_var)
    end
    return
  end

  return original_handlers.hover(err, result, ctx, config)
end

-- Handle definition request (optimized)
local function handle_definition(err, result, ctx, config, providers, ecolog)
  if err then
    return original_handlers.definition(err, result, ctx, config)
  end

  -- Get available providers
  local available_providers = providers.get_providers(bo[0].filetype)

  -- Try to get env var at cursor
  local env_var = utils.get_var_word_under_cursor(available_providers, ecolog.get_config())
  if env_var then
    local var = ecolog.get_env_vars()[env_var]
    if not var then
      return
    end

    -- Open the file
    cmd("edit " .. vim.fn.fnameescape(var.source))

    -- Find the line with the variable
    local lines = api.nvim_buf_get_lines(0, 0, -1, false)
    for i, line in ipairs(lines) do
      if line:match("^" .. vim.pesc(env_var) .. "=") then
        -- Move cursor to the line
        api.nvim_win_set_cursor(0, { i, 0 })
        -- Center the screen on the line
        cmd("normal! zz")
        break
      end
    end
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
