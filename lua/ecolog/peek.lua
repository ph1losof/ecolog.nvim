local api = vim.api
local fn = vim.fn
local notify = vim.notify
local win = require("ecolog.win")
local shelter = require("ecolog.shelter")

local M = {}

-- Cached patterns
local PATTERNS = {
	word = "[%w_]",
	label_width = 10, -- 8 chars for label + 2 chars for ":"
}

-- Peek state
local peek = {
	bufnr = nil,
	winid = nil,
	cancel = nil,
}

-- Clean up peek window resources
function peek:clean()
	if self.cancel then
		self.cancel()
		self.cancel = nil
	end
	self.bufnr = nil
	self.winid = nil
end

-- Find word boundaries around cursor
local function find_word_boundaries(line, col)
	local word_start = col
	while word_start > 0 and line:sub(word_start, word_start):match(PATTERNS.word) do
		word_start = word_start - 1
	end

	local word_end = col
	while word_end <= #line and line:sub(word_end + 1, word_end + 1):match(PATTERNS.word) do
		word_end = word_end + 1
	end

	return word_start + 1, word_end
end

-- Extract variable using providers
local function extract_variable(line, word_end, available_providers, var_name)
	-- Try each provider with the full word
	for _, provider in ipairs(available_providers) do
		local extracted = provider.extract_var(line, word_end)
		if extracted then
			return extracted
		end
	end

	-- If var_name provided, use that
	if var_name and #var_name > 0 then
		return var_name
	end

	return nil
end

-- Create peek window content
local function create_peek_content(var_name, var_info, types)
	-- Re-detect type to ensure accuracy
	local type_name, value = types.detect_type(var_info.value)
	
	-- Use the re-detected type and value, or fall back to stored ones
	local display_type = type_name or var_info.type
	local display_value = shelter.mask_value(value or var_info.value, "peek")
	local source = fn.fnamemodify(var_info.source, ":t")

	local lines = {
		"Name    : " .. var_name,
		"Type    : " .. display_type,
		"Source  : " .. source,
		"Value   : " .. display_value,
	}

	local label_width = 10 -- 8 chars for label + 2 chars for ":"

	local highlights = {
		{ "EcologTitle", 0, 0, -1 },
		{ "EcologVariable", 0, label_width, label_width + #var_name },
		{ "EcologType", 1, label_width, label_width + #display_type },
		{ "EcologSource", 2, label_width, label_width + #source },
		{ "EcologValue", 3, label_width, label_width + #display_value },
	}

	-- Add comment line if comment exists
	if var_info.comment then
		table.insert(lines, "Comment : " .. var_info.comment)
			table.insert(highlights, { "Comment", #lines - 1, label_width, -1 })
	end

	return {
		lines = lines,
		highlights = highlights,
	}
end

-- Set up peek window autocommands
local function setup_peek_autocommands(curbuf)
	-- Auto-close window on cursor move in main buffer
	api.nvim_create_autocmd({ "CursorMoved", "InsertEnter", "BufDelete" }, {
		buffer = curbuf,
		callback = function(opt)
			if peek.winid and api.nvim_win_is_valid(peek.winid) and api.nvim_get_current_win() ~= peek.winid then
				api.nvim_win_close(peek.winid, true)
				peek:clean()
			end
			api.nvim_del_autocmd(opt.id)
		end,
		once = true,
	})

	-- Clean up on buffer wipeout
	api.nvim_create_autocmd("BufWipeout", {
		buffer = peek.bufnr,
		callback = function()
			peek:clean()
		end,
	})
end

function M.peek_env_value(var_name, opts, env_vars, providers, parse_env_file)
	local filetype = vim.bo.filetype
	local available_providers = providers.get_providers(filetype)
	local types = require("ecolog.types")

	if #available_providers == 0 then
		notify("EcologPeek is not available for " .. filetype .. " files", vim.log.levels.WARN)
		return
	end

	-- Check if window exists and is valid
	if peek.winid and api.nvim_win_is_valid(peek.winid) then
		api.nvim_set_current_win(peek.winid)
		api.nvim_win_set_cursor(peek.winid, { 1, 0 })
		return
	end

	local line = api.nvim_get_current_line()
	local cursor_pos = api.nvim_win_get_cursor(0)
	local word_start, word_end = find_word_boundaries(line, cursor_pos[2])

	-- Try to extract variable
	local extracted_var = extract_variable(line, word_end, available_providers, var_name)
	if not extracted_var then
		extracted_var = line:sub(word_start, word_end)
	end

	if not extracted_var or #extracted_var == 0 then
		notify("No environment variable pattern matched at cursor", vim.log.levels.WARN)
		return
	end

	parse_env_file()

	local var = env_vars[extracted_var]
	if not var then
		notify(string.format("Environment variable '%s' not found", extracted_var), vim.log.levels.WARN)
		return
	end

	-- Create peek window content with types module
	local content = create_peek_content(extracted_var, var, types)
	local curbuf = api.nvim_get_current_buf()

	-- Create peek window
	peek.bufnr, peek.winid = win:new_float({
		width = 52,
		height = #content.lines,
		focusable = true,
		border = "rounded",
		relative = "cursor",
		row = 1,
		col = 0,
		style = "minimal",
		noautocmd = true,
	}, false)
		:setlines(content.lines)
		:bufopt({
			modifiable = false,
			bufhidden = "wipe",
			buftype = "nofile",
			filetype = "ecolog",
		})
		:winopt({
			conceallevel = 2,
			concealcursor = "niv",
			cursorline = true,
		})
		:winhl("EcologNormal", "EcologBorder")
		:wininfo()

	-- Apply syntax highlighting
	for _, hl in ipairs(content.highlights) do
		api.nvim_buf_add_highlight(peek.bufnr, -1, hl[1], hl[2], hl[3], hl[4])
	end

	-- Set buffer mappings
	api.nvim_buf_set_keymap(peek.bufnr, "n", "q", "", {
		callback = function()
			if peek.winid and api.nvim_win_is_valid(peek.winid) then
				api.nvim_win_close(peek.winid, true)
				peek:clean()
			end
		end,
		noremap = true,
		silent = true,
	})

	-- Set up autocommands
	setup_peek_autocommands(curbuf)
end

return M

