local M = {}
local api = vim.api
local notify = vim.notify

-- Create namespace for virtual text
local namespace = api.nvim_create_namespace("ecolog_shelter")

-- Cached patterns
local PATTERNS = {
  env_line = "^([^#%s][^=]+)=(.+)$",
  quoted = "^(['\"])(.*[^%s])['\"]%s*", -- Updated to match quotes with optional trailing spaces
  quoted_with_comment = "^(['\"])(.*[^%s])['\"]%s+(.+)$", -- New pattern for quoted values with comments
  unquoted_with_spaces = "^(%S+)%s+(%S.*)$", -- New pattern to match unquoted values with spaces
}

-- Features list for iteration
local FEATURES = { "cmp", "peek", "files", "telescope" }

-- State management
local state = {
  initial_settings = {},
  current = {
    cmp = false,
    peek = false,
    files = false,
  },
  char = "*",
  revealed_lines = {}, -- Track lines that should show actual values
}

-- Default partial mode settings
local DEFAULT_PARTIAL_MODE = {
  show_start = 3,
  show_end = 3,
  min_mask = 3,
}

local config = {
  partial_mode = false, -- Disabled by default
  mask_char = "*",
}

-- Clear shelter from buffer
local function unshelter_buffer()
  api.nvim_buf_clear_namespace(0, namespace, 0, -1)
  state.revealed_lines = {} -- Clear revealed lines state
end

-- Apply shelter to buffer
local function shelter_buffer()
  -- Clear existing shelter
  api.nvim_buf_clear_namespace(0, namespace, 0, -1)

  -- Get all lines at once
  local lines = api.nvim_buf_get_lines(0, 0, -1, false)

  for i, line in ipairs(lines) do
    -- Match key=value pattern, excluding comments and empty lines
    local key, value = line:match(PATTERNS.env_line)
    if key and value then
      -- Find the start position of the value (after =)
      local value_start = line:find("=") + 1

      -- Use M.mask_value instead of create_masked_value
      local masked_value = state.revealed_lines[i] and value or M.mask_value(value, "files")

      -- Set virtual text overlay
      api.nvim_buf_set_extmark(0, namespace, i - 1, value_start - 1, {
        virt_text = { { masked_value, state.revealed_lines[i] and "String" or "Comment" } },
        virt_text_pos = "overlay",
        hl_mode = "combine",
      })
    end
  end
end

-- Set up file shelter autocommands
local function setup_file_shelter()
  local group = api.nvim_create_augroup("ecolog_shelter", { clear = true })

  -- Watch for env file events
  api.nvim_create_autocmd({ "BufEnter", "TextChanged", "TextChangedI", "TextChangedP" }, {
    pattern = ".env*",
    callback = function()
      if state.current.files then
        shelter_buffer()
      else
        unshelter_buffer()
      end
    end,
    group = group,
  })

  -- Add command for revealing lines
  api.nvim_create_user_command("EcologShelterLinePeek", function()
    if not state.current.files then
      notify("Shelter mode for files is not enabled", vim.log.levels.WARN)
      return
    end

    -- Get current line number
    local current_line = api.nvim_win_get_cursor(0)[1]

    -- Clear previous revealed lines
    state.revealed_lines = {}

    -- Mark current line as revealed
    state.revealed_lines[current_line] = true

    -- Update display
    shelter_buffer()

    -- Set up autocommand to hide values when cursor moves
    local bufnr = api.nvim_get_current_buf()
    api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "InsertEnter", "BufLeave" }, {
      buffer = bufnr,
      callback = function(ev)
        if
          ev.event == "BufLeave"
          or (ev.event:match("Cursor") and not state.revealed_lines[api.nvim_win_get_cursor(0)[1]])
        then
          state.revealed_lines = {}
          shelter_buffer()
          return true -- Delete the autocmd
        end
      end,
      desc = "Hide revealed env values on cursor move",
    })
  end, {
    desc = "Temporarily reveal env value for current line",
  })
end

-- Initialize shelter mode settings
function M.setup(opts)
  opts = opts or {}

  -- Update configuration
  if opts.config then
    -- Handle partial_mode configuration
    if type(opts.config.partial_mode) == "boolean" then
      config.partial_mode = opts.config.partial_mode and DEFAULT_PARTIAL_MODE or false
    elseif type(opts.config.partial_mode) == "table" then
      config.partial_mode = vim.tbl_deep_extend("force", DEFAULT_PARTIAL_MODE, opts.config.partial_mode)
    else
      config.partial_mode = false
    end

    -- Get mask_char from configuration
    config.mask_char = opts.config.mask_char or "*"
  end

  -- Set initial and current settings from partial config
  local partial = opts.partial or {}
  for _, feature in ipairs(FEATURES) do
    local value = type(partial[feature]) == "boolean" and partial[feature] or false
    state.initial_settings[feature] = value
    state.current[feature] = value
  end

  state.char = config.mask_char

  -- Set up autocommands for file sheltering if needed
  if state.current.files then
    setup_file_shelter()
  end
end

-- Mask a value based on shelter settings
function M.mask_value(value, context)
  if not M.is_enabled(context) then
    return value
  end

  -- Check if value has an inline comment
  local quote, content = value:match(PATTERNS.quoted_with_comment)
  if quote and content then
    -- If there's an inline comment, only mask the content and preserve the comment
    local masked = M.mask_value(quote .. content .. quote, context)
    return masked .. " " .. value:match(PATTERNS.quoted_with_comment):sub(3)
  end

  -- Check if value is quoted (without comment) and extract content if it is
  quote, content = value:match(PATTERNS.quoted)
  if quote and content then
    -- For quoted values, mask everything inside quotes but preserve trailing spaces
    local trailing_spaces = value:match(quote .. content .. quote .. "(%s*)$") or ""
    local masked = string.rep(config.mask_char, #content)
    return quote .. masked .. quote .. trailing_spaces
  end

  -- Handle unquoted values with spaces
  local first_word, rest = value:match(PATTERNS.unquoted_with_spaces)
  if first_word and rest then
    -- Mask only the first word, preserve the rest
    return string.rep(config.mask_char, #first_word) .. " " .. rest
  end

  -- For single words or other cases, preserve trailing spaces
  local word, spaces = value:match("^(%S+)(%s*)$")
  if word then
    return string.rep(config.mask_char, #word) .. spaces
  end

  -- Default case: mask everything
  return string.rep(config.mask_char, #value)
end

-- Get current state for a feature
function M.is_enabled(feature)
  return state.current[feature] or false
end

-- Toggle all shelter modes
function M.toggle_all()
  local any_enabled = false
  for _, feature in ipairs(FEATURES) do
    if state.current[feature] then
      any_enabled = true
      break
    end
  end

  if any_enabled then
    -- Disable all
    for _, feature in ipairs(FEATURES) do
      state.current[feature] = false
    end
    unshelter_buffer()
    notify("All shelter modes disabled", vim.log.levels.INFO)
  else
    -- Restore initial settings
    local files_enabled = false
    for feature, value in pairs(state.initial_settings) do
      state.current[feature] = value
      if feature == "files" and value then
        files_enabled = true
      end
    end
    if files_enabled then
      setup_file_shelter()
      shelter_buffer()
    end
    notify("Shelter modes restored to initial settings", vim.log.levels.INFO)
  end
end

-- Enable or disable specific or all features
function M.set_state(command, feature)
  local should_enable = command == "enable"

  if feature then
    if not vim.tbl_contains(FEATURES, feature) then
      notify("Invalid feature. Use 'cmp', 'peek', 'files', or 'telescope'", vim.log.levels.ERROR)
      return
    end

    state.current[feature] = should_enable
    if feature == "files" then
      if should_enable then
        setup_file_shelter()
        shelter_buffer()
      else
        unshelter_buffer()
      end
    end
    notify(
      string.format("Shelter mode for %s is now %s", feature:upper(), should_enable and "enabled" or "disabled"),
      vim.log.levels.INFO
    )
  else
    -- Apply to all features
    for _, f in ipairs(FEATURES) do
      state.current[f] = should_enable
    end
    if should_enable then
      setup_file_shelter()
      shelter_buffer()
    else
      unshelter_buffer()
    end
    notify(
      string.format("All shelter modes are now %s", should_enable and "enabled" or "disabled"),
      vim.log.levels.INFO
    )
  end
end

return M
