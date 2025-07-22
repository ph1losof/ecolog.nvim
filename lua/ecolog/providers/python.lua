local M = {}
local utils = require("ecolog.utils")

M.providers = {
  -- os.environ.get with double quotes completion
  {
    pattern = 'os%.environ%.get%("[%w_]*$',
    filetype = "python",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, 'os%.environ%.get%("([%w_]*)$')
    end,
    get_completion_trigger = function()
      return 'os.environ.get("'
    end,
  },
  -- os.environ.get with single quotes completion
  {
    pattern = "os%.environ%.get%('[%w_]*$",
    filetype = "python",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "os%.environ%.get%('([%w_]*)$")
    end,
    get_completion_trigger = function()
      return "os.environ.get('"
    end,
  },
  -- os.environ.get full pattern with double quotes
  {
    pattern = 'os%.environ%.get%("[%w_]+"%)?$',
    filetype = "python",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, 'os%.environ%.get%("([%w_]+)"%)?$')
    end,
    get_completion_trigger = function()
      return 'os.environ.get("'
    end,
  },
  -- os.environ.get full pattern with single quotes
  {
    pattern = "os%.environ%.get%('[%w_]+'%)?$",
    filetype = "python",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "os%.environ%.get%('([%w_]+)'%)?$")
    end,
    get_completion_trigger = function()
      return "os.environ.get('"
    end,
  },
  -- os.environ[] with double quotes completion
  {
    pattern = 'os%.environ%["[%w_]*$',
    filetype = "python",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, 'os%.environ%["([%w_]*)$')
    end,
    get_completion_trigger = function()
      return 'os.environ["'
    end,
  },
  -- os.environ[] with single quotes completion
  {
    pattern = "os%.environ%['[%w_]*$",
    filetype = "python",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "os%.environ%['([%w_]*)$")
    end,
    get_completion_trigger = function()
      return "os.environ['"
    end,
  },
  -- os.environ[] full pattern with double quotes
  {
    pattern = 'os%.environ%["[%w_]+"%]?$',
    filetype = "python",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, 'os%.environ%["([%w_]+)"%]?$')
    end,
    get_completion_trigger = function()
      return 'os.environ["'
    end,
  },
  -- os.environ[] full pattern with single quotes
  {
    pattern = "os%.environ%['[%w_]+'%]?$",
    filetype = "python",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "os%.environ%['([%w_]+)'%]?$")
    end,
    get_completion_trigger = function()
      return "os.environ['"
    end,
  },
  -- os.environ.get with default value - double quotes
  {
    pattern = 'os%.environ%.get%("[%w_]+", *[^)]+%)',
    filetype = "python",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, 'os%.environ%.get%("([%w_]+)", *[^)]+%)')
    end,
    get_completion_trigger = function()
      return 'os.environ.get("'
    end,
  },
  -- os.environ.get with default value - single quotes  
  {
    pattern = "os%.environ%.get%('[%w_]+', *[^)]+%)",
    filetype = "python", 
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "os%.environ%.get%('([%w_]+)', *[^)]+%)")
    end,
    get_completion_trigger = function()
      return "os.environ.get('"
    end,
  },
  -- os.getenv() function
  {
    pattern = 'os%.getenv%("[%w_]+"%)',
    filetype = "python",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, 'os%.getenv%("([%w_]+)"%)')
    end,
    get_completion_trigger = function()
      return 'os.getenv("'
    end,
  },
  {
    pattern = "os%.getenv%('[%w_]+'%)",
    filetype = "python",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "os%.getenv%('([%w_]+)'%)")
    end,
    get_completion_trigger = function()
      return "os.getenv('"
    end,
  },
  -- os.getenv with default value - double quotes
  {
    pattern = 'os%.getenv%("[%w_]+", *[^)]+%)',
    filetype = "python",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, 'os%.getenv%("([%w_]+)", *[^)]+%)')
    end,
    get_completion_trigger = function()
      return 'os.getenv("'
    end,
  },
  -- os.getenv with default value - single quotes
  {
    pattern = "os%.getenv%('[%w_]+', *[^)]+%)",
    filetype = "python",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "os%.getenv%('([%w_]+)', *[^)]+%)")
    end,
    get_completion_trigger = function()
      return "os.getenv('"
    end,
  },
}

return M.providers
