local api = vim.api
local win = require("ecolog.win")

local M = {}

---@class SelectOptions
---@field path? string Path to search for env files
---@field active_file? string Currently active env file

function M.select_env_file(opts, callback)
  local env_files = vim.fn.globpath(opts.path or vim.fn.getcwd(), ".env*", false, true)

  -- Filter and sort env files
  env_files = vim.tbl_filter(function(v)
    return v:match("%.env$") or v:match("%.env%.[^.]+$")
  end, env_files)

  if #env_files == 0 then
    vim.notify("No environment files found", vim.log.levels.WARN)
    return
  end

  -- State for selection
  local selected_idx = 1

  -- Set initial selection to active file if it exists
  if opts.active_file then
    for i, file in ipairs(env_files) do
      if file == opts.active_file then
        selected_idx = i
        break
      end
    end
  end

  -- Function to update content
  local function get_content()
    local content = {}

    -- Add file list
    for i, file in ipairs(env_files) do
      local prefix = i == selected_idx and " → " or "   "
      table.insert(content, string.format("%s%d. %s", prefix, i, vim.fn.fnamemodify(file, ":t")))
    end

    return content
  end

  -- Function to update buffer content and cursor
  local function update_buffer(bufnr, winid)
    local content = get_content()
    api.nvim_buf_set_option(bufnr, "modifiable", true)
    api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
    api.nvim_buf_set_option(bufnr, "modifiable", false)

    -- Update highlights
    api.nvim_buf_clear_namespace(bufnr, -1, 0, -1)
    for i = 1, #content do
      local hl_group = i == selected_idx and "EcologVariable" or "EcologSelected"
      api.nvim_buf_add_highlight(bufnr, -1, hl_group, i - 1, 0, -1)
    end

    -- Update cursor position (hidden but needed for navigation)
    api.nvim_win_set_cursor(winid, { selected_idx, 4 })
  end

  -- Calculate window dimensions
  local width = 60
  local height = #env_files

  -- Get screen dimensions
  local screen_width = vim.o.columns
  local screen_height = vim.o.lines

  local float_opts = {
    height = height,
    width = width,
    relative = "editor",
    row = math.floor((screen_height - height) / 2),
    col = math.floor((screen_width - width) / 2),
    border = "rounded",
    style = "minimal",
    focusable = true,
  }

  -- Store original guicursor value
  local original_guicursor = vim.opt.guicursor:get()

  -- Create floating window
  local bufnr, winid = win
    :new_float(float_opts, true)
    :setlines(get_content())
    :bufopt({
      ["buftype"] = "nofile",
      ["bufhidden"] = "wipe",
      ["modifiable"] = false,
      ["filetype"] = "ecolog",
    })
    :winopt({
      ["conceallevel"] = 2,
      ["concealcursor"] = "niv",
      ["cursorline"] = true,
    })
    :winhl("EcologNormal", "EcologBorder")
    :wininfo()

  -- Set initial cursor position and highlight
  update_buffer(bufnr, winid)

  -- Movement keymaps
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

  -- Selection and exit keymaps
  local function close_window()
    if api.nvim_win_is_valid(winid) then
      -- Restore original cursor
      vim.opt.guicursor = original_guicursor
      api.nvim_win_close(winid, true)
    end
  end

  vim.keymap.set("n", "<CR>", function()
    close_window()
    callback(env_files[selected_idx])
  end, { buffer = bufnr, nowait = true })

  vim.keymap.set("n", "q", close_window, { buffer = bufnr, nowait = true })
  vim.keymap.set("n", "<ESC>", close_window, { buffer = bufnr, nowait = true })

  -- Number shortcuts
  for i = 1, #env_files do
    vim.keymap.set("n", tostring(i), function()
      close_window()
      callback(env_files[i])
    end, { buffer = bufnr, nowait = true })
  end

  -- Autoclose on buffer leave
  api.nvim_create_autocmd("BufLeave", {
    buffer = bufnr,
    once = true,
    callback = close_window,
  })
end

return M

