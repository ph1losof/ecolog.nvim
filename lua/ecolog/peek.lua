local api = vim.api
local fn = vim.fn
local notify = vim.notify
local win = require("ecolog.win")

local M = {}

-- Peek state
local peek = {
    bufnr = nil,
    winid = nil,
    cancel = nil,
}

function peek:clean()
    if self.cancel then
        self.cancel()
        self.cancel = nil
    end
    self.bufnr = nil
    self.winid = nil
end

function M.peek_env_value(var_name, opts, env_vars, providers, parse_env_file)
    local filetype = vim.bo.filetype
    local available_providers = providers.get_providers(filetype)
    
    if #available_providers == 0 then
        notify("EnvPeek is not available for " .. filetype .. " files", vim.log.levels.WARN)
        return
    end
    
    local line = api.nvim_get_current_line()
    local cursor_pos = api.nvim_win_get_cursor(0)
    local row, col = cursor_pos[1], cursor_pos[2]
    
    -- Find word boundaries around cursor
    local word_start = col
    while word_start > 0 and line:sub(word_start, word_start):match("[%w_]") do
        word_start = word_start - 1
    end
    
    local word_end = col
    while word_end <= #line and line:sub(word_end + 1, word_end + 1):match("[%w_]") do
        word_end = word_end + 1
    end
    
    -- Try each provider with the full word
    local extracted_var
    for _, provider in ipairs(available_providers) do
        extracted_var = provider.extract_var(line, word_end)
        if extracted_var then
            break
        end
    end
    
    -- If no variable found and var_name is provided, use that
    if not extracted_var and var_name and #var_name > 0 then
        extracted_var = var_name
    -- If still no variable, try to get word under cursor
    elseif not extracted_var then
        extracted_var = line:sub(word_start + 1, word_end)
    end
    
    if not extracted_var or #extracted_var == 0 then
        notify("No environment variable pattern matched at cursor", vim.log.levels.WARN)
        return
    end
    
    -- Check if window exists and is valid
    if peek.winid and api.nvim_win_is_valid(peek.winid) then
        api.nvim_set_current_win(peek.winid)
        api.nvim_win_set_cursor(peek.winid, { 1, 0 })
        return
    end
    
    parse_env_file()
    
    local var = env_vars[extracted_var]
    if var then
        local lines = {
            "Name   : " .. extracted_var,
            "Type   : " .. var.type,
            "Source : " .. fn.fnamemodify(var.source, ":t"),
            "Value  : " .. var.value,
        }

        local curbuf = api.nvim_get_current_buf()

        peek.bufnr, peek.winid = win:new_float({
            width = 52,
            height = #lines,
            focusable = true,
            border = "rounded",
            relative = "cursor",
            row = 1,
            col = 0,
            style = "minimal",
            noautocmd = true,
        }, false)
            :setlines(lines)
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
        api.nvim_buf_add_highlight(peek.bufnr, -1, "EcologTitle", 0, 0, -1)
        api.nvim_buf_add_highlight(peek.bufnr, -1, "EcologVariable", 0, 9, 9 + #extracted_var)
        api.nvim_buf_add_highlight(peek.bufnr, -1, "EcologType", 1, 9, 9 + #var.type)
        api.nvim_buf_add_highlight(peek.bufnr, -1, "EcologSource", 2, 9, 9 + #fn.fnamemodify(var.source, ":t"))
        api.nvim_buf_add_highlight(peek.bufnr, -1, "EcologValue", 3, 9, 9 + #var.value)

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
    else
        notify(string.format("Environment variable '%s' not found", extracted_var), vim.log.levels.WARN)
    end
end

return M 