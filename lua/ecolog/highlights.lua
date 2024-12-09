local M = {}

function M.setup()
    -- Get colors from current colorscheme
    local colors = {
        bg = vim.api.nvim_get_hl(0, { name = 'Normal' }).bg,
        border = vim.api.nvim_get_hl(0, { name = 'FloatBorder' }).fg,
        text = vim.api.nvim_get_hl(0, { name = 'Normal' }).fg,
        type = vim.api.nvim_get_hl(0, { name = 'Type' }).fg,
        source = vim.api.nvim_get_hl(0, { name = 'Directory' }).fg,
        value = vim.api.nvim_get_hl(0, { name = 'String' }).fg,
        variable = vim.api.nvim_get_hl(0, { name = 'Identifier' }).fg
    }

    -- Create highlight groups using system colors
    vim.api.nvim_set_hl(0, 'EcologNormal', { bg = colors.bg, fg = colors.text })
    vim.api.nvim_set_hl(0, 'EcologBorder', { fg = colors.border })
    vim.api.nvim_set_hl(0, 'EcologType', { fg = colors.type, bold = true })
    vim.api.nvim_set_hl(0, 'EcologSource', { fg = colors.source, bold = true })
    vim.api.nvim_set_hl(0, 'EcologValue', { fg = colors.value })
    vim.api.nvim_set_hl(0, 'EcologVariable', { fg = colors.variable, bold = true })

    return colors
end

return M 