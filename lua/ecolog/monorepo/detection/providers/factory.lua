---@class ProviderFactory
local Factory = {}

local BaseProvider = require("ecolog.monorepo.detection.providers.base")

---Create a simple provider from configuration
---@param config table Provider configuration
---@return table provider Created provider instance
function Factory.create_simple_provider(config)
  -- Validate required fields
  if not config.name or type(config.name) ~= "string" then
    error("Provider name is required")
  end

  if not config.detection or not config.detection.file_markers then
    error("Provider detection.file_markers is required")
  end

  -- Create provider class
  local SimpleProvider = {}
  setmetatable(SimpleProvider, { __index = BaseProvider })

  ---Create new instance
  ---@param instance_config? table Optional instance configuration
  function SimpleProvider.new(instance_config)
    local merged_config = instance_config and vim.tbl_deep_extend("force", config, instance_config) or config

    local valid, error_msg = BaseProvider.validate_config(merged_config)
    if not valid then
      error("Invalid provider configuration: " .. error_msg)
    end

    local instance = BaseProvider.new(merged_config)
    setmetatable(instance, { __index = SimpleProvider })
    return instance
  end

  ---Simple detection based on file markers
  ---@param path string Directory path to check
  ---@return boolean can_detect Whether provider can detect monorepo
  ---@return number confidence Detection confidence (0-100)
  ---@return table? metadata Additional detection metadata
  function SimpleProvider:detect(path)
    local markers = self.config.detection.file_markers
    local confidence = 50 -- Base confidence for simple providers
    local found_markers = {}

    for _, marker in ipairs(markers) do
      local marker_path = path .. "/" .. marker
      if self:file_exists(marker_path) then
        table.insert(found_markers, marker)
        confidence = confidence + (40 / #markers) -- Distribute confidence across markers
      end
    end

    if #found_markers == 0 then
      return false, 0, nil
    end

    local metadata = {
      marker_files = found_markers,
      provider_type = "simple",
    }

    -- Custom detection function if provided
    if config.custom_detect then
      local custom_result = config.custom_detect(self, path, found_markers)
      if custom_result then
        if custom_result.confidence then
          confidence = custom_result.confidence
        end
        if custom_result.metadata then
          metadata = vim.tbl_deep_extend("force", metadata, custom_result.metadata)
        end
      end
    end

    return true, math.min(confidence, 99), metadata
  end

  return SimpleProvider
end

---Create a JSON-based provider that reads configuration files
---@param config table Provider configuration with json_parser field
---@return table provider Created provider instance
function Factory.create_json_provider(config)
  -- Validate JSON-specific requirements
  if not config.json_parser or not config.json_parser.config_field then
    error("JSON provider requires json_parser.config_field")
  end

  local JsonProvider = {}
  setmetatable(JsonProvider, { __index = BaseProvider })

  function JsonProvider.new(instance_config)
    local merged_config = instance_config and vim.tbl_deep_extend("force", config, instance_config) or config

    local valid, error_msg = BaseProvider.validate_config(merged_config)
    if not valid then
      error("Invalid JSON provider configuration: " .. error_msg)
    end

    local instance = BaseProvider.new(merged_config)
    setmetatable(instance, { __index = JsonProvider })
    return instance
  end

  ---JSON-based detection with configuration parsing
  function JsonProvider:detect(path)
    local markers = self.config.detection.file_markers
    local config_field = self.config.json_parser.config_field
    local confidence = 60 -- Higher base confidence for JSON providers
    local found_markers = {}
    local json_configs = {}

    for _, marker in ipairs(markers) do
      local marker_path = path .. "/" .. marker
      if self:file_exists(marker_path) then
        table.insert(found_markers, marker)

        -- Parse JSON configuration
        local json_config = self:read_json_file(marker_path)
        if json_config and json_config[config_field] then
          json_configs[marker] = json_config
          confidence = confidence + 20
        end
      end
    end

    if #found_markers == 0 then
      return false, 0, nil
    end

    local metadata = {
      marker_files = found_markers,
      json_configs = json_configs,
      provider_type = "json",
    }

    -- Custom JSON validation if provided
    if config.json_parser.validate then
      for marker, json_config in pairs(json_configs) do
        if config.json_parser.validate(json_config, marker) then
          confidence = confidence + 10
        end
      end
    end

    return true, math.min(confidence, 99), metadata
  end

  ---Get dynamic workspace patterns from JSON configuration
  function JsonProvider:get_dynamic_workspace_patterns(detection_metadata)
    local patterns = self:get_workspace_patterns()

    if detection_metadata and detection_metadata.json_configs then
      for _, json_config in pairs(detection_metadata.json_configs) do
        local config_field = self.config.json_parser.config_field
        local workspace_config = json_config[config_field]

        if workspace_config and self.config.json_parser.extract_patterns then
          local extracted_patterns = self.config.json_parser.extract_patterns(workspace_config)
          if extracted_patterns then
            for _, pattern in ipairs(extracted_patterns) do
              if not vim.tbl_contains(patterns, pattern) then
                table.insert(patterns, pattern)
              end
            end
          end
        end
      end
    end

    return patterns
  end

  return JsonProvider
end

---Create a custom provider with full control over detection logic
---@param config table Provider configuration with custom detection functions
---@return table provider Created provider instance
function Factory.create_custom_provider(config)
  if not config.detect_function then
    error("Custom provider requires detect_function")
  end

  local CustomProvider = {}
  setmetatable(CustomProvider, { __index = BaseProvider })

  function CustomProvider.new(instance_config)
    local merged_config = instance_config and vim.tbl_deep_extend("force", config, instance_config) or config

    local valid, error_msg = BaseProvider.validate_config(merged_config)
    if not valid then
      error("Invalid custom provider configuration: " .. error_msg)
    end

    local instance = BaseProvider.new(merged_config)
    setmetatable(instance, { __index = CustomProvider })
    return instance
  end

  ---Custom detection logic
  function CustomProvider:detect(path)
    return config.detect_function(self, path)
  end

  -- Override other methods if provided
  if config.get_workspace_patterns then
    function CustomProvider:get_workspace_patterns()
      return config.get_workspace_patterns(self)
    end
  end

  if config.get_env_resolution then
    function CustomProvider:get_env_resolution()
      return config.get_env_resolution(self)
    end
  end

  return CustomProvider
end

---Create provider from template
---@param template_name string Name of the template to use
---@param overrides table Configuration overrides
---@return table provider Created provider instance
function Factory.create_from_template(template_name, overrides)
  local templates = {
    -- Simple file marker-based template
    simple = {
      detection = {
        strategies = { "file_markers" },
        max_depth = 4,
        cache_duration = 300000,
      },
      workspace = {
        patterns = { "packages/*", "apps/*" },
        priority = { "apps", "packages" },
      },
      env_resolution = {
        strategy = "workspace_first",
        inheritance = true,
        override_order = { "workspace", "root" },
      },
      priority = 50,
    },

    -- JavaScript/TypeScript monorepo template
    js_monorepo = {
      detection = {
        strategies = { "file_markers" },
        max_depth = 4,
        cache_duration = 300000,
      },
      workspace = {
        patterns = { "packages/*", "apps/*", "libs/*", "tools/*" },
        priority = { "apps", "packages", "libs", "tools" },
      },
      env_resolution = {
        strategy = "workspace_first",
        inheritance = true,
        override_order = { "workspace", "root" },
      },
      priority = 30,
    },

    -- Generic workspace template
    generic = {
      detection = {
        strategies = { "file_markers" },
        max_depth = 6,
        cache_duration = 300000,
      },
      workspace = {
        patterns = { "*/*" },
        priority = {},
      },
      env_resolution = {
        strategy = "merge",
        inheritance = true,
        override_order = { "workspace", "root" },
      },
      priority = 90,
    },
  }

  local template = templates[template_name]
  if not template then
    error("Unknown template: " .. template_name)
  end

  local config = vim.tbl_deep_extend("force", template, overrides)
  return Factory.create_simple_provider(config)
end

---Validate provider configuration before creation
---@param config table Provider configuration to validate
---@return boolean valid Whether configuration is valid
---@return string? error Error message if invalid
function Factory.validate_provider_config(config)
  return BaseProvider.validate_config(config)
end

---Get available templates
---@return string[] templates List of available template names
function Factory.get_available_templates()
  return { "simple", "js_monorepo", "generic" }
end

return Factory

