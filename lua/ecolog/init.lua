local M = {}
local api = vim.api
local fn = vim.fn
local notify = vim.notify
local providers = require("ecolog.providers")
local select = require("ecolog.select")
local peek = require("ecolog.peek")
local shelter = require("ecolog.shelter")

-- Cached patterns
local PATTERNS = {
	env_file = "%.env$",
	env_with_suffix = "%.env%.[^.]+$",
	env_line = "^[^#](.+)$",
	key_value = "([^=]+)=(.+)",
	quoted = "^['\"](.*)['\"]$",
	trim = "^%s*(.-)%s*$",
}

-- Cache and state management
local env_vars = {}
local cached_env_files = nil
local last_opts = nil
local current_watcher_group = nil
local selected_env_file = nil

-- Find environment files
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
	last_opts = vim.tbl_extend("force", {}, opts)

	-- Find all env files
	local raw_files = fn.globpath(opts.path, ".env*", false, true)
	local files = vim.tbl_filter(function(v)
		return v:match(PATTERNS.env_file) or v:match(PATTERNS.env_with_suffix)
	end, raw_files)

	if #files == 0 then
		return {}
	end

	-- Sort files by priority
	table.sort(files, function(a, b)
		-- If preferred environment is specified, prioritize it
		if opts.preferred_environment ~= "" then
			local pref_pattern = "%.env%." .. vim.pesc(opts.preferred_environment) .. "$"
			local a_is_preferred = a:match(pref_pattern) ~= nil
			local b_is_preferred = b:match(pref_pattern) ~= nil
			if a_is_preferred ~= b_is_preferred then
				return a_is_preferred
			end
		end

		-- Then prioritize .env file
		local a_is_env = a:match(PATTERNS.env_file) ~= nil
		local b_is_env = b:match(PATTERNS.env_file) ~= nil
		if a_is_env ~= b_is_env then
			return a_is_env
		end

		-- Default to alphabetical order
		return a < b
	end)

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

	value = value:gsub(PATTERNS.quoted, "%1")
	key = key:match(PATTERNS.trim)

	return key, {
		value = value,
		type = tonumber(value) and "number" or "string",
		source = file_path,
	}
end

-- Parse environment files
local function parse_env_file(opts, force)
	if not force and next(env_vars) ~= nil then
		return
	end

	local env_files = find_env_files(opts)
	env_vars = {}

	for _, file_path in ipairs(env_files) do
		local env_file = io.open(file_path, "r")
		if env_file then
			for line in env_file:lines() do
				local key, var_info = parse_env_line(line, file_path)
				if key then
					env_vars[key] = var_info
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

-- Create completion source
local function setup_completion(cmp)
	-- Create highlight groups for cmp
	api.nvim_set_hl(0, "CmpItemKindEcolog", { link = "EcologVariable" })
	api.nvim_set_hl(0, "CmpItemAbbrMatchEcolog", { link = "EcologVariable" })
	api.nvim_set_hl(0, "CmpItemAbbrMatchFuzzyEcolog", { link = "EcologVariable" })
	api.nvim_set_hl(0, "CmpItemMenuEcolog", { link = "EcologSource" })

	-- Register completion source
	cmp.register_source("ecolog", {
		get_trigger_characters = function()
			return { ".", "'" }
		end,

		complete = function(_, request, callback)
			local filetype = vim.bo.filetype
			local available_providers = providers.get_providers(filetype)

			-- Check completion trigger
			local should_complete = false
			local line = request.context.cursor_before_line

			for _, provider in ipairs(available_providers) do
				local trigger = provider.get_completion_trigger()
				local parts = vim.split(trigger, ".", { plain = true })
				local pattern = table.concat(
					vim.tbl_map(function(part)
						return vim.pesc(part)
					end, parts),
					"%."
				)

				if line:match(pattern .. "$") then
					should_complete = true
					break
				end
			end

			if not should_complete then
				callback({ items = {}, isIncomplete = false })
				return
			end

			parse_env_file()

			local items = {}
			for var_name, var_info in pairs(env_vars) do
				local doc_value = shelter.mask_value(var_info.value, "cmp")
				table.insert(items, {
					label = var_name,
					kind = cmp.lsp.CompletionItemKind.Variable,
					detail = fn.fnamemodify(var_info.source, ":t"),
					documentation = {
						kind = "markdown",
						value = string.format("**Type:** `%s`\n**Value:** `%s`", var_info.type, doc_value),
					},
					kind_hl_group = "CmpItemKindEcolog",
					menu_hl_group = "CmpItemMenuEcolog",
					abbr_hl_group = "CmpItemAbbrMatchEcolog",
				})
			end

			callback({ items = items, isIncomplete = false })
		end,
	})
end

-- Get environment variables (for telescope integration)
function M.get_env_vars()
	if next(env_vars) == nil then
		parse_env_file()
	end
	return env_vars
end

-- Setup function
function M.setup(opts)
	opts = vim.tbl_deep_extend("force", {
		shelter = {
			configuration = {
				-- When partial_mode is enabled, secrets will be partially visible
				-- Can be boolean or table:
				-- true: uses default settings
				-- false: disables partial mode
				-- table: custom settings
				partial_mode = false, -- Default to disabled
				mask_char = "*", -- Character used for masking
			},
			modules = {
				cmp = false, -- Enable masking in completion
				peek = false, -- Enable masking in peek view
				files = false, -- Enable masking in files
				telescope = false, -- Enable masking in telescope
			},
		},
	}, opts or {})

	-- Initialize shelter mode with the config
	shelter.setup({
		config = opts.shelter.configuration,
		partial = opts.shelter.modules,
	})

	-- Create highlight groups
	require("ecolog.highlights").setup()

	-- Find and select initial environment file
	local env_files = find_env_files(opts)
	if #env_files > 0 then
		selected_env_file = env_files[1]
		opts.preferred_environment = fn.fnamemodify(selected_env_file, ":t"):gsub("^%.env%.", "")
		notify("Using environment file: " .. fn.fnamemodify(selected_env_file, ":t"), vim.log.levels.INFO)
	end

	parse_env_file(opts)

	-- Register built-in providers
	local providers_list = {
		typescript = require("ecolog.providers.typescript"),
		javascript = require("ecolog.providers.javascript"),
		python = require("ecolog.providers.python"),
		php = require("ecolog.providers.php"),
		lua = require("ecolog.providers.lua"),
		go = require("ecolog.providers.go"),
		rust = require("ecolog.providers.rust"),
	}

	-- Register providers
	for _, provider in pairs(providers_list) do
		if type(provider) == "table" then
			if provider.provider then
				providers.register(provider.provider)
			else
				providers.register_many(provider)
			end
		else
			providers.register(provider)
		end
	end

	-- Set up file watchers
	setup_file_watcher(opts)

	-- Set up completion if available
	local has_cmp, cmp = pcall(require, "cmp")
	if has_cmp then
		setup_completion(cmp)
	end

	-- Create commands
	api.nvim_create_user_command("EcologPeek", function(args)
		peek.peek_env_value(args.args, opts, env_vars, providers, parse_env_file)
	end, {
		nargs = "?",
		desc = "Peek at environment variable value",
	})

	api.nvim_create_user_command("EcologShelterToggle", function(args)
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
	end, {
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
	})

	api.nvim_create_user_command("EcologRefresh", function()
		M.refresh_env_vars(opts)
	end, {
		desc = "Refresh environment variables cache",
	})

	api.nvim_create_user_command("EcologSelect", function()
		select.select_env_file(opts, function(file)
			if file then
				selected_env_file = file
				opts.preferred_environment = fn.fnamemodify(file, ":t"):gsub("^%.env%.", "")
				M.refresh_env_vars(opts)
				notify("Switched to environment file: " .. fn.fnamemodify(file, ":t"), vim.log.levels.INFO)
			end
		end)
	end, {
		desc = "Select environment file to use",
	})

	api.nvim_create_user_command("EcologGoto", function()
		if selected_env_file then
			vim.cmd("edit " .. fn.fnameescape(selected_env_file))
		else
			notify("No environment file selected", vim.log.levels.WARN)
		end
	end, {
		desc = "Go to selected environment file",
	})
end

return M
