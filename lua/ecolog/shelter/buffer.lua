---@class EcologShelterBuffer
---@field NAMESPACE number Namespace ID for buffer highlights and virtual text
local M = {}

---@class KeyValueResult
---@field key string The key part of the key-value pair
---@field value string The value part of the key-value pair
---@field quote_char string? The quote character used (if any)
---@field eq_pos number Position of the equals sign
---@field next_pos number Position after the value

---@class ProcessedItem
---@field key string The key part of the key-value pair
---@field value string The value part of the key-value pair
---@field quote_char string? The quote character used (if any)
---@field eq_pos number Position of the equals sign
---@field is_comment boolean Whether this item was found in a comment

---@class ExtmarkData
---@field line_num number The line number
---@field eq_pos number Position of the equals sign
---@field extmarks table[] Array of extmark data

local api = vim.api
local string_find = string.find
local string_sub = string.sub
local string_match = string.match
local table_insert = table.insert
local fn = vim.fn
local pcall = pcall

local state = require("ecolog.shelter.state")
local shelter_utils = require("ecolog.shelter.utils")
local main_utils = require("ecolog.utils")
local lru_cache = require("ecolog.shelter.lru_cache")

local NAMESPACE = api.nvim_create_namespace("ecolog_shelter")
local CHUNK_SIZE = 1000
local CLEANUP_INTERVAL = 300000
local BUFFER_TIMEOUT = 3600000
local COMMENT_PATTERN = "^#"
local KEY_PATTERN = "^%s*(.-)%s*$"
local VALUE_PATTERN = "^%s*(.-)%s*$"
local BATCH_SIZE = 100

local line_cache = lru_cache.new(1000)
local active_buffers = setmetatable({}, { __mode = "k" })
local string_buffer = table.new and table.new(1000, 0) or {}

M.NAMESPACE = NAMESPACE

---@param text string
---@param start_pos number?
---@param multi_line_state table? Multi-line parsing state
---@return KeyValueResult?
---@return table? multi_line_state Updated multi-line state
M.find_next_key_value = function(text, start_pos, multi_line_state)
  vim.validate("text", text, "string")
  vim.validate("start_pos", start_pos, "number", true)

  start_pos = start_pos or 1
  if start_pos > #text then
    return nil, multi_line_state
  end

  local eq_pos = string_find(text, "=", start_pos)
  if not eq_pos then
    return nil, multi_line_state
  end

  -- Find the key by scanning backwards from equals sign
  local key_start = eq_pos
  while key_start > start_pos do
    local char = text:sub(key_start - 1, key_start - 1)
    if char:match("[%s#]") then
      break
    end
    key_start = key_start - 1
  end

  local key = string_match(string_sub(text, key_start, eq_pos - 1), KEY_PATTERN)
  if not key or #key == 0 then
    return M.find_next_key_value(text, eq_pos + 1, multi_line_state)
  end

  local value_part = text:sub(eq_pos + 1)
  

  -- Handle quoted values
  local pos = eq_pos + 1
  local quote_char = text:sub(pos, pos)
  local in_quotes = quote_char == '"' or quote_char == "'"

  local value
  if in_quotes then
    pos = pos + 1
    local value_end = nil
    while pos <= #text do
      if text:sub(pos, pos) == quote_char and text:sub(pos - 1, pos - 1) ~= "\\" then
        value_end = pos
        break
      end
      pos = pos + 1
    end

    if value_end then
      value = text:sub(eq_pos + 2, value_end - 1)
      pos = value_end + 1
    else
      return M.find_next_key_value(text, eq_pos + 1, multi_line_state)
    end
  else
    -- Handle unquoted values
    while pos <= #text do
      local char = text:sub(pos, pos)
      if char:match("[%s#]") then
        break
      end
      pos = pos + 1
    end
    value = string_match(text:sub(eq_pos + 1, pos - 1), VALUE_PATTERN)
  end

  if not value or #value == 0 then
    return M.find_next_key_value(text, eq_pos + 1, multi_line_state)
  end

  return {
    key = key,
    value = value,
    quote_char = in_quotes and quote_char or nil,
    eq_pos = eq_pos,
    next_pos = pos,
  }, multi_line_state
end

---@param line string
---@param multi_line_state table? Multi-line parsing state
---@return ProcessedItem[]
---@return table? multi_line_state Updated multi-line state
function M.process_line(line, multi_line_state)
  vim.validate("line", line, "string")

  local results = {}
  local comment_start = string_find(line, "#")
  local is_comment_line = comment_start == 1

  if not is_comment_line then
    local kv, updated_state = M.find_next_key_value(line, nil, multi_line_state)
    if kv and (not comment_start or kv.eq_pos < comment_start) then
      table_insert(results, {
        key = kv.key,
        value = kv.value,
        quote_char = kv.quote_char,
        eq_pos = kv.eq_pos,
        is_comment = false,
      })
    end
    multi_line_state = updated_state
  end

  if comment_start then
    local comment_text = string_sub(line, comment_start + 1)
    local pos = 1

    while true do
      local kv, updated_state = M.find_next_key_value(comment_text, pos, multi_line_state)
      if not kv then
        break
      end

      table_insert(results, {
        key = kv.key,
        value = kv.value,
        quote_char = kv.quote_char,
        eq_pos = comment_start + kv.eq_pos,
        is_comment = true,
      })

      pos = kv.next_pos
      multi_line_state = updated_state
    end
  end

  return results, multi_line_state
end

---@param line string
---@param line_num number
---@param bufname string
---@return ExtmarkData?
local function get_cached_line(line, line_num, bufname)
  vim.validate("line", line, "string")
  vim.validate("line_num", line_num, "number")
  vim.validate("bufname", bufname, "string")

  local cache_key = string.format("%s:%d:%s", bufname, line_num, vim.fn.sha256(line))
  return line_cache:get(cache_key)
end

---@param line string
---@param line_num number
---@param bufname string
---@param extmark table
local function cache_line(line, line_num, bufname, extmark)
  vim.validate("line", line, "string")
  vim.validate("line_num", line_num, "number")
  vim.validate("bufname", bufname, "string")
  vim.validate("extmark", extmark, "table")

  local cache_key = string.format("%s:%d:%s", bufname, line_num, vim.fn.sha256(line))
  local existing = line_cache:get(cache_key)
  if existing then
    if not existing.extmarks then
      existing.extmarks = {}
    end
    table_insert(existing.extmarks, extmark)
    line_cache:put(cache_key, existing)
  else
    line_cache:put(cache_key, { extmarks = { extmark } })
  end
end

local function cleanup_invalid_buffers()
  local current_time = vim.loop.now()
  for bufnr, timestamp in pairs(active_buffers) do
    if not api.nvim_buf_is_valid(bufnr) or (current_time - timestamp) > BUFFER_TIMEOUT then
      pcall(api.nvim_buf_clear_namespace, bufnr, NAMESPACE, 0, -1)
      line_cache:remove(bufnr)
      active_buffers[bufnr] = nil
    end
  end
end

---@param bufnr number
---@return boolean
local function is_buffer_valid(bufnr)
  return type(bufnr) == "number" and api.nvim_buf_is_valid(bufnr)
end

---@param ... string
---@return string
local function fast_concat(...)
  local n = select("#", ...)
  for i = 1, n do
    local value = select(i, ...)
    string_buffer[i] = value ~= nil and tostring(value) or ""
  end
  local result = table.concat(string_buffer, "", 1, n)
  for i = 1, n do
    string_buffer[i] = nil
  end
  return result
end

function M.unshelter_buffer()
  local bufnr = api.nvim_get_current_buf()
  if not is_buffer_valid(bufnr) then
    vim.notify("Invalid buffer", vim.log.levels.WARN)
    return
  end

  local winid = api.nvim_get_current_win()
  api.nvim_win_set_option(winid, "conceallevel", 0)
  api.nvim_win_set_option(winid, "concealcursor", "")

  api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)
  state.reset_revealed_lines()
  active_buffers[bufnr] = nil

  if state.get_buffer_state().disable_cmp then
    vim.b.completion = true
    if shelter_utils.has_cmp() then
      require("cmp").setup.buffer({ enabled = true })
    end
  end
end

---@param bufnr number
---@param winid number
local function setup_buffer_options(bufnr, winid)
  vim.opt_local.wrap = false

  api.nvim_win_set_option(winid, "conceallevel", 2)
  api.nvim_win_set_option(winid, "concealcursor", "nvic")
  active_buffers[bufnr] = vim.loop.now()

  if vim.loop.now() % CLEANUP_INTERVAL == 0 then
    cleanup_invalid_buffers()
  end

  if state.get_buffer_state().disable_cmp then
    vim.b.completion = false
    if shelter_utils.has_cmp() then
      require("cmp").setup.buffer({ enabled = false })
    end
  end
end

---@param value string
---@param item ProcessedItem
---@param config table
---@param bufname string
---@param line_num number
---@return table|table[]? extmark(s) Single extmark or array of extmarks for multi-line values
function M.create_extmark(value, item, config, bufname, line_num)
  local is_revealed = state.is_line_revealed(line_num)
  local raw_value = item.quote_char and (item.quote_char .. value .. item.quote_char) or value

  local masked_value = is_revealed and raw_value
    or shelter_utils.determine_masked_value(value, {
      partial_mode = config.partial_mode,
      key = item.key,
      source = bufname,
      quote_char = item.quote_char,
    })

  if not masked_value or #masked_value == 0 then
    return nil
  end

  local mask_length = state.get_config().mask_length
  
  -- Check if this is a multi-line value
  local is_multi_line = masked_value:find("\n") ~= nil
  if is_multi_line then
    return M.create_multi_line_extmarks(raw_value, masked_value, item, config, line_num)
  end

  local extmark_opts = {
    virt_text = {
      { masked_value, (is_revealed or masked_value == raw_value) and "String" or config.highlight_group },
    },
    virt_text_pos = "overlay",
    hl_mode = "combine",
    priority = item.is_comment and 10000 or 9999,
    strict = false,
  }

  if mask_length then
    local padding = string.rep(" ", math.max(0, #raw_value - #masked_value))
    extmark_opts.virt_text = {
      { masked_value .. padding, (is_revealed or masked_value == raw_value) and "String" or config.highlight_group },
    }
  end

  return {
    line_num - 1,
    item.eq_pos,
    extmark_opts,
  }
end

---Create extmarks for multi-line values
---@param raw_value string The original raw value
---@param masked_value string The masked value
---@param item ProcessedItem The processed item
---@param config table Configuration
---@param start_line_num number The starting line number
---@return table[] extmarks Array of extmarks for each line
function M.create_multi_line_extmarks(raw_value, masked_value, item, config, start_line_num)
  local raw_lines = vim.split(raw_value, "\n", { plain = true })
  local masked_lines = vim.split(masked_value, "\n", { plain = true })
  local extmarks = {}
  
  for i, masked_line in ipairs(masked_lines) do
    local line_num = start_line_num + i - 1
    local is_revealed = state.is_line_revealed(line_num)
    local display_value = is_revealed and (raw_lines[i] or "") or masked_line
    
    local extmark_opts = {
      virt_text = {
        { display_value, (is_revealed or display_value == (raw_lines[i] or "")) and "String" or config.highlight_group },
      },
      virt_text_pos = "overlay",
      hl_mode = "combine",
      priority = item.is_comment and 10000 or 9999,
      strict = false,
    }
    
    -- For the first line, use the equals position; for subsequent lines, start at column 0
    local col_pos = i == 1 and item.eq_pos or 0
    
    table.insert(extmarks, {
      line_num - 1,
      col_pos,
      extmark_opts,
    })
  end
  
  return extmarks
end

---@param bufnr number
---@param extmarks table[]
local function apply_extmarks(bufnr, extmarks)
  if #extmarks == 0 then
    return
  end

  pcall(api.nvim_buf_clear_namespace, bufnr, NAMESPACE, 0, -1)

  for i = 1, #extmarks, BATCH_SIZE do
    local batch_end = math.min(i + BATCH_SIZE - 1, #extmarks)
    for j = i, batch_end do
      local mark = extmarks[j]
      pcall(api.nvim_buf_set_extmark, bufnr, NAMESPACE, mark[1], mark[2], mark[3])
    end
  end
end

function M.shelter_buffer()
  local config = require("ecolog").get_config and require("ecolog").get_config() or {}
  local bufname = fn.bufname()

  if not shelter_utils.match_env_file(bufname, config) then
    return
  end

  local bufnr = api.nvim_get_current_buf()
  if not is_buffer_valid(bufnr) then
    vim.notify("Invalid buffer", vim.log.levels.WARN)
    return
  end

  local winid = api.nvim_get_current_win()
  setup_buffer_options(bufnr, winid)

  local line_count = api.nvim_buf_line_count(bufnr)
  local extmarks = {}
  local config_partial_mode = state.get_config().partial_mode
  local config_highlight_group = state.get_config().highlight_group
  local skip_comments = state.get_config().skip_comments
  
  -- Read all lines at once for proper multi-line parsing
  local ok, all_lines = pcall(api.nvim_buf_get_lines, bufnr, 0, -1, false)
  if not ok then
    vim.notify("Failed to get buffer lines", vim.log.levels.ERROR)
    return
  end

  -- Parse the buffer content using the multi-line parser
  local utils = require("ecolog.utils")
  local types = require("ecolog.types")
  local multi_line_state = {}
  local parsed_vars = {}
  local current_line_idx = 1
  
  -- Parse all lines sequentially to handle multi-line values correctly
  local line_start_positions = {}  -- Track where each variable starts
  local line_spans = {}  -- Track line spans for multi-line values
  
  while current_line_idx <= #all_lines do
    local line = all_lines[current_line_idx]
    
    local is_comment_line = string_find(line, COMMENT_PATTERN)
    if is_comment_line and skip_comments then
      current_line_idx = current_line_idx + 1
      goto continue
    end

    local key, value, comment, quote_char, updated_state = utils.extract_line_parts(line, multi_line_state)
    
    -- Track the start of a new variable BEFORE we enter multi-line mode
    if not multi_line_state.in_multi_line and line:find("=") then
      local potential_key = line:match("^%s*([^=]+)%s*=")
      if potential_key then
        line_start_positions[potential_key] = current_line_idx
      end
    end
    
    -- If we're entering multi-line mode, track the key start position
    if updated_state and updated_state.in_multi_line and updated_state.key and not line_start_positions[updated_state.key] then
      line_start_positions[updated_state.key] = current_line_idx
    end
    
    -- Update multi-line state after tracking start position
    multi_line_state = updated_state or multi_line_state
    
    if key and value then
      -- This is a complete key-value pair
      local start_line = line_start_positions[key] or current_line_idx
      local end_line = current_line_idx
      
      parsed_vars[key] = {
        key = key,
        value = value,
        quote_char = quote_char,
        comment = comment,
        start_line = start_line,
        end_line = end_line,
        eq_pos = all_lines[start_line]:find("=") or 1,
        is_comment = false,
      }
      
      -- Store line span for multi-line values
      if start_line < end_line then
        line_spans[key] = {
          start_line = start_line,
          end_line = end_line,
        }
      end
      
      -- Reset multi-line state after processing
      multi_line_state = {}
    end
    
    current_line_idx = current_line_idx + 1
    ::continue::
  end
  
  -- Create extmarks for all variables
  for _, var_info in pairs(parsed_vars) do
    if skip_comments and var_info.is_comment then
      goto continue_var
    end

    if var_info.value and #var_info.value > 0 then
      -- Check if this is a multi-line value that spans multiple buffer lines
      local is_multi_line_span = var_info.start_line < var_info.end_line
      -- Check if the value contains newlines (quoted multi-line)
      local has_newlines = var_info.value:find("\n") ~= nil
      
      if is_multi_line_span or has_newlines then
        -- Handle both backslash continuation and quoted multi-line - mask entire value, then distribute across buffer lines
        -- For multi-line values, we need to mask the entire value as a single unit, not per line
        local clean_value = has_newlines and var_info.value:gsub("\n", "") or var_info.value
        local entire_masked_value = shelter_utils.determine_masked_value(clean_value, {
          partial_mode = config_partial_mode,
          key = var_info.key,
          source = bufname,
          quote_char = var_info.quote_char,
        })
        
        if entire_masked_value then
          if is_multi_line_span and not has_newlines then
            -- Backslash continuation - distribute mask based on actual parsed content including spaces
            local consumed_chars = 0
            for line_idx = var_info.start_line, var_info.end_line do
              local buffer_line = all_lines[line_idx]
              local is_first_line = line_idx == var_info.start_line
              local is_last_line = line_idx == var_info.end_line
              
              -- Get the actual content on this line as it appears in the parsed value
              local parsed_content_part
              if is_first_line then
                local eq_pos = buffer_line:find("=")
                if eq_pos then
                  -- For first line, remove trailing backslash and spaces but keep the content as parsed
                  parsed_content_part = buffer_line:sub(eq_pos + 1):gsub("\\%s*$", "")
                else
                  parsed_content_part = ""
                end
              elseif is_last_line then
                -- Last line: keep as is
                parsed_content_part = buffer_line
              else
                -- Middle lines: remove trailing backslash and spaces 
                parsed_content_part = buffer_line:gsub("\\%s*$", "")
              end
              
              local parsed_length = #parsed_content_part
              
              if parsed_length > 0 then
                -- Get the mask portion for this parsed content
                local mask_for_parsed = entire_masked_value:sub(consumed_chars + 1, consumed_chars + parsed_length)
                consumed_chars = consumed_chars + parsed_length
                
                if is_first_line then
                  local eq_pos = buffer_line:find("=")
                  if eq_pos then
                    -- For first line, preserve the backslash if it exists
                    local has_backslash = buffer_line:match("\\%s*$")
                    local display_mask = mask_for_parsed .. (has_backslash and "\\" or "")
                    
                    local extmark_opts = {
                      virt_text = { { display_mask, config_highlight_group } },
                      virt_text_pos = "overlay",
                      hl_mode = "combine",
                      priority = 9999,
                      strict = false,
                    }
                    table_insert(extmarks, { line_idx - 1, eq_pos, extmark_opts })
                  end
                else
                  -- For other lines, preserve the backslash if it exists
                  local has_backslash = buffer_line:match("\\%s*$")
                  local display_mask = mask_for_parsed .. (has_backslash and "\\" or "")
                  
                  local extmark_opts = {
                    virt_text = { { display_mask, config_highlight_group } },
                    virt_text_pos = "overlay",
                    hl_mode = "combine",
                    priority = 9999,
                    strict = false,
                  }
                  table_insert(extmarks, { line_idx - 1, 0, extmark_opts })
                end
              end
            end
            
          elseif has_newlines then
            -- Quoted multi-line - distribute based on actual buffer content
            local raw_lines = vim.split(var_info.value, "\n", { plain = true })
            
            -- Remove quotes from the masked value for distribution
            local content_only_mask = entire_masked_value
            if var_info.quote_char and entire_masked_value:sub(1, 1) == var_info.quote_char then
              content_only_mask = entire_masked_value:sub(2, -2)  -- Remove first and last quote
            end
            
            local consumed_chars = 0
            
            for line_idx = var_info.start_line, var_info.end_line do
              local array_idx = line_idx - var_info.start_line + 1
              local buffer_line = all_lines[line_idx]
              local is_first_line = line_idx == var_info.start_line
              local is_last_line = line_idx == var_info.end_line
              local raw_line = raw_lines[array_idx] or ""
              local raw_length = #raw_line
              
              if raw_length > 0 then
                local mask_for_line = content_only_mask:sub(consumed_chars + 1, consumed_chars + raw_length)
                consumed_chars = consumed_chars + raw_length
                
                if is_first_line then
                  local eq_pos = buffer_line:find("=")
                  if eq_pos then
                    -- For first line, include the opening quote
                    local display_mask = (var_info.quote_char or "") .. mask_for_line
                    
                    local extmark_opts = {
                      virt_text = { { display_mask, config_highlight_group } },
                      virt_text_pos = "overlay",
                      hl_mode = "combine",
                      priority = 9999,
                      strict = false,
                    }
                    table_insert(extmarks, { line_idx - 1, eq_pos, extmark_opts })
                  end
                else
                  -- For other lines, check if it's the last line for closing quote
                  local display_mask = mask_for_line .. (is_last_line and (var_info.quote_char or "") or "")
                  
                  local extmark_opts = {
                    virt_text = { { display_mask, config_highlight_group } },
                    virt_text_pos = "overlay",
                    hl_mode = "combine",
                    priority = 9999,
                    strict = false,
                  }
                  table_insert(extmarks, { line_idx - 1, 0, extmark_opts })
                end
              end
            end
          end
        end
      else
        -- Single line value - use existing logic
        local extmark_result = M.create_extmark(var_info.value, var_info, {
          partial_mode = config_partial_mode,
          highlight_group = config_highlight_group,
        }, bufname, var_info.start_line)

        if extmark_result then
          -- Handle both single extmarks and arrays of extmarks (multi-line)
          if type(extmark_result[1]) == "table" and extmark_result[1][1] then
            -- Array of extmarks (multi-line)
            for _, extmark in ipairs(extmark_result) do
              table_insert(extmarks, extmark)
            end
          else
            -- Single extmark
            table_insert(extmarks, extmark_result)
          end
        end
      end
    end
    ::continue_var::
  end

  apply_extmarks(bufnr, extmarks)
end

---@param config table
---@return table
local function setup_buffer_state(config)
  local shelter_config = type(config.shelter) == "table"
      and type(config.shelter.modules) == "table"
      and type(config.shelter.modules.files) == "table"
      and config.shelter.modules.files
    or {}

  local buffer_state = {
    disable_cmp = type(shelter_config) == "table" and shelter_config.disable_cmp ~= false or false,
    revealed_lines = {},
  }
  state.set_buffer_state(buffer_state)
  return buffer_state
end

---@param config table
---@param group number
local function setup_buffer_autocmds(config, group)
  local watch_patterns = main_utils.get_watch_patterns(config)
  
  -- Add monorepo workspace patterns if in monorepo mode
  if config._monorepo_root then
    local monorepo_patterns = {}
    local base_patterns = config.env_file_patterns or { ".env", ".envrc", ".env.*" }
    
    -- Add patterns for monorepo root and all workspaces
    for _, pattern in ipairs(base_patterns) do
      table.insert(monorepo_patterns, config._monorepo_root .. "/" .. pattern)
      table.insert(monorepo_patterns, config._monorepo_root .. "/**/" .. pattern)
    end
    
    -- Extend existing patterns with monorepo patterns
    for _, pattern in ipairs(monorepo_patterns) do
      table.insert(watch_patterns, pattern)
    end
  end
  
  if #watch_patterns == 0 then
    watch_patterns = { ".env*" }
  end

  -- BufReadCmd handler
  api.nvim_create_autocmd("BufReadCmd", {
    pattern = watch_patterns,
    group = group,
    callback = function(ev)
      if not shelter_utils.match_env_file(ev.file, config) then
        return
      end

      local bufnr = ev.buf
      local ok, err = pcall(function()
        vim.cmd("keepalt edit " .. fn.fnameescape(ev.file))

        local ft = vim.filetype.match({ filename = ev.file })
        if ft then
          vim.bo[bufnr].filetype = ft
        else
          vim.bo[bufnr].filetype = "sh"
        end

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

  -- Buffer modification handlers
  api.nvim_create_autocmd({ "BufWritePost", "BufEnter", "TextChanged", "TextChangedI", "TextChangedP" }, {
    pattern = watch_patterns,
    group = group,
    callback = function(ev)
      if shelter_utils.match_env_file(ev.file, config) then
        if state.is_enabled("files") then
          vim.cmd('noautocmd lua require("ecolog.shelter.buffer").shelter_buffer()')
        else
          M.unshelter_buffer()
        end
      end
    end,
  })

  -- Buffer leave handler
  api.nvim_create_autocmd("BufLeave", {
    pattern = watch_patterns,
    group = group,
    callback = function(ev)
      if shelter_utils.match_env_file(ev.file, config) and state.get_config().shelter_on_leave then
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
  })
end

---@param config table
---@return table
local function setup_paste_override(config)
  local original_paste = vim.paste
  vim.paste = (function()
    return function(lines, phase)
      local bufnr = api.nvim_get_current_buf()
      local filename = fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":t")

      if not shelter_utils.match_env_file(filename, config) or not state.is_enabled("files") then
        return original_paste(lines, phase)
      end

      if type(lines) == "string" then
        lines = vim.split(lines, "\n", { plain = true })
      end

      if not lines or #lines == 0 then
        return true
      end

      local cursor = api.nvim_win_get_cursor(0)
      local row, col = cursor[1], cursor[2]
      local current_line = api.nvim_get_current_line()
      local pre = current_line:sub(1, col)
      local post = current_line:sub(col + 1)

      local new_lines = {}
      if #lines == 1 then
        new_lines[1] = fast_concat(pre or "", lines[1] or "", post or "")
      else
        new_lines[1] = fast_concat(pre or "", lines[1] or "")
        for i = 2, #lines - 1 do
          new_lines[i] = lines[i] or ""
        end
        if #lines > 1 then
          new_lines[#lines] = fast_concat(lines[#lines] or "", post or "")
        end
      end

      pcall(api.nvim_buf_set_lines, bufnr, row - 1, row, false, new_lines)

      local new_row = row + #new_lines - 1
      local new_col = #new_lines == 1 and col + (lines[1] and #lines[1] or 0) or (lines[#lines] and #lines[#lines] or 0)
      pcall(api.nvim_win_set_cursor, 0, { new_row, new_col })

      return true
    end
  end)()
end

function M.setup_file_shelter()
  local group = api.nvim_create_augroup("ecolog_shelter", { clear = true })
  local config = require("ecolog").get_config and require("ecolog").get_config() or {}

  setup_buffer_state(config)
  setup_buffer_autocmds(config, group)
  setup_paste_override(config)
end

-- Refresh shelter when monorepo workspace changes
function M.refresh_shelter_for_monorepo()
  -- Clear existing autocmds
  pcall(api.nvim_del_augroup_by_name, "ecolog_shelter")
  
  -- Re-setup with current config (which should include updated monorepo context)
  M.setup_file_shelter()
  
  -- Re-apply masking to current buffer if it's an env file
  local current_file = fn.bufname()
  local config = require("ecolog").get_config and require("ecolog").get_config() or {}
  if current_file and shelter_utils.match_env_file(current_file, config) and state.is_enabled("files") then
    vim.schedule(function()
      M.shelter_buffer()
    end)
  end
end

---@param line_num number The line number to clear from cache
---@param bufname string The buffer name
---@return boolean success Whether the cache was successfully cleared
function M.clear_line_cache(line_num, bufname)
  vim.validate("line_num", line_num, "number")
  vim.validate("bufname", bufname, "string")

  local ok, line = pcall(api.nvim_buf_get_lines, 0, line_num - 1, line_num, false)
  if not ok or not line or #line == 0 then
    return false
  end

  local cache_key = string.format("%s:%d:%s", bufname, line_num, vim.fn.sha256(line[1]))
  line_cache:remove(cache_key)
  return true
end

return M
