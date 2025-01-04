local M = {}

M.providers = {
  -- Double quotes completion
  {
    pattern = 'os%.getenv%("[%w_]*$',
    filetype = "lua",
    extract_var = function(line, col)
      local before_cursor = line:sub(1, col)
      return before_cursor:match('os%.getenv%("([%w_]*)$')
    end,
    get_completion_trigger = function()
      return 'os.getenv("'
    end,
  },
  -- Single quotes completion
  {
    pattern = "os%.getenv%('[%w_]*$",
    filetype = "lua",
    extract_var = function(line, col)
      local before_cursor = line:sub(1, col)
      return before_cursor:match("os%.getenv%('([%w_]*)$")
    end,
    get_completion_trigger = function()
      return "os.getenv('"
    end,
  },
  -- Full pattern with double quotes
  {
    pattern = 'os%.getenv%("[%w_]+"%)?$',
    filetype = "lua",
    extract_var = function(line, col)
      local before_cursor = line:sub(1, col)
      return before_cursor:match('os%.getenv%("([%w_]+)"%)?$')
    end,
    get_completion_trigger = function()
      return 'os.getenv("'
    end,
  },
  -- Full pattern with single quotes
  {
    pattern = "os%.getenv%('[%w_]+'%)?$",
    filetype = "lua",
    extract_var = function(line, col)
      local before_cursor = line:sub(1, col)
      return before_cursor:match("os%.getenv%('([%w_]+)'%)?$")
    end,
    get_completion_trigger = function()
      return "os.getenv('"
    end,
  }
}

return M.providers

