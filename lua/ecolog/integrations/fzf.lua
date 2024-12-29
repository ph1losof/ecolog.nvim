local has_fzf, fzf = pcall(require, "fzf-lua")
if not has_fzf then
  error("This extension requires fzf-lua (https://github.com/ibhagwan/fzf-lua)")
end

local shelter = require("ecolog.shelter")

local M = {}

-- Default configuration
local config = {
  shelter = {
    -- Whether to show masked values when copying to clipboard
    mask_on_copy = false,
  },
  -- Default keybindings
  mappings = {
    -- Key to copy value to clipboard
    copy_value = "ctrl-y",
    -- Key to copy name to clipboard
    copy_name = "ctrl-n",
    -- Key to append value to buffer
    append_value = "ctrl-a",
    -- Key to append name to buffer (defaults to 'enter')
    append_name = "enter",
  },
}

function M.get_env_vars()
  if not M._ecolog then
    M._ecolog = require("ecolog")
  end
  return M._ecolog.get_env_vars()
end

local function get_masked_value(value)
  return shelter.mask_value(value, "telescope")
end

function M.actions()
  return {
    -- Copy value to clipboard
    [config.mappings.copy_value] = function(selected)
      local entry_str = selected[1]
      local var_name = entry_str:match("^(.-)%s*=")
      local selection = M.get_env_vars()[var_name]

      local value = config.shelter.mask_on_copy and get_masked_value(selection.value) or selection.value
      vim.fn.setreg("+", value)

      vim.notify("Copied value to clipboard", vim.log.levels.INFO)
    end,

    -- Copy name to clipboard
    [config.mappings.copy_name] = function(selected)
      local entry_str = selected[1]
      local var_name = entry_str:match("^(.-)%s*=")

      vim.fn.setreg("+", var_name)
      vim.notify("Copied variable name to clipboard", vim.log.levels.INFO)
    end,

    -- Append environment name to buffer
    [config.mappings.append_name] = function(selected)
      local entry_str = selected[1]
      local var_name = entry_str:match("^(.-)%s*=")
      local selection = M.get_env_vars()[var_name]

      local cursor = vim.api.nvim_win_get_cursor(0)
      local line = vim.api.nvim_get_current_line()
      local new_line = line:sub(1, cursor[2]) .. selection.name .. line:sub(cursor[2] + 1)

      vim.api.nvim_set_current_line(new_line)
      vim.api.nvim_win_set_cursor(0, { cursor[1], cursor[2] + #selection.name })
      vim.notify("Appended environment name", vim.log.levels.INFO)
    end,

    -- Append environment value to buffer
    [config.mappings.append_value] = function(selected)
      local entry_str = selected[1]
      local var_name = entry_str:match("^(.-)%s*=")
      local selection = M.get_env_vars()[var_name]
      local value = config.shelter.mask_on_copy and get_masked_value(selection.value) or selection.value

      local cursor = vim.api.nvim_win_get_cursor(0)
      local line = vim.api.nvim_get_current_line()
      local new_line = line:sub(1, cursor[2]) .. value .. line:sub(cursor[2] + 1)
      vim.api.nvim_set_current_line(new_line)
      vim.api.nvim_win_set_cursor(0, { cursor[1], cursor[2] + #value })

      vim.notify("Appended environment value", vim.log.levels.INFO)
    end,
  }
end

function M.env_picker(fzf_opts)
  local results = {}
  for var_name, var_info in pairs(M.get_env_vars()) do
    local display_value = get_masked_value(var_info.value)
    table.insert(results, string.format("%-30s = %s", var_name, display_value))
  end

  local default_opts = {}

  default_opts.previewer = false
  default_opts.actions = M.actions()

  fzf_opts = vim.tbl_deep_extend("force", default_opts, fzf_opts or {})

  fzf.fzf_exec(results, fzf_opts)
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
  M.fzf = M.env_picker
end

return M
