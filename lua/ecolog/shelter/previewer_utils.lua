local M = {}

local api = vim.api
local state = require("ecolog.shelter.state")
local utils = require("ecolog.utils")
local shelter_utils = require("ecolog.shelter.utils")

local namespace = api.nvim_create_namespace("ecolog_shelter")

local processed_buffers = {}

local function process_extmarks(bufnr, lines, start_idx, end_idx)
  local extmarks = {}

  for i = start_idx, end_idx do
    local line = lines[i]
    local key, value, eq_pos = utils.parse_env_line(line)

    if key and value then
      local quote_char, actual_value = utils.extract_quoted_value(value)

      if actual_value then
        local masked_value = shelter_utils.determine_masked_value(actual_value, {
          partial_mode = state.get_config().partial_mode,
          key = key,
        })

        if masked_value and #masked_value > 0 then
          if quote_char then
            masked_value = quote_char .. masked_value .. quote_char
          end

          extmarks[#extmarks + 1] = {
            i - 1,
            eq_pos,
            {
              virt_text = { { masked_value, state.get_config().highlight_group } },
              virt_text_pos = "overlay",
              hl_mode = "combine",
            },
          }
        end
      end
    end
  end

  if #extmarks > 0 then
    for _, mark in ipairs(extmarks) do
      pcall(api.nvim_buf_set_extmark, bufnr, namespace, mark[1], mark[2], mark[3])
    end
  end
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

  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local content_hash = vim.fn.sha256(table.concat(lines, "\n"))

  if processed_buffers[bufnr] and processed_buffers[bufnr].hash == content_hash then
    return
  end

  pcall(api.nvim_buf_set_var, bufnr, "ecolog_masked", true)

  local chunk_size = 100
  for i = 1, #lines, chunk_size do
    local end_idx = math.min(i + chunk_size - 1, #lines)
    vim.schedule(function()
      process_extmarks(bufnr, lines, i, end_idx)
    end)
  end

  processed_buffers[bufnr] = { hash = content_hash, timestamp = vim.loop.now() }

  if vim.tbl_count(processed_buffers) > 100 then
    local current_time = vim.loop.now()
    for buf, info in pairs(processed_buffers) do
      if current_time - info.timestamp > 300000 then -- 5 minutes
        processed_buffers[buf] = nil
      end
    end
  end
end

return M 