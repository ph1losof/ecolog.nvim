local M = {}
local utils = require("ecolog.utils")

-- Use utils lazy loading with caching
M.providers = setmetatable({}, {
  __index = function(t, k)
    t[k] = {}
    return t[k]
  end,
})

-- Provider cache
local _provider_cache = {}
local _provider_loading = {}

-- Load providers
function M.load_providers()
  if M._providers_loaded then
    return
  end

  local providers_list = {
    typescript = "ecolog.providers.typescript",
    javascript = "ecolog.providers.javascript",
    python = "ecolog.providers.python",
    php = "ecolog.providers.php",
    lua = "ecolog.providers.lua",
    go = "ecolog.providers.go",
    rust = "ecolog.providers.rust",
    java = "ecolog.providers.java",
    csharp = "ecolog.providers.csharp",
    ruby = "ecolog.providers.ruby",
  }

  for name, module_path in pairs(providers_list) do
    if not _provider_cache[name] and not _provider_loading[name] then
      _provider_loading[name] = true
      local ok, provider = pcall(require, module_path)
      _provider_loading[name] = nil
      
      if ok then
        _provider_cache[name] = provider
        if type(provider) == "table" then
          if provider.provider then
            M.register(provider.provider)
          else
            M.register_many(provider)
          end
        else
          M.register(provider)
        end
      end
    end
  end

  M._providers_loaded = true
end

-- Get a specific provider
function M.get_provider(name)
  if _provider_cache[name] then
    return _provider_cache[name]
  end
  
  if _provider_loading[name] then
    return nil
  end

  local module_path = "ecolog.providers." .. name
  _provider_loading[name] = true
  local ok, provider = pcall(require, module_path)
  _provider_loading[name] = nil

  if ok then
    _provider_cache[name] = provider
    return provider
  end
  return nil
end

-- Optimized register function with validation caching
local _pattern_cache = setmetatable({}, {
  __mode = "k" -- Weak keys to avoid memory leaks
})

function M.register(provider)
  local cache_key = provider
  if _pattern_cache[cache_key] ~= nil then
    return _pattern_cache[cache_key]
  end

  if not provider.pattern or not provider.filetype or not provider.extract_var then
    _pattern_cache[cache_key] = false
    return false
  end

  local filetypes = type(provider.filetype) == "string" and { provider.filetype } or provider.filetype
  for _, ft in ipairs(filetypes) do
    M.providers[ft] = M.providers[ft] or {}
    table.insert(M.providers[ft], provider)
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
