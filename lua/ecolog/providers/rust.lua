local M = {}
local utils = require("ecolog.utils")

M.providers = {
  -- env::var with single quotes completion
  {
    pattern = [[env::var%('[%w_]*$]],
    filetype = "rust",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, [[env::var%('([%w_]*)$]])
    end,
    get_completion_trigger = function()
      return [[env::var(']]
    end,
  },
  -- env::var with double quotes completion
  {
    pattern = [[env::var%("[%w_]*$]],
    filetype = "rust",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, [[env::var%("([%w_]*)$]])
    end,
    get_completion_trigger = function()
      return [[env::var("]]
    end,
  },
  -- env::var with single quotes full pattern
  {
    pattern = [[env::var%('[%w_]+'%)?$]],
    filetype = "rust",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, [[env::var%('([%w_]+)'%)?$]])
    end,
    get_completion_trigger = function()
      return [[env::var(']]
    end,
  },
  -- env::var with double quotes full pattern
  {
    pattern = [[env::var%("[%w_]+"%)?$]],
    filetype = "rust",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, [[env::var%("([%w_]+)"%)?$]])
    end,
    get_completion_trigger = function()
      return [[env::var("]]
    end,
  },
  -- env::var_os with single quotes completion
  {
    pattern = [[env::var_os%('[%w_]*$]],
    filetype = "rust",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, [[env::var_os%('([%w_]*)$]])
    end,
    get_completion_trigger = function()
      return [[env::var_os(']]
    end,
  },
  -- env::var_os with double quotes completion
  {
    pattern = [[env::var_os%("[%w_]*$]],
    filetype = "rust",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, [[env::var_os%("([%w_]*)$]])
    end,
    get_completion_trigger = function()
      return [[env::var_os("]]
    end,
  },
  -- env::var_os with single quotes full pattern
  {
    pattern = [[env::var_os%('[%w_]+'%)?$]],
    filetype = "rust",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, [[env::var_os%('([%w_]+)'%)?$]])
    end,
    get_completion_trigger = function()
      return [[env::var_os(']]
    end,
  },
  -- env::var_os with double quotes full pattern
  {
    pattern = [[env::var_os%("[%w_]+"%)?$]],
    filetype = "rust",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, [[env::var_os%("([%w_]+)"%)?$]])
    end,
    get_completion_trigger = function()
      return [[env::var_os("]]
    end,
  },
  -- std::env::var with single quotes completion
  {
    pattern = [[std::env::var%('[%w_]*$]],
    filetype = "rust",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, [[std::env::var%('([%w_]*)$]])
    end,
    get_completion_trigger = function()
      return [[std::env::var(']]
    end,
  },
  -- std::env::var with double quotes completion
  {
    pattern = [[std::env::var%("[%w_]*$]],
    filetype = "rust",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, [[std::env::var%("([%w_]*)$]])
    end,
    get_completion_trigger = function()
      return [[std::env::var("]]
    end,
  },
  -- std::env::var with single quotes full pattern
  {
    pattern = [[std::env::var%('[%w_]+'%)?$]],
    filetype = "rust",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, [[std::env::var%('([%w_]+)'%)?$]])
    end,
    get_completion_trigger = function()
      return [[std::env::var(']]
    end,
  },
  -- std::env::var with double quotes full pattern
  {
    pattern = [[std::env::var%("[%w_]+"%)?$]],
    filetype = "rust",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, [[std::env::var%("([%w_]+)"%)?$]])
    end,
    get_completion_trigger = function()
      return [[std::env::var("]]
    end,
  },
  -- std::env::var_os with single quotes completion
  {
    pattern = [[std::env::var_os%('[%w_]*$]],
    filetype = "rust",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, [[std::env::var_os%('([%w_]*)$]])
    end,
    get_completion_trigger = function()
      return [[std::env::var_os(']]
    end,
  },
  -- std::env::var_os with double quotes completion
  {
    pattern = [[std::env::var_os%("[%w_]*$]],
    filetype = "rust",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, [[std::env::var_os%("([%w_]*)$]])
    end,
    get_completion_trigger = function()
      return [[std::env::var_os("]]
    end,
  },
  -- std::env::var_os with single quotes full pattern
  {
    pattern = [[std::env::var_os%('[%w_]+'%)?$]],
    filetype = "rust",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, [[std::env::var_os%('([%w_]+)'%)?$]])
    end,
    get_completion_trigger = function()
      return [[std::env::var_os(']]
    end,
  },
  -- std::env::var_os with double quotes full pattern
  {
    pattern = [[std::env::var_os%("[%w_]+"%)?$]],
    filetype = "rust",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, [[std::env::var_os%("([%w_]+)"%)?$]])
    end,
    get_completion_trigger = function()
      return [[std::env::var_os("]]
    end,
  },
}

return M.providers