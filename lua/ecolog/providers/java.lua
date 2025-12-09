local M = {}
local providers_module = require("ecolog.providers")

-- Java environment variable access patterns
M.providers = {}

local filetype = "java"

-- System.getenv("VAR") and System.getenv('VAR')
vim.list_extend(M.providers, providers_module.create_function_call_patterns("System.getenv", filetype, "both"))

-- System.getProperty("VAR") and System.getProperty('VAR') - allows dots in property names
local property_providers = {}
local escaped_func = "System%.getProperty"
local quotes = { '"', "'" }

for _, q in ipairs(quotes) do
  local complete_pattern = escaped_func .. "%(" .. q .. "([%w_.%-]+)" .. q .. "%)"
  local partial_pattern = escaped_func .. "%(" .. q .. "([%w_.%-]*)" .. "$"
  
  table.insert(property_providers, {
    pattern = complete_pattern,
    filetype = filetype,
    extract_var = function(line, col)
      local cursor_pos = col + 1
      local trigger_len = #("System.getProperty(" .. q)
      
      local search_pos = 1
      while search_pos <= #line do
        local match_start, match_end, var_name = line:find(complete_pattern, search_pos)
        if not match_start or not var_name then
          break
        end
        
        local var_start = match_start + trigger_len
        local var_end = var_start + (#var_name - 1)
        
        if cursor_pos >= var_start and cursor_pos <= var_end then
          return var_name
        end
        
        search_pos = match_end + 1
      end
      
      return nil
    end,
  })
  
  table.insert(property_providers, {
    pattern = partial_pattern,
    filetype = filetype,
    extract_var = function(line, col)
      local utils = require("ecolog.utils")
      return utils.extract_env_var(line, col, partial_pattern)
    end,
    get_completion_trigger = function()
      return "System.getProperty(" .. q
    end,
  })
end

vim.list_extend(M.providers, property_providers)

-- processBuilder.environment().get("VAR") and processBuilder.environment().get('VAR')
vim.list_extend(M.providers, providers_module.create_function_call_patterns("processBuilder.environment().get", filetype, "both"))

-- env.get("VAR") and env.get('VAR') - generic Map<String, String> access
vim.list_extend(M.providers, providers_module.create_function_call_patterns("env.get", filetype, "both"))

return M.providers
