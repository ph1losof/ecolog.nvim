local M = {}
local api = vim.api

local cached_colors = nil

function M.setup()
  if cached_colors then
    return cached_colors
  end

  cached_colors = {
    bg = api.nvim_get_hl(0, { name = "Normal" }).bg,
    border = api.nvim_get_hl(0, { name = "FloatBorder" }).fg,
    text = api.nvim_get_hl(0, { name = "Normal" }).fg,
    type = api.nvim_get_hl(0, { name = "Type" }).fg,
    source = api.nvim_get_hl(0, { name = "Directory" }).fg,
    value = api.nvim_get_hl(0, { name = "String" }).fg,
    variable = api.nvim_get_hl(0, { name = "Identifier" }).fg,
  }

  api.nvim_set_hl(0, "EcologNormal", { bg = cached_colors.bg, fg = cached_colors.text })
  api.nvim_set_hl(0, "EcologBorder", { fg = cached_colors.border })
  api.nvim_set_hl(0, "EcologType", { fg = cached_colors.type, bold = true })
  api.nvim_set_hl(0, "EcologSource", { fg = cached_colors.source, bold = true })
  api.nvim_set_hl(0, "EcologValue", { fg = cached_colors.value })
  api.nvim_set_hl(0, "EcologVariable", { fg = cached_colors.variable, bold = true })

  api.nvim_set_hl(0, "CmpItemKindEcolog", { link = "EcologVariable" })
  api.nvim_set_hl(0, "CmpItemAbbrMatchEcolog", { link = "EcologVariable" })
  api.nvim_set_hl(0, "CmpItemMenuEcolog", { link = "EcologSource" })

  return cached_colors
end

api.nvim_create_autocmd("ColorScheme", {
  callback = function()
    cached_colors = nil
  end,
})

return M
