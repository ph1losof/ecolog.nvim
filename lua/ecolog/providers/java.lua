local M = {}
local utils = require("ecolog.utils")

M.providers = {
  -- System.getenv() with double quotes completion
  {
    pattern = 'System%.getenv%("[%w_]*$',
    filetype = "java",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, 'System%.getenv%("([%w_]*)$')
    end,
    get_completion_trigger = function()
      return 'System.getenv("'
    end,
  },
  -- System.getenv() with single quotes completion
  {
    pattern = "System%.getenv%('[%w_]*$",
    filetype = "java",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "System%.getenv%('([%w_]*)$")
    end,
    get_completion_trigger = function()
      return "System.getenv('"
    end,
  },
  -- System.getenv() with double quotes full pattern
  {
    pattern = 'System%.getenv%("[%w_]+"%)?$',
    filetype = "java",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, 'System%.getenv%("([%w_]+)"%)?$')
    end,
    get_completion_trigger = function()
      return 'System.getenv("'
    end,
  },
  -- System.getenv() with single quotes full pattern
  {
    pattern = "System%.getenv%('[%w_]+'%)?$",
    filetype = "java",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "System%.getenv%('([%w_]+'%)?$")
    end,
    get_completion_trigger = function()
      return "System.getenv('"
    end,
  },
  -- ProcessBuilder environment map with double quotes completion
  {
    pattern = 'processBuilder%.environment%(%)%.get%("[%w_]*$',
    filetype = "java",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, 'processBuilder%.environment%(%)%.get%("([%w_]*)$')
    end,
    get_completion_trigger = function()
      return 'processBuilder.environment().get("'
    end,
  },
  -- ProcessBuilder environment map with single quotes completion
  {
    pattern = "processBuilder%.environment%(%)%.get%('[%w_]*$",
    filetype = "java",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "processBuilder%.environment%(%)%.get%('([%w_]*)$")
    end,
    get_completion_trigger = function()
      return "processBuilder.environment().get('"
    end,
  },
  -- ProcessBuilder environment map with double quotes full pattern
  {
    pattern = 'processBuilder%.environment%(%)%.get%("[%w_]+"%)?$',
    filetype = "java",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, 'processBuilder%.environment%(%)%.get%("([%w_]+)"%)?$')
    end,
    get_completion_trigger = function()
      return 'processBuilder.environment().get("'
    end,
  },
  -- ProcessBuilder environment map with single quotes full pattern
  {
    pattern = "processBuilder%.environment%(%)%.get%('[%w_]+'%)?$",
    filetype = "java",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "processBuilder%.environment%(%)%.get%('([%w_]+'%)?$")
    end,
    get_completion_trigger = function()
      return "processBuilder.environment().get('"
    end,
  },
  -- Map<String, String> env = System.getenv() map access with double quotes completion
  {
    pattern = 'env%.get%("[%w_]*$',
    filetype = "java",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, 'env%.get%("([%w_]*)$')
    end,
    get_completion_trigger = function()
      return 'env.get("'
    end,
  },
  -- Map<String, String> env = System.getenv() map access with single quotes completion
  {
    pattern = "env%.get%('[%w_]*$",
    filetype = "java",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "env%.get%('([%w_]*)$")
    end,
    get_completion_trigger = function()
      return "env.get('"
    end,
  },
  -- Map<String, String> env = System.getenv() map access with double quotes full pattern
  {
    pattern = 'env%.get%("[%w_]+"%)?$',
    filetype = "java",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, 'env%.get%("([%w_]+)"%)?$')
    end,
    get_completion_trigger = function()
      return 'env.get("'
    end,
  },
  -- Map<String, String> env = System.getenv() map access with single quotes full pattern
  {
    pattern = "env%.get%('[%w_]+'%)?$",
    filetype = "java",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "env%.get%('([%w_]+'%)?$")
    end,
    get_completion_trigger = function()
      return "env.get('"
    end,
  },
}

return M.providers 