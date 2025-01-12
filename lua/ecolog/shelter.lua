local M = {}

local api = vim.api
local notify = vim.notify
local string_rep = string.rep
local string_sub = string.sub
local string_match = string.match
local string_find = string.find
local tbl_contains = vim.tbl_contains
local tbl_deep_extend = vim.tbl_deep_extend

local FEATURES = { "cmp", "peek", "files", "telescope", "fzf", "telescope_previewer", "fzf_previewer" }
local DEFAULT_PARTIAL_MODE = {
  show_start = 3,
  show_end = 3,
  min_mask = 3,
}

local namespace = api.nvim_create_namespace("ecolog_shelter")

local function match_env_file(filename, config)
  if not filename then
    return false
  end

  if filename:match("^%.env$") or filename:match("^%.env%.[^.]+$") then
    return true
  end

  if config and config.env_file_pattern then
    local patterns = type(config.env_file_pattern) == "string" and { config.env_file_pattern }
      or config.env_file_pattern

    for _, pattern in ipairs(patterns) do
      if filename:match(pattern) then
        return true
      end
    end
  end

  return false
end

local state = {
  config = {
    partial_mode = false,
    mask_char = "*",
    patterns = {},
    default_mode = "full",
  },
  features = {
    enabled = {},
    initial = {},
  },
  buffer = {
    revealed_lines = {},
  },
  telescope = {
    last_selection = nil,
  },
}

---@class ShelterSetupOptions
---@field config? ShelterConfiguration
---@field partial? table<string, boolean>

local function matches_shelter_pattern(key)
  if not key or not state.config.patterns or vim.tbl_isempty(state.config.patterns) then
    return nil
  end

  for pattern, mode in pairs(state.config.patterns) do
    local lua_pattern = pattern:gsub("%*", ".*"):gsub("%%", "%%%%")
    if key:match("^" .. lua_pattern .. "$") then
      return mode
    end
  end

  return nil
end

local function determine_masked_value(value, opts)
  if not value or value == "" then
    return ""
  end

  opts = opts or {}
  local key = opts.key
  local pattern_mode = key and matches_shelter_pattern(key)

  if pattern_mode then
    if pattern_mode == "none" then
      return value
    elseif pattern_mode == "full" then
      return string_rep(state.config.mask_char, #value)
    end
  else
    if state.config.default_mode == "none" then
      return value
    elseif state.config.default_mode == "full" then
      return string_rep(state.config.mask_char, #value)
    end
  end

  local settings = type(state.config.partial_mode) == "table" and state.config.partial_mode or DEFAULT_PARTIAL_MODE

  local show_start = math.max(0, settings.show_start or 0)
  local show_end = math.max(0, settings.show_end or 0)
  local min_mask = math.max(1, settings.min_mask or 1)

  if #value <= (show_start + show_end) or #value < (show_start + show_end + min_mask) then
    return string_rep(state.config.mask_char, #value)
  end

  local mask_length = math.max(min_mask, #value - show_start - show_end)

  return string_sub(value, 1, show_start)
    .. string_rep(state.config.mask_char, mask_length)
    .. string_sub(value, -show_end)
end

M.determine_masked_value = determine_masked_value

local function unshelter_buffer()
  api.nvim_buf_clear_namespace(0, namespace, 0, -1)
  state.buffer.revealed_lines = {}
end

local function shelter_buffer()
  api.nvim_buf_clear_namespace(0, namespace, 0, -1)

  local lines = api.nvim_buf_get_lines(0, 0, -1, false)
  local extmarks = {}

  for i, line in ipairs(lines) do
    if string_find(line, "^%s*#") or string_find(line, "^%s*$") then
      goto continue
    end

    local eq_pos = string_find(line, "=")
    if not eq_pos then
      goto continue
    end

    local key = string_sub(line, 1, eq_pos - 1)
    local value = string_sub(line, eq_pos + 1)

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
          key = key,
        })

      if masked_value and #masked_value > 0 then
        if quote_char then
          masked_value = quote_char .. masked_value .. quote_char
        end

        table.insert(extmarks, {
          i - 1,
          eq_pos,
          {
            virt_text = { { masked_value, state.buffer.revealed_lines[i] and "String" or "Comment" } },
            virt_text_pos = "overlay",
            hl_mode = "combine",
          },
        })
      end
    end
    ::continue::
  end

  for _, mark in ipairs(extmarks) do
    api.nvim_buf_set_extmark(0, namespace, mark[1], mark[2], mark[3])
  end
end

local function setup_file_shelter()
  local group = api.nvim_create_augroup("ecolog_shelter", { clear = true })

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

  api.nvim_create_user_command("EcologShelterLinePeek", function()
    if not state.features.enabled.files then
      notify("Shelter mode for files is not enabled", vim.log.levels.WARN)
      return
    end

    local current_line = api.nvim_win_get_cursor(0)[1]

    state.buffer.revealed_lines = {}

    state.buffer.revealed_lines[current_line] = true

    shelter_buffer()

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

local function setup_telescope_shelter()
  local previewers = require("telescope.previewers")
  local from_entry = require("telescope.from_entry")
  local conf = require("telescope.config").values

  local extmarks = {}
  local function clear_extmarks()
    for i = 1, #extmarks do
      extmarks[i] = nil
    end
  end

  local masked_previewer = function(opts)
    opts = opts or {}

    return previewers.new_buffer_previewer({
      title = opts.title or "File Preview",

      get_buffer_by_name = function(_, entry)
        return from_entry.path(entry, false)
      end,

      define_preview = function(self, entry, status)
        local p = from_entry.path(entry, false)
        if not p or p == "" then
          return
        end

        local filename = vim.fn.fnamemodify(p, ":t")
        local config = require("ecolog").get_config and require("ecolog").get_config() or {}
        local is_env_file = match_env_file(filename, config)

        conf.buffer_previewer_maker(p, self.state.bufnr, {
          bufname = self.state.bufname,
          callback = function(bufnr)
            if not (is_env_file and state.features.enabled.telescope_previewer) then
              return
            end

            pcall(api.nvim_buf_set_var, bufnr, "ecolog_masked", true)

            local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
            clear_extmarks()

            local chunk_size = 100
            for i = 1, #lines, chunk_size do
              local end_idx = math.min(i + chunk_size - 1, #lines)

              vim.schedule(function()
                for j = i, end_idx do
                  local line = lines[j]
                  if not (string_find(line, "^%s*#") or string_find(line, "^%s*$")) then
                    local eq_pos = string_find(line, "=")
                    if eq_pos then
                      local value = string_sub(line, eq_pos + 1)
                      value = string_match(value, "^%s*(.-)%s*$")

                      if value then
                        local quote_char = string_match(value, "^([\"'])")
                        local actual_value = quote_char
                            and string_match(value, "^" .. quote_char .. "(.-)" .. quote_char)
                          or string_match(value, "^([^%s#]+)")

                        if actual_value then
                          local masked_value = determine_masked_value(actual_value, {
                            partial_mode = state.config.partial_mode,
                          })

                          if masked_value and #masked_value > 0 then
                            if quote_char then
                              masked_value = quote_char .. masked_value .. quote_char
                            end

                            table.insert(extmarks, {
                              j - 1,
                              eq_pos,
                              {
                                virt_text = { { masked_value, "Comment" } },
                                virt_text_pos = "overlay",
                                hl_mode = "combine",
                              },
                            })
                          end
                        end
                      end
                    end
                  end
                end

                if #extmarks > 0 then
                  for _, mark in ipairs(extmarks) do
                    api.nvim_buf_set_extmark(bufnr, namespace, mark[1], mark[2], mark[3])
                  end
                  clear_extmarks()
                end
              end)
            end
          end,
        })
      end,
    })
  end

  if not state._original_file_previewer then
    state._original_file_previewer = conf.file_previewer
  end

  if state.features.enabled.telescope_previewer then
    conf.file_previewer = masked_previewer
  else
    conf.file_previewer = state._original_file_previewer
  end
end

local function setup_fzf_shelter()
  if not state.features.enabled.fzf_previewer then
    return
  end

  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    return
  end

  local builtin = require("fzf-lua.previewer.builtin")
  local buffer_or_file = builtin.buffer_or_file

  local orig_preview_buf_post = buffer_or_file.preview_buf_post

  local processed_buffers = {}

  buffer_or_file.preview_buf_post = function(self, entry, min_winopts)
    if orig_preview_buf_post then
      orig_preview_buf_post(self, entry, min_winopts)
    end

    local bufnr = self.preview_bufnr
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end

    local filename = entry and (entry.path or entry.filename or entry.name)
    if not filename then
      return
    end
    filename = vim.fn.fnamemodify(filename, ":t")

    local config = require("ecolog").get_config and require("ecolog").get_config() or {}
    local is_env_file = match_env_file(filename, config)

    if not (is_env_file and state.features.enabled.fzf_previewer) then
      return
    end

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    local content_hash = vim.fn.sha256(table.concat(lines, "\n"))

    if processed_buffers[bufnr] and processed_buffers[bufnr].hash == content_hash then
      return
    end

    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)

    pcall(vim.api.nvim_buf_set_var, bufnr, "ecolog_masked", true)

    local comment_pattern = "^%s*#"
    local empty_pattern = "^%s*$"
    local quote_pattern = "^([\"'])"

    local all_extmarks = {}
    for i, line in ipairs(lines) do
      if not (string_find(line, comment_pattern) or string_find(line, empty_pattern)) then
        local eq_pos = string_find(line, "=")
        if eq_pos then
          local value = string_sub(line, eq_pos + 1)
          value = string_match(value, "^%s*(.-)%s*$")

          if value then
            local quote_char = string_match(value, quote_pattern)
            local actual_value = quote_char and string_match(value, "^" .. quote_char .. "(.-)" .. quote_char)
              or string_match(value, "^([^%s#]+)")

            if actual_value then
              local masked_value = determine_masked_value(actual_value, {
                partial_mode = state.config.partial_mode,
              })

              if masked_value and #masked_value > 0 then
                if quote_char then
                  masked_value = quote_char .. masked_value .. quote_char
                end

                table.insert(all_extmarks, {
                  i - 1,
                  eq_pos,
                  {
                    virt_text = { { masked_value, "Comment" } },
                    virt_text_pos = "overlay",
                    hl_mode = "combine",
                  },
                })
              end
            end
          end
        end
      end
    end

    if #all_extmarks > 0 then
      vim.schedule(function()
        for _, mark in ipairs(all_extmarks) do
          pcall(vim.api.nvim_buf_set_extmark, bufnr, namespace, mark[1], mark[2], mark[3])
        end
      end)
    end

    processed_buffers[bufnr] = {
      hash = content_hash,
      timestamp = vim.loop.now(),
    }

    if vim.tbl_count(processed_buffers) > 100 then
      local current_time = vim.loop.now()
      for buf, info in pairs(processed_buffers) do
        if current_time - info.timestamp > 300000 then
          processed_buffers[buf] = nil
        end
      end
    end
  end
end

function M.setup(opts)
  opts = opts or {}

  if opts.config then
    -- Handle partial_mode first as it affects default_mode
    if type(opts.config.partial_mode) == "boolean" then
      state.config.partial_mode = opts.config.partial_mode and DEFAULT_PARTIAL_MODE or false
      -- Set default_mode based on partial_mode unless it's explicitly set
      if opts.config.default_mode == nil then
        state.config.default_mode = opts.config.partial_mode and "partial" or "full"
      end
    elseif type(opts.config.partial_mode) == "table" then
      state.config.partial_mode = tbl_deep_extend("force", DEFAULT_PARTIAL_MODE, opts.config.partial_mode)
      -- Set default_mode to partial unless it's explicitly set
      if opts.config.default_mode == nil then
        state.config.default_mode = "partial"
      end
    else
      state.config.partial_mode = false
      -- Set default_mode to full unless it's explicitly set
      if opts.config.default_mode == nil then
        state.config.default_mode = "full"
      end
    end

    state.config.mask_char = opts.config.mask_char or "*"

    -- Add patterns configuration
    if opts.config.patterns then
      state.config.patterns = opts.config.patterns
    end

    -- Handle explicit default_mode configuration
    if opts.config.default_mode then
      if not vim.tbl_contains({ "none", "partial", "full" }, opts.config.default_mode) then
        notify("Invalid default_mode. Using '" .. state.config.default_mode .. "'.", vim.log.levels.WARN)
      else
        state.config.default_mode = opts.config.default_mode
      end
    end
  end

  local partial = opts.partial or {}
  for _, feature in ipairs(FEATURES) do
    local value = type(partial[feature]) == "boolean" and partial[feature] or false
    state.features.initial[feature] = value
    state.features.enabled[feature] = value
  end

  if state.features.enabled.files then
    setup_file_shelter()
  end

  if state.features.enabled.telescope_previewer then
    setup_telescope_shelter()
  end

  if state.features.enabled.fzf_previewer then
    setup_fzf_shelter()
  end
end

function M.mask_value(value, feature, key)
  if not value then
    return ""
  end
  if not state.features.enabled[feature] then
    return value
  end

  return determine_masked_value(value, {
    partial_mode = state.config.partial_mode,
    key = key,
  })
end

function M.is_enabled(feature)
  return state.features.enabled[feature] or false
end

function M.toggle_all()
  local any_enabled = false
  for _, feature in ipairs(FEATURES) do
    if state.features.enabled[feature] then
      any_enabled = true
      break
    end
  end

  if any_enabled then
    for _, feature in ipairs(FEATURES) do
      state.features.enabled[feature] = false
    end
    unshelter_buffer()
    notify("All shelter modes disabled", vim.log.levels.INFO)
  else
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

function M.set_state(command, feature)
  local should_enable = command == "enable"

  if feature then
    if not tbl_contains(FEATURES, feature) then
      notify(
        "Invalid feature. Use 'cmp', 'peek', 'files', 'telescope', 'fzf', or 'telescope_previewer'",
        vim.log.levels.ERROR
      )
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
