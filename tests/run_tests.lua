#!/usr/bin/env lua
-- Simple test runner for ecolog.nvim
-- Run with: nvim --headless -u tests/minimal_init.lua -c "luafile tests/run_tests.lua" -c "qa!"

-- Add plugin to path
package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua"

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print("PASS: " .. name)
  else
    print("FAIL: " .. name)
    print("  Error: " .. tostring(err))
  end
end

local function assert_equal(expected, actual, msg)
  if expected ~= actual then
    error(string.format("%s: expected %s, got %s", msg or "Assertion failed", tostring(expected), tostring(actual)))
  end
end

local function assert_table_equal(expected, actual, msg)
  if type(expected) ~= "table" or type(actual) ~= "table" then
    error(string.format("%s: expected table, got %s and %s", msg or "Assertion failed", type(expected), type(actual)))
  end
  for k, v in pairs(expected) do
    if actual[k] ~= v then
      error(string.format("%s: key '%s' expected %s, got %s", msg or "Assertion failed", k, tostring(v), tostring(actual[k])))
    end
  end
  for k, v in pairs(actual) do
    if expected[k] ~= v then
      error(string.format("%s: unexpected key '%s' with value %s", msg or "Assertion failed", k, tostring(v)))
    end
  end
end

print("=== Running ecolog.nvim tests ===\n")

-- Test state module
print("-- State Module Tests --")

local state = require("ecolog.state")

test("state: set and get active files", function()
  state.set_active_files({ "/path/.env", "/path/.env.local" })
  local files = state.get_active_files()
  assert_equal(2, #files, "file count")
  assert_equal("/path/.env", files[1], "first file")
  assert_equal("/path/.env.local", files[2], "second file")
end)

test("state: set and get var count", function()
  state.set_var_count(42)
  assert_equal(42, state.get_var_count(), "var count")
end)

test("state: set and get enabled sources", function()
  state.set_enabled_sources({ shell = true, file = false })
  local sources = state.get_enabled_sources()
  assert_table_equal({ shell = true, file = false }, sources, "enabled sources")
end)

test("state: get active file returns first file", function()
  state.set_active_files({ "/first.env", "/second.env" })
  assert_equal("/first.env", state.get_active_file(), "active file")
end)

test("state: get active file returns nil when empty", function()
  state.set_active_files({})
  assert_equal(nil, state.get_active_file(), "active file when empty")
end)

-- Test that setting empty sources doesn't crash
test("state: set empty sources uses default", function()
  state.set_enabled_sources(nil)
  local sources = state.get_enabled_sources()
  assert_equal(true, sources.shell, "shell default")
  assert_equal(true, sources.file, "file default")
end)

print("\n=== Tests complete ===")
