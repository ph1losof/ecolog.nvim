local M = {}

local function ensure_dir(dir)
  vim.fn.mkdir(dir, "p")
end

local function write_file(path, content)
  local file = io.open(path, "w")
  if file then
    file:write(content)
    file:close()
  end
end

function M.run_tests_with_report()
  local test_results = {
    total = 0,
    passed = 0,
    failed = 0,
    errors = {},
    timestamp = os.date("%Y-%m-%d %H:%M:%S"),
    environment = {
      nvim_version = vim.version().major .. "." .. vim.version().minor .. "." .. vim.version().patch,
      os = vim.loop.os_uname().sysname,
      arch = vim.loop.os_uname().machine
    }
  }
  
  local results_dir = "test-results"
  ensure_dir(results_dir)
  
  local original_describe = describe
  local original_it = it
  local test_output = {}
  
  _G.describe = function(name, fn)
    local suite_results = {
      name = name,
      tests = {}
    }
    
    _G.it = function(test_name, test_fn)
      test_results.total = test_results.total + 1
      local success, err = pcall(test_fn)
      
      local test_result = {
        name = test_name,
        suite = name,
        passed = success,
        error = err
      }
      
      if success then
        test_results.passed = test_results.passed + 1
        print("✓ " .. name .. " - " .. test_name)
      else
        test_results.failed = test_results.failed + 1
        table.insert(test_results.errors, {
          suite = name,
          test = test_name,
          error = tostring(err)
        })
        print("✗ " .. name .. " - " .. test_name)
        print("  Error: " .. tostring(err))
      end
      
      table.insert(suite_results.tests, test_result)
      table.insert(test_output, test_result)
    end
    
    fn()
    _G.it = original_it
  end
  
  require('plenary.test_harness').test_directory('tests/spec/', {
    minimal_init = 'tests/minimal_init.lua',
    sequential = true
  })
  
  _G.describe = original_describe
  
  local summary = string.format([[
Test Results Summary
====================
Total Tests: %d
Passed: %d
Failed: %d
Success Rate: %.1f%%
Timestamp: %s
Neovim Version: %s
OS: %s (%s)
]], 
    test_results.total,
    test_results.passed,
    test_results.failed,
    test_results.total > 0 and (test_results.passed / test_results.total * 100) or 0,
    test_results.timestamp,
    test_results.environment.nvim_version,
    test_results.environment.os,
    test_results.environment.arch
  )
  
  if test_results.failed > 0 then
    summary = summary .. "\nFailed Tests:\n"
    for _, error in ipairs(test_results.errors) do
      summary = summary .. string.format("  - %s::%s\n    %s\n", 
        error.suite, error.test, error.error)
    end
  end
  
  write_file(results_dir .. "/summary.txt", summary)
  
  local json_results = vim.fn.json_encode(test_results)
  write_file(results_dir .. "/results.json", json_results)
  
  local xml_content = string.format([[<?xml version="1.0" encoding="UTF-8"?>
<testsuites name="ecolog.nvim" tests="%d" failures="%d" errors="0" time="0">
  <testsuite name="ecolog.nvim" tests="%d" failures="%d" errors="0" time="0">
]], test_results.total, test_results.failed, test_results.total, test_results.failed)
  
  for _, result in ipairs(test_output or {}) do
    if result.passed then
      xml_content = xml_content .. string.format('    <testcase classname="%s" name="%s" time="0"/>\n',
        result.suite or "unknown", result.name or "unknown")
    else
      xml_content = xml_content .. string.format([[    <testcase classname="%s" name="%s" time="0">
      <failure message="%s" type="AssertionError">%s</failure>
    </testcase>
]], 
        result.suite or "unknown", 
        result.name or "unknown",
        vim.fn.escape(tostring(result.error), '"'),
        tostring(result.error))
    end
  end
  
  xml_content = xml_content .. [[  </testsuite>
</testsuites>]]
  
  write_file(results_dir .. "/junit.xml", xml_content)
  
  print("\n" .. summary)
  
  if test_results.failed > 0 then
    vim.cmd("cq 1")
  end
end

return M