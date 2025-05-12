-- Run with `nvim -u repro.lua`
--
-- Please update the code below to reproduce your issue and send the updated code, with reproduction
--  steps, in your issue report

vim.env.LAZY_STDPATH = ".repro"
load(vim.fn.system("curl -s https://raw.githubusercontent.com/folke/lazy.nvim/main/bootstrap.lua"))()

---@diagnostic disable-next-line: missing-fields
require("lazy.minit").repro({
  spec = {
    {
      "t3ntxcl3s/ecolog.nvim",
      -- please test on 'main' if possible
      lazy = false,
      opts = {},
    },
  },
})
