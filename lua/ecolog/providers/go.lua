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
  -- syscall.Getenv with double quotes
  {
    pattern = 'syscall%.Getenv%("[%w_]+"%)',
    filetype = "go",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, 'syscall%.Getenv%("([%w_]+)"%)')
    end,
    get_completion_trigger = function()
      return 'syscall.Getenv("'
    end,
  },
  -- syscall.Getenv with single quotes
  {
    pattern = "syscall%.Getenv%('[%w_]+'%)",
    filetype = "go",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "syscall%.Getenv%('([%w_]+)'%)")
    end,
    get_completion_trigger = function()
      return "syscall.Getenv('"
    end,
  },
  -- syscall.Getenv with backticks
  {
    pattern = "syscall%.Getenv%(`[%w_]+`%)",
    filetype = "go",
    extract_var = function(line, col)
      return utils.extract_env_var(line, col, "syscall%.Getenv%(`([%w_]+)`%)")
    end,
    get_completion_trigger = function()
      return "syscall.Getenv(`"
    end,
  },
}

return M.providers
