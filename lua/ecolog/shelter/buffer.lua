local M = {}

local api = vim.api
local string_find = string.find
local string_sub = string.sub
local string_match = string.match
local table_insert = table.insert
local fn = vim.fn
local pcall = pcall

local state = require("ecolog.shelter.state")
local utils = require("ecolog.shelter.utils")
local lru_cache = require("ecolog.shelter.lru_cache")

local namespace = api.nvim_create_namespace("ecolog_shelter")
local CHUNK_SIZE = 1000
local line_cache = lru_cache.new(1000)

local active_buffers = setmetatable({}, {
  __mode = "k",
})

local COMMENT_PATTERN = "^%s*[#%s]"
local KEY_PATTERN = "^%s*(.-)%s*$"
local VALUE_PATTERN = "^%s*(.-)%s*$"

local function process_line(line, eq_pos)
  if not eq_pos then
    return nil
  end

  local key = string_match(string_sub(line, 1, eq_pos - 1), KEY_PATTERN)
  local value_part = string_sub(line, eq_pos + 1)
  local value = string_match(value_part, VALUE_PATTERN)

  if not (key and value) then
    return nil
  end

  local first_char = value:sub(1, 1)
  if first_char == '"' or first_char == "'" then
    local end_quote_pos = nil
    local pos = 2
    while pos <= #value do
      if value:sub(pos, pos) == first_char and value:sub(pos - 1, pos - 1) ~= "\\" then
        end_quote_pos = pos
        break
      end
      pos = pos + 1
    end

    if end_quote_pos then
      local quoted_value = value:sub(2, end_quote_pos - 1)
      local rest = value:sub(end_quote_pos + 1)
      if rest then
        local comment = rest:match("^%s*#%s*(.-)%s*$")
        if comment then
          return key, quoted_value, first_char
        end
      end
      return key, quoted_value, first_char
    end
  end

  local hash_pos = value:find("#")
  if hash_pos then
    if hash_pos > 1 and value:sub(hash_pos - 1, hash_pos - 1):match("%s") then
      value = value:sub(1, hash_pos - 1):match("^%s*(.-)%s*$")
    end
  end

  return key, value, nil
end

local function get_cached_line(line, line_num, bufname)
  local cache_key = string.format("%s:%d:%s", bufname, line_num, line)
  return line_cache:get(cache_key)
end

local function cache_line(line, line_num, bufname, processed_data)
  local cache_key = string.format("%s:%d:%s", bufname, line_num, line)
  line_cache:put(cache_key, processed_data)
end

local function cleanup_invalid_buffers()
  local current_time = vim.loop.now()
  for bufnr, timestamp in pairs(active_buffers) do
    if not api.nvim_buf_is_valid(bufnr) or (current_time - timestamp) > 3600000 then
      pcall(api.nvim_buf_clear_namespace, bufnr, namespace, 0, -1)

      line_cache:remove(bufnr)
      active_buffers[bufnr] = nil
    end
  end
end

function M.unshelter_buffer()
  local bufnr = api.nvim_get_current_buf()
  api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  state.reset_revealed_lines()
  active_buffers[bufnr] = nil

  if state.get_buffer_state().disable_cmp then
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

  local bufnr = api.nvim_get_current_buf()
  active_buffers[bufnr] = vim.loop.now()

  if vim.loop.now() % 300000 == 0 then
    cleanup_invalid_buffers()
  end

  if state.get_buffer_state().disable_cmp then
    vim.b.completion = false

    if utils.has_cmp() then
      require("cmp").setup.buffer({ enabled = false })
    end
  end

  local bufname = api.nvim_buf_get_name(bufnr)
  local line_count = api.nvim_buf_line_count(bufnr)
  local extmarks = {}
  local config_partial_mode = state.get_config().partial_mode
  local config_highlight_group = state.get_config().highlight_group

  for chunk_start = 0, line_count - 1, CHUNK_SIZE do
    local chunk_end = math.min(chunk_start + CHUNK_SIZE - 1, line_count - 1)
    local lines = api.nvim_buf_get_lines(bufnr, chunk_start, chunk_end + 1, false)

    for i, line in ipairs(lines) do
      local line_num = chunk_start + i

      local cached_data = get_cached_line(line, line_num, bufname)
      if cached_data then
        if cached_data.extmark then
          table_insert(extmarks, cached_data.extmark)
        end
        goto continue
      end

      if string_find(line, COMMENT_PATTERN) then
        goto continue
      end

      local eq_pos = string_find(line, "=")
      local key, actual_value, quote_char = process_line(line, eq_pos)

      if actual_value and #actual_value > 0 then
        local is_revealed = state.is_line_revealed(line_num)
        local raw_value = quote_char and (quote_char .. actual_value .. quote_char) or actual_value
        local masked_value = is_revealed and raw_value
          or utils.determine_masked_value(raw_value, {
            partial_mode = config_partial_mode,
            key = key,
            source = bufname,
          })

        if masked_value and #masked_value > 0 then
          local extmark = {
            line_num - 1,
            eq_pos,
            {
              virt_text = {
                { masked_value, (is_revealed or masked_value == raw_value) and "String" or config_highlight_group },
              },
              virt_text_pos = "overlay",
              hl_mode = "combine",
              priority = 9999,
              strict = true,
            },
          }

          table_insert(extmarks, extmark)

          cache_line(line, line_num, bufname, { extmark = extmark })
        end
      end
      ::continue::
    end
  end

  if #extmarks > 0 then
    local temp_ns = api.nvim_create_namespace("")

    for _, mark in ipairs(extmarks) do
      api.nvim_buf_set_extmark(bufnr, temp_ns, mark[1], mark[2], mark[3])
    end

    api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
    for _, mark in ipairs(extmarks) do
      api.nvim_buf_set_extmark(bufnr, namespace, mark[1], mark[2], mark[3])
    end
    api.nvim_buf_clear_namespace(bufnr, temp_ns, 0, -1)
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

  api.nvim_create_autocmd({ "BufWritePost", "BufEnter", "TextChanged", "TextChangedI", "TextChangedP" }, {
    pattern = watch_patterns,
    callback = function(ev)
      local filename = vim.fn.fnamemodify(ev.file, ":t")
      if utils.match_env_file(filename, config) then
        if state.is_enabled("files") then
          vim.cmd('noautocmd lua require("ecolog.shelter.buffer").shelter_buffer()')
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
