local M = {}
local providers_module = require("ecolog.providers")
local utils = require("ecolog.utils")

-- Python environment variable access patterns
M.providers = {}

local filetype = "python"

-- os.environ["VAR"] and os.environ['VAR'] (dictionary access)
vim.list_extend(M.providers, providers_module.create_bracket_patterns("os.environ", filetype, "both"))

-- os.environ.get("VAR", default) and os.environ.get('VAR', default) with optional default parameter
local function create_python_function_patterns(func_name, quote_char)
  local escaped_func = func_name:gsub("%.", "%%.")
  local quotes = quote_char == "both" and { '"', "'" } or { quote_char }
  local providers = {}

  for _, q in ipairs(quotes) do
    local trigger = func_name .. "(" .. q
    local pattern = escaped_func .. "%(" .. q
    local var_pattern = "([%w_]+)"
    -- Allow optional parameters after the variable name: , anything before )
    local end_boundary = q .. "[^%)]*%)"

    -- Pre-compile pattern outside function for performance
    local capture_pattern = pattern .. "(" .. var_pattern:gsub("[()]", "") .. ")" .. end_boundary
    local trigger_len = #trigger

    -- Complete pattern (for extraction/peek)
    local complete_pattern = pattern .. var_pattern .. end_boundary

    -- Partial pattern (for completion)
    local partial_var_pattern = var_pattern:gsub("%+", "*")
    local partial_pattern = pattern .. partial_var_pattern .. "$"

    -- Complete provider
    table.insert(providers, {
      pattern = complete_pattern,
      filetype = filetype,
      extract_var = function(line, col)
        local cursor_pos = col + 1

        local search_pos = 1
        while search_pos <= #line do
          local match_start, match_end, var_name = line:find(capture_pattern, search_pos)
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

    -- Partial provider (for completion)
    table.insert(providers, {
      pattern = partial_pattern,
      filetype = filetype,
      extract_var = function(line, col)
        return utils.extract_env_var(line, col, pattern .. partial_var_pattern .. "$")
      end,
      get_completion_trigger = function()
        return trigger
      end,
    })
  end

  return providers
end

-- os.environ.get("VAR") and os.environ.get('VAR') with optional default parameter
vim.list_extend(M.providers, create_python_function_patterns("os.environ.get", "both"))

-- os.getenv("VAR") and os.getenv('VAR') with optional default parameter
vim.list_extend(M.providers, create_python_function_patterns("os.getenv", "both"))

return M.providers
