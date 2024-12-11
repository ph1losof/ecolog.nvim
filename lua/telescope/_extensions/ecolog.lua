local has_telescope, telescope = pcall(require, "telescope")
if not has_telescope then
  error("This extension requires telescope.nvim (https://github.com/nvim-telescope/telescope.nvim)")
end

local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values

local ecolog = require("ecolog")
local shelter = require("ecolog.shelter")

-- Default configuration
local config = {
  shelter = {
    -- Whether to show masked values when copying to clipboard
    mask_on_copy = false,
  },
  -- Default keybindings
  mappings = {
    -- Key to copy value to clipboard
    copy_value = "<C-y>",
    -- Key to copy name to clipboard
    copy_name = "<C-n>",
    -- Key to append value to buffer
    append_value = "<C-a>",
    -- Key to append name to buffer (defaults to <CR>)
    append_name = "<CR>",
  },
}

local function setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
end

local function get_masked_value(value)
  return shelter.mask_value(value, "telescope")
end

local function env_picker(opts)
  opts = opts or {}
  opts = vim.tbl_deep_extend("force", {
    layout_strategy = "vertical",
    layout_config = {
      width = 0.8,
      height = 0.8,
      preview_height = 0.6,
    },
  }, opts)

  local results = {}
  for var_name, var_info in pairs(ecolog.get_env_vars()) do
    table.insert(results, {
      name = var_name,
      value = var_info.value,
      source = var_info.source,
      type = var_info.type,
    })
  end

  pickers
    .new(opts, {
      prompt_title = "Environment Variables",
      finder = finders.new_table({
        results = results,
        entry_maker = function(entry)
          local display_value = get_masked_value(entry.value)
          return {
            value = entry,
            display = string.format("%-30s = %s", entry.name, display_value),
            ordinal = entry.name,
          }
        end,
      }),
      previewer = false,
      sorter = conf.generic_sorter(opts),
      attach_mappings = function(prompt_bufnr, map)
        -- Copy value to clipboard
        if config.mappings.copy_value then
          map("i", config.mappings.copy_value, function()
            local selection = action_state.get_selected_entry()
            local value = config.shelter.mask_on_copy and get_masked_value(selection.value.value)
              or selection.value.value
            vim.fn.setreg("+", value)
            actions.close(prompt_bufnr)
            vim.notify("Copied value to clipboard", vim.log.levels.INFO)
          end)
        end

        -- Copy name to clipboard
        if config.mappings.copy_name then
          map("i", config.mappings.copy_name, function()
            local selection = action_state.get_selected_entry()
            vim.fn.setreg("+", selection.value.name)
            actions.close(prompt_bufnr)
            vim.notify("Copied variable name to clipboard", vim.log.levels.INFO)
          end)
        end

        -- Append environment name to buffer
        if config.mappings.append_name then
          local append_name_fn = function()
            local selection = action_state.get_selected_entry()
            actions.close(prompt_bufnr)
            local cursor = vim.api.nvim_win_get_cursor(0)
            local line = vim.api.nvim_get_current_line()
            local new_line = line:sub(1, cursor[2]) .. selection.value.name .. line:sub(cursor[2] + 1)
            vim.api.nvim_set_current_line(new_line)
            vim.api.nvim_win_set_cursor(0, { cursor[1], cursor[2] + #selection.value.name })
            vim.notify("Appended environment name", vim.log.levels.INFO)
          end

          if config.mappings.append_name == "<CR>" then
            actions.select_default:replace(append_name_fn)
          else
            map("i", config.mappings.append_name, append_name_fn)
          end
        end

        -- Append environment value to buffer
        if config.mappings.append_value then
          map("i", config.mappings.append_value, function()
            local selection = action_state.get_selected_entry()
            local value = config.shelter.mask_on_copy and get_masked_value(selection.value.value)
              or selection.value.value
            actions.close(prompt_bufnr)
            local cursor = vim.api.nvim_win_get_cursor(0)
            local line = vim.api.nvim_get_current_line()
            local new_line = line:sub(1, cursor[2]) .. value .. line:sub(cursor[2] + 1)
            vim.api.nvim_set_current_line(new_line)
            vim.api.nvim_win_set_cursor(0, { cursor[1], cursor[2] + #value })
            vim.notify("Appended environment value", vim.log.levels.INFO)
          end)
        end

        return true
      end,
    })
    :find()
end

return telescope.register_extension({
  exports = {
    env = env_picker,
    setup = setup,
  },
})
