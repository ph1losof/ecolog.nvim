local has_telescope, telescope = pcall(require, "telescope")
if not has_telescope then
  error("This extension requires telescope.nvim (https://github.com/nvim-telescope/telescope.nvim)")
end

local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local BasePicker = require("ecolog.integrations.pickers.base")

---@class TelescopePicker : BasePicker
local TelescopePicker = setmetatable({}, { __index = BasePicker })
TelescopePicker.__index = TelescopePicker

---Create a new TelescopePicker instance
---@param opts table|nil Optional configuration to override defaults
---@return TelescopePicker
function TelescopePicker:new(opts)
  local instance = BasePicker.new(self, opts)
  return instance
end

---Get the name of this picker for notifications
---@return string
function TelescopePicker:get_name()
  return "Ecolog Telescope"
end

---Get the default configuration for this picker
---@return table
function TelescopePicker:get_default_config()
  return {
    shelter = {
      mask_on_copy = false,
    },
    mappings = {
      copy_value = "<C-y>",
      copy_name = "<C-n>",
      append_value = "<C-a>",
      append_name = "<CR>",
      edit_var = "<C-e>",
    },
    custom_actions = {},
  }
end

---Open environment variables picker
---@param opts table|nil Optional configuration for telescope
function TelescopePicker:open(opts)
  if not self._initialized then
    self:setup({})
    self._initialized = true
  end

  opts = opts or {}
  opts = vim.tbl_deep_extend("force", {
    layout_strategy = "vertical",
    layout_config = {
      vertical = {
        width = 0.8,
        height = 0.8,
        preview_height = 0.6,
      },
    },
  }, opts)

  self:save_current_window()

  local data = require("ecolog.integrations.pickers.data")
  local results = data.format_env_vars_for_picker(self:get_name():lower())

  pickers
    .new(opts, {
      prompt_title = "Environment Variables",
      finder = finders.new_table({
        results = results,
        entry_maker = function(entry)
          return {
            value = entry,
            display = function(entry_item)
              local longest = entry_item.value.longest_name or 20
              local name = entry_item.value.name
              local masked_value = entry_item.value.masked_value or ""

              local display_text = string.format("%-" .. longest .. "s %s", name, masked_value)

              return display_text
            end,
            ordinal = string.format("%04d_%s", entry.idx, entry.name),
          }
        end,
      }),
      previewer = false,
      sorter = conf.generic_sorter(opts),
      attach_mappings = function(prompt_bufnr, map)
        if self._config.mappings.copy_value then
          map("i", self._config.mappings.copy_value, function()
            local selection = action_state.get_selected_entry()
            local value = self._config.shelter.mask_on_copy and selection.value.masked_value or selection.value.value

            self:copy_to_clipboard(value, string.format("value of '%s'", selection.value.name))
            actions.close(prompt_bufnr)
          end)
        end

        if self._config.mappings.copy_name then
          map("i", self._config.mappings.copy_name, function()
            local selection = action_state.get_selected_entry()
            self:copy_to_clipboard(selection.value.name, "variable name")
            actions.close(prompt_bufnr)
          end)
        end

        if self._config.mappings.append_value then
          map("i", self._config.mappings.append_value, function()
            local selection = action_state.get_selected_entry()
            local value = self._config.shelter.mask_on_copy and selection.value.masked_value or selection.value.value

            actions.close(prompt_bufnr)
            self:append_at_cursor(value)
            self:notify("Appended environment value", vim.log.levels.INFO)
          end)
        end

        if self._config.mappings.append_name then
          local append_name_fn = function()
            local selection = action_state.get_selected_entry()
            actions.close(prompt_bufnr)
            self:append_at_cursor(selection.value.name)
            self:notify("Appended environment name", vim.log.levels.INFO)
          end

          if self._config.mappings.append_name == "<CR>" then
            actions.select_default:replace(append_name_fn)
          else
            map("i", self._config.mappings.append_name, append_name_fn)
          end
        end

        if self._config.mappings.edit_var then
          map("i", self._config.mappings.edit_var, function()
            local selection = action_state.get_selected_entry()
            actions.close(prompt_bufnr)
            self:edit_environment_var(selection.value.name, selection.value.value)
          end)
        end

        local custom_actions = self:get_custom_actions()
        for name, action in pairs(custom_actions) do
          if type(action.key) == "string" then
            map("i", action.key, function()
              local selection = action_state.get_selected_entry()
              local should_close = action.opts.close_on_action ~= false

              local result = self:run_custom_action(name, selection.value)

              if should_close then
                actions.close(prompt_bufnr)
              end

              if result and action.opts.notify ~= false then
                self:notify(
                  action.opts.message or string.format("Custom action '%s' executed", name),
                  vim.log.levels.INFO
                )
              end
            end)
          elseif type(action.key) == "table" then
            for _, key in ipairs(action.key) do
              map("i", key, function()
                local selection = action_state.get_selected_entry()
                local should_close = action.opts.close_on_action ~= false

                local result = self:run_custom_action(name, selection.value)

                if should_close then
                  actions.close(prompt_bufnr)
                end

                if result and action.opts.notify ~= false then
                  self:notify(
                    action.opts.message or string.format("Custom action '%s' executed", name),
                    vim.log.levels.INFO
                  )
                end
              end)
            end
          end
        end

        return true
      end,
    })
    :find()
end

---Setup the telescope picker with configuration
---@param opts table|nil
function TelescopePicker:setup(opts)
  BasePicker.setup(self, opts)
end

---Add a custom action to the telescope picker
---@param name string The name of the action
---@param key string|table The key or keys to map to this action
---@param callback function The callback function to run
---@param opts table|nil Additional options for the action
function TelescopePicker:add_action(name, key, callback, opts)
  self:add_custom_action(name, key, callback, opts)
end

local instance = TelescopePicker:new()

return telescope.register_extension({
  exports = {
    env = function(opts)
      instance:open(opts)
    end,
    env_picker = function(opts)
      instance:open(opts)
    end,
    setup = function(opts)
      instance:setup(opts)
    end,
    add_action = function(name, key, callback, opts)
      instance:add_action(name, key, callback, opts)
    end,
  },
})
