---@class LspConfig
---@field on_hover? fun(result: table) Custom hover handler
---@field on_definition? fun(result: table) Custom definition handler

local M = {}

local api = vim.api
local bo = vim.bo
local cmd = vim.cmd
local fn = vim.fn
local lsp = vim.lsp

local utils = require("ecolog.utils")

local original_handlers = {
  hover = nil,
  definition = nil,
}

local function handle_hover(err, result, ctx, config, providers, ecolog)
  if err then
    return original_handlers.hover(err, result, ctx, config)
  end

  local available_providers = providers.get_providers(bo.filetype)

  local env_var = utils.get_var_word_under_cursor(available_providers)
  if env_var and ecolog.get_env_vars()[env_var] then
    local commands = api.nvim_get_commands({})
    if commands.EcologPeek and commands.EcologPeek.callback then
      commands.EcologPeek.callback({ args = env_var })
    else
      cmd("EcologPeek " .. env_var)
    end
    return
  end

  return original_handlers.hover(err, result, ctx, config)
end

local function handle_definition(err, result, ctx, config, providers, ecolog)
  if err then
    return original_handlers.definition(err, result, ctx, config)
  end

  local available_providers = providers.get_providers(bo.filetype)

  local env_var = utils.get_var_word_under_cursor(available_providers)
  if env_var then
    local var = ecolog.get_env_vars()[env_var]
    if not var then
      return
    end

    cmd("edit " .. fn.fnameescape(var.source))

    local lines = api.nvim_buf_get_lines(0, 0, -1, false)
    for i, line in ipairs(lines) do
      if line:match("^" .. vim.pesc(env_var) .. "=") then
        api.nvim_win_set_cursor(0, { i, 0 })
        cmd("normal! zz")
        break
      end
    end
    return
  end

  return original_handlers.definition(err, result, ctx, config)
end

function M.setup()
  local providers = require("ecolog.providers")
  local ecolog = require("ecolog")

  original_handlers.hover = lsp.handlers["textDocument/hover"]
  original_handlers.definition = lsp.handlers["textDocument/definition"]

  lsp.handlers["textDocument/hover"] = function(err, result, ctx, config)
    return handle_hover(err, result, ctx, config, providers, ecolog)
  end

  lsp.handlers["textDocument/definition"] = function(err, result, ctx, config)
    return handle_definition(err, result, ctx, config, providers, ecolog)
  end
end

function M.restore()
  if original_handlers.hover then
    lsp.handlers["textDocument/hover"] = original_handlers.hover
  end
  if original_handlers.definition then
    lsp.handlers["textDocument/definition"] = original_handlers.definition
  end
end

return M
