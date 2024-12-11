local M = {}
local api = vim.api
local fn = vim.fn
local notify = vim.notify

-- Cache frequently used functions
local tbl_extend = vim.tbl_deep_extend
local schedule = vim.schedule
local pesc = vim.pesc

-- Lazy load modules with caching
local _cached_modules = {}
local function require_on_demand(name)
	if not _cached_modules[name] then
		_cached_modules[name] = require(name)
	end
	return _cached_modules[name]
end

-- Lazy load modules only when needed
local function get_module(name)
	return setmetatable({}, {
		__index = function(_, key)
			return require_on_demand(name)[key]
		end,
	})
end

local providers = get_module("ecolog.providers")
local select = get_module("ecolog.select")
local peek = get_module("ecolog.peek")
local shelter = get_module("ecolog.shelter")

-- Pre-compile patterns for better performance
local PATTERNS = {
	env_file = "^.+/%.env$",
	env_with_suffix = "^.+/%.env%.[^.]+$",
	env_line = "^[^#](.+)$",
	key_value = "([^=]+)=(.+)",
	quoted = "^['\"](.*)['\"]$",
	trim = "^%s*(.-)%s*$",
}

-- Find word boundaries around cursor position
local function find_word_boundaries(line, col)
	local word_start = col
	while word_start > 0 and line:sub(word_start, word_start):match("[%w_]") do
		word_start = word_start - 1
	end

	local word_end = col
	while word_end <= #line and line:sub(word_end + 1, word_end + 1):match("[%w_]") do
		word_end = word_end + 1
	end

	return word_start + 1, word_end
end

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
	last_opts = tbl_extend("force", {}, opts)

	-- Find all env files
	local raw_files = fn.globpath(opts.path, ".env*", false, true)

	-- Ensure raw_files is a table
	if type(raw_files) == "string" then
		raw_files = vim.split(raw_files, "\n")
	end

	local files = vim.tbl_filter(function(v)
		local is_env = v:match(PATTERNS.env_file) or v:match(PATTERNS.env_with_suffix)
		return is_env ~= nil -- Return true if there's a match
	end, raw_files)

	if #files == 0 then
		return {}
	end

	-- Sort files by priority using string patterns
	table.sort(files, function(a, b)
		-- If preferred environment is specified, prioritize it
		if opts.preferred_environment ~= "" then
			local pref_pattern = "%.env%." .. pesc(opts.preferred_environment) .. "$"
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

	return key,
		{
			value = value,
			type = tonumber(value) and "number" or "string",
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

		complete = function(self, request, callback)
			local filetype = vim.bo.filetype
			local available_providers = providers.get_providers(filetype)

			-- Force parse env files to ensure we have the latest
			parse_env_file(nil, true)

			-- Check completion trigger
			local should_complete = false
			local line = request.context.cursor_before_line

			for _, provider in ipairs(available_providers) do
				if provider.get_completion_trigger then
					local trigger = provider.get_completion_trigger()
					local parts = vim.split(trigger, ".", { plain = true })
					local pattern = table.concat(
						vim.tbl_map(function(part)
							return pesc(part)
						end, parts),
						"%."
					)

					if line:match(pattern .. "$") then
						should_complete = true
						break
					end
				end
			end

			if not should_complete then
				callback({ items = {}, isIncomplete = false })
				return
			end

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
			},
		},
	}, opts or {})

	-- Initialize highlights first
	require("ecolog.highlights").setup()

	-- Initialize shelter mode with the config
	shelter.setup({
		config = opts.shelter.configuration,
		partial = opts.shelter.modules,
	})

	-- Lazy load providers only when needed
	local function load_providers()
		if M._providers_loaded then
			return
		end

		local providers_list = {
			typescript = "ecolog.providers.typescript",
			javascript = "ecolog.providers.javascript",
			python = "ecolog.providers.python",
			php = "ecolog.providers.php",
			lua = "ecolog.providers.lua",
			go = "ecolog.providers.go",
			rust = "ecolog.providers.rust",
		}

		for name, module_path in pairs(providers_list) do
			local ok, provider = pcall(require, module_path)
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

	-- Find and select initial environment file
	local env_files = find_env_files(opts)
	if #env_files > 0 then
		selected_env_file = env_files[1]
		opts.preferred_environment = fn.fnamemodify(selected_env_file, ":t"):gsub("^%.env%.", "")
		notify("Using environment file: " .. fn.fnamemodify(selected_env_file, ":t"), vim.log.levels.INFO)
	end

	-- Defer initial parsing
	schedule(function()
		parse_env_file(opts)
	end)

	-- Set up file watchers
	setup_file_watcher(opts)

	-- Set up lazy loading for cmp
	vim.api.nvim_create_autocmd("InsertEnter", {
		callback = function()
			local has_cmp, cmp = pcall(require, "cmp")
			if has_cmp and not M._cmp_loaded then
				-- Load providers first
				load_providers()
				-- Then set up completion
				setup_completion(cmp)
				M._cmp_loaded = true
			end
		end,
		once = true,
	})

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
				select.select_env_file(opts, function(file)
					if file then
						selected_env_file = file
						opts.preferred_environment = fn.fnamemodify(file, ":t"):gsub("^%.env%.", "")
						M.refresh_env_vars(opts)
						notify("Switched to environment file: " .. fn.fnamemodify(file, ":t"), vim.log.levels.INFO)
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
					local word_start, word_end = find_word_boundaries(line, col)

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
	}

	for name, cmd in pairs(commands) do
		api.nvim_create_user_command(name, cmd.callback, {
			nargs = cmd.nargs,
			desc = cmd.desc,
			complete = cmd.complete,
		})
	end
end

return M
