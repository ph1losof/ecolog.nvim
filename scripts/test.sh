#!/usr/bin/env bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

usage() {
    echo "Usage: $0 [OPTION]"
    echo "Options:"
    echo "  all       Run all tests"
    echo "  file      Run a specific test file"
    echo "  pattern   Run tests matching a pattern"
    echo "  coverage  Run tests with coverage report"
    echo "  watch     Run tests in watch mode"
    echo "  clean     Clean test dependencies"
    echo "  help      Show this help message"
}

install_deps() {
    echo -e "${YELLOW}Installing test dependencies...${NC}"
    make deps
}

run_all_tests() {
    echo -e "${GREEN}Running all tests...${NC}"
    nvim --headless -u tests/minimal_init.lua \
        -c "lua require('plenary.test_harness').test_directory('tests/spec/', {minimal_init='tests/minimal_init.lua'})" \
        -c "qa!"
    echo -e "${GREEN}Tests completed. Check output above for any failures.${NC}"
}

run_test_file() {
    if [ -z "$1" ]; then
        echo -e "${RED}Error: No test file specified${NC}"
        echo "Usage: $0 file <test_file_path>"
        exit 1
    fi
    echo -e "${GREEN}Running test file: $1${NC}"
    nvim --headless -u tests/minimal_init.lua \
        -c "PlenaryBustedFile $1" \
        -c "qa!"
}

run_pattern_tests() {
    if [ -z "$1" ]; then
        echo -e "${RED}Error: No pattern specified${NC}"
        echo "Usage: $0 pattern <pattern>"
        exit 1
    fi
    echo -e "${GREEN}Running tests matching pattern: $1${NC}"

    nvim --headless -u tests/minimal_init.lua \
        -c "lua require('plenary.test_harness').test_directory('tests/spec/', {minimal_init='tests/minimal_init.lua', pattern='$1'})" \
        -c "qa!"
}

run_coverage() {
    echo -e "${YELLOW}Coverage reporting not yet implemented${NC}"
    echo "Running standard tests instead..."
    run_all_tests
}

run_watch() {
    echo -e "${GREEN}Running tests in watch mode...${NC}"
    make test-watch
}

clean_deps() {
    echo -e "${YELLOW}Cleaning test dependencies...${NC}"
    make clean
}

case "${1:-all}" in
all)
    install_deps
    run_all_tests
    ;;
file)
    install_deps
    run_test_file "$2"
    ;;
pattern)
    install_deps
    run_pattern_tests "$2"
    ;;
coverage)
    install_deps
    run_coverage
    ;;
watch)
    install_deps
    run_watch
    ;;
clean)
    clean_deps
    ;;
help)
    usage
    ;;
*)
    echo -e "${RED}Unknown option: $1${NC}"
    usage
    exit 1
    ;;
esac
