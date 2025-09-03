#!/usr/bin/env bash

# Direct test runner - shows output immediately without timeout handling

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

echo "Running tests directly..."

# Run tests with direct output
nvim --headless -u tests/minimal_init.lua \
    -c "lua require('plenary.test_harness').test_directory('tests/spec/', {minimal_init='tests/minimal_init.lua'})" \
    -c "qa!"

echo "Tests completed!"