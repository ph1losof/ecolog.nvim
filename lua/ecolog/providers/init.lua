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

-- Map of provider modules to their supported filetypes
local _provider_filetype_map = {
  typescript = { "typescript", "typescriptreact" },
  javascript = { "javascript", "javascriptreact" },
  python = { "python" },
  php = { "php" },
  lua = { "lua" },
  go = { "go" },
  rust = { "rust" },
  java = { "java" },
  csharp = { "cs", "csharp" },
  ruby = { "ruby" },
  shell = { "sh", "bash", "zsh" },
}

-- Reverse map of filetypes to their provider modules
local _filetype_provider_map = {}
for provider, filetypes in pairs(_provider_filetype_map) do
  for _, ft in ipairs(filetypes) do
    _filetype_provider_map[ft] = provider
  end
end

-- Load a specific provider module
local function load_provider(name)
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

-- Load providers for a specific filetype
function M.load_providers_for_filetype(filetype)
  local provider_name = _filetype_provider_map[filetype]
  if not provider_name then
    return
  end

  local provider = load_provider(provider_name)
  if provider then
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

-- Get providers for a specific filetype, loading them if needed
function M.get_providers(filetype)
  if not M.providers[filetype] or #M.providers[filetype] == 0 then
    M.load_providers_for_filetype(filetype)
  end
  return M.providers[filetype]
end

return M
