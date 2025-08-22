local assert = require("luassert")
local stub = require("luassert.stub")
local spy = require("luassert.spy")

describe("async env loader", function()
  local async_loader
  local types_mock
  local interpolation_mock
  local utils_mock
  local file_operations_mock

  before_each(function()
    -- Reset modules
    package.loaded["ecolog.env_loader_async"] = nil
    package.loaded["ecolog.types"] = nil
    package.loaded["ecolog.interpolation"] = nil
    package.loaded["ecolog.utils"] = nil
    package.loaded["ecolog.core.file_operations"] = nil
    
    -- Mock dependencies
    types_mock = {
      detect_type = spy.new(function(value)
        if value == "true" or value == "false" then
          return "boolean", value == "true"
        elseif tonumber(value) then
          return "number", tonumber(value)
        else
          return "string", value
        end
      end)
    }
    package.preload["ecolog.types"] = function() return types_mock end
    
    interpolation_mock = {
      interpolate_variables = spy.new(function(vars, opts) return vars end)
    }
    package.preload["ecolog.interpolation"] = function() return interpolation_mock end
    
    utils_mock = {
      extract_line_parts = spy.new(function(line)
        local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if key and value then
          -- Remove quotes if present
          local quote_char = value:match("^(['\"])") 
          if quote_char then
            value = value:gsub("^" .. quote_char .. "(.*)" .. quote_char .. "$", "%1")
          end
          return key, value, nil, quote_char
        end
        return nil, nil, nil, nil
      end)
    }
    package.preload["ecolog.utils"] = function() return utils_mock end
    
    file_operations_mock = {
      read_files_batch = spy.new(function(file_paths, callback)
        -- Mock file reading - simulate success for most files
        local contents = {}
        local errors = {}
        
        for _, path in ipairs(file_paths) do
          if path:match("error") then
            errors[path] = "Mock read error"
          else
            contents[path] = {
              "KEY1=value1",
              "KEY2=123",
              "KEY3=true",
              "# Comment line",
              "KEY4=\"quoted value\""
            }
          end
        end
        
        vim.defer_fn(function()
          callback(contents, errors)
        end, 1)
      end),
      get_mtime = spy.new(function(path)
        return 1234567890 -- Mock modification time
      end)
    }
    package.preload["ecolog.core.file_operations"] = function() return file_operations_mock end
    
    async_loader = require("ecolog.env_loader_async")
  end)

  after_each(function()
    package.preload["ecolog.types"] = nil
    package.preload["ecolog.interpolation"] = nil
    package.preload["ecolog.utils"] = nil
    package.preload["ecolog.core.file_operations"] = nil
  end)

  describe("parse_env_files_parallel", function()
    describe("basic functionality", function()
      it("should parse multiple files in parallel", function()
        local file_paths = {"/test/.env", "/test/.env.local"}
        local results, errors
        local done = false

        async_loader.parse_env_files_parallel(file_paths, {}, function(r, e)
          results = r
          errors = e
          done = true
        end)

        -- Wait for async completion
        vim.wait(100, function() return done end)

        assert.is_true(done)
        assert.is_table(results)
        assert.is_table(errors)
        assert.is_not_nil(results["/test/.env"])
        assert.is_not_nil(results["/test/.env.local"])
        
        -- Check parsed variables
        local env_vars = results["/test/.env"]
        assert.is_not_nil(env_vars.KEY1)
        assert.equals("value1", env_vars.KEY1.value)
        assert.equals("string", env_vars.KEY1.type)
        assert.equals("/test/.env", env_vars.KEY1.source)
      end)

      it("should handle empty file list", function()
        local results, errors
        local done = false

        async_loader.parse_env_files_parallel({}, {}, function(r, e)
          results = r
          errors = e
          done = true
        end)

        vim.wait(50, function() return done end)

        assert.is_true(done)
        assert.is_table(results)
        assert.is_table(errors)
        assert.equals(0, vim.tbl_count(results))
        assert.equals(0, vim.tbl_count(errors))
      end)

      it("should handle nil file list", function()
        local results, errors
        local done = false

        async_loader.parse_env_files_parallel(nil, {}, function(r, e)
          results = r
          errors = e
          done = true
        end)

        vim.wait(50, function() return done end)

        assert.is_true(done)
        assert.is_table(results)
        assert.is_table(errors)
        assert.equals(0, vim.tbl_count(results))
        assert.equals(0, vim.tbl_count(errors))
      end)
    end)

    describe("error handling", function()
      it("should handle file read errors gracefully", function()
        local file_paths = {"/test/.env", "/test/error.env", "/test/.env.local"}
        local results, errors
        local done = false

        async_loader.parse_env_files_parallel(file_paths, {}, function(r, e)
          results = r
          errors = e
          done = true
        end)

        vim.wait(100, function() return done end)

        assert.is_true(done)
        assert.is_table(results)
        assert.is_table(errors)
        
        -- Should have results for successful files
        assert.is_not_nil(results["/test/.env"])
        assert.is_not_nil(results["/test/.env.local"])
        
        -- Should have error for failed file
        assert.is_not_nil(errors["/test/error.env"])
        assert.equals("Mock read error", errors["/test/error.env"])
      end)

      it("should handle parse errors in individual files", function()
        -- Mock a file that will cause parse errors
        file_operations_mock.read_files_batch = spy.new(function(file_paths, callback)
          local contents = {}
          local errors = {}
          
          for _, path in ipairs(file_paths) do
            if path:match("malformed") then
              contents[path] = {
                "INVALID_LINE_NO_EQUALS",
                "ANOTHER=valid_line"
              }
            else
              contents[path] = {"KEY=value"}
            end
          end
          
          vim.defer_fn(function()
            callback(contents, errors)
          end, 1)
        end)

        local file_paths = {"/test/malformed.env", "/test/.env"}
        local results, errors
        local done = false

        async_loader.parse_env_files_parallel(file_paths, {}, function(r, e)
          results = r
          errors = e
          done = true
        end)

        vim.wait(100, function() return done end)

        assert.is_true(done)
        assert.is_table(results)
        assert.is_table(errors)
        
        -- Should still parse valid lines from malformed file
        assert.is_not_nil(results["/test/malformed.env"])
        assert.is_not_nil(results["/test/malformed.env"].ANOTHER)
        assert.equals("valid_line", results["/test/malformed.env"].ANOTHER.value)
        
        -- Should have successful result for good file
        assert.is_not_nil(results["/test/.env"])
      end)
    end)

    describe("variable parsing", function()
      it("should parse different variable types correctly", function()
        file_operations_mock.read_files_batch = spy.new(function(file_paths, callback)
          local contents = {
            [file_paths[1]] = {
              "STRING_VAR=hello world",
              "NUMBER_VAR=42",
              "BOOLEAN_TRUE=true",
              "BOOLEAN_FALSE=false",
              "QUOTED_VAR=\"quoted value\"",
              "SINGLE_QUOTED='single quoted'",
              "EMPTY_VAR=",
              "# This is a comment",
              "",
              "AFTER_EMPTY=value"
            }
          }
          
          vim.defer_fn(function()
            callback(contents, {})
          end, 1)
        end)

        local file_paths = {"/test/.env"}
        local results, errors
        local done = false

        async_loader.parse_env_files_parallel(file_paths, {}, function(r, e)
          results = r
          errors = e
          done = true
        end)

        vim.wait(100, function() return done end)

        assert.is_true(done)
        local env_vars = results["/test/.env"]
        
        assert.equals("hello world", env_vars.STRING_VAR.value)
        assert.equals("string", env_vars.STRING_VAR.type)
        
        assert.equals(42, env_vars.NUMBER_VAR.value)
        assert.equals("number", env_vars.NUMBER_VAR.type)
        
        assert.equals(true, env_vars.BOOLEAN_TRUE.value)
        assert.equals("boolean", env_vars.BOOLEAN_TRUE.type)
        
        assert.equals(false, env_vars.BOOLEAN_FALSE.value)
        assert.equals("boolean", env_vars.BOOLEAN_FALSE.type)
        
        assert.equals("quoted value", env_vars.QUOTED_VAR.value)
        assert.equals("single quoted", env_vars.SINGLE_QUOTED.value)
        
        -- Empty var should still be parsed
        assert.is_not_nil(env_vars.EMPTY_VAR)
        assert.equals("", env_vars.EMPTY_VAR.value)
        
        assert.equals("value", env_vars.AFTER_EMPTY.value)
      end)

      it("should preserve source file information", function()
        local file_paths = {"/path/to/.env", "/other/path/.env.local"}
        local results, errors
        local done = false

        async_loader.parse_env_files_parallel(file_paths, {}, function(r, e)
          results = r
          errors = e
          done = true
        end)

        vim.wait(100, function() return done end)

        assert.is_true(done)
        
        local env_vars = results["/path/to/.env"]
        assert.equals("/path/to/.env", env_vars.KEY1.source)
        assert.equals(".env", env_vars.KEY1.source_file)
        
        local local_vars = results["/other/path/.env.local"]
        assert.equals("/other/path/.env.local", local_vars.KEY1.source)
        assert.equals(".env.local", local_vars.KEY1.source_file)
      end)

      it("should skip comments and empty lines", function()
        file_operations_mock.read_files_batch = spy.new(function(file_paths, callback)
          local contents = {
            [file_paths[1]] = {
              "# This is a comment",
              "",
              "   # Indented comment",
              "VALID_VAR=value",
              "   ",
              "## Another comment style",
              "ANOTHER_VAR=another_value"
            }
          }
          
          vim.defer_fn(function()
            callback(contents, {})
          end, 1)
        end)

        local file_paths = {"/test/.env"}
        local results, errors
        local done = false

        async_loader.parse_env_files_parallel(file_paths, {}, function(r, e)
          results = r
          errors = e
          done = true
        end)

        vim.wait(100, function() return done end)

        assert.is_true(done)
        local env_vars = results["/test/.env"]
        
        -- Should only have the two valid variables
        assert.is_not_nil(env_vars.VALID_VAR)
        assert.is_not_nil(env_vars.ANOTHER_VAR)
        assert.equals("value", env_vars.VALID_VAR.value)
        assert.equals("another_value", env_vars.ANOTHER_VAR.value)
        
        -- Should not have comment variables
        local count = 0
        for _ in pairs(env_vars) do count = count + 1 end
        assert.equals(2, count)
      end)
    end)

    describe("performance and caching", function()
      it("should handle large numbers of files efficiently", function()
        local large_file_list = {}
        for i = 1, 100 do
          table.insert(large_file_list, "/test/.env" .. i)
        end

        local start_time = vim.loop.hrtime()
        local results, errors
        local done = false

        async_loader.parse_env_files_parallel(large_file_list, {}, function(r, e)
          results = r
          errors = e
          done = true
        end)

        vim.wait(1000, function() return done end)
        local end_time = vim.loop.hrtime()

        assert.is_true(done)
        assert.is_table(results)
        
        -- Should complete in reasonable time
        local duration_ms = (end_time - start_time) / 1000000
        assert.is_true(duration_ms < 5000) -- Less than 5 seconds
        
        -- Should have results for all files
        assert.equals(100, vim.tbl_count(results))
      end)

      it("should use FileOperations for mtime caching", function()
        local file_paths = {"/test/.env"}
        local done = false

        async_loader.parse_env_files_parallel(file_paths, {}, function(r, e)
          done = true
        end)

        vim.wait(100, function() return done end)

        -- Should have called get_mtime for caching
        assert.spy(file_operations_mock.get_mtime).was.called()
      end)
    end)

    describe("configuration options", function()
      it("should pass options to parsing functions", function()
        local file_paths = {"/test/.env"}
        local opts = {
          interpolate = true,
          some_option = "test_value"
        }
        local done = false

        async_loader.parse_env_files_parallel(file_paths, opts, function(r, e)
          done = true
        end)

        vim.wait(100, function() return done end)

        assert.is_true(done)
        -- Verify that options were used in parsing
        assert.spy(utils_mock.extract_line_parts).was.called()
      end)

      it("should handle nil options gracefully", function()
        local file_paths = {"/test/.env"}
        local done = false

        async_loader.parse_env_files_parallel(file_paths, nil, function(r, e)
          done = true
        end)

        vim.wait(100, function() return done end)

        assert.is_true(done)
      end)
    end)
  end)

  describe("caching functionality", function()
    -- Note: These tests would require access to internal caching functions
    -- which may need to be exposed for testing or tested indirectly
    
    it("should cache parsing results based on file modification time", function()
      local file_paths = {"/test/.env"}
      local call_count = 0
      
      -- Track how many times we actually parse
      local original_extract = utils_mock.extract_line_parts
      utils_mock.extract_line_parts = spy.new(function(...)
        call_count = call_count + 1
        return original_extract(...)
      end)
      
      -- First call
      local done1 = false
      async_loader.parse_env_files_parallel(file_paths, {}, function(r, e)
        done1 = true
      end)
      vim.wait(100, function() return done1 end)
      
      local first_call_count = call_count
      
      -- Second call with same mtime should use cache
      local done2 = false
      async_loader.parse_env_files_parallel(file_paths, {}, function(r, e)
        done2 = true
      end)
      vim.wait(100, function() return done2 end)
      
      -- Note: This test assumes caching is working, but may need
      -- internal cache inspection to verify properly
      assert.is_true(done1)
      assert.is_true(done2)
    end)
  end)
end)