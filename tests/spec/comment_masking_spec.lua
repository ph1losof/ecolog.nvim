describe("comment masking with skip_comments", function()
  local masking_engine
  local state

  before_each(function()
    -- Clear module cache
    package.loaded["ecolog.shelter.masking_engine"] = nil
    package.loaded["ecolog.shelter.state"] = nil
    package.loaded["ecolog.shelter.common"] = nil
    package.loaded["ecolog.utils"] = nil

    masking_engine = require("ecolog.shelter.masking_engine")
    state = require("ecolog.shelter.state")

    -- Setup state with default configuration
    state.init({
      partial_mode = false,
      mask_char = "*",
      mask_length = nil,
      highlight_group = "Comment",
      skip_comments = false, -- Default: comments should be masked
    })
  end)

  after_each(function()
    masking_engine.clear_caches()
  end)

  describe("parse_lines_cached with comment lines", function()
    it("should parse key-value pairs in comment lines", function()
      local lines = {
        "# API_KEY=secret123",
        "NORMAL_KEY=value456",
        "# Another comment without key-value",
        "# DB_PASSWORD=pass789",
      }

      local content_hash = "test_hash_1"
      local parsed = masking_engine.parse_lines_cached(lines, content_hash)

      -- Check that comment variables were parsed
      local found_api_key = false
      local found_db_password = false
      local found_normal_key = false

      for key, var_info in pairs(parsed) do
        if var_info.key == "API_KEY" then
          found_api_key = true
          assert.equals("secret123", var_info.value)
          assert.equals(1, var_info.start_line)
          assert.is_true(var_info.is_comment)
        elseif var_info.key == "DB_PASSWORD" then
          found_db_password = true
          assert.equals("pass789", var_info.value)
          assert.equals(4, var_info.start_line)
          assert.is_true(var_info.is_comment)
        elseif var_info.key == "NORMAL_KEY" then
          found_normal_key = true
          assert.equals("value456", var_info.value)
          assert.equals(2, var_info.start_line)
          assert.is_false(var_info.is_comment)
        end
      end

      assert.is_true(found_api_key, "API_KEY from comment should be parsed")
      assert.is_true(found_db_password, "DB_PASSWORD from comment should be parsed")
      assert.is_true(found_normal_key, "NORMAL_KEY should be parsed")
    end)

    it("should handle quoted values in comment lines", function()
      local lines = {
        '# API_KEY="secret with spaces"',
        "# TOKEN='single_quoted_value'",
      }

      local content_hash = "test_hash_2"
      local parsed = masking_engine.parse_lines_cached(lines, content_hash)

      local found_api_key = false
      local found_token = false

      for key, var_info in pairs(parsed) do
        if var_info.key == "API_KEY" then
          found_api_key = true
          assert.equals("secret with spaces", var_info.value)
          assert.equals('"', var_info.quote_char)
          assert.is_true(var_info.is_comment)
        elseif var_info.key == "TOKEN" then
          found_token = true
          assert.equals("single_quoted_value", var_info.value)
          assert.equals("'", var_info.quote_char)
          assert.is_true(var_info.is_comment)
        end
      end

      assert.is_true(found_api_key, "Quoted API_KEY from comment should be parsed")
      assert.is_true(found_token, "Quoted TOKEN from comment should be parsed")
    end)

    it("should skip comment lines without key-value pairs", function()
      local lines = {
        "# This is just a comment",
        "# Another plain comment",
        "REAL_KEY=value",
      }

      local content_hash = "test_hash_3"
      local parsed = masking_engine.parse_lines_cached(lines, content_hash)

      -- Should only have REAL_KEY
      local count = 0
      for _ in pairs(parsed) do
        count = count + 1
      end

      assert.equals(1, count, "Should only parse the real key-value pair")
    end)
  end)

  describe("create_extmarks_batch with skip_comments=false", function()
    it("should create extmarks for comment variables when skip_comments=false", function()
      state.get_config().skip_comments = false

      local lines = {
        "# API_KEY=secret123",
        "NORMAL_KEY=value456",
      }

      local content_hash = "test_hash_4"
      local parsed = masking_engine.parse_lines_cached(lines, content_hash)

      local config = {
        partial_mode = false,
        highlight_group = "Comment",
      }

      local extmarks = masking_engine.create_extmarks_batch(
        parsed,
        lines,
        config,
        "test.env",
        false -- skip_comments parameter
      )

      -- Should create extmarks for both comment and normal variables
      assert.is_true(#extmarks >= 2, "Should create extmarks for both variables")
    end)
  end)

  describe("create_extmarks_batch with skip_comments=true", function()
    it("should NOT create extmarks for comment variables when skip_comments=true", function()
      state.get_config().skip_comments = true

      local lines = {
        "# API_KEY=secret123",
        "NORMAL_KEY=value456",
      }

      local content_hash = "test_hash_5"
      local parsed = masking_engine.parse_lines_cached(lines, content_hash)

      local config = {
        partial_mode = false,
        highlight_group = "Comment",
      }

      local extmarks = masking_engine.create_extmarks_batch(
        parsed,
        lines,
        config,
        "test.env",
        true -- skip_comments parameter
      )

      -- Should only create extmark for the normal variable, not the comment one
      -- Verify that no extmark was created for the comment line (line 0 in 0-based indexing)
      local has_comment_extmark = false
      for _, extmark in ipairs(extmarks) do
        if extmark.line == 0 then -- First line (comment line)
          has_comment_extmark = true
        end
      end

      assert.is_false(has_comment_extmark, "Should not create extmark for comment variable when skip_comments=true")
      assert.equals(1, #extmarks, "Should only create extmark for non-comment variable")
    end)
  end)

  describe("integration test: skip_comments behavior", function()
    it("should mask comment values by default (skip_comments=false)", function()
      state.get_config().skip_comments = false

      local lines = {
        "# Test comment",
        "# SECRET_KEY=my_secret_value",
        "PUBLIC_KEY=public_value",
      }

      local content_hash = "integration_test_1"
      local parsed = masking_engine.parse_lines_cached(lines, content_hash)

      -- Verify that SECRET_KEY from comment was parsed
      local found_secret_key = false
      for key, var_info in pairs(parsed) do
        if var_info.key == "SECRET_KEY" then
          found_secret_key = true
          assert.is_true(var_info.is_comment, "SECRET_KEY should be marked as comment")
          assert.equals("my_secret_value", var_info.value)
        end
      end

      assert.is_true(found_secret_key, "SECRET_KEY from comment should be parsed")

      -- Create extmarks - comment should be masked
      local config = {
        partial_mode = false,
        highlight_group = "Comment",
      }

      local extmarks = masking_engine.create_extmarks_batch(
        parsed,
        lines,
        config,
        "test.env",
        false -- skip_comments=false
      )

      -- Should have extmarks for both SECRET_KEY and PUBLIC_KEY
      assert.is_true(#extmarks >= 2, "Should create extmarks for both variables")
    end)

    it("should NOT mask comment values when skip_comments=true", function()
      state.get_config().skip_comments = true

      local lines = {
        "# SECRET_KEY=my_secret_value",
        "PUBLIC_KEY=public_value",
      }

      local content_hash = "integration_test_2"
      local parsed = masking_engine.parse_lines_cached(lines, content_hash)

      -- SECRET_KEY should still be parsed (with is_comment flag)
      local found_secret_key = false
      for key, var_info in pairs(parsed) do
        if var_info.key == "SECRET_KEY" then
          found_secret_key = true
          assert.is_true(var_info.is_comment, "SECRET_KEY should be marked as comment")
        end
      end

      assert.is_true(found_secret_key, "SECRET_KEY should be parsed even with skip_comments=true")

      -- Create extmarks - comment should NOT be masked
      local config = {
        partial_mode = false,
        highlight_group = "Comment",
      }

      local extmarks = masking_engine.create_extmarks_batch(
        parsed,
        lines,
        config,
        "test.env",
        true -- skip_comments=true
      )

      -- Should only have extmark for PUBLIC_KEY, not SECRET_KEY
      local has_comment_extmark = false
      for _, extmark in ipairs(extmarks) do
        if extmark.line == 0 then -- First line (comment line)
          has_comment_extmark = true
        end
      end

      assert.is_false(has_comment_extmark, "Should not mask comment variable")
      assert.equals(1, #extmarks, "Should only have extmark for non-comment variable")
    end)
  end)

  describe("edge cases", function()
    it("should handle comments with whitespace around key-value", function()
      local lines = {
        "#   KEY1  =  value1  ",
        "#KEY2=value2",
        "  #  KEY3  =  value3  ",
      }

      local content_hash = "edge_case_1"
      local parsed = masking_engine.parse_lines_cached(lines, content_hash)

      local found_keys = {}
      for key, var_info in pairs(parsed) do
        found_keys[var_info.key] = var_info.value
      end

      assert.is_not_nil(found_keys["KEY1"], "KEY1 should be parsed")
      assert.is_not_nil(found_keys["KEY2"], "KEY2 should be parsed")
      assert.is_not_nil(found_keys["KEY3"], "KEY3 should be parsed")
    end)

    it("should handle empty comment values", function()
      local lines = {
        "# EMPTY_KEY=",
      }

      local content_hash = "edge_case_2"
      local parsed = masking_engine.parse_lines_cached(lines, content_hash)

      -- Empty values should not be parsed
      local count = 0
      for _ in pairs(parsed) do
        count = count + 1
      end

      assert.equals(0, count, "Empty comment values should not be parsed")
    end)

    it("should handle multiple key-value pairs on same comment line", function()
      local lines = {
        "# KEY1=value1 KEY2=value2",
      }

      local content_hash = "edge_case_3"
      local parsed = masking_engine.parse_lines_cached(lines, content_hash)

      -- Should parse at least the first key-value pair
      local found_key1 = false
      for key, var_info in pairs(parsed) do
        if var_info.key == "KEY1" then
          found_key1 = true
        end
      end

      assert.is_true(found_key1, "Should parse at least first key-value in comment")
    end)
  end)
end)
