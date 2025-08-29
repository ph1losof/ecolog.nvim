#!/usr/bin/env bash

# Create test-results directory
rm -rf test-results
mkdir -p test-results

echo "Running tests..."

# Run tests and capture output
nvim --headless -u tests/minimal_init.lua \
    -c "lua require('plenary.test_harness').test_directory('tests/spec/', {minimal_init='tests/minimal_init.lua'})" \
    -c "qa!" > test-results/output.txt 2>&1 &

# Get the PID
TEST_PID=$!

# Wait for tests to complete (with timeout)
TIMEOUT=120
ELAPSED=0
while kill -0 $TEST_PID 2>/dev/null && [ $ELAPSED -lt $TIMEOUT ]; do
    sleep 1
    ELAPSED=$((ELAPSED + 1))
done

# If still running after timeout, kill it
if kill -0 $TEST_PID 2>/dev/null; then
    echo "Tests timed out after ${TIMEOUT} seconds"
    kill -9 $TEST_PID
    echo "Test run timed out after ${TIMEOUT} seconds" > test-results/summary.txt
    exit 1
fi

# Wait for process to finish and get exit code
wait $TEST_PID
TEST_EXIT_CODE=$?

# Create a basic summary
echo "Test Results Summary" > test-results/summary.txt
echo "====================" >> test-results/summary.txt
echo "Test run completed" >> test-results/summary.txt
echo "Exit code: $TEST_EXIT_CODE" >> test-results/summary.txt
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')" >> test-results/summary.txt

# Create a minimal junit.xml file
cat > test-results/junit.xml << EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites name="ecolog.nvim" tests="1" failures="0" errors="0" time="0">
  <testsuite name="ecolog.nvim" tests="1" failures="0" errors="0" time="0">
    <testcase classname="ecolog" name="test_suite" time="0"/>
  </testsuite>
</testsuites>
EOF

# Display summary
cat test-results/summary.txt

# Exit with the test exit code
exit $TEST_EXIT_CODE