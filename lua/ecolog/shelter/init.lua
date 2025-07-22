local M = {}

local api = vim.api
local notify = vim.notify
local tbl_contains = vim.tbl_contains
local tbl_deep_extend = vim.tbl_deep_extend

local state, buffer, utils

local function get_state()
  if not state then
    state = require("ecolog.shelter.state")
  end
  return state
end

local function get_buffer()
  if not buffer then
    buffer = require("ecolog.shelter.buffer")
  end
  return buffer
end

local function get_utils()
  if not utils then
    utils = require("ecolog.shelter.utils")
  end
  return utils
end

function M.setup(opts)
  opts = opts or {}

  local state_module = get_state()

  if opts.config then
    if type(opts.config.partial_mode) == "boolean" then
      state_module.get_config().partial_mode = opts.config.partial_mode and state_module.get_default_partial_mode()
        or false
      if opts.config.default_mode == nil then
        state_module.get_config().default_mode = opts.config.partial_mode and "partial" or "full"
      end
    elseif type(opts.config.partial_mode) == "table" then
      state_module.get_config().partial_mode =
        tbl_deep_extend("force", state_module.get_default_partial_mode(), opts.config.partial_mode)
      if opts.config.default_mode == nil then
        state_module.get_config().default_mode = "partial"
      end
    else
      state_module.get_config().partial_mode = false
      if opts.config.default_mode == nil then
        state_module.get_config().default_mode = "full"
      end
    end

    state_module.get_config().mask_char = opts.config.mask_char or "*"
    state_module.get_config().highlight_group = opts.config.highlight_group or "Comment"
    state_module.get_config().mask_length = type(opts.config.mask_length) == "number" and opts.config.mask_length or nil
    state_module.get_config().skip_comments = type(opts.config.skip_comments) == "boolean" and opts.config.skip_comments
      or false

    if opts.config.patterns then
      state_module.get_config().patterns = opts.config.patterns
    end

    if opts.config.sources then
      state_module.get_config().sources = opts.config.sources
    end

    if opts.config.default_mode then
      if not vim.tbl_contains({ "none", "partial", "full" }, opts.config.default_mode) then
        notify("Invalid default_mode. Using '" .. state_module.get_config().default_mode .. "'.", vim.log.levels.WARN)
      else
        state_module.get_config().default_mode = opts.config.default_mode
      end
    end
  end

  local partial = opts.partial or {}
  for _, feature in ipairs(state_module.get_features()) do
    local value = type(partial[feature]) == "boolean" and partial[feature] or false
    if feature == "files" then
      if type(partial[feature]) == "table" then
        state_module.set_feature_state(feature, true)
        state_module.set_initial_feature_state(feature, true)
        state_module.get_config().shelter_on_leave = partial[feature].shelter_on_leave
        state_module.update_buffer_state("disable_cmp", partial[feature].disable_cmp ~= false)

        if partial[feature].skip_comments ~= nil then
          notify(
            "DEPRECATED: Using skip_comments in shelter.modules.files module is deprecated. "
              .. "Please move it to shelter.configuration.skip_comments instead.",
            vim.log.levels.WARN
          )
          state_module.get_config().skip_comments = partial[feature].skip_comments == true
        end
      else
        state_module.set_feature_state(feature, value)
        state_module.set_initial_feature_state(feature, value)
        if value then
          state_module.get_config().shelter_on_leave = true
          state_module.update_buffer_state("disable_cmp", true)
        end
      end
    else
      state_module.set_initial_feature_state(feature, value)
      state_module.set_feature_state(feature, value)
    end
  end

  if state_module.is_enabled("files") then
    get_buffer().setup_file_shelter()
  end

  if state_module.is_enabled("telescope_previewer") then
    local ok, telescope_integration = pcall(require, "ecolog.shelter.integrations.telescope")
    if ok then
      telescope_integration.setup_telescope_shelter()
    end
  end

  if state_module.is_enabled("fzf_previewer") then
    local ok, fzf_integration = pcall(require, "ecolog.shelter.integrations.fzf")
    if ok then
      fzf_integration.setup_fzf_shelter()
    end
  end

  if state_module.is_enabled("snacks_previewer") then
    local ok, snacks_integration = pcall(require, "ecolog.shelter.integrations.snacks")
    if ok then
      snacks_integration.setup_snacks_shelter()
    end
  end

  api.nvim_create_user_command("EcologShelterLinePeek", function()
    local state_cmd = get_state()
    if not state_cmd.is_enabled("files") then
      notify("Shelter mode for files is not enabled. Enable with: shelter.modules.files = true", vim.log.levels.WARN)
      return
    end

    local current_line = api.nvim_win_get_cursor(0)[1]
    local bufnr = api.nvim_get_current_buf()

    state_cmd.reset_revealed_lines()
    state_cmd.set_revealed_line(current_line, true)

    local multiline_engine = require("ecolog.shelter.multiline_engine")
    multiline_engine.clear_caches()

    get_buffer().shelter_buffer()

    -- Use CursorHold instead of CursorMoved to avoid immediate triggering
    -- This will trigger after the user stops moving the cursor for a short time
    local function cleanup_peek()
      if not state_cmd.is_enabled("files") then
        return
      end

      state_cmd.reset_revealed_lines()
      get_buffer().clear_line_cache(current_line, api.nvim_buf_get_name(bufnr))

      local multiline_engine = require("ecolog.shelter.multiline_engine")
      multiline_engine.clear_caches()

      get_buffer().shelter_buffer()

      vim.schedule(function()
        if api.nvim_buf_is_valid(bufnr) then
          vim.cmd("redraw")
        end
      end)
    end

    local autocmd_group = api.nvim_create_augroup("EcologPeek_" .. bufnr .. "_" .. current_line, { clear = true })

    -- Helper function to check if a line is part of the same multiline variable as current_line
    local function is_within_same_multiline_var(line_num)
      if line_num == current_line then
        return true
      end

      local all_lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local multiline_engine = require("ecolog.shelter.multiline_engine")
      local content_hash = vim.fn.sha256(table.concat(all_lines, "\n"))
      local parsed_vars = multiline_engine.parse_lines_cached(all_lines, content_hash)

      local current_var = nil
      for _, var_info in pairs(parsed_vars) do
        if current_line >= var_info.start_line and current_line <= var_info.end_line then
          current_var = var_info
          break
        end
      end

      if not current_var or not (current_var.is_multi_line or current_var.has_newlines) then
        return false
      end

      return line_num >= current_var.start_line and line_num <= current_var.end_line
    end

    local cursor_timer = nil
    api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
      buffer = bufnr,
      group = autocmd_group,
      callback = function(ev)
        local new_line = api.nvim_win_get_cursor(0)[1]

        if new_line ~= current_line and not is_within_same_multiline_var(new_line) then
          if cursor_timer then
            vim.fn.timer_stop(cursor_timer)
          end
          cursor_timer = vim.fn.timer_start(50, function()
            cleanup_peek()
            api.nvim_del_augroup_by_id(autocmd_group)
          end)
        end
      end,
    })

    api.nvim_create_autocmd("BufLeave", {
      buffer = bufnr,
      group = autocmd_group,
      callback = function()
        if cursor_timer then
          vim.fn.timer_stop(cursor_timer)
        end
        cleanup_peek()
        api.nvim_del_augroup_by_id(autocmd_group)
      end,
    })
  end, {
    desc = "Temporarily reveal env value for current line",
  })
end

function M.mask_value(value, feature, key, source)
  if not value then
    return ""
  end
  local state_module = get_state()
  if not state_module.is_enabled(feature) then
    return value
  end

  return get_utils().determine_masked_value(value, {
    partial_mode = state_module.get_config().partial_mode,
    key = key,
    source = source,
  })
end

function M.is_enabled(feature)
  return get_state().is_enabled(feature)
end

function M.get_config()
  return get_state().get_config()
end

function M.toggle_all()
  local state_module = get_state()
  local buffer_module = get_buffer()

  local any_enabled = false
  for _, feature in ipairs(state_module.get_features()) do
    if state_module.is_enabled(feature) then
      any_enabled = true
      break
    end
  end

  if any_enabled then
    for _, feature in ipairs(state_module.get_features()) do
      state_module.set_feature_state(feature, false)
    end
    buffer_module.unshelter_buffer()
    notify("All shelter modes disabled", vim.log.levels.INFO)
  else
    local files_enabled = false
    for feature, value in pairs(state_module.get_state().features.initial) do
      state_module.set_feature_state(feature, value)
      if feature == "files" and value then
        files_enabled = true
      end
    end
    if files_enabled then
      buffer_module.setup_file_shelter()
      buffer_module.shelter_buffer()
    end
    notify("Shelter modes restored to initial settings", vim.log.levels.INFO)
  end
end

function M.toggle_feature(feature)
  local state_module = get_state()
  
  if not tbl_contains(state_module.get_features(), feature) then
    notify(
      "Invalid feature. Use 'cmp', 'peek', 'files', 'telescope', 'fzf', 'telescope_previewer', 'snacks_previewer', or 'snacks'",
      vim.log.levels.ERROR
    )
    return
  end
  
  local current_state = state_module.is_enabled(feature)
  local new_command = current_state and "disable" or "enable"
  M.set_state(new_command, feature)
end

function M.set_state(command, feature)
  local should_enable = command == "enable"
  local state_module = get_state()
  local buffer_module = get_buffer()

  if feature then
    if not tbl_contains(state_module.get_features(), feature) then
      notify(
        "Invalid feature. Use 'cmp', 'peek', 'files', 'telescope', 'fzf', 'telescope_previewer', 'snacks_previewer', or 'snacks'",
        vim.log.levels.ERROR
      )
      return
    end

    state_module.set_feature_state(feature, should_enable)
    if feature == "files" then
      if should_enable then
        buffer_module.setup_file_shelter()
        buffer_module.shelter_buffer()
        state_module.get_config().shelter_on_leave = true
      else
        buffer_module.unshelter_buffer()
        state_module.get_config().shelter_on_leave = false
      end
    elseif feature == "telescope_previewer" then
      local ok, telescope_integration = pcall(require, "ecolog.shelter.integrations.telescope")
      if ok then
        telescope_integration.setup_telescope_shelter()
      end
    elseif feature == "fzf_previewer" then
      local ok, fzf_integration = pcall(require, "ecolog.shelter.integrations.fzf")
      if ok then
        fzf_integration.setup_fzf_shelter()
      end
    elseif feature == "snacks_previewer" then
      local ok, snacks_integration = pcall(require, "ecolog.shelter.integrations.snacks")
      if ok then
        snacks_integration.setup_snacks_shelter()
      end
    end
    notify(
      string.format("Shelter mode for %s is now %s", feature:upper(), should_enable and "enabled" or "disabled"),
      vim.log.levels.INFO
    )
  else
    for _, f in ipairs(state_module.get_features()) do
      state_module.set_feature_state(f, should_enable)
      if f == "files" then
        state_module.get_config().shelter_on_leave = should_enable
      end
    end
    if should_enable then
      buffer_module.setup_file_shelter()
      buffer_module.shelter_buffer()
      local ok, telescope_integration = pcall(require, "ecolog.shelter.integrations.telescope")
      if ok then
        telescope_integration.setup_telescope_shelter()
      end
      local ok2, fzf_integration = pcall(require, "ecolog.shelter.integrations.fzf")
      if ok2 then
        fzf_integration.setup_fzf_shelter()
      end
      local ok3, snacks_integration = pcall(require, "ecolog.shelter.integrations.snacks")
      if ok3 then
        snacks_integration.setup_snacks_shelter()
      end
    else
      buffer_module.unshelter_buffer()
    end
    notify(
      string.format("All shelter modes are now %s", should_enable and "enabled" or "disabled"),
      vim.log.levels.INFO
    )
  end
end

return M
