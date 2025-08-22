local assert = require("luassert")

describe("environment file parsing edge cases", function()
  local env_loader
  local utils
  local test_dir

  local function create_test_file(path, content)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local file = io.open(path, "w")
    if file then
      file:write(content)
      file:close()
    end
  end

  local function cleanup_test_files(path)
    vim.fn.delete(path, "rf")
  end

  before_each(function()
    package.loaded["ecolog.env_loader"] = nil
    package.loaded["ecolog.utils"] = nil

    test_dir = vim.fn.tempname()
    vim.fn.mkdir(test_dir, "p")

    env_loader = require("ecolog.env_loader")
    utils = require("ecolog.utils")
  end)

  after_each(function()
    cleanup_test_files(test_dir)
  end)

  describe("malformed file handling", function()
    it("should handle files with missing equals signs", function()
      local content = [[
VALID_VAR=value
INVALID_LINE_NO_EQUALS
ANOTHER_VALID=another_value
]]
      create_test_file(test_dir .. "/.env", content)

      local result = utils.parse_env_file(test_dir .. "/.env")
      
      assert.is_not_nil(result.VALID_VAR)
      assert.equals("value", result.VALID_VAR.value)
      assert.is_not_nil(result.ANOTHER_VALID)
      assert.equals("another_value", result.ANOTHER_VALID.value)
      -- Invalid line should be ignored
      assert.is_nil(result.INVALID_LINE_NO_EQUALS)
    end)

    it("should handle files with multiple equals signs", function()
      local content = [[
VAR_WITH_EQUALS=key=value
URL_VAR=https://example.com/path?param=value&other=data
COMPLEX_VAR=a=b=c=d
]]
      create_test_file(test_dir .. "/.env", content)

      local result = utils.parse_env_file(test_dir .. "/.env")
      
      assert.equals("key=value", result.VAR_WITH_EQUALS.value)
      assert.equals("https://example.com/path?param=value&other=data", result.URL_VAR.value)
      assert.equals("a=b=c=d", result.COMPLEX_VAR.value)
    end)

    it("should handle lines with only equals signs", function()
      local content = [[
VALID=value
=
===
=value_without_key
ANOTHER_VALID=test
]]
      create_test_file(test_dir .. "/.env", content)

      local result = utils.parse_env_file(test_dir .. "/.env")
      
      assert.equals("value", result.VALID.value)
      assert.equals("test", result.ANOTHER_VALID.value)
      -- Lines with only equals or missing keys should be ignored
    end)

    it("should handle empty values correctly", function()
      local content = [[
EMPTY_VAR=
SPACE_VAR= 
TAB_VAR=	
QUOTE_EMPTY=""
SINGLE_QUOTE_EMPTY=''
]]
      create_test_file(test_dir .. "/.env", content)

      local result = utils.parse_env_file(test_dir .. "/.env")
      
      assert.equals("", result.EMPTY_VAR.value)
      assert.equals(" ", result.SPACE_VAR.value)
      assert.equals("\t", result.TAB_VAR.value)
      assert.equals("", result.QUOTE_EMPTY.value)
      assert.equals("", result.SINGLE_QUOTE_EMPTY.value)
    end)
  end)

  describe("quote handling edge cases", function()
    it("should handle mismatched quotes", function()
      local content = [[
MISMATCHED_SINGLE='value"
MISMATCHED_DOUBLE="value'
UNCLOSED_SINGLE='value
UNCLOSED_DOUBLE="value
NESTED_QUOTES="value 'with' quotes"
REVERSE_NESTED='value "with" quotes'
]]
      create_test_file(test_dir .. "/.env", content)

      local result = utils.parse_env_file(test_dir .. "/.env")
      
      -- Should handle mismatched quotes gracefully
      assert.is_not_nil(result.MISMATCHED_SINGLE)
      assert.is_not_nil(result.MISMATCHED_DOUBLE)
      assert.is_not_nil(result.UNCLOSED_SINGLE)
      assert.is_not_nil(result.UNCLOSED_DOUBLE)
      assert.equals("value 'with' quotes", result.NESTED_QUOTES.value)
      assert.equals('value "with" quotes', result.REVERSE_NESTED.value)
    end)

    it("should handle escape sequences in quotes", function()
      local content = [[
ESCAPED_NEWLINE="line1\nline2"
ESCAPED_TAB="tab\there"
ESCAPED_QUOTE="say \"hello\""
ESCAPED_BACKSLASH="path\\to\\file"
ESCAPED_SINGLE='can\'t'
]]
      create_test_file(test_dir .. "/.env", content)

      local result = utils.parse_env_file(test_dir .. "/.env")
      
      assert.equals("line1\nline2", result.ESCAPED_NEWLINE.value)
      assert.equals("tab\there", result.ESCAPED_TAB.value)
      assert.equals('say "hello"', result.ESCAPED_QUOTE.value)
      assert.equals("path\\to\\file", result.ESCAPED_BACKSLASH.value)
      assert.equals("can't", result.ESCAPED_SINGLE.value)
    end)

    it("should handle multiline values correctly", function()
      local content = [[
MULTILINE="line1
line2
line3"
MULTILINE_SINGLE='line1
line2
line3'
]]
      create_test_file(test_dir .. "/.env", content)

      local result = utils.parse_env_file(test_dir .. "/.env")
      
      local expected_value = "line1\nline2\nline3"
      assert.equals(expected_value, result.MULTILINE.value)
      assert.equals(expected_value, result.MULTILINE_SINGLE.value)
    end)
  end)

  describe("special characters and unicode", function()
    it("should handle unicode characters", function()
      local content = [[
UNICODE_VAR=Hello 世界 🌍
EMOJI_VAR=🚀 🎉 ✨
ACCENTED_VAR=café naïve résumé
]]
      create_test_file(test_dir .. "/.env", content)

      local result = utils.parse_env_file(test_dir .. "/.env")
      
      assert.equals("Hello 世界 🌍", result.UNICODE_VAR.value)
      assert.equals("🚀 🎉 ✨", result.EMOJI_VAR.value)
      assert.equals("café naïve résumé", result.ACCENTED_VAR.value)
    end)

    it("should handle special control characters", function()
      local content = [[
NULL_CHAR=before]] .. "\0" .. [[after
BELL_CHAR=]] .. "\a" .. [[
FORM_FEED=]] .. "\f" .. [[
VERTICAL_TAB=]] .. "\v" .. [[
]]
      create_test_file(test_dir .. "/.env", content)

      local result = utils.parse_env_file(test_dir .. "/.env")
      
      -- Should handle control characters without crashing
      assert.is_not_nil(result.NULL_CHAR)
      assert.is_not_nil(result.BELL_CHAR)
      assert.is_not_nil(result.FORM_FEED)
      assert.is_not_nil(result.VERTICAL_TAB)
    end)

    it("should handle very long variable names and values", function()
      local long_name = string.rep("A", 1000)
      local long_value = string.rep("B", 10000)
      local content = long_name .. "=" .. long_value .. "\n"
      
      create_test_file(test_dir .. "/.env", content)

      local result = utils.parse_env_file(test_dir .. "/.env")
      
      assert.is_not_nil(result[long_name])
      assert.equals(long_value, result[long_name].value)
    end)
  end)

  describe("whitespace and formatting edge cases", function()
    it("should handle various whitespace patterns", function()
      local content = [[
  LEADING_SPACES=value
TRAILING_SPACES=value  
	TAB_INDENTED=value
 	MIXED_INDENT=value
VAR_WITH_SPACES = value with spaces 
   EXTRA_SPACES   =   value   
]]
      create_test_file(test_dir .. "/.env", content)

      local result = utils.parse_env_file(test_dir .. "/.env")
      
      assert.is_not_nil(result.LEADING_SPACES)
      assert.is_not_nil(result.TRAILING_SPACES)
      assert.is_not_nil(result.TAB_INDENTED)
      assert.is_not_nil(result.MIXED_INDENT)
      assert.is_not_nil(result.VAR_WITH_SPACES)
      assert.is_not_nil(result.EXTRA_SPACES)
    end)

    it("should handle different line ending formats", function()
      -- Test Unix LF
      create_test_file(test_dir .. "/.env.unix", "VAR1=value1\nVAR2=value2\n")
      
      -- Test Windows CRLF
      create_test_file(test_dir .. "/.env.windows", "VAR1=value1\r\nVAR2=value2\r\n")
      
      -- Test old Mac CR
      create_test_file(test_dir .. "/.env.mac", "VAR1=value1\rVAR2=value2\r")

      local unix_result = utils.parse_env_file(test_dir .. "/.env.unix")
      local windows_result = utils.parse_env_file(test_dir .. "/.env.windows")
      local mac_result = utils.parse_env_file(test_dir .. "/.env.mac")

      assert.equals("value1", unix_result.VAR1.value)
      assert.equals("value2", unix_result.VAR2.value)
      assert.equals("value1", windows_result.VAR1.value)
      assert.equals("value2", windows_result.VAR2.value)
      assert.equals("value1", mac_result.VAR1.value)
      assert.equals("value2", mac_result.VAR2.value)
    end)

    it("should handle mixed line endings in single file", function()
      local content = "VAR1=value1\nVAR2=value2\r\nVAR3=value3\rVAR4=value4"
      create_test_file(test_dir .. "/.env", content)

      local result = utils.parse_env_file(test_dir .. "/.env")
      
      assert.equals("value1", result.VAR1.value)
      assert.equals("value2", result.VAR2.value)
      assert.equals("value3", result.VAR3.value)
      assert.equals("value4", result.VAR4.value)
    end)
  end)

  describe("performance with edge cases", function()
    it("should handle files with many variables efficiently", function()
      local content = {}
      for i = 1, 1000 do
        table.insert(content, "VAR_" .. i .. "=value_" .. i)
      end
      create_test_file(test_dir .. "/.env", table.concat(content, "\n"))

      local start_time = vim.loop.hrtime()
      local result = utils.parse_env_file(test_dir .. "/.env")
      local elapsed = (vim.loop.hrtime() - start_time) / 1e6 -- Convert to milliseconds

      assert.is_not_nil(result.VAR_1)
      assert.is_not_nil(result.VAR_500)
      assert.is_not_nil(result.VAR_1000)
      assert.equals("value_1", result.VAR_1.value)
      assert.equals("value_500", result.VAR_500.value)
      assert.equals("value_1000", result.VAR_1000.value)
      
      -- Should complete in reasonable time (less than 500ms)
      assert.is_true(elapsed < 500, "Parsing 1000 variables should complete in under 500ms, took " .. elapsed .. "ms")
    end)

    it("should handle deeply nested directories", function()
      local deep_path = test_dir
      for i = 1, 10 do
        deep_path = deep_path .. "/dir" .. i
      end
      
      create_test_file(deep_path .. "/.env", "DEEP_VAR=deep_value")

      local result = utils.parse_env_file(deep_path .. "/.env")
      
      assert.equals("deep_value", result.DEEP_VAR.value)
    end)
  end)

  describe("file system edge cases", function()
    it("should handle non-existent files gracefully", function()
      local result = utils.parse_env_file(test_dir .. "/.nonexistent")
      assert.is_table(result)
      assert.is_true(vim.tbl_isempty(result))
    end)

    it("should handle directory instead of file", function()
      vim.fn.mkdir(test_dir .. "/.env", "p")

      local result = utils.parse_env_file(test_dir .. "/.env")
      assert.is_table(result)
      assert.is_true(vim.tbl_isempty(result))
    end)

    it("should handle empty files", function()
      create_test_file(test_dir .. "/.env", "")

      local result = utils.parse_env_file(test_dir .. "/.env")
      assert.is_table(result)
      assert.is_true(vim.tbl_isempty(result))
    end)

    it("should handle files with only comments and whitespace", function()
      local content = [[
# This is a comment
  # Another comment with spaces
	# Comment with tab

  
# Final comment
]]
      create_test_file(test_dir .. "/.env", content)

      local result = utils.parse_env_file(test_dir .. "/.env")
      assert.is_table(result)
      assert.is_true(vim.tbl_isempty(result))
    end)
  end)
end)