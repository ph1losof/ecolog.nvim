local assert = require("luassert")
local stub = require("luassert.stub")
local spy = require("luassert.spy")

describe("file_operations", function()
  local file_operations
  local test_dir
  local notification_manager

  local function create_test_file(path, content)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local file = io.open(path, "w")
    if file then
      file:write(content or "test content")
      file:close()
    end
  end

  local function cleanup_test_files(path)
    vim.fn.delete(path, "rf")
  end

  before_each(function()
    -- Reset modules
    package.loaded["ecolog.core.file_operations"] = nil
    package.loaded["ecolog.core.notification_manager"] = nil
    
    -- Mock notification manager
    notification_manager = {
      notify = spy.new(function() end),
      notify_file_deleted = spy.new(function() end)
    }
    package.preload["ecolog.core.notification_manager"] = function()
      return notification_manager
    end
    
    file_operations = require("ecolog.core.file_operations")
    test_dir = vim.fn.tempname()
    vim.fn.mkdir(test_dir, "p")
    
    -- Clear any existing cache
    file_operations.clear_mtime_cache()
  end)

  after_each(function()
    cleanup_test_files(test_dir)
    file_operations.clear_mtime_cache()
    package.preload["ecolog.core.notification_manager"] = nil
  end)

  describe("is_readable", function()
    it("should return true for readable files", function()
      local test_file = test_dir .. "/readable.txt"
      create_test_file(test_file, "test content")
      
      assert.is_true(file_operations.is_readable(test_file))
    end)

    it("should return false for non-existent files", function()
      local non_existent = test_dir .. "/does-not-exist.txt"
      assert.is_false(file_operations.is_readable(non_existent))
    end)

    it("should return false for invalid input", function()
      assert.is_false(file_operations.is_readable(nil))
      assert.is_false(file_operations.is_readable(123))
      assert.is_false(file_operations.is_readable(""))
    end)
  end)

  describe("get_mtime", function()
    it("should return modification time for existing files", function()
      local test_file = test_dir .. "/mtime_test.txt"
      create_test_file(test_file, "content")
      
      local mtime = file_operations.get_mtime(test_file)
      assert.is_number(mtime)
      assert.is_true(mtime > 0)
    end)

    it("should return 0 for non-existent files", function()
      local non_existent = test_dir .. "/does-not-exist.txt"
      local mtime = file_operations.get_mtime(non_existent)
      assert.equals(0, mtime)
    end)

    it("should cache modification time", function()
      local test_file = test_dir .. "/cache_test.txt"
      create_test_file(test_file, "content")
      
      local mtime1 = file_operations.get_mtime(test_file)
      local mtime2 = file_operations.get_mtime(test_file)
      
      assert.equals(mtime1, mtime2)
    end)

    it("should respect cache duration", function()
      local test_file = test_dir .. "/cache_duration_test.txt"
      create_test_file(test_file, "content")
      
      -- Mock vim.loop.now to control time
      local original_now = vim.loop.now
      local mock_time = 1000000
      
      stub(vim.loop, "now", function()
        return mock_time
      end)
      
      local mtime1 = file_operations.get_mtime(test_file)
      
      -- Advance time beyond cache duration
      mock_time = mock_time + 31000 -- 31 seconds
      
      local mtime2 = file_operations.get_mtime(test_file)
      
      vim.loop.now:revert()
      
      assert.equals(mtime1, mtime2) -- Should still be same since file didn't change
    end)
  end)

  describe("is_modified", function()
    it("should detect when file is modified", function()
      local test_file = test_dir .. "/modified_test.txt"
      create_test_file(test_file, "original content")
      
      local initial_mtime = file_operations.get_mtime(test_file)
      
      -- Force clear cache and wait longer for filesystem
      file_operations.clear_mtime_cache(test_file)
      vim.wait(1000) -- Wait longer for file system
      create_test_file(test_file, "new content")
      
      local is_modified, current_mtime = file_operations.is_modified(test_file, initial_mtime)
      assert.is_true(is_modified)
      assert.is_true(current_mtime >= initial_mtime)
    end)

    it("should return true when no last_mtime provided", function()
      local test_file = test_dir .. "/no_mtime_test.txt"
      create_test_file(test_file, "content")
      
      local is_modified, current_mtime = file_operations.is_modified(test_file, nil)
      assert.is_true(is_modified)
      assert.is_number(current_mtime)
    end)
  end)

  describe("read_file_sync", function()
    it("should read file content successfully", function()
      local test_file = test_dir .. "/sync_read.txt"
      local test_content = "line1\nline2\nline3"
      create_test_file(test_file, test_content)
      
      local content, error = file_operations.read_file_sync(test_file)
      
      assert.is_nil(error)
      assert.are.same({"line1", "line2", "line3"}, content)
    end)

    it("should handle empty files", function()
      local test_file = test_dir .. "/empty.txt"
      create_test_file(test_file, "")
      
      local content, error = file_operations.read_file_sync(test_file)
      
      assert.is_nil(error)
      assert.are.same({}, content)
    end)

    it("should return error for non-readable files", function()
      local non_existent = test_dir .. "/does-not-exist.txt"
      
      local content, error = file_operations.read_file_sync(non_existent)
      
      assert.is_nil(content)
      assert.is_string(error)
      assert.matches("not readable", error)
    end)

    it("should handle file read errors gracefully", function()
      local test_file = test_dir .. "/read_error.txt"
      create_test_file(test_file, "content")
      
      -- Mock io.open to simulate read error
      local original_open = io.open
      stub(io, "open", function()
        return nil, "Permission denied"
      end)
      
      local content, error = file_operations.read_file_sync(test_file)
      
      io.open:revert()
      
      assert.is_nil(content)
      assert.is_string(error)
      assert.matches("Could not open file", error)
    end)
  end)

  describe("read_file_async", function()
    it("should read file asynchronously", function()
      local test_file = test_dir .. "/async_read.txt"
      create_test_file(test_file, "line1\nline2")
      
      local callback_called = false
      local result_content, result_error
      
      file_operations.read_file_async(test_file, function(content, error)
        callback_called = true
        result_content = content
        result_error = error
      end)
      
      -- Wait for async operation
      vim.wait(100)
      
      assert.is_true(callback_called)
      assert.is_nil(result_error)
      assert.are.same({"line1", "line2"}, result_content)
    end)

    it("should handle non-readable files", function()
      local non_existent = test_dir .. "/does-not-exist.txt"
      
      local callback_called = false
      local result_content, result_error
      
      file_operations.read_file_async(non_existent, function(content, error)
        callback_called = true
        result_content = content
        result_error = error
      end)
      
      -- Wait for async operation
      vim.wait(100)
      
      assert.is_true(callback_called)
      assert.is_nil(result_content)
      assert.is_string(result_error)
      assert.matches("not readable", result_error)
    end)

    it("should validate callback function", function()
      local test_file = test_dir .. "/callback_validation.txt"
      create_test_file(test_file, "content")
      
      file_operations.read_file_async(test_file, nil)
      file_operations.read_file_async(test_file, "not a function")
      
      assert.spy(notification_manager.notify).was.called(2)
    end)
  end)

  describe("read_files_batch", function()
    it("should read multiple files", function()
      local file1 = test_dir .. "/batch1.txt"
      local file2 = test_dir .. "/batch2.txt"
      create_test_file(file1, "content1\nline2")
      create_test_file(file2, "content2")
      
      local callback_called = false
      local results, errors
      
      file_operations.read_files_batch({file1, file2}, function(res, err)
        callback_called = true
        results = res
        errors = err
      end)
      
      -- Wait for async operation
      vim.wait(200)
      
      assert.is_true(callback_called)
      assert.are.same({"content1", "line2"}, results[file1])
      assert.are.same({"content2"}, results[file2])
      assert.is_table(errors)
    end)

    it("should handle mix of readable and non-readable files", function()
      local readable_file = test_dir .. "/readable.txt"
      local non_existent = test_dir .. "/does-not-exist.txt"
      create_test_file(readable_file, "content")
      
      local callback_called = false
      local results, errors
      
      file_operations.read_files_batch({readable_file, non_existent}, function(res, err)
        callback_called = true
        results = res
        errors = err
      end)
      
      -- Wait for async operation
      vim.wait(200)
      
      assert.is_true(callback_called)
      assert.are.same({"content"}, results[readable_file])
      assert.is_string(errors[non_existent])
    end)

    it("should handle empty file list", function()
      local callback_called = false
      local results, errors
      
      file_operations.read_files_batch({}, function(res, err)
        callback_called = true
        results = res
        errors = err
      end)
      
      -- Wait for async operation
      vim.wait(100)
      
      assert.is_true(callback_called)
      assert.are.same({}, results)
      assert.are.same({}, errors)
    end)
  end)

  describe("check_files_batch", function()
    it("should check multiple files", function()
      local file1 = test_dir .. "/exists1.txt"
      local file2 = test_dir .. "/exists2.txt"
      local non_existent = test_dir .. "/does-not-exist.txt"
      
      create_test_file(file1, "content")
      create_test_file(file2, "content")
      
      local readable_map = file_operations.check_files_batch({file1, file2, non_existent})
      
      assert.is_true(readable_map[file1])
      assert.is_true(readable_map[file2])
      assert.is_false(readable_map[non_existent])
    end)
  end)

  describe("get_files_stats", function()
    it("should get stats for existing files", function()
      local test_file = test_dir .. "/stats_test.txt"
      create_test_file(test_file, "test content")
      
      local stats_map = file_operations.get_files_stats({test_file})
      local stats = stats_map[test_file]
      
      assert.is_true(stats.exists)
      assert.is_number(stats.mtime)
      assert.is_number(stats.size)
      assert.is_string(stats.type)
    end)

    it("should handle non-existent files", function()
      local non_existent = test_dir .. "/does-not-exist.txt"
      
      local stats_map = file_operations.get_files_stats({non_existent})
      local stats = stats_map[non_existent]
      
      assert.is_false(stats.exists)
      assert.is_nil(stats.mtime)
    end)
  end)

  describe("clear_mtime_cache", function()
    it("should clear specific file from cache", function()
      local test_file = test_dir .. "/cache_clear.txt"
      create_test_file(test_file, "content")
      
      -- Populate cache
      file_operations.get_mtime(test_file)
      
      local stats_before = file_operations.get_cache_stats()
      assert.is_true(stats_before.mtime_cache_size > 0)
      
      -- Clear specific file
      file_operations.clear_mtime_cache(test_file)
      
      local stats_after = file_operations.get_cache_stats()
      assert.equals(0, stats_after.mtime_cache_size)
    end)

    it("should clear entire cache when no file specified", function()
      local file1 = test_dir .. "/cache1.txt"
      local file2 = test_dir .. "/cache2.txt"
      create_test_file(file1, "content1")
      create_test_file(file2, "content2")
      
      -- Populate cache
      file_operations.get_mtime(file1)
      file_operations.get_mtime(file2)
      
      local stats_before = file_operations.get_cache_stats()
      assert.is_true(stats_before.mtime_cache_size >= 2)
      
      -- Clear all cache
      file_operations.clear_mtime_cache()
      
      local stats_after = file_operations.get_cache_stats()
      assert.equals(0, stats_after.mtime_cache_size)
    end)
  end)

  describe("get_cache_stats", function()
    it("should return cache statistics", function()
      local stats = file_operations.get_cache_stats()
      
      assert.is_number(stats.mtime_cache_size)
      assert.is_number(stats.mtime_cache_duration)
      assert.equals(30000, stats.mtime_cache_duration)
    end)
  end)

  describe("handle_file_deletion", function()
    it("should handle deletion and select new file", function()
      -- Reset the module to ensure fresh state
      package.loaded["ecolog.utils"] = nil
      
      -- Mock utils.find_env_files
      local mock_utils = {
        find_env_files = function()
          return {test_dir .. "/backup.env"}
        end
      }
      package.preload["ecolog.utils"] = function()
        return mock_utils
      end
      
      -- Force reload file_operations to pick up new utils mock  
      package.loaded["ecolog.core.file_operations"] = nil
      local fresh_file_operations = require("ecolog.core.file_operations")
      
      local state = {
        env_vars = {TEST = "value"},
        _env_line_cache = {cached = true},
        selected_env_file = test_dir .. "/deleted.env"
      }
      local config = {}
      local deleted_file = test_dir .. "/deleted.env"
      
      local new_file = fresh_file_operations.handle_file_deletion(state, config, deleted_file)
      
      assert.equals(test_dir .. "/backup.env", new_file)
      assert.equals(test_dir .. "/backup.env", state.selected_env_file)
      assert.are.same({}, state.env_vars)
      assert.are.same({}, state._env_line_cache)
      assert.spy(notification_manager.notify_file_deleted).was.called(1)
      
      package.preload["ecolog.utils"] = nil
    end)

    it("should handle deletion with no backup files", function()
      -- Reset the module to ensure fresh state
      package.loaded["ecolog.utils"] = nil
      
      -- Mock utils.find_env_files to return empty
      local mock_utils = {
        find_env_files = function()
          return {}
        end
      }
      package.preload["ecolog.utils"] = function()
        return mock_utils
      end
      
      -- Force reload file_operations to pick up new utils mock
      package.loaded["ecolog.core.file_operations"] = nil
      local fresh_file_operations = require("ecolog.core.file_operations")
      
      local state = {
        env_vars = {TEST = "value"},
        _env_line_cache = {cached = true},
        selected_env_file = test_dir .. "/deleted.env"
      }
      local config = {}
      local deleted_file = test_dir .. "/deleted.env"
      
      local new_file = fresh_file_operations.handle_file_deletion(state, config, deleted_file)
      
      assert.is_nil(new_file)
      assert.is_nil(state.selected_env_file)
      assert.are.same({}, state.env_vars)
      assert.are.same({}, state._env_line_cache)
      assert.spy(notification_manager.notify_file_deleted).was.called(1)
      
      package.preload["ecolog.utils"] = nil
    end)

    it("should handle invalid parameters", function()
      local result = file_operations.handle_file_deletion(nil, {}, "file.env")
      assert.is_nil(result)
      
      local result2 = file_operations.handle_file_deletion({}, nil, "file.env")
      assert.is_nil(result2)
    end)
  end)

  describe("performance and memory optimization tests", function()
    describe("large file handling", function()
      it("should handle very large files efficiently", function()
        local large_file = test_dir .. "/large_file.txt"
        
        -- Create a large file (1MB+)
        local large_content = {}
        for i = 1, 10000 do
          table.insert(large_content, "LARGE_VAR_" .. i .. "=" .. string.rep("value", 10))
        end
        create_test_file(large_file, table.concat(large_content, "\n"))
        
        local start_time = vim.loop.hrtime()
        local content, error = file_operations.read_file_sync(large_file)
        local elapsed = (vim.loop.hrtime() - start_time) / 1e6 -- Convert to milliseconds
        
        assert.is_nil(error)
        assert.is_table(content)
        assert.is_true(#content >= 10000)
        assert.is_true(elapsed < 500, "Large file reading should complete within 500ms, took " .. elapsed .. "ms")
      end)

      it("should handle very long individual lines", function()
        local long_line_file = test_dir .. "/long_lines.txt"
        
        -- Create file with very long lines
        local very_long_value = string.rep("x", 50000)
        local content = "NORMAL_VAR=short\nLONG_VAR=" .. very_long_value .. "\nANOTHER_VAR=short"
        create_test_file(long_line_file, content)
        
        local start_time = vim.loop.hrtime()
        local lines, error = file_operations.read_file_sync(long_line_file)
        local elapsed = (vim.loop.hrtime() - start_time) / 1e6
        
        assert.is_nil(error)
        assert.equals(3, #lines)
        assert.is_true(elapsed < 200, "Long line processing should be fast, took " .. elapsed .. "ms")
      end)

      it("should efficiently process many small files", function()
        local files = {}
        
        -- Create 100 small files
        for i = 1, 100 do
          local file_path = test_dir .. "/small_" .. i .. ".txt"
          create_test_file(file_path, "VAR" .. i .. "=value" .. i)
          table.insert(files, file_path)
        end
        
        local start_time = vim.loop.hrtime()
        local callback_called = false
        local results, errors
        
        file_operations.read_files_batch(files, function(res, err)
          callback_called = true
          results = res
          errors = err
        end)
        
        -- Wait for completion
        vim.wait(2000, function()
          return callback_called
        end)
        
        local elapsed = (vim.loop.hrtime() - start_time) / 1e6
        
        assert.is_true(callback_called)
        assert.equals(100, vim.tbl_count(results))
        assert.equals(0, vim.tbl_count(errors))
        assert.is_true(elapsed < 1000, "Batch processing should be efficient, took " .. elapsed .. "ms")
      end)
    end)

    describe("memory management", function()
      it("should manage memory efficiently with repeated operations", function()
        local test_file = test_dir .. "/memory_test.txt"
        create_test_file(test_file, "TEST_VAR=test_value\nANOTHER_VAR=another_value")
        
        -- Perform many read operations to test memory usage
        for i = 1, 100 do
          local content, error = file_operations.read_file_sync(test_file)
          assert.is_nil(error)
          assert.is_table(content)
          
          -- Force garbage collection periodically
          if i % 10 == 0 then
            collectgarbage("collect")
          end
        end
        
        -- Final garbage collection
        collectgarbage("collect")
        
        -- Memory usage should be reasonable after many operations
        local memory_kb = collectgarbage("count")
        assert.is_true(memory_kb < 10000, "Memory usage should be reasonable: " .. memory_kb .. "KB")
      end)

      it("should efficiently manage cache memory", function()
        local files = {}
        
        -- Create and cache many files
        for i = 1, 50 do
          local file_path = test_dir .. "/cache_" .. i .. ".txt"
          create_test_file(file_path, "CACHE_VAR" .. i .. "=value" .. i)
          table.insert(files, file_path)
          
          -- Cache mtime for each file
          file_operations.get_mtime(file_path)
        end
        
        local stats = file_operations.get_cache_stats()
        assert.equals(50, stats.mtime_cache_size)
        
        -- Clear cache and verify memory is released
        file_operations.clear_mtime_cache()
        collectgarbage("collect")
        
        local stats_after = file_operations.get_cache_stats()
        assert.equals(0, stats_after.mtime_cache_size)
      end)

      it("should handle memory pressure gracefully", function()
        -- Create a scenario that uses significant memory
        local large_files = {}
        
        for i = 1, 20 do
          local file_path = test_dir .. "/pressure_" .. i .. ".txt"
          -- Create moderately large content
          local content = string.rep("PRESSURE_VAR" .. i .. "=" .. string.rep("data", 1000) .. "\n", 100)
          create_test_file(file_path, content)
          table.insert(large_files, file_path)
        end
        
        -- Process files with limited memory
        local success_count = 0
        for _, file in ipairs(large_files) do
          local content, error = file_operations.read_file_sync(file)
          if not error and content then
            success_count = success_count + 1
          end
          
          -- Force occasional garbage collection
          if success_count % 5 == 0 then
            collectgarbage("collect")
          end
        end
        
        assert.equals(20, success_count)
      end)
    end)

    describe("concurrent operation performance", function()
      it("should handle concurrent file reads efficiently", function()
        local files = {}
        local results = {}
        local completed = 0
        
        -- Create test files
        for i = 1, 10 do
          local file_path = test_dir .. "/concurrent_" .. i .. ".txt"
          create_test_file(file_path, "CONCURRENT_VAR" .. i .. "=value" .. i .. "\nDATA" .. i .. "=data" .. i)
          table.insert(files, file_path)
        end
        
        local start_time = vim.loop.hrtime()
        
        -- Start concurrent reads
        for i, file in ipairs(files) do
          vim.schedule(function()
            local content, error = file_operations.read_file_sync(file)
            results[file] = {content = content, error = error}
            completed = completed + 1
          end)
        end
        
        -- Wait for all operations to complete
        vim.wait(1000, function()
          return completed == #files
        end)
        
        local elapsed = (vim.loop.hrtime() - start_time) / 1e6
        
        assert.equals(#files, completed)
        assert.is_true(elapsed < 500, "Concurrent operations should complete quickly, took " .. elapsed .. "ms")
        
        -- Verify all results are valid
        for _, file in ipairs(files) do
          assert.is_not_nil(results[file])
          assert.is_nil(results[file].error)
          assert.is_table(results[file].content)
        end
      end)

      it("should handle concurrent cache operations", function()
        local files = {}
        local cache_results = {}
        local cache_completed = 0
        
        -- Create test files
        for i = 1, 20 do
          local file_path = test_dir .. "/cache_concurrent_" .. i .. ".txt"
          create_test_file(file_path, "CACHE_TEST" .. i .. "=value")
          table.insert(files, file_path)
        end
        
        -- Perform concurrent cache operations
        for _, file in ipairs(files) do
          vim.schedule(function()
            local mtime = file_operations.get_mtime(file)
            cache_results[file] = mtime
            cache_completed = cache_completed + 1
          end)
        end
        
        vim.wait(500, function()
          return cache_completed == #files
        end)
        
        assert.equals(#files, cache_completed)
        
        local stats = file_operations.get_cache_stats()
        assert.equals(#files, stats.mtime_cache_size)
        
        -- Verify all cache results are valid
        for _, file in ipairs(files) do
          assert.is_number(cache_results[file])
          assert.is_true(cache_results[file] > 0)
        end
      end)
    end)

    describe("edge case performance", function()
      it("should handle files with many empty lines efficiently", function()
        local empty_lines_file = test_dir .. "/empty_lines.txt"
        
        -- Create file with many empty lines
        local content_parts = {}
        for i = 1, 1000 do
          if i % 10 == 0 then
            table.insert(content_parts, "VAR" .. i .. "=value" .. i)
          else
            table.insert(content_parts, "") -- Empty line
          end
        end
        create_test_file(empty_lines_file, table.concat(content_parts, "\n"))
        
        local start_time = vim.loop.hrtime()
        local lines, error = file_operations.read_file_sync(empty_lines_file)
        local elapsed = (vim.loop.hrtime() - start_time) / 1e6
        
        assert.is_nil(error)
        assert.equals(1000, #lines)
        assert.is_true(elapsed < 100, "Empty line processing should be fast, took " .. elapsed .. "ms")
      end)

      it("should handle files with special characters efficiently", function()
        local special_file = test_dir .. "/special_chars.txt"
        
        -- Create file with various special characters
        local special_content = {}
        for i = 1, 500 do
          table.insert(special_content, "VAR" .. i .. "=value_with_特殊文字_" .. i .. "_🔥_αβγ")
        end
        create_test_file(special_file, table.concat(special_content, "\n"))
        
        local start_time = vim.loop.hrtime()
        local lines, error = file_operations.read_file_sync(special_file)
        local elapsed = (vim.loop.hrtime() - start_time) / 1e6
        
        assert.is_nil(error)
        assert.equals(500, #lines)
        assert.is_true(elapsed < 200, "Special character processing should be efficient, took " .. elapsed .. "ms")
      end)

      it("should efficiently handle rapid cache invalidation", function()
        local test_file = test_dir .. "/cache_invalidation.txt"
        create_test_file(test_file, "INITIAL_VAR=initial_value")
        
        local start_time = vim.loop.hrtime()
        
        -- Perform rapid cache/invalidation cycles
        for i = 1, 50 do
          -- Cache the file
          local mtime = file_operations.get_mtime(test_file)
          assert.is_number(mtime)
          
          -- Invalidate cache
          file_operations.clear_mtime_cache(test_file)
          
          -- Verify cache is cleared
          local stats = file_operations.get_cache_stats()
          assert.equals(0, stats.mtime_cache_size)
        end
        
        local elapsed = (vim.loop.hrtime() - start_time) / 1e6
        assert.is_true(elapsed < 100, "Rapid cache operations should be efficient, took " .. elapsed .. "ms")
      end)
    end)

    describe("resource cleanup and limits", function()
      it("should properly cleanup resources after batch operations", function()
        local files = {}
        
        -- Create many files for batch processing
        for i = 1, 30 do
          local file_path = test_dir .. "/cleanup_" .. i .. ".txt"
          create_test_file(file_path, "CLEANUP_VAR" .. i .. "=value" .. i)
          table.insert(files, file_path)
        end
        
        local callback_called = false
        local results, errors
        
        -- Perform batch operation
        file_operations.read_files_batch(files, function(res, err)
          callback_called = true
          results = res
          errors = err
        end)
        
        vim.wait(1000, function()
          return callback_called
        end)
        
        assert.is_true(callback_called)
        assert.equals(30, vim.tbl_count(results))
        
        -- Force cleanup
        collectgarbage("collect")
        
        -- Verify resources are properly managed
        local memory_after = collectgarbage("count")
        assert.is_true(memory_after < 5000, "Memory usage should be reasonable after cleanup")
      end)

      it("should handle filesystem resource limits gracefully", function()
        local stress_files = {}
        
        -- Create files that might stress filesystem limits
        for i = 1, 100 do
          local file_path = test_dir .. "/stress_" .. i .. ".txt"
          create_test_file(file_path, "STRESS" .. i .. "=data")
          table.insert(stress_files, file_path)
        end
        
        -- Try to process all files, should handle any resource limits
        local readable_map = file_operations.check_files_batch(stress_files)
        
        -- Should successfully check all files
        assert.equals(100, vim.tbl_count(readable_map))
        
        -- All files should be readable
        for _, file in ipairs(stress_files) do
          assert.is_true(readable_map[file])
        end
      end)

      it("should maintain performance with cache pressure", function()
        local cache_files = {}
        
        -- Create files to fill cache
        for i = 1, 200 do
          local file_path = test_dir .. "/cache_pressure_" .. i .. ".txt"
          create_test_file(file_path, "PRESSURE" .. i .. "=value")
          table.insert(cache_files, file_path)
        end
        
        local start_time = vim.loop.hrtime()
        
        -- Fill cache with many entries
        for _, file in ipairs(cache_files) do
          file_operations.get_mtime(file)
        end
        
        local cache_time = (vim.loop.hrtime() - start_time) / 1e6
        
        -- Verify cache performance
        assert.is_true(cache_time < 1000, "Cache filling should be reasonably fast, took " .. cache_time .. "ms")
        
        local stats = file_operations.get_cache_stats()
        assert.equals(200, stats.mtime_cache_size)
        
        -- Test cache lookup performance
        local lookup_start = vim.loop.hrtime()
        for i = 1, 10 do
          local random_file = cache_files[math.random(1, #cache_files)]
          local mtime = file_operations.get_mtime(random_file) -- Should hit cache
          assert.is_number(mtime)
        end
        local lookup_time = (vim.loop.hrtime() - lookup_start) / 1e6
        
        assert.is_true(lookup_time < 10, "Cache lookups should be very fast, took " .. lookup_time .. "ms")
      end)
    end)
  end)
end)