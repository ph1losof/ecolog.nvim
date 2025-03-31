local M = {}

local api = vim.api
local notify = vim.notify
local tbl_contains = vim.tbl_contains
local tbl_deep_extend = vim.tbl_deep_extend

local state = require("ecolog.shelter.state")
local buffer = require("ecolog.shelter.buffer")
local utils = require("ecolog.shelter.utils")

function M.setup(opts)
  opts = opts or {}

  if opts.config then
    if type(opts.config.partial_mode) == "boolean" then
      state.get_config().partial_mode = opts.config.partial_mode and state.get_default_partial_mode() or false
      if opts.config.default_mode == nil then
        state.get_config().default_mode = opts.config.partial_mode and "partial" or "full"
      end
    elseif type(opts.config.partial_mode) == "table" then
      state.get_config().partial_mode =
        tbl_deep_extend("force", state.get_default_partial_mode(), opts.config.partial_mode)
      if opts.config.default_mode == nil then
        state.get_config().default_mode = "partial"
      end
    else
      state.get_config().partial_mode = false
      if opts.config.default_mode == nil then
        state.get_config().default_mode = "full"
      end
    end

    state.get_config().mask_char = opts.config.mask_char or "*"
    state.get_config().highlight_group = opts.config.highlight_group or "Comment"
    state.get_config().mask_length = type(opts.config.mask_length) == "number" and opts.config.mask_length or nil
    state.get_config().skip_comments = type(opts.config.skip_comments) == "boolean" and opts.config.skip_comments or false

    if opts.config.patterns then
      state.get_config().patterns = opts.config.patterns
    end

    if opts.config.sources then
      state.get_config().sources = opts.config.sources
    end

    if opts.config.default_mode then
      if not vim.tbl_contains({ "none", "partial", "full" }, opts.config.default_mode) then
        notify("Invalid default_mode. Using '" .. state.get_config().default_mode .. "'.", vim.log.levels.WARN)
      else
        state.get_config().default_mode = opts.config.default_mode
      end
    end
  end

  local partial = opts.partial or {}
  for _, feature in ipairs(state.get_features()) do
    local value = type(partial[feature]) == "boolean" and partial[feature] or false
    if feature == "files" then
      if type(partial[feature]) == "table" then
        state.set_feature_state(feature, true)
        state.set_initial_feature_state(feature, true)
        state.get_config().shelter_on_leave = partial[feature].shelter_on_leave
        state.update_buffer_state("disable_cmp", partial[feature].disable_cmp ~= false)
        
        -- Handle deprecated skip_comments in files module
        if partial[feature].skip_comments ~= nil then
          notify(
            "DEPRECATED: Using skip_comments in shelter.modules.files module is deprecated. " ..
            "Please move it to shelter.configuration.skip_comments instead.",
            vim.log.levels.WARN
          )
          state.get_config().skip_comments = partial[feature].skip_comments == true
        end
      else
        state.set_feature_state(feature, value)
        state.set_initial_feature_state(feature, value)
        if value then
          state.get_config().shelter_on_leave = true
          state.update_buffer_state("disable_cmp", true)
        end
      end
    else
      state.set_initial_feature_state(feature, value)
      state.set_feature_state(feature, value)
    end
  end

  if state.is_enabled("files") then
    buffer.setup_file_shelter()
  end

  if state.is_enabled("telescope_previewer") then
    require("ecolog.shelter.integrations.telescope").setup_telescope_shelter()
  end

  if state.is_enabled("fzf_previewer") then
    require("ecolog.shelter.integrations.fzf").setup_fzf_shelter()
  end

  if state.is_enabled("snacks_previewer") then
    require("ecolog.shelter.integrations.snacks").setup_snacks_shelter()
  end

  api.nvim_create_user_command("EcologShelterLinePeek", function()
    if not state.is_enabled("files") then
      notify("Shelter mode for files is not enabled", vim.log.levels.WARN)
      return
    end

    local current_line = api.nvim_win_get_cursor(0)[1]
    state.reset_revealed_lines()
    state.set_revealed_line(current_line, true)
    buffer.shelter_buffer()

    local bufnr = api.nvim_get_current_buf()
    api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufLeave" }, {
      buffer = bufnr,
      callback = function(ev)
        if ev.event == "BufLeave" then
          local bufname = api.nvim_buf_get_name(bufnr)
          state.reset_revealed_lines()
          buffer.clear_line_cache(current_line, bufname)
          buffer.shelter_buffer()
          api.nvim_del_autocmd(ev.id)
          return true
        end

        if ev.event:match("Cursor") then
          local new_line = api.nvim_win_get_cursor(0)[1]

          if new_line ~= current_line then
            local bufname = api.nvim_buf_get_name(bufnr)
            state.reset_revealed_lines()
            buffer.clear_line_cache(current_line, bufname)
            buffer.clear_line_cache(new_line, bufname)
            buffer.shelter_buffer()
            api.nvim_del_autocmd(ev.id)
            return true
          end
        end
      end,
      desc = "Hide revealed env values on cursor move",
    })
  end, {
    desc = "Temporarily reveal env value for current line",
  })
end

function M.mask_value(value, feature, key, source)
  if not value then
    return ""
  end
  if not state.is_enabled(feature) then
    return value
  end

  return utils.determine_masked_value(value, {
    partial_mode = state.get_config().partial_mode,
    key = key,
    source = source,
  })
end

function M.is_enabled(feature)
  return state.is_enabled(feature)
end

function M.get_config()
  return state.get_config()
end

function M.toggle_all()
  local any_enabled = false
  for _, feature in ipairs(state.get_features()) do
    if state.is_enabled(feature) then
      any_enabled = true
      break
    end
  end

  if any_enabled then
    for _, feature in ipairs(state.get_features()) do
      state.set_feature_state(feature, false)
    end
    buffer.unshelter_buffer()
    notify("All shelter modes disabled", vim.log.levels.INFO)
  else
    local files_enabled = false
    for feature, value in pairs(state.get_state().features.initial) do
      state.set_feature_state(feature, value)
      if feature == "files" and value then
        files_enabled = true
      end
    end
    if files_enabled then
      buffer.setup_file_shelter()
      buffer.shelter_buffer()
    end
    notify("Shelter modes restored to initial settings", vim.log.levels.INFO)
  end
end

function M.set_state(command, feature)
  local should_enable = command == "enable"

  if feature then
    if not tbl_contains(state.get_features(), feature) then
      notify(
        "Invalid feature. Use 'cmp', 'peek', 'files', 'telescope', 'fzf', 'telescope_previewer', 'snacks_previewer', or 'snacks'",
        vim.log.levels.ERROR
      )
      return
    end

    state.set_feature_state(feature, should_enable)
    if feature == "files" then
      if should_enable then
        buffer.setup_file_shelter()
        buffer.shelter_buffer()
        state.get_config().shelter_on_leave = true
      else
        buffer.unshelter_buffer()
        state.get_config().shelter_on_leave = false
      end
    elseif feature == "telescope_previewer" then
      require("ecolog.shelter.integrations.telescope").setup_telescope_shelter()
    elseif feature == "fzf_previewer" then
      require("ecolog.shelter.integrations.fzf").setup_fzf_shelter()
    elseif feature == "snacks_previewer" then
      require("ecolog.shelter.integrations.snacks").setup_snacks_shelter()
    end
    notify(
      string.format("Shelter mode for %s is now %s", feature:upper(), should_enable and "enabled" or "disabled"),
      vim.log.levels.INFO
    )
  else
    for _, f in ipairs(state.get_features()) do
      state.set_feature_state(f, should_enable)
      if f == "files" then
        state.get_config().shelter_on_leave = should_enable
      end
    end
    if should_enable then
      buffer.setup_file_shelter()
      buffer.shelter_buffer()
      require("ecolog.shelter.integrations.telescope").setup_telescope_shelter()
      require("ecolog.shelter.integrations.fzf").setup_fzf_shelter()
      require("ecolog.shelter.integrations.snacks").setup_snacks_shelter()
    else
      buffer.unshelter_buffer()
    end
    notify(
      string.format("All shelter modes are now %s", should_enable and "enabled" or "disabled"),
      vim.log.levels.INFO
    )
  end
end

return M
