local M = {}

local api = vim.api
local state = require("ecolog.shelter.state")
local shelter_utils = require("ecolog.shelter.utils")
local buffer_utils = require("ecolog.shelter.buffer")
local LRUCache = require("ecolog.shelter.lru_cache")

local namespace = api.nvim_create_namespace("ecolog_shelter")
local processed_buffers = LRUCache.new(100)

---Process all lines with multi-line support and create extmarks
---@param bufnr number Buffer number
---@param lines string[] Lines to process
---@param content_hash string Content hash
---@param filename string Filename
---@param on_complete? function Optional callback when processing is complete
local function process_buffer_with_multiline(bufnr, lines, content_hash, filename, on_complete)
  if not api.nvim_buf_is_valid(bufnr) then
    return
  end

  local config = state.get_config()
  local skip_comments = state.get_buffer_state().skip_comments
  local utils = require("ecolog.utils")
  
  -- Parse all lines to handle multi-line values correctly
  local multi_line_state = {}
  local parsed_vars = {}
  local line_start_positions = {}
  local current_line_idx = 1
  
  while current_line_idx <= #lines do
    local line = lines[current_line_idx]
    
    -- Skip comment lines if configured
    local is_comment_line = line:find("^%s*#")
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
        eq_pos = lines[start_line]:find("=") or 1,
        is_comment = false,
      }
      
      -- Reset multi-line state after processing
      multi_line_state = {}
    end
    
    current_line_idx = current_line_idx + 1
    ::continue::
  end
  
  -- Create extmarks for all parsed variables
  local all_extmarks = {}
  for _, var_info in pairs(parsed_vars) do
    if skip_comments and var_info.is_comment then
      goto continue_var
    end

    if var_info.value and #var_info.value > 0 then
      -- Check if this is a multi-line value
      local is_multi_line_span = var_info.start_line < var_info.end_line
      local has_newlines = var_info.value:find("\n") ~= nil
      
      if is_multi_line_span or has_newlines then
        -- Handle multi-line values similar to buffer.lua
        local shelter_utils = require("ecolog.shelter.utils")
        local config_partial_mode = config.partial_mode
        local config_highlight_group = config.highlight_group
        
        local clean_value = has_newlines and var_info.value:gsub("\n", "") or var_info.value
        local entire_masked_value = shelter_utils.determine_masked_value(clean_value, {
          partial_mode = config_partial_mode,
          key = var_info.key,
          source = filename,
          quote_char = var_info.quote_char,
        })
        
        if entire_masked_value then
          if is_multi_line_span and not has_newlines then
            -- Backslash continuation
            local consumed_chars = 0
            for line_idx = var_info.start_line, var_info.end_line do
              local buffer_line = lines[line_idx]
              local is_first_line = line_idx == var_info.start_line
              local is_last_line = line_idx == var_info.end_line
              
              local parsed_content_part
              if is_first_line then
                local eq_pos = buffer_line:find("=")
                if eq_pos then
                  parsed_content_part = buffer_line:sub(eq_pos + 1):gsub("\\%s*$", "")
                else
                  parsed_content_part = ""
                end
              elseif is_last_line then
                parsed_content_part = buffer_line
              else
                parsed_content_part = buffer_line:gsub("\\%s*$", "")
              end
              
              local parsed_length = #parsed_content_part
              
              if parsed_length > 0 then
                local mask_for_parsed = entire_masked_value:sub(consumed_chars + 1, consumed_chars + parsed_length)
                consumed_chars = consumed_chars + parsed_length
                
                local extmark_opts = {
                  virt_text = {
                    { mask_for_parsed .. (buffer_line:match("\\%s*$") and "\\" or ""), config_highlight_group },
                  },
                  virt_text_pos = "overlay",
                  hl_mode = "combine",
                  priority = 9999,
                  strict = false,
                }
                
                local col_pos = is_first_line and var_info.eq_pos or 0
                table.insert(all_extmarks, { line_idx - 1, col_pos, extmark_opts })
              end
            end
          elseif has_newlines then
            -- Quoted multi-line
            local raw_lines = vim.split(var_info.value, "\n", { plain = true })
            local content_only_mask = entire_masked_value
            if var_info.quote_char and entire_masked_value:sub(1, 1) == var_info.quote_char then
              content_only_mask = entire_masked_value:sub(2, -2)
            end
            
            local consumed_chars = 0
            for line_idx = var_info.start_line, var_info.end_line do
              local array_idx = line_idx - var_info.start_line + 1
              local is_first_line = line_idx == var_info.start_line
              local is_last_line = line_idx == var_info.end_line
              local raw_line = raw_lines[array_idx] or ""
              local raw_length = #raw_line
              
              if raw_length > 0 then
                local mask_for_line = content_only_mask:sub(consumed_chars + 1, consumed_chars + raw_length)
                consumed_chars = consumed_chars + raw_length
                
                local display_mask = mask_for_line
                if is_first_line then
                  display_mask = (var_info.quote_char or "") .. mask_for_line
                elseif is_last_line then
                  display_mask = mask_for_line .. (var_info.quote_char or "")
                end
                
                local extmark_opts = {
                  virt_text = { { display_mask, config_highlight_group } },
                  virt_text_pos = "overlay",
                  hl_mode = "combine",
                  priority = 9999,
                  strict = false,
                }
                
                local col_pos = is_first_line and var_info.eq_pos or 0
                table.insert(all_extmarks, { line_idx - 1, col_pos, extmark_opts })
              end
            end
          end
        end
      else
        -- Single line value - use existing logic
        local extmark_result = buffer_utils.create_extmark(var_info.value, var_info, config, filename, var_info.start_line)
        if extmark_result then
          if type(extmark_result[1]) == "table" and extmark_result[1][1] then
            -- Array of extmarks
            for _, extmark in ipairs(extmark_result) do
              table.insert(all_extmarks, extmark)
            end
          else
            -- Single extmark
            table.insert(all_extmarks, extmark_result)
          end
        end
      end
    end
    ::continue_var::
  end
  
  -- Apply all extmarks
  if #all_extmarks > 0 then
    vim.schedule(function()
      if api.nvim_buf_is_valid(bufnr) then
        for _, mark in ipairs(all_extmarks) do
          pcall(api.nvim_buf_set_extmark, bufnr, namespace, mark[1], mark[2], mark[3])
        end
      end
    end)
  end
  
  -- Complete processing
  if on_complete then
    on_complete(content_hash)
  else
    processed_buffers:put(bufnr, content_hash)
  end
end

---Check if a buffer needs processing based on its content hash
---@param bufnr number Buffer number
---@param content_hash string Content hash
---@param cache table? Optional cache table to use instead of global cache
---@return boolean needs_processing
function M.needs_processing(bufnr, content_hash, cache)
  local cache_to_use = cache or processed_buffers
  local cached = cache_to_use:get(bufnr)

  if type(cached) == "table" then
    return not cached.hash or cached.hash ~= content_hash
  end

  return not cached or cached ~= content_hash
end

---Reset buffer settings to user's preferences for non-env files
---@param bufnr number Buffer number
---@param force boolean? Force reset even if buffer wasn't modified
---@param from_setup boolean? Whether this is called from setup_preview_buffer
function M.reset_buffer_settings(bufnr, force, from_setup)
  if not api.nvim_buf_is_valid(bufnr) then
    return
  end

  local has_env_settings = false
  local ok, val = pcall(api.nvim_buf_get_var, bufnr, "ecolog_env_settings")
  if ok and val then
    has_env_settings = true
  end

  if not has_env_settings and not force then
    return
  end

  local original_settings = {}
  ok, val = pcall(api.nvim_buf_get_var, bufnr, "ecolog_original_settings")
  if ok and val then
    original_settings = val
  end

  local wrap_setting = original_settings.wrap
  if from_setup then
    local config = require("ecolog").get_config and require("ecolog").get_config() or {}
    wrap_setting = config.default_wrap ~= nil and config.default_wrap or vim.o.wrap
  else
    wrap_setting = wrap_setting or vim.o.wrap
  end

  local conceallevel_setting = original_settings.conceallevel or vim.o.conceallevel
  local concealcursor_setting = original_settings.concealcursor or vim.o.concealcursor

  for _, winid in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(winid) == bufnr then
      pcall(api.nvim_win_set_option, winid, "wrap", wrap_setting)
      pcall(api.nvim_win_set_option, winid, "conceallevel", conceallevel_setting)
      pcall(api.nvim_win_set_option, winid, "concealcursor", concealcursor_setting)
      break
    end
  end

  pcall(api.nvim_buf_set_var, bufnr, "ecolog_env_settings", false)
end

---@param bufnr number
---@param filename string? Optional filename to check if it's an env file
function M.setup_preview_buffer(bufnr, filename)
  if not filename then
    return
  end

  local config = require("ecolog").get_config and require("ecolog").get_config() or {}
  local is_env_file = shelter_utils.match_env_file(filename, config)

  if is_env_file then
    local original_settings = {}

    for _, winid in ipairs(api.nvim_list_wins()) do
      if api.nvim_win_get_buf(winid) == bufnr then
        original_settings.wrap = vim.wo[winid].wrap
        original_settings.conceallevel = vim.wo[winid].conceallevel
        original_settings.concealcursor = vim.wo[winid].concealcursor
        break
      end
    end

    pcall(api.nvim_buf_set_var, bufnr, "ecolog_original_settings", original_settings)

    for _, winid in ipairs(api.nvim_list_wins()) do
      if api.nvim_win_get_buf(winid) == bufnr then
        pcall(api.nvim_win_set_option, winid, "wrap", false)
        pcall(api.nvim_win_set_option, winid, "conceallevel", 2)
        pcall(api.nvim_win_set_option, winid, "concealcursor", "nvic")
        break
      end
    end

    pcall(api.nvim_buf_set_var, bufnr, "ecolog_env_settings", true)
  else
    M.reset_buffer_settings(bufnr, nil, true)
  end
end

---Process a buffer and apply masking
---@param bufnr number Buffer number
---@param source_filename string? Source filename
---@param cache table? Optional cache table to use instead of global cache
---@param on_complete? function Optional callback when processing is complete
function M.process_buffer(bufnr, source_filename, cache, on_complete)
  if not bufnr or not api.nvim_buf_is_valid(bufnr) then
    return
  end

  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local content_hash = vim.fn.sha256(table.concat(lines, "\n"))
  local filename = source_filename or vim.fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":t")

  pcall(api.nvim_buf_clear_namespace, bufnr, namespace, 0, -1)
  pcall(api.nvim_buf_set_var, bufnr, "ecolog_masked", true)

  M.setup_preview_buffer(bufnr, filename)
  process_buffer_with_multiline(bufnr, lines, content_hash, filename, on_complete)
end

---@param bufnr number
---@param filename string
---@param integration_name string
function M.mask_preview_buffer(bufnr, filename, integration_name)
  if not bufnr or not api.nvim_buf_is_valid(bufnr) then
    return
  end

  local config = require("ecolog").get_config and require("ecolog").get_config() or {}
  local is_env_file = shelter_utils.match_env_file(filename, config)

  if not (is_env_file and state.is_enabled(integration_name .. "_previewer")) then
    return
  end

  M.process_buffer(bufnr, filename)
end

return M
