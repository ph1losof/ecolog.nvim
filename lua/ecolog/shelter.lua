local M = {}

-- Cache frequently used functions and APIs
local api = vim.api
local notify = vim.notify
local string_rep = string.rep
local string_sub = string.sub
local string_match = string.match
local string_find = string.find
local tbl_contains = vim.tbl_contains
local tbl_deep_extend = vim.tbl_deep_extend

-- Constants
local FEATURES = { "cmp", "peek", "files", "telescope", "fzf" }
local DEFAULT_PARTIAL_MODE = {
  show_start = 3,
  show_end = 3,
  min_mask = 3,
}

-- Create namespace once
local namespace = api.nvim_create_namespace("ecolog_shelter")

-- Internal state with clear structure
local state = {
  config = {
    partial_mode = false,
    mask_char = "*",
  },
  features = {
    enabled = {},
    initial = {},
  },
  buffer = {
    revealed_lines = {},
  },
}

---@class ShelterSetupOptions
---@field config? ShelterConfiguration
---@field partial? table<string, boolean>

-- Optimized masking function
local function determine_masked_value(value, opts)
  if not value or value == "" then
    return ""
  end

  opts = opts or {}
  local partial_mode = opts.partial_mode or state.config.partial_mode

  if not partial_mode then
    return string_rep(state.config.mask_char, #value)
  end

  -- Get settings from partial mode config
  local settings = type(partial_mode) == "table" and partial_mode or DEFAULT_PARTIAL_MODE
  local show_start = math.max(0, settings.show_start or 0)
  local show_end = math.max(0, settings.show_end or 0)
  local min_mask = math.max(1, settings.min_mask or 1)

  -- If value is too short for partial masking, mask everything
  if #value <= (show_start + show_end) or #value < (show_start + show_end + min_mask) then
    return string_rep(state.config.mask_char, #value)
  end

  -- Calculate mask length ensuring min_mask requirement
  local mask_length = math.max(min_mask, #value - show_start - show_end)

  return string_sub(value, 1, show_start) .. string_rep(state.config.mask_char, mask_length) .. string_sub(value, -show_end)
end

M.determine_masked_value = determine_masked_value

-- Buffer management functions
local function unshelter_buffer()
  api.nvim_buf_clear_namespace(0, namespace, 0, -1)
  state.buffer.revealed_lines = {}
end

local function shelter_buffer()
  api.nvim_buf_clear_namespace(0, namespace, 0, -1)

  local lines = api.nvim_buf_get_lines(0, 0, -1, false)
  local extmarks = {}

  for i, line in ipairs(lines) do
    -- Fast path: skip comments and empty lines using string.find
    if string_find(line, "^%s*#") or string_find(line, "^%s*$") then
      goto continue
    end

    -- Fast path: find key-value separator
    local eq_pos = string_find(line, "=")
    if not eq_pos then
      goto continue
    end

    local key = string_sub(line, 1, eq_pos - 1)
    local value = string_sub(line, eq_pos + 1)

    -- Clean up key and value
    key = string_match(key, "^%s*(.-)%s*$")
    value = string_match(value, "^%s*(.-)%s*$")

    if not (key and value) then
      goto continue
    end

    local actual_value
    local quote_char = string_match(value, "^([\"'])")

    if quote_char then
      actual_value = string_match(value, "^" .. quote_char .. "(.-)" .. quote_char)
    else
      actual_value = string_match(value, "^([^%s#]+)")
    end

    if actual_value then
      local masked_value = state.buffer.revealed_lines[i] and actual_value
        or determine_masked_value(actual_value, {
          partial_mode = state.config.partial_mode,
        })

      if masked_value and #masked_value > 0 then
        if quote_char then
          masked_value = quote_char .. masked_value .. quote_char
        end

        -- Collect extmarks for batch update
        table.insert(extmarks, {
          i - 1,
          eq_pos,
          {
            virt_text = { { masked_value, state.buffer.revealed_lines[i] and "String" or "Comment" } },
            virt_text_pos = "overlay",
            hl_mode = "combine",
          }
        })
      end
    end
    ::continue::
  end

  -- Batch set all extmarks at once
  for _, mark in ipairs(extmarks) do
    api.nvim_buf_set_extmark(0, namespace, mark[1], mark[2], mark[3])
  end
end

-- Set up file shelter autocommands
local function setup_file_shelter()
  local group = api.nvim_create_augroup("ecolog_shelter", { clear = true })

  -- Watch for env file events
  api.nvim_create_autocmd({ "BufEnter", "TextChanged", "TextChangedI", "TextChangedP" }, {
    pattern = ".env*",
    callback = function()
      if state.features.enabled.files then
        shelter_buffer()
      else
        unshelter_buffer()
      end
    end,
    group = group,
  })

  -- Add command for revealing lines
  api.nvim_create_user_command("EcologShelterLinePeek", function()
    if not state.features.enabled.files then
      notify("Shelter mode for files is not enabled", vim.log.levels.WARN)
      return
    end

    -- Get current line number
    local current_line = api.nvim_win_get_cursor(0)[1]

    -- Clear previous revealed lines
    state.buffer.revealed_lines = {}

    -- Mark current line as revealed
    state.buffer.revealed_lines[current_line] = true

    -- Update display
    shelter_buffer()

    -- Set up autocommand to hide values when cursor moves
    local bufnr = api.nvim_get_current_buf()
    api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "InsertEnter", "BufLeave" }, {
      buffer = bufnr,
      callback = function(ev)
        if
          ev.event == "BufLeave"
          or (ev.event:match("Cursor") and not state.buffer.revealed_lines[api.nvim_win_get_cursor(0)[1]])
        then
          state.buffer.revealed_lines = {}
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
      state.config.partial_mode = opts.config.partial_mode and DEFAULT_PARTIAL_MODE or false
    elseif type(opts.config.partial_mode) == "table" then
      state.config.partial_mode = tbl_deep_extend("force", DEFAULT_PARTIAL_MODE, opts.config.partial_mode)
    else
      state.config.partial_mode = false
    end

    -- Get mask_char from configuration
    state.config.mask_char = opts.config.mask_char or "*"
  end

  -- Set initial and current settings from partial config
  local partial = opts.partial or {}
  for _, feature in ipairs(FEATURES) do
    local value = type(partial[feature]) == "boolean" and partial[feature] or false
    state.features.initial[feature] = value
    state.features.enabled[feature] = value
  end

  -- Set up autocommands for file sheltering if needed
  if state.features.enabled.files then
    setup_file_shelter()
  end
end

-- Mask value with proper checks
function M.mask_value(value, feature)
  if not value then
    return ""
  end
  if not state.features.enabled[feature] then
    return value
  end

  return determine_masked_value(value, {
    partial_mode = state.config.partial_mode,
  })
end

-- Get current state for a feature
function M.is_enabled(feature)
  return state.features.enabled[feature] or false
end

-- Toggle all shelter modes
function M.toggle_all()
  local any_enabled = false
  for _, feature in ipairs(FEATURES) do
    if state.features.enabled[feature] then
      any_enabled = true
      break
    end
  end

  if any_enabled then
    -- Disable all
    for _, feature in ipairs(FEATURES) do
      state.features.enabled[feature] = false
    end
    unshelter_buffer()
    notify("All shelter modes disabled", vim.log.levels.INFO)
  else
    -- Restore initial settings
    local files_enabled = false
    for feature, value in pairs(state.features.initial) do
      state.features.enabled[feature] = value
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
    if not tbl_contains(FEATURES, feature) then
      notify("Invalid feature. Use 'cmp', 'peek', 'files', 'telescope', or 'fzf'", vim.log.levels.ERROR)
      return
    end

    state.features.enabled[feature] = should_enable
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
      state.features.enabled[f] = should_enable
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
