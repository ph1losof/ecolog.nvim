#!/usr/bin/env nvim --headless -l

-- Debug memory leak test runner
local plenary_path = "/tmp/plenary.nvim"
vim.opt.rtp:prepend(plenary_path)

-- Add test dependencies to runtime path
local deps = {
  "/tmp/telescope.nvim",
  "/tmp/fzf-lua", 
  "/tmp/snacks.nvim",
  "/tmp/nvim-cmp",
  "/tmp/blink.cmp",
  "/tmp/lspsaga.nvim"
}

for _, dep in ipairs(deps) do
  vim.opt.rtp:prepend(dep)
end

-- Load minimal test init
dofile("tests/minimal_init.lua")

local test_harness = require('plenary.test_harness')

-- Memory monitoring function
local function get_memory_usage()
  collectgarbage("collect")
  return collectgarbage("count")
end

-- Test runner with memory monitoring
local function run_tests_with_memory_monitoring()
  local initial_memory = get_memory_usage()
  print(string.format("Initial memory: %.2f MB", initial_memory / 1024))
  
  local test_files = {
    "tests/spec/env_spec.lua",
    "tests/spec/ecolog_spec.lua", 
    "tests/spec/notification_timer_spec.lua",
    "tests/spec/file_watcher_spec.lua",
    "tests/spec/integrations_spec.lua"
  }
  
  for i, test_file in ipairs(test_files) do
    local before_test = get_memory_usage()
    print(string.format("Before %s: %.2f MB", test_file, before_test / 1024))
    
    -- Run individual test
    local success, result = pcall(function()
      return require('plenary.busted').run(test_file)
    end)
    
    if not success then
      print(string.format("Error running %s: %s", test_file, result))
    end
    
    local after_test = get_memory_usage()
    print(string.format("After %s: %.2f MB (delta: +%.2f MB)", 
          test_file, after_test / 1024, (after_test - before_test) / 1024))
    
    -- Force cleanup
    collectgarbage("collect")
    local after_gc = get_memory_usage()
    print(string.format("After GC: %.2f MB (freed: %.2f MB)", 
          after_gc / 1024, (after_test - after_gc) / 1024))
    
    -- Check for significant memory growth
    local net_growth = after_gc - initial_memory
    if net_growth > 50000 then -- 50MB threshold
      print(string.format("WARNING: Significant memory growth detected: %.2f MB", net_growth / 1024))
    end
    
    print("---")
  end
  
  local final_memory = get_memory_usage()
  print(string.format("Final memory: %.2f MB (total growth: +%.2f MB)", 
        final_memory / 1024, (final_memory - initial_memory) / 1024))
end

run_tests_with_memory_monitoring()
vim.cmd("qa!")