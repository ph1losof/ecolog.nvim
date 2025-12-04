---@class MonorepoDetection
local Detection = {}

-- Compatibility layer for uv -> vim.uv migration
local uv = require("ecolog.core.compat").uv

local BaseProvider = require("ecolog.monorepo.detection.providers.base")
local Cache = require("ecolog.monorepo.detection.cache")

-- Registry of loaded providers
local _providers = {}
local _provider_modules = {}

---Register a provider
---@param provider MonorepoBaseProvider Provider instance
function Detection.register_provider(provider)
  if not provider or not provider.name then
    error("Invalid provider: must have a name")
  end

  -- Validate provider implements required methods
  if not provider.detect or type(provider.detect) ~= "function" then
    error("Provider must implement detect() method")
  end

  _providers[provider.name] = provider
end

---Unregister a provider
---@param name string Provider name
function Detection.unregister_provider(name)
  _providers[name] = nil
  _provider_modules[name] = nil
end

---Clear all registered providers
function Detection.clear_providers()
  _providers = {}
  _provider_modules = {}
end

---Get registered provider by name
---@param name string Provider name
---@return MonorepoBaseProvider? provider Provider instance or nil
function Detection.get_provider(name)
  return _providers[name]
end

---Get all registered providers
---@return table<string, MonorepoBaseProvider> providers Map of provider name to instance
function Detection.get_providers()
  return _providers
end

---Lazy load provider module
---@param name string Provider name
---@return MonorepoBaseProvider? provider Loaded provider or nil
local function load_provider(name)
  if _provider_modules[name] then
    return _provider_modules[name]
  end

  local module_path = "ecolog.monorepo.detection.providers." .. name
  local ok, provider_module = pcall(require, module_path)
  if not ok then
    return nil
  end

  _provider_modules[name] = provider_module
  return provider_module
end

---Load built-in providers
---@param provider_configs table[] List of provider configurations
function Detection.load_builtin_providers(provider_configs)
  for _, config in ipairs(provider_configs or {}) do
    local provider_module = load_provider(config.name)
    if provider_module then
      local provider = provider_module.new(config)
      Detection.register_provider(provider)
    end
  end
end

---Detect monorepo at given path using all registered providers
---@param path string Directory path to check
---@return string? root_path Root path of detected monorepo
---@param MonorepoBaseProvider? provider Provider that detected the monorepo
---@param table? detection_info Additional detection information
function Detection.detect_monorepo(path)
  -- Early exit if no providers are registered
  if not next(_providers) then
    return nil, nil, nil
  end

  path = path or vim.fn.getcwd()
  path = vim.fn.fnamemodify(path, ":p:h")

  -- Check cache first
  local cache_key = "detection:" .. path
  local cached_result = Cache.get_detection(cache_key)
  if cached_result then
    return cached_result.root_path, cached_result.provider, cached_result.detection_info
  end

  -- Early termination: check if we're already at filesystem root
  if path == "/" or path == "" then
    return nil, nil, nil
  end

  local max_iterations = 10
  local current_path = path
  local iteration = 0
  local checked_paths = {} -- Avoid re-checking same paths

  while current_path ~= "/" and iteration < max_iterations do
    iteration = iteration + 1

    -- Skip if already checked this path
    if checked_paths[current_path] then
      break
    end
    checked_paths[current_path] = true

    -- Get providers sorted by priority
    local sorted_providers = {}
    for _, provider in pairs(_providers) do
      table.insert(sorted_providers, provider)
    end
    
    -- Skip if no providers available
    if #sorted_providers == 0 then
      break
    end
    
    table.sort(sorted_providers, function(a, b)
      return a.priority < b.priority
    end)

    -- Try each provider in priority order
    for _, provider in ipairs(sorted_providers) do
      local can_detect, confidence, metadata = provider:detect(current_path)

      if can_detect and confidence > 0 then
        local result = {
          root_path = current_path,
          provider = provider,
          detection_info = {
            confidence = confidence,
            metadata = metadata or {},
            detected_at = uv.now(),
          },
        }

        -- Cache the result for original path and all checked paths
        local cache_ttl = provider:get_cache_duration()
        Cache.set_detection(cache_key, result, cache_ttl)
        for checked_path in pairs(checked_paths) do
          if checked_path ~= path then
            Cache.set_detection("detection:" .. checked_path, result, cache_ttl)
          end
        end

        return result.root_path, result.provider, result.detection_info
      end
    end

    -- Move up one directory
    local parent = vim.fn.fnamemodify(current_path, ":h")
    if parent == current_path then
      break
    end
    current_path = parent
  end

  -- Cache negative result with shorter TTL for all checked paths
  local negative_result = {
    root_path = nil,
    provider = nil,
    detection_info = nil,
  }
  local negative_ttl = 60000 -- 1 minute TTL for negative results
  Cache.set_detection(cache_key, negative_result, negative_ttl)
  for checked_path in pairs(checked_paths) do
    if checked_path ~= path then
      Cache.set_detection("detection:" .. checked_path, negative_result, negative_ttl)
    end
  end

  return nil, nil, nil
end

---Detect monorepo for specific provider
---@param provider_name string Provider name
---@param path string Directory path to check
---@return string? root_path Root path of detected monorepo
---@param table? detection_info Additional detection information
function Detection.detect_with_provider(provider_name, path)
  local provider = _providers[provider_name]
  if not provider then
    return nil, nil
  end

  path = path or vim.fn.getcwd()
  path = vim.fn.fnamemodify(path, ":p:h")

  -- Check cache first
  local cache_key = "detection:" .. provider_name .. ":" .. path
  local cached_result = Cache.get_detection(cache_key)
  if cached_result then
    return cached_result.root_path, cached_result.detection_info
  end

  local max_iterations = 10
  local current_path = path
  local iteration = 0

  while current_path ~= "/" and iteration < max_iterations do
    iteration = iteration + 1

    local can_detect, confidence, metadata = provider:detect(current_path)

    if can_detect and confidence > 0 then
      local result = {
        root_path = current_path,
        detection_info = {
          confidence = confidence,
          metadata = metadata or {},
          detected_at = uv.now(),
        },
      }

      -- Cache the result
      Cache.set_detection(cache_key, result, provider:get_cache_duration())

      return result.root_path, result.detection_info
    end

    -- Move up one directory
    local parent = vim.fn.fnamemodify(current_path, ":h")
    if parent == current_path then
      break
    end
    current_path = parent
  end

  -- Cache negative result
  local negative_result = {
    root_path = nil,
    detection_info = nil,
  }
  Cache.set_detection(cache_key, negative_result, 60000) -- 1 minute TTL for negative results

  return nil, nil
end

---Get detection statistics
---@return table stats Detection performance statistics
function Detection.get_stats()
  local provider_stats = {}
  for name, provider in pairs(_providers) do
    provider_stats[name] = {
      priority = provider.priority,
      loaded = _provider_modules[name] ~= nil,
    }
  end

  return {
    providers = provider_stats,
    cache = Cache.get_stats(),
  }
end

---Clear all caches
function Detection.clear_cache()
  Cache.clear_all()
end

---Configure detection settings
---@param config table Detection configuration
function Detection.configure(config)
  if config.cache then
    Cache.configure(config.cache)
  end
end

---Get applicable providers for a path using quick heuristics
---@param path string Path to check
---@return table[] applicable_providers Providers that might detect this path
function Detection._get_applicable_providers(path)
  local applicable = {}
  
  for name, provider in pairs(_providers) do
    -- Quick heuristic: check if provider's detection markers exist
    if provider.get_quick_markers then
      local markers = provider:get_quick_markers()
      if #markers == 0 then
        -- No markers defined, include this provider
        table.insert(applicable, provider)
      else
        local has_marker = false
        for _, marker in ipairs(markers) do
          if vim.fn.filereadable(path .. "/" .. marker) == 1 then
            has_marker = true
            break
          end
        end
        if has_marker then
          table.insert(applicable, provider)
        end
      end
    else
      -- Fallback: include all providers if no quick markers method available
      table.insert(applicable, provider)
    end
  end
  
  -- If no applicable providers found, return empty list
  if #applicable == 0 then
    return {}
  end
  
  -- Sort by priority
  table.sort(applicable, function(a, b)
    return a.priority < b.priority
  end)
  
  return applicable
end

return Detection

