local M = {}

local PREFIX = "[ECOLOG]"

---@param msg string
---@param level? integer vim.log.levels.*
function M.notify(msg, level)
  vim.notify(PREFIX .. " " .. msg, level or vim.log.levels.INFO)
end

---@param msg string
function M.info(msg)
  M.notify(msg, vim.log.levels.INFO)
end

---@param msg string
function M.warn(msg)
  M.notify(msg, vim.log.levels.WARN)
end

---@param msg string
function M.error(msg)
  M.notify(msg, vim.log.levels.ERROR)
end

return M
