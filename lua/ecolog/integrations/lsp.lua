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
local NotificationManager = require("ecolog.core.notification_manager")

local original_handlers = {
  hover = nil,
  definition = nil,
}

local original_buf_methods = {
  hover = nil,
  definition = nil,
}

local is_neovim_011_plus = (vim.version and vim.version().minor >= 11)

-- Common helper functions
---@param env_var string Environment variable name
---@param ecolog table Ecolog module
---@return boolean true if variable was handled
local function handle_env_var_hover(env_var, ecolog)
  if env_var and ecolog.get_env_vars()[env_var] then
    local commands = api.nvim_get_commands({})
    if commands.EcologPeek and commands.EcologPeek.callback then
      commands.EcologPeek.callback({ args = env_var })
    else
      cmd("EcologPeek " .. env_var)
    end
    return true
  end
  return false
end

---@param env_var string Environment variable name
---@param ecolog table Ecolog module
---@return boolean true if variable was handled
local function handle_env_var_definition(env_var, ecolog)
  if not env_var then
    return false
  end

  local var = ecolog.get_env_vars()[env_var]
  if not var then
    return false
  end

  if var.source == "shell" then
    NotificationManager.warn("Cannot go to definition of shell variables")
    return true
  end

  if var.source:match("^asm:") or var.source:match("^vault:") then
    NotificationManager.warn("Cannot go to definition of secret manager variables")
    return true
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
  return true
end

local function handle_hover(err, result, ctx, config, providers, ecolog)
  if err then
    if original_handlers.hover then
      return original_handlers.hover(err, result, ctx, config)
    else
      return
    end
  end

  local available_providers = providers.get_providers(bo.filetype)
  local env_var = utils.get_var_word_under_cursor(available_providers)

  if handle_env_var_hover(env_var, ecolog) then
    return
  end

  if original_handlers.hover then
    return original_handlers.hover(err, result, ctx, config)
  end
end

local function handle_definition(err, result, ctx, config, providers, ecolog)
  if err then
    if original_handlers.definition then
      return original_handlers.definition(err, result, ctx, config)
    else
      return
    end
  end

  local available_providers = providers.get_providers(bo.filetype)
  local env_var = utils.get_var_word_under_cursor(available_providers)

  if handle_env_var_definition(env_var, ecolog) then
    return
  end

  if original_handlers.definition then
    return original_handlers.definition(err, result, ctx, config)
  else
    if result and type(result) == "table" and result[1] then
      local first_result = result[1]
      if first_result.uri or first_result.targetUri then
        local uri = first_result.uri or first_result.targetUri
        local range = first_result.range or first_result.targetRange
        if uri and range then
          local path = uri:gsub("file://", "")
          cmd("edit " .. fn.fnameescape(path))
          if range.start then
            api.nvim_win_set_cursor(0, { range.start.line + 1, range.start.character })
            cmd("normal! zz")
          end
        end
      end
    end
    return
  end
end

local function create_default_definition_handler()
  return function(err, result, ctx, config)
    if err then
      return
    end

    if result and type(result) == "table" and result[1] then
      local first_result = result[1]
      if first_result.uri or first_result.targetUri then
        local uri = first_result.uri or first_result.targetUri
        local range = first_result.range or first_result.targetRange
        if uri and range then
          local path = uri:gsub("file://", "")
          cmd("edit " .. fn.fnameescape(path))
          if range.start then
            api.nvim_win_set_cursor(0, { range.start.line + 1, range.start.character })
            cmd("normal! zz")
          end
        end
      end
    end
  end
end

local function setup_lsp_handlers(providers, ecolog)
  lsp.handlers["textDocument/hover"] = function(err, result, ctx, config)
    return handle_hover(err, result, ctx, config or {}, providers, ecolog)
  end

  lsp.handlers["textDocument/definition"] = function(err, result, ctx, config)
    return handle_definition(err, result, ctx, config or {}, providers, ecolog)
  end

  if is_neovim_011_plus and vim.lsp.handlers and type(vim.lsp.handlers) == "table" then
    if type(vim.lsp.handlers.hover) == "function" then
      original_handlers.hover = vim.lsp.handlers.hover
      vim.lsp.handlers.hover = function(err, result, ctx, config)
        return handle_hover(err, result, ctx, config or {}, providers, ecolog)
      end
    end

    if type(vim.lsp.handlers.definition) == "function" then
      original_handlers.definition = vim.lsp.handlers.definition
      vim.lsp.handlers.definition = function(err, result, ctx, config)
        return handle_definition(err, result, ctx, config or {}, providers, ecolog)
      end
    end
  end
end

local function setup_request_hook(providers, ecolog)
  if not vim.lsp._request then
    return
  end

  local original_request = vim.lsp._request
  vim._ecolog_original_lsp_request = original_request

  vim.lsp._request = function(method, params, handler, bufnr, ...)
    local available_providers = providers.get_providers(bo.filetype)
    local env_var = utils.get_var_word_under_cursor(available_providers)

    if method == "textDocument/hover" and handle_env_var_hover(env_var, ecolog) then
      return
    end

    if method == "textDocument/definition" and env_var then
      local var = ecolog.get_env_vars()[env_var]
      if var and handle_env_var_definition(env_var, ecolog) then
        return
      end
    end

    return original_request(method, params, handler, bufnr, ...)
  end
end

local function setup_buf_methods_hooks(providers, ecolog)
  if not vim.lsp.buf then
    return
  end

  if vim.lsp.buf.hover then
    original_buf_methods.hover = vim.lsp.buf.hover

    vim.lsp.buf.hover = function(...)
      local available_providers = providers.get_providers(bo.filetype)
      local env_var = utils.get_var_word_under_cursor(available_providers)

      if handle_env_var_hover(env_var, ecolog) then
        return
      end

      return original_buf_methods.hover(...)
    end
  end

  if vim.lsp.buf.definition then
    original_buf_methods.definition = vim.lsp.buf.definition

    vim.lsp.buf.definition = function(...)
      local available_providers = providers.get_providers(bo.filetype)
      local env_var = utils.get_var_word_under_cursor(available_providers)

      if handle_env_var_definition(env_var, ecolog) then
        return
      end

      return original_buf_methods.definition(...)
    end
  end
end

local function setup_on_request_hook(providers, ecolog)
  if not vim.lsp.on_request then
    return
  end

  vim._ecolog_original_lsp_on_request = vim.lsp.on_request

  vim.lsp.on_request = function(method, params, client_id, bufnr, orig_callback)
    local available_providers = providers.get_providers(bo.filetype)
    local env_var = utils.get_var_word_under_cursor(available_providers)

    if method == "textDocument/hover" and env_var and ecolog.get_env_vars()[env_var] then
      return function(err, result, ctx)
        if not err then
          vim.schedule(function()
            handle_env_var_hover(env_var, ecolog)
          end)
          return true
        end
        return false
      end
    end

    if method == "textDocument/definition" and env_var then
      local var = ecolog.get_env_vars()[env_var]
      if var then
        return function(err, result, ctx)
          vim.schedule(function()
            handle_env_var_definition(env_var, ecolog)
          end)
          return true
        end
      end
    end

    return false
  end
end

function M.setup()
  local providers = require("ecolog.providers")
  local ecolog = require("ecolog")

  original_handlers.hover = lsp.handlers["textDocument/hover"]
  original_handlers.definition = lsp.handlers["textDocument/definition"]

  if is_neovim_011_plus and original_handlers.definition == nil then
    original_handlers.definition = create_default_definition_handler()
  end

  setup_lsp_handlers(providers, ecolog)

  if is_neovim_011_plus then
    setup_request_hook(providers, ecolog)
    setup_buf_methods_hooks(providers, ecolog)
    setup_on_request_hook(providers, ecolog)
  end
end

local function restore_handlers()
  if original_handlers.hover then
    lsp.handlers["textDocument/hover"] = original_handlers.hover
  end

  if original_handlers.definition then
    lsp.handlers["textDocument/definition"] = original_handlers.definition
  end

  original_handlers.hover = nil
  original_handlers.definition = nil
end

local function restore_buf_methods()
  if original_buf_methods.hover then
    vim.lsp.buf.hover = original_buf_methods.hover
  end

  if original_buf_methods.definition then
    vim.lsp.buf.definition = original_buf_methods.definition
  end

  original_buf_methods.hover = nil
  original_buf_methods.definition = nil
end

local function restore_neovim_011_hooks()
  if vim.lsp._request ~= nil and vim._ecolog_original_lsp_request ~= nil then
    vim.lsp._request = vim._ecolog_original_lsp_request
    vim._ecolog_original_lsp_request = nil
  end

  if vim.lsp.on_request ~= nil and vim._ecolog_original_lsp_on_request ~= nil then
    vim.lsp.on_request = vim._ecolog_original_lsp_on_request
    vim._ecolog_original_lsp_on_request = nil
  end
end

function M.restore()
  restore_handlers()

  restore_buf_methods()

  if is_neovim_011_plus then
    restore_neovim_011_hooks()
  end
end

return M
