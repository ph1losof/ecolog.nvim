---@class EcologBinary
---Binary detection and validation for ecolog-lsp
local M = {}

---@type string|nil Cached binary path
local cached_path = nil

---@type string|nil Cached source name
local cached_source = nil

---@class BinarySearchLocation
---@field name string Display name of the location
---@field path fun(): string Function that returns the path to check

---Search locations in priority order
---@type BinarySearchLocation[]
local SEARCH_LOCATIONS = {
  {
    name = "Mason",
    path = function()
      return vim.fn.stdpath("data") .. "/mason/bin/ecolog-lsp"
    end,
  },
  {
    name = "PATH",
    path = function()
      return "ecolog-lsp"
    end,
  },
  {
    name = "Cargo",
    path = function()
      return vim.fn.expand("$HOME/.cargo/bin/ecolog-lsp")
    end,
  },
}

---Check if a binary path is executable
---@param path string
---@return boolean
local function is_executable(path)
  return vim.fn.executable(path) == 1
end

---Find the ecolog-lsp binary
---@param force_refresh? boolean Force re-detection even if cached
---@return string path Binary path
---@return string|nil source Source name (Mason, PATH, Cargo) or nil if fallback
function M.find(force_refresh)
  if cached_path and not force_refresh then
    return cached_path, cached_source
  end

  for _, location in ipairs(SEARCH_LOCATIONS) do
    local path = location.path()
    if is_executable(path) then
      cached_path = path
      cached_source = location.name
      return path, location.name
    end
  end

  -- Fallback: assume it will be in PATH at runtime
  -- This allows setup to proceed; health check will catch issues
  cached_path = "ecolog-lsp"
  cached_source = nil
  return cached_path, nil
end

---Get the cached path without re-detection
---@return string|nil path
---@return string|nil source
function M.get_cached()
  return cached_path, cached_source
end

---Clear the cached path
function M.clear_cache()
  cached_path = nil
  cached_source = nil
end

---Get detailed info about all search locations
---@return {name: string, path: string, available: boolean}[]
function M.get_search_info()
  local info = {}
  for _, location in ipairs(SEARCH_LOCATIONS) do
    local path = location.path()
    table.insert(info, {
      name = location.name,
      path = path,
      available = is_executable(path),
    })
  end
  return info
end

---Check if ecolog-lsp binary is available
---@return boolean available
---@return string|nil path Path if found
---@return string|nil source Source if found
function M.is_available()
  local path, source = M.find()
  if source then
    return true, path, source
  end
  -- Check if fallback path is actually executable
  return is_executable(path), path, nil
end

return M
