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
      snacks = false,
      snacks_previewer = false,
    },
  },
  integrations = {
    lsp = false,
    lspsaga = false,
    nvim_cmp = true,
    blink_cmp = false,
    fzf = false,
    statusline = false,
    snacks = false,
    aws_secrets_manager = false,
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
local _setup_done = false
local _lazy_setup_tasks = {}

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
  _env_module = nil,
  _file_watchers = {},
}

local function get_env_module()
  if not state._env_module then
    state._env_module = require("ecolog.env")
    state._env_module.setup()
  end
  return state._env_module
end

-- Cache for parsed env lines
local _env_line_cache = setmetatable({}, {
  __mode = "k", -- Make it a weak table to avoid memory leaks
})

local function parse_env_line(line, file_path)
  local cache_key = line .. file_path
  if _env_line_cache[cache_key] then
    return unpack(_env_line_cache[cache_key])
  end

  -- Skip empty lines and comments
  if line:match("^%s*$") or line:match("^%s*#") then
    _env_line_cache[cache_key] = { nil }
    return nil
  end

  -- Use the optimized pattern matching from utils
  local key, value, comment = utils.extract_line_parts(line)
  if not key or not value then
    _env_line_cache[cache_key] = { nil }
    return nil
  end

  -- Detect type and transform value
  local type_name, transformed_value = types.detect_type(value)

  local result = {
    key,
    {
      value = transformed_value or value,
      type = type_name,
      raw_value = value,
      source = fn.fnamemodify(file_path, ":t"),
      comment = comment,
    },
  }
  _env_line_cache[cache_key] = result
  return unpack(result)
end

local function cleanup_file_watchers()
  if state.current_watcher_group then
    pcall(api.nvim_del_augroup_by_id, state.current_watcher_group)
  end
  for _, watcher in pairs(state._file_watchers) do
    pcall(api.nvim_del_autocmd, watcher)
  end
  state._file_watchers = {}
end

local function setup_file_watcher(opts)
  cleanup_file_watchers()

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

  local function handle_env_file_change()
    state.cached_env_files = nil
    state.last_opts = nil
    M.refresh_env_vars(opts)
    if state._env_module then
      state._env_module.update_env_vars()
    end
  end

  -- Watch for new files
  table.insert(
    state._file_watchers,
    api.nvim_create_autocmd({ "BufNewFile", "BufAdd" }, {
      group = state.current_watcher_group,
      pattern = watch_patterns,
      callback = function(ev)
        local matches = utils.filter_env_files({ ev.file }, opts.env_file_pattern)
        if #matches > 0 then
          state.cached_env_files = nil
          state.last_opts = nil

          local env_files = utils.find_env_files(opts)
          if #env_files > 0 then
            state.selected_env_file = env_files[1]
            handle_env_file_change()
            notify("New environment file detected: " .. fn.fnamemodify(ev.file, ":t"), vim.log.levels.INFO)
          end
        end
      end,
    })
  )

  if state.selected_env_file then
    table.insert(
      state._file_watchers,
      api.nvim_create_autocmd({ "BufWritePost", "FileChangedShellPost" }, {
        group = state.current_watcher_group,
        pattern = state.selected_env_file,
        callback = function()
          handle_env_file_change()
          notify("Environment file updated: " .. fn.fnamemodify(state.selected_env_file, ":t"), vim.log.levels.INFO)
        end,
      })
    )
  end
end

local function parse_env_file(opts, force)
  -- Always use full config
  opts = vim.tbl_deep_extend("force", state.last_opts or DEFAULT_CONFIG, opts or {})

  if not force and next(state.env_vars) ~= nil then
    return
  end

  state.env_vars = {}

  if not state.selected_env_file then
    local env_files = utils.find_env_files(opts)
    if #env_files > 0 then
      state.selected_env_file = env_files[1]
    end
  end

  -- Load AWS Secrets Manager secrets if configured
  if opts.integrations and opts.integrations.aws_secrets_manager then
    local aws_secrets = require("ecolog.integrations.aws_secrets_manager").load_aws_secrets(opts.integrations.aws_secrets_manager)
    for key, var_info in pairs(aws_secrets) do
      if opts.integrations.aws_secrets_manager.override or not state.env_vars[key] then
        state.env_vars[key] = var_info
      end
    end
  end

  if
    opts.load_shell
    and (
      (type(opts.load_shell) == "boolean" and opts.load_shell)
      or (type(opts.load_shell) == "table" and opts.load_shell.enabled)
    )
  then
    local shell_config = type(opts.load_shell) == "boolean" and { enabled = true, override = false } or opts.load_shell

    local shell_vars = shell.load_shell_vars(shell_config)

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
          local shell_config = type(opts.load_shell) == "boolean" and { enabled = opts.load_shell, override = false }
            or opts.load_shell

          if not opts.load_shell or not shell_config.override or not state.env_vars[key] then
            state.env_vars[key] = var_info
          end
        end
      end
      env_file:close()
    end
  end
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
        var.source
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

  -- Invalidate statusline cache only if integration is enabled
  if opts.integrations.statusline then
    local statusline = require("ecolog.integrations.statusline")
    statusline.invalidate_cache()
  end
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
---@field snacks boolean Mask values in snacks picker
---@field snacks_previewer boolean Mask values in snacks preview buffers

---@class FilesModuleConfig
---@field enabled boolean Enable masking in environment files
---@field shelter_on_leave boolean Re-enable shelter when leaving buffer even if disabled by user

---@class IntegrationsConfig
---@field lsp boolean Enable LSP integration for hover and goto-definition
---@field lspsaga boolean Enable LSP Saga integration for hover and goto-definition
---@field nvim_cmp boolean Enable nvim-cmp integration for autocompletion
---@field blink_cmp boolean Enable Blink CMP integration for autocompletion
---@field fzf boolean Enable fzf-lua integration for environment variable picking
---@field statusline boolean|StatuslineConfig Enable statusline integration
---@field snacks boolean Enable snacks integration
---@field aws_secrets_manager boolean Enable AWS Secrets Manager integration

---@class StatuslineConfig
---@field hidden_mode boolean When true, hides the statusline section if no env file is selected

---@class LoadShellConfig
---@field enabled boolean Enable loading shell variables into environment
---@field override boolean When true, shell variables take precedence over .env files
---@field filter? function Optional function to filter which shell variables to load
---@field transform? function Optional function to transform shell variable values

---@param opts? EcologConfig
function M.setup(opts)
  if _setup_done then
    return
  end
  _setup_done = true

  -- Merge user options with defaults
  local config = vim.tbl_deep_extend("force", DEFAULT_CONFIG, opts or {})

  -- Add this near the start of setup
  state.selected_env_file = nil -- Make sure this is tracked in state

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

  -- Core setup
  require("ecolog.highlights").setup()
  shelter.setup({
    config = config.shelter.configuration,
    partial = config.shelter.modules,
  })
  types.setup({
    types = config.types,
    custom_types = config.custom_types,
  })

  -- Defer integration loading
  local function setup_integrations()
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

    if config.integrations.statusline then
      local statusline = require("ecolog.integrations.statusline")
      statusline.setup(type(opts.integrations.statusline) == "table" and opts.integrations.statusline or {})
    end

    if config.integrations.snacks then
      local snacks = require("ecolog.integrations.snacks")
      snacks.setup(type(opts.integrations.snacks) == "table" and opts.integrations.snacks or {})
    end
  end

  -- Schedule integration setup
  table.insert(_lazy_setup_tasks, setup_integrations)

  local initial_env_files = utils.find_env_files({
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
        local sorted_files = utils.find_env_files(config)
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
    setup_file_watcher(config)

    -- Execute lazy setup tasks
    for _, task in ipairs(_lazy_setup_tasks) do
      task()
    end
  end)

  -- Create commands with the config
  local commands = {
    EcologPeek = {
      callback = function(args)
        local filetype = vim.bo.filetype
        local available_providers = providers.get_providers(filetype)
        peek.peek_env_var(available_providers, args.args)
      end,
      nargs = "?",
      desc = "Peek environment variable value",
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
    EcologCopy = {
      callback = function(args)
        local filetype = vim.bo.filetype
        local var_name = args.args

        if var_name == "" then
          if config.provider_patterns.extract then
            local available_providers = providers.get_providers(filetype)
            var_name = utils.get_var_word_under_cursor(available_providers)
          else
            local word = vim.fn.expand("<cword>")
            if word and #word > 0 then
              var_name = word
            end
          end
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

        local value = var.raw_value
        vim.fn.setreg("+", value)
        vim.fn.setreg('"', value)
        notify(string.format("Copied raw value of '%s' to clipboard", var_name), vim.log.levels.INFO)
      end,
      nargs = "?",
      desc = "Copy environment variable value to clipboard",
    },
    EcologAWSSecrets = {
      callback = function()
        local aws_secrets = require("ecolog.integrations.aws_secrets_manager")
        aws_secrets.select()
      end,
      desc = "Select AWS Secrets Manager secrets to load",
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
    schedule(function()
      get_env_module()
    end)
  end
end

M.find_word_boundaries = utils.find_word_boundaries

-- Get the current configuration
function M.get_config()
  return state.last_opts or DEFAULT_CONFIG
end

-- Add these new functions
function M.get_status()
  if not state.last_opts or not state.last_opts.integrations.statusline then
    return ""
  end

  local config = state.last_opts.integrations.statusline
  if type(config) == "table" and config.hidden_mode and not state.selected_env_file then
    return ""
  end

  return require("ecolog.integrations.statusline").get_statusline()
end

function M.get_lualine()
  if not state.last_opts or not state.last_opts.integrations.statusline then
    return ""
  end

  local config = state.last_opts.integrations.statusline
  if type(config) == "table" and config.hidden_mode and not state.selected_env_file then
    return ""
  end

  return require("ecolog.integrations.statusline").lualine()
end

function M.get_state()
  return state
end

return M
