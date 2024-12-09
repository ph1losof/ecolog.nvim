local M = {}

-- Table to store language providers
M.providers = {}

-- Provider interface definition
---@class Provider
---@field pattern string Pattern to match environment variable access
---@field filetype string[] List of filetypes this provider supports
---@field extract_var function Function to extract variable name from line
---@field get_completion_trigger function Function to get completion trigger pattern

-- Register multiple providers
function M.register_many(providers)
	if type(providers) ~= "table" then
		error("Providers must be a table")
	end

	for _, provider in ipairs(providers) do
		M.register(provider)
	end
end

-- Register a new language provider
function M.register(provider)
	if not provider.pattern or not provider.filetype or not provider.extract_var then
		error("Provider must have pattern, filetype, and extract_var fields")
	end

	-- Allow single filetype to be passed as string
	if type(provider.filetype) == "string" then
		provider.filetype = { provider.filetype }
	end

	-- Register provider for each filetype
	for _, ft in ipairs(provider.filetype) do
		if not M.providers[ft] then
			M.providers[ft] = {}
		end
		table.insert(M.providers[ft], provider)
	end
end

-- Get providers for a filetype
function M.get_providers(filetype)
	return M.providers[filetype] or {}
end

return M

