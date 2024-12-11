local M = {}

-- Cache vim functions
local type = type
local error = error
local ipairs = ipairs
local tinsert = table.insert

-- Optimize provider storage
M.providers = setmetatable({}, {
  __index = function(t, k)
    t[k] = {}
    return t[k]
  end,
})

-- Optimized register function
function M.register(provider)
  if not (provider.pattern and provider.filetype and provider.extract_var) then
    error("Provider must have pattern, filetype, and extract_var fields")
  end

  local filetypes = type(provider.filetype) == "string" and { provider.filetype } or provider.filetype

  for _, ft in ipairs(filetypes) do
    tinsert(M.providers[ft], provider)
  end
end

-- Optimized register_many
function M.register_many(providers)
  if type(providers) ~= "table" then
    error("Providers must be a table")
  end

  for _, provider in ipairs(providers) do
    M.register(provider)
  end
end

-- Optimized get_providers
function M.get_providers(filetype)
  return M.providers[filetype]
end

return M
