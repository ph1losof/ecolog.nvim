local M = {}

local api = vim.api
local string_find = string.find
local string_sub = string.sub
local string_match = string.match
local table_insert = table.insert
local fn = vim.fn
local bo = vim.bo
local notify = vim.notify
local log_levels = vim.log.levels
local pcall = pcall

local state = require("ecolog.shelter.state")
local utils = require("ecolog.shelter.utils")

local namespace = api.nvim_create_namespace("ecolog_shelter")

function M.unshelter_buffer()
  api.nvim_buf_clear_namespace(0, namespace, 0, -1)
  state.reset_revealed_lines()

  -- Re-enable completion if it was disabled
  if state.get_buffer_state().disable_cmp then
    -- Re-enable blink-cmp
    vim.b.completion = true

    if utils.has_cmp() then
      require("cmp").setup.buffer({ enabled = true })
    end
  end
end

function M.shelter_buffer()
  local config = require("ecolog").get_config and require("ecolog").get_config() or {}
  local filename = fn.fnamemodify(fn.bufname(), ":t")

  if not utils.match_env_file(filename, config) then
    return
  end

  api.nvim_buf_clear_namespace(0, namespace, 0, -1)

  if state.get_buffer_state().disable_cmp then
    vim.b.completion = false

    if utils.has_cmp() then
      require("cmp").setup.buffer({ enabled = false })
    end
  end

  local lines = api.nvim_buf_get_lines(0, 0, -1, false)
  local extmarks = {}
  local config_partial_mode = state.get_config().partial_mode
  local config_highlight_group = state.get_config().highlight_group

  for i, line in ipairs(lines) do
    if string_find(line, "^%s*[#%s]") then
      goto continue
    end

    local eq_pos = string_find(line, "=")
    if not eq_pos then
      goto continue
    end

    local key = string_match(string_sub(line, 1, eq_pos - 1), "^%s*(.-)%s*$")
    local value = string_match(string_sub(line, eq_pos + 1), "^%s*(.-)%s*$")

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

    if actual_value and #actual_value > 0 then
      local is_revealed = state.is_line_revealed(i)
      local masked_value = is_revealed and actual_value
        or utils.determine_masked_value(actual_value, {
          partial_mode = config_partial_mode,
          key = key,
          source = fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"),
        })

      if masked_value and #masked_value > 0 then
        if quote_char then
          masked_value = quote_char .. masked_value .. quote_char
        end

        table_insert(extmarks, {
          i - 1,
          eq_pos,
          {
            virt_text = {
              { masked_value, is_revealed and "String" or config_highlight_group },
            },
            virt_text_pos = "overlay",
            hl_mode = "combine",
          },
        })
      end
    end
    ::continue::
  end

  if #extmarks > 0 then
    for _, mark in ipairs(extmarks) do
      api.nvim_buf_set_extmark(0, namespace, mark[1], mark[2], mark[3])
    end
  end
end

function M.setup_file_shelter()
  local group = api.nvim_create_augroup("ecolog_shelter", { clear = true })

  local config = require("ecolog").get_config and require("ecolog").get_config() or {}
  local watch_patterns = {}

  if not config.env_file_pattern then
    watch_patterns[1] = ".env*"
  else
    local patterns = type(config.env_file_pattern) == "string" and { config.env_file_pattern }
      or config.env_file_pattern
      or {}
    for _, pattern in ipairs(patterns) do
      if type(pattern) == "string" then
        local glob_pattern = pattern:gsub("^%^", ""):gsub("%$$", ""):gsub("%%.", "")
        watch_patterns[#watch_patterns + 1] = glob_pattern:gsub("^%.%+/", "")
      end
    end
  end

  if #watch_patterns == 0 then
    watch_patterns[1] = ".env*"
  end

  api.nvim_create_autocmd("BufReadCmd", {
    pattern = watch_patterns,
    group = group,
    callback = function(ev)
      local filename = vim.fn.fnamemodify(ev.file, ":t")
      if not utils.match_env_file(filename, config) then
        return
      end

      local lines = vim.fn.readfile(ev.file)
      local bufnr = ev.buf

      vim.bo[bufnr].buftype = ""
      vim.bo[bufnr].filetype = "sh"

      local ok, err = pcall(function()
        vim.bo[bufnr].modifiable = true
        api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        vim.bo[bufnr].modified = false
      end)

      if not ok then
        vim.notify("Failed to set buffer contents: " .. tostring(err), vim.log.levels.ERROR)
        return true
      end

      if state.is_enabled("files") then
        M.shelter_buffer()
      end

      return true
    end,
  })

  api.nvim_create_autocmd({ "BufEnter", "TextChanged", "TextChangedI", "TextChangedP" }, {
    pattern = watch_patterns,
    callback = function(ev)
      local filename = vim.fn.fnamemodify(ev.file, ":t")
      if utils.match_env_file(filename, config) then
        if state.is_enabled("files") then
          M.shelter_buffer()
        else
          M.unshelter_buffer()
        end
      end
    end,
    group = group,
  })

  api.nvim_create_autocmd("BufLeave", {
    pattern = watch_patterns,
    callback = function(ev)
      local filename = vim.fn.fnamemodify(ev.file, ":t")
      if utils.match_env_file(filename, config) and state.get_config().shelter_on_leave then
        state.set_feature_state("files", true)

        if state.get_state().features.initial.telescope_previewer then
          state.set_feature_state("telescope_previewer", true)
          require("ecolog.shelter.integrations.telescope").setup_telescope_shelter()
        end

        if state.get_state().features.initial.fzf_previewer then
          state.set_feature_state("fzf_previewer", true)
          require("ecolog.shelter.integrations.fzf").setup_fzf_shelter()
        end

        if state.get_state().features.initial.snacks_previewer then
          state.set_feature_state("snacks_previewer", true)
          require("ecolog.shelter.integrations.snacks").setup_snacks_shelter()
        end

        M.shelter_buffer()
      end
    end,
    group = group,
  })
end

return M
