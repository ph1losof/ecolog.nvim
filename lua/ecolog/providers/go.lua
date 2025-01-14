local M = {}
local utils = require("ecolog.utils")

M.providers = {
  -- os.Getenv with double quotes completion
  {
    pattern = 'os%.Getenv%("[%w_]*$',
    filetype = "go",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, 'os%.Getenv%("([%w_]*)$')
    end,
    get_completion_trigger = function()
      return 'os.Getenv("'
    end,
  },
  -- os.Getenv with single quotes completion
  {
    pattern = "os%.Getenv%('[%w_]*$",
    filetype = "go",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "os%.Getenv%('([%w_]*)$")
    end,
    get_completion_trigger = function()
      return "os.Getenv('"
    end,
  },
  -- os.Getenv with backticks completion
  {
    pattern = "os%.Getenv%(`[%w_]*$",
    filetype = "go",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "os%.Getenv%(`([%w_]*)$")
    end,
    get_completion_trigger = function()
      return "os.Getenv(`"
    end,
  },
  -- os.Getenv full pattern with double quotes
  {
    pattern = 'os%.Getenv%("[%w_]+"%)?$',
    filetype = "go",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, 'os%.Getenv%("([%w_]+)"%)?$')
    end,
    get_completion_trigger = function()
      return 'os.Getenv("'
    end,
  },
  -- os.Getenv full pattern with single quotes
  {
    pattern = "os%.Getenv%('[%w_]+'%)?$",
    filetype = "go",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "os%.Getenv%('([%w_]+)'%)?$")
    end,
    get_completion_trigger = function()
      return "os.Getenv('"
    end,
  },
  -- os.Getenv full pattern with backticks
  {
    pattern = "os%.Getenv%(`[%w_]+`%)?$",
    filetype = "go",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "os%.Getenv%(`([%w_]+)`%)?$")
    end,
    get_completion_trigger = function()
      return "os.Getenv(`"
    end,
  },
  -- os.LookupEnv with double quotes completion
  {
    pattern = 'os%.LookupEnv%("[%w_]*$',
    filetype = "go",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, 'os%.LookupEnv%("([%w_]*)$')
    end,
    get_completion_trigger = function()
      return 'os.LookupEnv("'
    end,
  },
  -- os.LookupEnv with single quotes completion
  {
    pattern = "os%.LookupEnv%('[%w_]*$",
    filetype = "go",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "os%.LookupEnv%('([%w_]*)$")
    end,
    get_completion_trigger = function()
      return "os.LookupEnv('"
    end,
  },
  -- os.LookupEnv with backticks completion
  {
    pattern = "os%.LookupEnv%(`[%w_]*$",
    filetype = "go",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "os%.LookupEnv%(`([%w_]*)$")
    end,
    get_completion_trigger = function()
      return "os.LookupEnv(`"
    end,
  },
  -- os.LookupEnv full pattern with double quotes
  {
    pattern = 'os%.LookupEnv%("[%w_]+"%)?$',
    filetype = "go",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, 'os%.LookupEnv%("([%w_]+)"%)?$')
    end,
    get_completion_trigger = function()
      return 'os.LookupEnv("'
    end,
  },
  -- os.LookupEnv full pattern with single quotes
  {
    pattern = "os%.LookupEnv%('[%w_]+'%)?$",
    filetype = "go",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "os%.LookupEnv%('([%w_]+)'%)?$")
    end,
    get_completion_trigger = function()
      return "os.LookupEnv('"
    end,
  },
  -- os.LookupEnv full pattern with backticks
  {
    pattern = "os%.LookupEnv%(`[%w_]+`%)?$",
    filetype = "go",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "os%.LookupEnv%(`([%w_]+)`%)?$")
    end,
    get_completion_trigger = function()
      return "os.LookupEnv(`"
    end,
  },
}

return M.providers
