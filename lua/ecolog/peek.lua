local api = vim.api
local notify = vim.notify
local shelter = require("ecolog.shelter")
local utils = require("ecolog.utils")

local M = {}

local PATTERNS = {
  label_width = 10,
}

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

local function create_peek_content(var_name, var_info, types, config)
  -- Input validation with nil checks
  if not var_name or type(var_name) ~= "string" then
    var_name = "unknown"
  end
  
  if not var_info or type(var_info) ~= "table" then
    return {
      lines = { "Error: Invalid variable information" },
      highlights = { { "ErrorMsg", 0, 0, -1 } },
    }
  end
  
  if not types or type(types) ~= "table" or type(types.detect_type) ~= "function" then
    return {
      lines = { "Error: Types module not available" },
      highlights = { { "ErrorMsg", 0, 0, -1 } },
    }
  end

  local type_name, value = types.detect_type(var_info.value)

  local display_type = type_name or var_info.type or "unknown"
  local var_value = value or var_info.value or ""
  local source = var_info.source or "unknown"
  
  -- Get workspace context for the source display
  local source_display = source
  if utils and utils.get_env_file_display_name and config then
    local success, display_name = pcall(utils.get_env_file_display_name, source, config)
    if success and display_name then
      source_display = display_name
    end
  end
  
  -- Safe call to shelter.mask_value with nil checks
  local display_value = var_value
  if shelter and shelter.mask_value then
    local success, masked = pcall(shelter.mask_value, var_value, "peek", var_name, source)
    if success and masked then
      display_value = masked
    end
  end
  
  -- Convert to string to prevent errors in string concatenation
  display_type = tostring(display_type)
  display_value = tostring(display_value)
  source = tostring(source)

  local lines = {}
  local highlights = {}

  lines[1] = "Name    : " .. var_name
  lines[2] = "Type    : " .. display_type
  lines[3] = "Source  : " .. source_display
  lines[4] = "Value   : " .. display_value

  highlights[1] = { "EcologVariable", 0, PATTERNS.label_width, PATTERNS.label_width + #var_name }
  highlights[2] = { "EcologType", 1, PATTERNS.label_width, PATTERNS.label_width + #display_type }
  highlights[3] = { "EcologSource", 2, PATTERNS.label_width, PATTERNS.label_width + #source_display }
  
  -- Safe highlight group selection with nil checks
  local highlight_group = "EcologValue"
  if shelter and shelter.is_enabled and shelter.get_config then
    local success_enabled, is_enabled = pcall(shelter.is_enabled, "peek")
    if success_enabled and is_enabled then
      local success_config, config = pcall(shelter.get_config)
      if success_config and config and config.highlight_group then
        highlight_group = config.highlight_group
      end
    end
  end
  
  highlights[4] = {
    highlight_group,
    3,
    PATTERNS.label_width,
    PATTERNS.label_width + #display_value,
  }

  if var_info.comment and type(var_info.comment) == "string" then
    local comment_value = var_info.comment
    
    -- Safe comment masking with nil checks
    if shelter and shelter.is_enabled and shelter.get_config then
      local success_enabled, is_enabled = pcall(shelter.is_enabled, "peek")
      if success_enabled and is_enabled then
        local success_config, config = pcall(shelter.get_config)
        if success_config and config and not config.skip_comments then
          local success_utils, utils = pcall(require, "ecolog.shelter.utils")
          if success_utils and utils and utils.mask_comment then
            local success_mask, masked = pcall(utils.mask_comment, comment_value, source, shelter, "peek")
            if success_mask and masked then
              comment_value = masked
            end
          end
        end
      end
    end
    
    lines[5] = "Comment : " .. tostring(comment_value)
    highlights[5] = { "Comment", 4, PATTERNS.label_width, -1 }
  end

  return {
    lines = lines,
    highlights = highlights,
  }
end

local function setup_peek_autocommands(curbuf)
  api.nvim_create_autocmd({ "CursorMoved", "InsertEnter", "BufDelete", "BufWinLeave" }, {
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

  api.nvim_create_autocmd("BufWipeout", {
    buffer = peek.bufnr,
    callback = function()
      peek:clean()
    end,
  })
end

---@class PeekContent
---@field lines string[] Lines of content to display
---@field highlights table[] Highlight definitions

function M.peek_env_var(available_providers, var_name)
  -- Input validation with nil checks
  if not available_providers or type(available_providers) ~= "table" then
    notify("Invalid providers table", vim.log.levels.ERROR)
    return
  end

  local filetype = vim.bo.filetype
  if not filetype or type(filetype) ~= "string" then
    filetype = "unknown"
  end

  if #available_providers == 0 then
    notify("EcologPeek is not available for " .. filetype .. " files", vim.log.levels.WARN)
    return
  end

  -- Check if window is already open
  if peek.winid and api.nvim_win_is_valid(peek.winid) then
    local success, err = pcall(api.nvim_set_current_win, peek.winid)
    if success then
      pcall(api.nvim_win_set_cursor, peek.winid, { 1, 0 })
    else
      vim.notify("Failed to focus peek window: " .. tostring(err), vim.log.levels.WARN)
    end
    return
  end

  -- Load required modules with error handling
  local has_ecolog, ecolog = pcall(require, "ecolog")
  if not has_ecolog or not ecolog then
    notify("Ecolog not found", vim.log.levels.ERROR)
    return
  end

  local has_types, types = pcall(require, "ecolog.types")
  if not has_types or not types then
    notify("Types module not found", vim.log.levels.ERROR)
    return
  end

  -- Get variable name with nil checks
  if not var_name or var_name == "" then
    if utils and utils.get_var_word_under_cursor then
      var_name = utils.get_var_word_under_cursor(available_providers)
    end
    if not var_name or var_name == "" then
      notify("No environment variable found under cursor", vim.log.levels.WARN)
      return
    end
  end

  -- Get environment variables with error handling
  local env_vars
  if ecolog.get_env_vars and type(ecolog.get_env_vars) == "function" then
    local success, result = pcall(ecolog.get_env_vars)
    if success and result then
      env_vars = result
    else
      notify("Failed to get environment variables: " .. tostring(result), vim.log.levels.ERROR)
      return
    end
  else
    notify("get_env_vars function not available", vim.log.levels.ERROR)
    return
  end

  local var_info = env_vars[var_name]
  if not var_info then
    notify(string.format("Environment variable '%s' not found", var_name), vim.log.levels.WARN)
    return
  end

  -- Get configuration for workspace context
  local config = nil
  if ecolog.get_config and type(ecolog.get_config) == "function" then
    local success, result = pcall(ecolog.get_config)
    if success and result then
      config = result
    end
  end

  -- Create content with error handling
  local content = create_peek_content(var_name, var_info, types, config)
  if not content or not content.lines or not content.highlights then
    notify("Failed to create peek content", vim.log.levels.ERROR)
    return
  end

  local curbuf = api.nvim_get_current_buf()

  -- Create buffer with error handling
  local success, bufnr = pcall(api.nvim_create_buf, false, true)
  if not success or not bufnr then
    notify("Failed to create peek buffer: " .. tostring(bufnr), vim.log.levels.ERROR)
    return
  end
  peek.bufnr = bufnr

  -- Set buffer options with error handling (using modern API)
  local function safe_buf_set_option(option, value)
    local success, err = pcall(vim.api.nvim_set_option_value, option, value, { buf = peek.bufnr })
    if not success then
      vim.notify("Failed to set buffer option " .. option .. ": " .. tostring(err), vim.log.levels.WARN)
    end
  end

  safe_buf_set_option("modifiable", true)
  local lines_success, lines_err = pcall(api.nvim_buf_set_lines, peek.bufnr, 0, -1, false, content.lines)
  if not lines_success then
    vim.notify("Failed to set buffer lines: " .. tostring(lines_err), vim.log.levels.ERROR)
    return
  end
  safe_buf_set_option("modifiable", false)
  safe_buf_set_option("bufhidden", "wipe")
  safe_buf_set_option("buftype", "nofile")
  safe_buf_set_option("filetype", "ecolog")

  -- Create window with error handling
  local win_success, winid = pcall(api.nvim_open_win, peek.bufnr, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = 52,
    height = #content.lines,
    style = "minimal",
    border = "rounded",
    focusable = true,
  })
  
  if not win_success or not winid then
    notify("Failed to create peek window: " .. tostring(winid), vim.log.levels.ERROR)
    return
  end
  peek.winid = winid

  -- Set window options with error handling (using modern API)
  local function safe_win_set_option(option, value)
    local success, err = pcall(vim.api.nvim_set_option_value, option, value, { win = peek.winid })
    if not success then
      vim.notify("Failed to set window option " .. option .. ": " .. tostring(err), vim.log.levels.WARN)
    end
  end

  safe_win_set_option("conceallevel", 2)
  safe_win_set_option("concealcursor", "niv")
  safe_win_set_option("cursorline", true)
  safe_win_set_option("winhl", "Normal:EcologNormal,FloatBorder:EcologBorder")

  -- Add highlights with error handling
  for _, hl in ipairs(content.highlights) do
    if hl and type(hl) == "table" and #hl >= 4 then
      local success, err = pcall(api.nvim_buf_add_highlight, peek.bufnr, -1, hl[1], hl[2], hl[3], hl[4])
      if not success then
        vim.notify("Failed to add highlight: " .. tostring(err), vim.log.levels.WARN)
      end
    end
  end

  -- Set up autocommands with error handling
  local success, err = pcall(setup_peek_autocommands, curbuf)
  if not success then
    vim.notify("Failed to setup peek autocommands: " .. tostring(err), vim.log.levels.WARN)
  end

  -- Set up keymap with error handling
  local close_fn = function()
    if peek.winid and api.nvim_win_is_valid(peek.winid) then
      local success, err = pcall(api.nvim_win_close, peek.winid, true)
      if not success then
        vim.notify("Failed to close peek window: " .. tostring(err), vim.log.levels.WARN)
      end
      peek:clean()
    end
  end

  local keymap_success, keymap_err = pcall(api.nvim_buf_set_keymap, peek.bufnr, "n", "q", "", {
    callback = close_fn,
    noremap = true,
    silent = true,
  })
  if not keymap_success then
    vim.notify("Failed to set peek keymap: " .. tostring(keymap_err), vim.log.levels.WARN)
  end
end

return M
