local M = {}

local api = vim.api
local string_find = string.find
local string_sub = string.sub
local string_match = string.match

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
  api.nvim_buf_clear_namespace(0, namespace, 0, -1)

  if state.get_buffer_state().disable_cmp then
    vim.b.completion = false

    if utils.has_cmp() then
      require("cmp").setup.buffer({ enabled = false })
    end
  end

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
      local masked_value = state.is_line_revealed(i) and actual_value
        or utils.determine_masked_value(actual_value, {
          partial_mode = state.get_config().partial_mode,
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
            virt_text = {
              { masked_value, state.is_line_revealed(i) and "String" or state.get_config().highlight_group },
            },
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

function M.setup_file_shelter()
  local group = api.nvim_create_augroup("ecolog_shelter", { clear = true })

  local config = require("ecolog").get_config and require("ecolog").get_config() or {}
  local watch_patterns = {}

  if not config.env_file_pattern then
    watch_patterns[1] = ".env*"
  else
    local patterns = type(config.env_file_pattern) == "string" and { config.env_file_pattern }
      or config.env_file_pattern or {}
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

  -- Agressive shelter
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

      -- Initialize buffer options first
      vim.bo[bufnr].buftype = ""
      vim.bo[bufnr].filetype = "sh"
      
      -- Set modifiable and make changes
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
        
        -- Enable telescope_previewer if it was in initial config
        if state.get_state().features.initial.telescope_previewer then
          state.set_feature_state("telescope_previewer", true)
          require("ecolog.shelter.integrations.telescope").setup_telescope_shelter()
        end
        
        -- Enable fzf_previewer if it was in initial config
        if state.get_state().features.initial.fzf_previewer then
          state.set_feature_state("fzf_previewer", true)
          require("ecolog.shelter.integrations.fzf").setup_fzf_shelter()
        end
        
        M.shelter_buffer()
      end
    end,
    group = group,
  })
end

return M 