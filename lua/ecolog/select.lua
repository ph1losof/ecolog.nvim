local api = vim.api
local utils = require("ecolog.utils")

local M = {}

---@class SelectOptions
---@field path? string Path to search for env files
---@field active_file? string Currently active env file
---@field env_file_patterns? string[] Custom glob patterns for matching env files
---@field sort_file_fn? function Custom function for sorting env files
---@field sort_fn? function Deprecated: Use sort_file_fn instead
---@field preferred_environment? string Preferred environment name

function M.select_env_file(opts, callback)
  local env_files = utils.find_env_files(opts)

  if not env_files or #env_files == 0 then
    vim.notify("No environment files found", vim.log.levels.WARN)
    return
  end

  local selected_idx = 1

  if opts.active_file then
    for i, file in ipairs(env_files) do
      if file == opts.active_file then
        selected_idx = i
        break
      end
    end
  end

  local function get_content()
    local content = {}
    for i, file in ipairs(env_files) do
      local prefix = i == selected_idx and " → " or "   "
      table.insert(content, string.format("%s%d. %s", prefix, i, vim.fn.fnamemodify(file, ":t")))
    end
    return content
  end

  local function update_buffer(bufnr, winid)
    local content = get_content()
    api.nvim_buf_set_option(bufnr, "modifiable", true)
    api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
    api.nvim_buf_set_option(bufnr, "modifiable", false)

    api.nvim_buf_clear_namespace(bufnr, -1, 0, -1)
    for i = 1, #content do
      local hl_group = i == selected_idx and "EcologVariable" or "EcologSelected"
      api.nvim_buf_add_highlight(bufnr, -1, hl_group, i - 1, 0, -1)
    end

    api.nvim_win_set_cursor(winid, { selected_idx, 4 })
  end

  local float_opts = utils.create_minimal_win_opts(60, #env_files)
  local original_guicursor = vim.opt.guicursor:get()
  local bufnr = api.nvim_create_buf(false, true)

  api.nvim_buf_set_option(bufnr, "buftype", "nofile")
  api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
  api.nvim_buf_set_option(bufnr, "modifiable", true)
  api.nvim_buf_set_option(bufnr, "filetype", "ecolog")

  api.nvim_buf_set_lines(bufnr, 0, -1, false, get_content())
  api.nvim_buf_set_option(bufnr, "modifiable", false)

  local winid = api.nvim_open_win(bufnr, true, float_opts)

  api.nvim_win_set_option(winid, "conceallevel", 2)
  api.nvim_win_set_option(winid, "concealcursor", "niv")
  api.nvim_win_set_option(winid, "cursorline", true)
  api.nvim_win_set_option(winid, "winhl", "Normal:EcologNormal,FloatBorder:EcologBorder")

  update_buffer(bufnr, winid)

  vim.keymap.set("n", "j", function()
    if selected_idx < #env_files then
      selected_idx = selected_idx + 1
      update_buffer(bufnr, winid)
    end
  end, { buffer = bufnr, nowait = true })

  vim.keymap.set("n", "k", function()
    if selected_idx > 1 then
      selected_idx = selected_idx - 1
      update_buffer(bufnr, winid)
    end
  end, { buffer = bufnr, nowait = true })

  local function close_window()
    if api.nvim_win_is_valid(winid) then
      vim.opt.guicursor = original_guicursor
      api.nvim_win_close(winid, true)
    end
  end

  vim.keymap.set("n", "<CR>", function()
    close_window()
    callback(env_files[selected_idx])
  end, { buffer = bufnr, nowait = true })

  vim.keymap.set("n", "q", function()
    close_window()
  end, { buffer = bufnr, nowait = true })

  vim.keymap.set("n", "<ESC>", function()
    close_window()
  end, { buffer = bufnr, nowait = true })

  for i = 1, #env_files do
    vim.keymap.set("n", tostring(i), function()
      close_window()
      callback(env_files[i])
    end, { buffer = bufnr, nowait = true })
  end

  api.nvim_create_autocmd("BufLeave", {
    buffer = bufnr,
    once = true,
    callback = close_window,
  })
end

return M
