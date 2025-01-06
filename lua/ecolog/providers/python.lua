local M = {}

M.providers = {
  -- os.environ.get with double quotes completion
  {
    pattern = 'os%.environ%.get%("[%w_]*$',
    filetype = "python",
    extract_var = function(line, col)
      local before_cursor = line:sub(1, col)
      return before_cursor:match('os%.environ%.get%("([%w_]*)$')
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
      local before_cursor = line:sub(1, col)
      return before_cursor:match("os%.environ%.get%('([%w_]*)$")
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
      local before_cursor = line:sub(1, col)
      return before_cursor:match('os%.environ%.get%("([%w_]+)"%)?$')
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
      local before_cursor = line:sub(1, col)
      return before_cursor:match("os%.environ%.get%('([%w_]+)'%)?$")
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
      local before_cursor = line:sub(1, col)
      return before_cursor:match('os%.environ%["([%w_]*)$')
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
      local before_cursor = line:sub(1, col)
      return before_cursor:match("os%.environ%['([%w_]*)$")
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
      local before_cursor = line:sub(1, col)
      return before_cursor:match('os%.environ%["([%w_]+)"%]?$')
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
      local before_cursor = line:sub(1, col)
      return before_cursor:match("os%.environ%['([%w_]+)'%]?$")
    end,
    get_completion_trigger = function()
      return "os.environ['"
    end,
  },
}

return M.providers
