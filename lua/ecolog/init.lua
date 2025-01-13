local M = {}

local api = vim.api
local fn = vim.fn
local notify = vim.notify
local schedule = vim.schedule
local tbl_extend = vim.tbl_deep_extend

local DEFAULT_CONFIG = {
  path = vim.fn.getcwd(),
  shelter = {
    configuration = {
      partial_mode = false,
      mask_char = "*",
    },
    modules = {
      cmp = false,
      peek = false,
      files = false,
      telescope = false,
      telescope_previewer = false,
      fzf = false,
      fzf_previewer = false,
    },
  },
  integrations = {
    lsp = false,
    lspsaga = false,
    nvim_cmp = true,
    blink_cmp = false,
    fzf = false,
  },
  vim_env = false,
  types = true,
  custom_types = {},
  preferred_environment = "",
  provider_patterns = {
    extract = true,
    cmp = true,
  },
  load_shell = {
    enabled = false,
    override = false,
    filter = nil,
    transform = nil,
  },
  env_file_pattern = nil,
  sort_fn = nil,
}

local _loaded_modules = {}
local _loading = {}

local function require_module(name)
  if _loaded_modules[name] then
    return _loaded_modules[name]
  end

  if _loading[name] then
    error("Circular dependency detected: " .. name)
  end

  _loading[name] = true
  local module = require(name)
  _loading[name] = nil
  _loaded_modules[name] = module
  return module
end

local utils = require_module("ecolog.utils")
local providers = utils.get_module("ecolog.providers")
local select = utils.get_module("ecolog.select")
local peek = utils.get_module("ecolog.peek")
local shelter = utils.get_module("ecolog.shelter")
local types = utils.get_module("ecolog.types")
local shell = utils.get_module("ecolog.shell")

local state = {
  env_vars = {},
  cached_env_files = nil,
  last_opts = nil,
  file_cache_opts = nil,
  current_watcher_group = nil,
  selected_env_file = nil,
  _providers_loaded = false,
  _env_module = nil,
}

local function get_env_module()
  if not state._env_module then
    state._env_module = require("ecolog.env")
    state._env_module.setup()
  end
  return state._env_module
end

local function parse_env_line(line, file_path)
  if not line:match(utils.PATTERNS.env_line) then
    return nil
  end

  local key, value = line:match(utils.PATTERNS.key_value)
  if not (key and value) then
    return nil
  end

  key = key:match(utils.PATTERNS.trim)

  local comment
  if value:match("^[\"'].-[\"']%s+(.+)$") then
    local quoted_value = value:match("^([\"'].-[\"'])%s+.+$")
    comment = value:match("^[\"'].-[\"']%s+#?%s*(.+)$")
    value = quoted_value
  elseif value:match("^[^%s]+%s+(.+)$") and not value:match("^[\"']") then
    local main_value = value:match("^([^%s]+)%s+.+$")
    comment = value:match("^[^%s]+%s+#?%s*(.+)$")
    value = main_value
  end

  value = value:gsub(utils.PATTERNS.quoted, "%1")
  value = value:match(utils.PATTERNS.trim)

  local type_name, transformed_value = types.detect_type(value)

  return key,
    {
      value = transformed_value or value,
      type = type_name,
      raw_value = value,
      source = file_path,
      comment = comment,
    }
end

local function find_env_files(opts)
  opts = opts or {}
  opts.path = opts.path or fn.getcwd()
  opts.preferred_environment = opts.preferred_environment or ""

  if
    state.cached_env_files
    and state.file_cache_opts
    and state.file_cache_opts.path == opts.path
    and state.file_cache_opts.preferred_environment == opts.preferred_environment
    and state.file_cache_opts.env_file_pattern == opts.env_file_pattern
    and state.file_cache_opts.sort_fn == opts.sort_fn
  then
    return state.cached_env_files
  end

  state.file_cache_opts = tbl_extend("force", {}, opts)
  state.cached_env_files = utils.find_env_files(opts)
  return state.cached_env_files
end

local function parse_env_file(opts, force)
  -- Always use full config
  opts = vim.tbl_deep_extend("force", state.last_opts or DEFAULT_CONFIG, opts or {})

  if not force and next(state.env_vars) ~= nil then
    return
  end

  state.env_vars = {}

  if not state.selected_env_file then
    local env_files = find_env_files(opts)
    if #env_files > 0 then
      state.selected_env_file = env_files[1]
    end
  end

  if
    opts.load_shell
    and (
      (type(opts.load_shell) == "boolean" and opts.load_shell)
      or (type(opts.load_shell) == "table" and opts.load_shell.enabled)
    )
  then
    local shell_vars, shell_config = shell.load_shell_vars(opts.load_shell)

    for key, var_info in pairs(shell_vars) do
      if shell_config.override or not state.env_vars[key] then
        state.env_vars[key] = var_info
      end
    end
  end

  if state.selected_env_file then
    local env_file = io.open(state.selected_env_file, "r")
    if env_file then
      for line in env_file:lines() do
        local key, var_info = parse_env_line(line, state.selected_env_file)
        if key then
          if not opts.load_shell or not opts.load_shell.override or not state.env_vars[key] then
            state.env_vars[key] = var_info
          end
        end
      end
      env_file:close()
    end
  end
end

local function setup_file_watcher(opts)
  if state.current_watcher_group then
    api.nvim_del_augroup_by_id(state.current_watcher_group)
  end

  state.current_watcher_group = api.nvim_create_augroup("EcologFileWatcher", { clear = true })

  local watch_patterns = {}

  if not opts.env_file_pattern then
    watch_patterns = {
      opts.path .. "/.env*",
    }
  else
    local patterns = type(opts.env_file_pattern) == "string" and { opts.env_file_pattern } or opts.env_file_pattern

    for _, pattern in ipairs(patterns) do
      local glob_pattern = pattern:gsub("^%^", ""):gsub("%$$", ""):gsub("%%.", "")
      table.insert(watch_patterns, opts.path .. glob_pattern:gsub("^%.%+/", "/"))
    end
  end

  api.nvim_create_autocmd({ "BufNewFile", "BufAdd" }, {
    group = state.current_watcher_group,
    pattern = watch_patterns,
    callback = function(ev)
      local matches = utils.filter_env_files({ ev.file }, opts.env_file_pattern)
      if #matches > 0 then
        state.cached_env_files = nil
        state.last_opts = nil

        local env_files = find_env_files(opts)
        if #env_files > 0 then
          state.selected_env_file = env_files[1]
          M.refresh_env_vars(opts)
          notify("New environment file detected: " .. fn.fnamemodify(ev.file, ":t"), vim.log.levels.INFO)
        end
      end
    end,
  })

  if state.selected_env_file then
    api.nvim_create_autocmd({ "BufWritePost", "FileChangedShellPost" }, {
      group = state.current_watcher_group,
      pattern = state.selected_env_file,
      callback = function()
        state.cached_env_files = nil
        state.last_opts = nil
        M.refresh_env_vars(opts)
        if state._env_module then
          state._env_module.update_env_vars()
        end
        notify("Environment file updated: " .. fn.fnamemodify(state.selected_env_file, ":t"), vim.log.levels.INFO)
      end,
    })
  end
end

local function load_providers()
  if state._providers_loaded then
    return
  end

  local provider_modules = {
    typescript = true,
    javascript = true,
    python = true,
    php = true,
    lua = true,
    go = true,
    rust = true,
  }

  for name in pairs(provider_modules) do
    local module_path = "ecolog.providers." .. name
    local ok, provider = pcall(require_module, module_path)
    if ok then
      if type(provider) == "table" then
        if provider.provider then
          providers.register(provider.provider)
        else
          providers.register_many(provider)
        end
      else
        providers.register(provider)
      end
    else
      notify(string.format("Failed to load %s provider: %s", name, provider), vim.log.levels.WARN)
    end
  end

  state._providers_loaded = true
end

function M.check_env_type(var_name, opts)
  parse_env_file(opts)

  local var = state.env_vars[var_name]
  if var then
    notify(
      string.format(
        "Environment variable '%s' exists with type: %s (from %s)",
        var_name,
        var.type,
        fn.fnamemodify(var.source, ":t")
      ),
      vim.log.levels.INFO
    )
    return var.type
  end

  notify(string.format("Environment variable '%s' does not exist", var_name), vim.log.levels.WARN)
  return nil
end

function M.refresh_env_vars(opts)
  state.cached_env_files = nil
  state.file_cache_opts = nil
  -- Use either last_opts or DEFAULT_CONFIG as the base
  local base_opts = state.last_opts or DEFAULT_CONFIG
  -- Always use full config
  opts = vim.tbl_deep_extend("force", base_opts, opts or {})
  parse_env_file(opts, true)
end

function M.get_env_vars()
  if next(state.env_vars) == nil then
    parse_env_file()
  end
  return state.env_vars
end

---@class EcologConfig
---@field path string Path to search for .env files
---@field shelter ShelterConfig Shelter mode configuration
---@field integrations IntegrationsConfig Integration settings
---@field types boolean|table Enable all types or specific type configuration
---@field custom_types table Custom type definitions
---@field preferred_environment string Preferred environment name
---@field load_shell LoadShellConfig Shell variables loading configuration
---@field env_file_pattern string|string[] Custom pattern(s) for matching env files
---@field sort_fn? function Custom function for sorting env files
---@field provider_patterns table|boolean Controls how environment variables are extracted from code. When table, contains 'extract' (default: true) and 'cmp' (default: true) fields. When boolean, sets both fields to that value. 'extract' controls whether variables are extracted through language-specific patterns, 'cmp' controls whether completion is enabled.

---@class ShelterConfig
---@field configuration ShelterConfiguration Configuration for shelter mode
---@field modules ShelterModules Module-specific shelter settings

---@class ShelterConfiguration
---@field partial_mode boolean|table Partial masking configuration. When false (default), completely masks values. When true, uses default partial masking. When table, customizes partial masking.
---@field mask_char string Character used for masking sensitive values
---@field highlight_group string The highlight group to use for masked values (default: "Comment")

---@class ShelterModules
---@field cmp boolean Mask values in completion menu
---@field peek boolean Mask values in peek view
---@field files boolean|FilesModuleConfig Mask values in environment files
---@field telescope boolean Mask values in telescope picker
---@field telescope_previewer boolean Mask values in telescope preview buffers
---@field fzf boolean Mask values in fzf picker
---@field fzf_previewer boolean Mask values in fzf preview buffers

---@class FilesModuleConfig
---@field enabled boolean Enable masking in environment files
---@field shelter_on_leave boolean Re-enable shelter when leaving buffer even if disabled by user

---@class IntegrationsConfig
---@field lsp boolean Enable LSP integration for hover and goto-definition
---@field lspsaga boolean Enable LSP Saga integration for hover and goto-definition
---@field nvim_cmp boolean Enable nvim-cmp integration for autocompletion
---@field blink_cmp boolean Enable Blink CMP integration for autocompletion
---@field fzf boolean Enable fzf-lua integration for environment variable picking

---@class LoadShellConfig
---@field enabled boolean Enable loading shell variables into environment
---@field override boolean When true, shell variables take precedence over .env files
---@field filter? function Optional function to filter which shell variables to load
---@field transform? function Optional function to transform shell variable values

---@param opts? EcologConfig
function M.setup(opts)
  -- Merge user options with defaults
  local config = vim.tbl_deep_extend("force", DEFAULT_CONFIG, opts or {})

  -- Normalize provider_patterns to table format
  if type(config.provider_patterns) == "boolean" then
    config.provider_patterns = {
      extract = config.provider_patterns,
      cmp = config.provider_patterns,
    }
  elseif type(config.provider_patterns) == "table" then
    config.provider_patterns = vim.tbl_deep_extend("force", {
      extract = true,
      cmp = true,
    }, config.provider_patterns)
  end

  state.last_opts = config

  if config.integrations.blink_cmp then
    config.integrations.nvim_cmp = false
  end

  require("ecolog.highlights").setup()
  shelter.setup({
    config = config.shelter.configuration,
    partial = config.shelter.modules,
  })
  types.setup({
    types = config.types,
    custom_types = config.custom_types,
  })

  if config.integrations.lsp then
    local lsp = require_module("ecolog.integrations.lsp")
    lsp.setup()
  end

  if config.integrations.lspsaga then
    local lspsaga = require_module("ecolog.integrations.lspsaga")
    lspsaga.setup()
  end

  if config.integrations.nvim_cmp then
    local nvim_cmp = require("ecolog.integrations.cmp.nvim_cmp")
    nvim_cmp.setup(opts.integrations.nvim_cmp, state.env_vars, providers, shelter, types, state.selected_env_file)
  end

  if config.integrations.blink_cmp then
    local blink_cmp = require("ecolog.integrations.cmp.blink_cmp")
    blink_cmp.setup(opts.integrations.blink_cmp, state.env_vars, providers, shelter, types, state.selected_env_file)
  end

  if config.integrations.fzf then
    local fzf = require("ecolog.integrations.fzf")
    fzf.setup(type(opts.integrations.fzf) == "table" and opts.integrations.fzf or {})
  end

  local initial_env_files = find_env_files({
    path = config.path,
    preferred_environment = config.preferred_environment,
    env_file_pattern = config.env_file_pattern,
    sort_fn = config.sort_fn,
  })

  if #initial_env_files > 0 then
    state.selected_env_file = initial_env_files[1]

    if config.preferred_environment == "" then
      local env_suffix = fn.fnamemodify(state.selected_env_file, ":t"):gsub("^%.env%.", "")
      if env_suffix ~= ".env" then
        config.preferred_environment = env_suffix
        local sorted_files = find_env_files(config)
        state.selected_env_file = sorted_files[1]
      end
    end

    notify(
      string.format("Selected environment file: %s", fn.fnamemodify(state.selected_env_file, ":t")),
      vim.log.levels.INFO
    )
  end

  schedule(function()
    parse_env_file(config)
  end)

  setup_file_watcher(config)

  -- Create commands with the config
  local commands = {
    EcologPeek = {
      callback = function(args)
        load_providers()
        parse_env_file(config)
        peek.peek_env_value(args.args, config, state.env_vars, providers, parse_env_file)
      end,
      nargs = "?",
      desc = "Peek at environment variable value",
    },
    EcologGenerateExample = {
      callback = function()
        if not state.selected_env_file then
          notify("No environment file selected. Use :EcologSelect to select one.", vim.log.levels.ERROR)
          return
        end
        utils.generate_example_file(state.selected_env_file)
      end,
      desc = "Generate .env.example file from selected .env file",
    },
    EcologShelterToggle = {
      callback = function(args)
        local arg = args.args:lower()
        if arg == "" then
          shelter.toggle_all()
          return
        end
        local parts = vim.split(arg, " ")
        local command = parts[1]
        local feature = parts[2]
        if command ~= "enable" and command ~= "disable" then
          notify("Invalid command. Use 'enable' or 'disable'", vim.log.levels.ERROR)
          return
        end
        shelter.set_state(command, feature)
      end,
      nargs = "?",
      desc = "Toggle all shelter modes or enable/disable specific features",
      complete = function(arglead, cmdline)
        local args = vim.split(cmdline, "%s+")
        if #args == 2 then
          return vim.tbl_filter(function(item)
            return item:find(arglead, 1, true)
          end, { "enable", "disable" })
        elseif #args == 3 then
          return vim.tbl_filter(function(item)
            return item:find(arglead, 1, true)
          end, { "cmp", "peek", "files" })
        end
        return { "enable", "disable" }
      end,
    },
    EcologRefresh = {
      callback = function()
        M.refresh_env_vars(config)
      end,
      desc = "Refresh environment variables cache",
    },
    EcologSelect = {
      callback = function()
        select.select_env_file({
          path = config.path,
          active_file = state.selected_env_file,
          env_file_pattern = config.env_file_pattern,
          sort_fn = config.sort_fn,
          preferred_environment = config.preferred_environment,
        }, function(file)
          if file then
            state.selected_env_file = file
            config.preferred_environment = fn.fnamemodify(file, ":t"):gsub("^%.env%.", "")
            setup_file_watcher(config)
            state.cached_env_files = nil
            M.refresh_env_vars(config)
            if state._env_module then
              state._env_module.update_env_vars()
            end
            notify(string.format("Selected environment file: %s", fn.fnamemodify(file, ":t")), vim.log.levels.INFO)
          end
        end)
      end,
      desc = "Select environment file to use",
    },
    EcologGoto = {
      callback = function()
        if state.selected_env_file then
          vim.cmd("edit " .. fn.fnameescape(state.selected_env_file))
        else
          notify("No environment file selected", vim.log.levels.WARN)
        end
      end,
      desc = "Go to selected environment file",
    },
    EcologGotoVar = {
      callback = function(args)
        local filetype = vim.bo.filetype
        local available_providers = providers.get_providers(filetype)
        local var_name = args.args

        if var_name == "" then
          var_name = utils.get_var_word_under_cursor(available_providers)
        end

        if not var_name or #var_name == 0 then
          notify("No environment variable specified or found at cursor", vim.log.levels.WARN)
          return
        end

        parse_env_file(config)

        local var = state.env_vars[var_name]
        if not var then
          notify(string.format("Environment variable '%s' not found", var_name), vim.log.levels.WARN)
          return
        end

        vim.cmd("edit " .. fn.fnameescape(var.source))

        local lines = api.nvim_buf_get_lines(0, 0, -1, false)
        for i, line in ipairs(lines) do
          if line:match("^" .. vim.pesc(var_name) .. "=") then
            api.nvim_win_set_cursor(0, { i, 0 })
            vim.cmd("normal! zz")
            break
          end
        end
      end,
      nargs = "?",
      desc = "Go to environment variable definition in file",
    },
    EcologFzf = {
      callback = function()
        local has_fzf, fzf = pcall(require, "ecolog.integrations.fzf")
        if not has_fzf or not config.integrations.fzf then
          notify(
            "FZF integration is not enabled. Enable it in your setup with integrations.fzf = true",
            vim.log.levels.ERROR
          )
          return
        end
        if not fzf._initialized then
          fzf.setup(type(opts.integrations.fzf) == "table" and opts.integrations.fzf or {})

          fzf._initialized = true
        end
        fzf.env_picker()
      end,
      desc = "Open FZF environment variable picker",
    },
  }

  for name, cmd in pairs(commands) do
    api.nvim_create_user_command(name, cmd.callback, {
      nargs = cmd.nargs,
      desc = cmd.desc,
      complete = cmd.complete,
    })
  end

  if opts.vim_env then
    get_env_module()
  end
end

M.find_word_boundaries = utils.find_word_boundaries

-- Get the current configuration
function M.get_config()
  return state.last_opts or DEFAULT_CONFIG
end

return M
