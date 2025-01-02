---@class EcologConfig
---@field path string Path to search for .env files
---@field shelter ShelterConfig Shelter mode configuration
---@field integrations IntegrationsConfig Integration settings
---@field types boolean|table Enable all types or specific type configuration
---@field custom_types table Custom type definitions
---@field preferred_environment string Preferred environment name
---@field load_shell LoadShellConfig Shell variables loading configuration

---@class ShelterConfig
---@field configuration ShelterConfiguration Configuration for shelter mode
---@field modules ShelterModules Module-specific shelter settings

---@class ShelterConfiguration
---@field partial_mode boolean|table Partial masking configuration
---@field mask_char string Character used for masking

---@class ShelterModules
---@field cmp boolean Mask values in completion
---@field peek boolean Mask values in peek view
---@field files boolean Mask values in files
---@field telescope boolean Mask values in telescope
---@field fzf boolean Mask values in fzf

---@class IntegrationsConfig
---@field lsp boolean Enable LSP integration
---@field lspsaga boolean Enable LSP Saga integration
---@field nvim_cmp boolean Enable nvim-cmp integration
---@field blink_cmp boolean Enable Blink CMP integration
---@field fzf boolean Enable fzf-lua integration

---@class LoadShellConfig
---@field enabled boolean Enable loading shell variables
---@field override boolean Override .env file variables with shell variables
---@field filter? function Optional function to filter shell variables
---@field transform? function Optional function to transform shell variables

local M = {}

-- Optimized module loading system
local _loaded_modules = {}
local _loading = {}

local function require_module(name)
  if _loaded_modules[name] then
    return _loaded_modules[name]
  end

  -- Prevent circular requires
  if _loading[name] then
    error("Circular dependency detected: " .. name)
  end

  _loading[name] = true
  local module = require(name)
  _loading[name] = nil
  _loaded_modules[name] = module
  return module
end

-- Cache frequently used modules
local utils = require_module("ecolog.utils")
local providers = utils.get_module("ecolog.providers")
local select = utils.get_module("ecolog.select")
local peek = utils.get_module("ecolog.peek")
local shelter = utils.get_module("ecolog.shelter")
local types = utils.get_module("ecolog.types")

-- Pre-compile patterns for better performance
local PATTERNS = utils.PATTERNS

-- Cache vim APIs
local api = vim.api
local fn = vim.fn
local notify = vim.notify
local schedule = vim.schedule
local tbl_extend = vim.tbl_deep_extend

-- Cache and state management
local env_vars = {}
local cached_env_files = nil
local last_opts = nil
local current_watcher_group = nil
local selected_env_file = nil

-- Find environment files for selection
local function find_env_files(opts)
  opts = opts or {}
  opts.path = opts.path or fn.getcwd()
  opts.preferred_environment = opts.preferred_environment or ""

  -- Use cached files if possible
  if
    cached_env_files
    and last_opts
    and last_opts.path == opts.path
    and last_opts.preferred_environment == opts.preferred_environment
  then
    return cached_env_files
  end

  -- Store options for cache validation
  last_opts = tbl_extend("force", {}, opts)

  -- Find all env files
  local raw_files = fn.globpath(opts.path, ".env*", false, true)

  -- Ensure raw_files is a table
  if type(raw_files) == "string" then
    raw_files = vim.split(raw_files, "\n")
  end

  local files = vim.tbl_filter(function(file)
    local is_env = file:match("%.env$") or file:match("%.env%.[^.]+$")
    return is_env ~= nil -- Return true if there's a match
  end, raw_files)

  if #files == 0 then
    return {}
  end

  -- Sort files by priority using string patterns
  files = utils.sort_env_files(files, opts)

  cached_env_files = files
  return files
end

-- Parse a single line from env file
local function parse_env_line(line, file_path)
  if not line:match(PATTERNS.env_line) then
    return nil
  end

  local key, value = line:match(PATTERNS.key_value)
  if not (key and value) then
    return nil
  end

  -- Clean up key
  key = key:match(PATTERNS.trim)

  -- Extract comment if present
  local comment
  if value:match("^[\"'].-[\"']%s+(.+)$") then
    -- For quoted values with comments
    local quoted_value = value:match("^([\"'].-[\"'])%s+.+$")
    comment = value:match("^[\"'].-[\"']%s+#?%s*(.+)$")
    value = quoted_value
  elseif value:match("^[^%s]+%s+(.+)$") and not value:match("^[\"']") then
    -- For unquoted values with comments
    local main_value = value:match("^([^%s]+)%s+.+$")
    comment = value:match("^[^%s]+%s+#?%s*(.+)$")
    value = main_value
  end

  -- Remove any quotes from value
  value = value:gsub(PATTERNS.quoted, "%1")
  value = value:match(PATTERNS.trim)

  -- Get types module
  local types = require("ecolog.types")

  -- Detect type and possibly transform value
  local type_name, transformed_value = types.detect_type(value)

  return key,
    {
      value = transformed_value or value, -- Use transformed value if available
      type = type_name,
      raw_value = value, -- Store original value
      source = file_path,
      comment = comment,
    }
end

-- Parse environment files
local function parse_env_file(opts, force)
  opts = opts or {}

  if not force and next(env_vars) ~= nil then
    return
  end

  -- Clear existing env vars
  env_vars = {}

  -- Load shell variables if enabled
  if
    opts.load_shell
    and (
      (type(opts.load_shell) == "boolean" and opts.load_shell)
      or (type(opts.load_shell) == "table" and opts.load_shell.enabled)
    )
  then
    local shell_vars = vim.fn.environ()
    local shell_config = type(opts.load_shell) == "table" and opts.load_shell or { enabled = true }

    -- Apply filter if provided
    if shell_config.filter then
      local filtered_vars = {}
      for key, value in pairs(shell_vars) do
        if shell_config.filter(key, value) then
          filtered_vars[key] = value
        end
      end
      shell_vars = filtered_vars
    end

    -- Process shell variables
    for key, value in pairs(shell_vars) do
      -- Apply transform if provided
      if shell_config.transform then
        value = shell_config.transform(key, value)
      end

      -- Get types module
      local types = require("ecolog.types")
      -- Detect type and possibly transform value
      local type_name, transformed_value = types.detect_type(value)

      env_vars[key] = {
        value = transformed_value or value,
        type = type_name,
        raw_value = value,
        source = "shell",
        comment = nil,
      }
    end
  end

  -- Only find files if we don't have a selected file
  if not selected_env_file then
    local env_files = find_env_files(opts)
    if #env_files > 0 then
      selected_env_file = env_files[1]
    end
  end

  -- Parse selected env file
  if selected_env_file then
    local env_file = io.open(selected_env_file, "r")
    if env_file then
      for line in env_file:lines() do
        local key, var_info = parse_env_line(line, selected_env_file)
        if key then
          -- Only override shell vars if configured to NOT override
          -- or if the key doesn't exist yet
          if not env_vars[key] or (opts.load_shell and not opts.load_shell.override) then
            env_vars[key] = var_info
          end
        end
      end
      env_file:close()
    end
  end
end

-- Set up file watcher
local function setup_file_watcher(opts)
  -- Clear existing watcher if any
  if current_watcher_group then
    api.nvim_del_augroup_by_id(current_watcher_group)
  end

  -- Create new watcher group
  current_watcher_group = api.nvim_create_augroup("EcologFileWatcher", { clear = true })

  -- Watch for new .env files in the directory
  api.nvim_create_autocmd({ "BufNewFile", "BufAdd" }, {
    group = current_watcher_group,
    pattern = opts.path .. "/.env*",
    callback = function(ev)
      if ev.file:match(PATTERNS.env_file) or ev.file:match(PATTERNS.env_with_suffix) then
        cached_env_files = nil -- Clear cache to force refresh
        M.refresh_env_vars(opts)
        notify("New environment file detected: " .. fn.fnamemodify(ev.file, ":t"), vim.log.levels.INFO)
      end
    end,
  })

  -- Watch selected env file for changes
  if selected_env_file then
    api.nvim_create_autocmd({ "BufWritePost", "FileChangedShellPost" }, {
      group = current_watcher_group,
      pattern = selected_env_file,
      callback = function()
        cached_env_files = nil -- Clear cache to force refresh
        M.refresh_env_vars(opts)
        notify("Environment file updated: " .. fn.fnamemodify(selected_env_file, ":t"), vim.log.levels.INFO)
      end,
    })
  end
end

-- Environment variable type checking
function M.check_env_type(var_name, opts)
  parse_env_file(opts)

  local var = env_vars[var_name]
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

-- Refresh environment variables
function M.refresh_env_vars(opts)
  cached_env_files = nil
  last_opts = nil
  parse_env_file(opts, true)
end

-- Get environment variables (for telescope integration)
function M.get_env_vars()
  if next(env_vars) == nil then
    parse_env_file()
  end
  return env_vars
end

-- Setup function
---@param opts? EcologConfig
function M.setup(opts)
  opts = vim.tbl_deep_extend("force", {
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
        fzf = false,
      },
    },
    integrations = {
      lsp = false,
      lspsaga = false,
      nvim_cmp = true, -- Enable nvim-cmp integration by default
      blink_cmp = false, -- Disable Blink CMP integration by default
      fzf = false,
    },
    types = true, -- Enable all types by default
    custom_types = {}, -- Custom types configuration
    preferred_environment = "", -- Add this default
    load_shell = {
      enabled = false,
      override = false,
      filter = nil,
      transform = nil,
    },
  }, opts or {})

  -- If blink_cmp is enabled, disable nvim_cmp to avoid conflicts
  if opts.integrations.blink_cmp then
    opts.integrations.nvim_cmp = false
  end

  -- Initialize highlights first
  require("ecolog.highlights").setup()

  -- Initialize shelter mode with the config
  shelter.setup({
    config = opts.shelter.configuration,
    partial = opts.shelter.modules,
  })

  -- Register custom types with the new configuration format
  types.setup({
    types = opts.types,
    custom_types = opts.custom_types,
  })

  -- Set up LSP integration if enabled
  if opts.integrations.lsp then
    local lsp = require_module("ecolog.integrations.lsp")
    lsp.setup()
  end

  -- Set up LSP Saga integration if enabled
  if opts.integrations.lspsaga then
    local lspsaga = require_module("ecolog.integrations.lspsaga")
    lspsaga.setup()
  end

  -- Set up nvim-cmp integration if enabled
  if opts.integrations.nvim_cmp then
    local nvim_cmp = require("ecolog.integrations.cmp.nvim_cmp")
    nvim_cmp.setup(opts, env_vars, providers, shelter, types, selected_env_file)
  end

  -- Set up Blink CMP integration if enabled
  if opts.integrations.blink_cmp then
    local blink_cmp = require("ecolog.integrations.cmp.blink_cmp")
    blink_cmp.setup(opts, env_vars, providers, shelter, types, selected_env_file)
    -- No need to do anything else since Blink will create instances using Source.new()
  end

  -- Set up fzf-lua integration if enabled
  if opts.integrations.fzf then
    local fzf = require("ecolog.integrations.fzf")
    fzf.setup(opts)
  end

  -- Lazy load providers only when needed
  local function load_providers()
    if M._providers_loaded then
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

    M._providers_loaded = true
  end

  -- Find initial environment files with preferred_environment if set
  local initial_env_files = find_env_files({
    path = opts.path,
    preferred_environment = opts.preferred_environment,
  })

  if #initial_env_files > 0 then
    -- Get the first file and set it as selected
    selected_env_file = initial_env_files[1]

    -- Only update preferred_environment if it wasn't already set
    if opts.preferred_environment == "" then
      local env_suffix = fn.fnamemodify(selected_env_file, ":t"):gsub("^%.env%.", "")
      if env_suffix ~= ".env" then
        opts.preferred_environment = env_suffix
        -- Re-find files with updated preferred_environment
        local sorted_files = find_env_files(opts)
        -- Update selected file
        selected_env_file = sorted_files[1]
      end
    end

    -- Show notification
    notify(string.format("Selected environment file: %s", fn.fnamemodify(selected_env_file, ":t")), vim.log.levels.INFO)
  end

  -- Defer initial parsing
  schedule(function()
    parse_env_file(opts)
  end)

  -- Set up file watchers
  setup_file_watcher(opts)

  -- Create commands
  local commands = {
    EcologPeek = {
      callback = function(args)
        load_providers() -- Lazy load providers when needed
        parse_env_file(opts) -- Make sure env vars are loaded
        peek.peek_env_value(args.args, opts, env_vars, providers, parse_env_file)
      end,
      nargs = "?",
      desc = "Peek at environment variable value",
    },
    EcologGenerateExample = {
      callback = function()
        if not selected_env_file then
          notify("No environment file selected. Use :EcologSelect to select one.", vim.log.levels.ERROR)
          return
        end

        utils.generate_example_file(selected_env_file)
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
        M.refresh_env_vars(opts)
      end,
      desc = "Refresh environment variables cache",
    },
    EcologSelect = {
      callback = function()
        select.select_env_file({
          path = opts.path,
          active_file = selected_env_file, -- Pass the currently selected file
        }, function(file)
          if file then
            selected_env_file = file
            opts.preferred_environment = fn.fnamemodify(file, ":t"):gsub("^%.env%.", "")
            -- Update file watchers for the new file
            setup_file_watcher(opts)
            -- Clear cache and force refresh
            cached_env_files = nil
            M.refresh_env_vars(opts)
            notify(string.format("Selected environment file: %s", fn.fnamemodify(file, ":t")), vim.log.levels.INFO)
          end
        end)
      end,
      desc = "Select environment file to use",
    },
    EcologGoto = {
      callback = function()
        if selected_env_file then
          vim.cmd("edit " .. fn.fnameescape(selected_env_file))
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

        -- If no variable name provided, try to get it from cursor position
        if var_name == "" then
          local line = api.nvim_get_current_line()
          local cursor_pos = api.nvim_win_get_cursor(0)
          local col = cursor_pos[2]

          -- Find word boundaries
          local word_start, word_end = utils.find_word_boundaries(line, col)

          -- Try to extract variable using providers
          for _, provider in ipairs(available_providers) do
            local extracted = provider.extract_var(line, word_end)
            if extracted then
              var_name = extracted
              break
            end
          end

          -- If no provider matched, use the word under cursor
          if not var_name or #var_name == 0 then
            var_name = line:sub(word_start, word_end)
          end
        end

        if not var_name or #var_name == 0 then
          notify("No environment variable specified or found at cursor", vim.log.levels.WARN)
          return
        end

        -- Parse env files if needed
        parse_env_file(opts)

        -- Check if variable exists
        local var = env_vars[var_name]
        if not var then
          notify(string.format("Environment variable '%s' not found", var_name), vim.log.levels.WARN)
          return
        end

        -- Open the file
        vim.cmd("edit " .. fn.fnameescape(var.source))

        -- Find the line with the variable
        local lines = api.nvim_buf_get_lines(0, 0, -1, false)
        for i, line in ipairs(lines) do
          if line:match("^" .. vim.pesc(var_name) .. "=") then
            -- Move cursor to the line
            api.nvim_win_set_cursor(0, { i, 0 })
            -- Center the screen on the line
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
        if not has_fzf or not opts.integrations.fzf then
          notify(
            "FZF integration is not enabled. Enable it in your setup with integrations.fzf = true",
            vim.log.levels.ERROR
          )
          return
        end
        -- Initialize FZF if it hasn't been initialized yet
        if not fzf._initialized then
          fzf.setup(opts)
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
end

-- Add find_word_boundaries to the module's return table
M.find_word_boundaries = utils.find_word_boundaries

-- Add this function to the module
function M.get_config()
  return {
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
        fzf = false,
      },
    },
    integrations = {
      lsp = false,
      lspsaga = false,
      nvim_cmp = true,
      blink_cmp = false,
      fzf = false,
    },
    types = true,
    custom_types = {},
    preferred_environment = "",
    load_shell = {
      enabled = false,
      override = false,
      filter = nil,
      transform = nil,
    },
  }
end

return M
