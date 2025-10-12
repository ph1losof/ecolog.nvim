#!/usr/bin/env bash

set -e

rm -rf test-results
mkdir -p test-results

echo "Running tests and capturing results..."

# Check if timeout command exists (macOS vs Linux)
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD="timeout 120"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD="gtimeout 120"
else
    TIMEOUT_CMD=""
fi

# Run tests and capture output
$TIMEOUT_CMD nvim --headless -u tests/minimal_init.lua \
    -c "lua require('plenary.test_harness').test_directory('tests/spec/', {minimal_init='tests/minimal_init.lua'})" \
    -c "qa!" 2>&1 | tee test-results/raw_output.txt || TEST_EXIT_CODE=$?

# Extract test results from output
SUCCESS_COUNT=$(grep -c "^\[32mSuccess\[0m" test-results/raw_output.txt || echo "0")
FAILED_COUNT=$(grep -c "^\[31mFailed" test-results/raw_output.txt || echo "0")
ERROR_COUNT=$(grep -c "^\[31mErrors" test-results/raw_output.txt || echo "0")

# Extract final summary counts
TOTAL_SUCCESS=$(grep "^\[32mSuccess: \[0m" test-results/raw_output.txt | tail -1 | awk '{print $3}' || echo "0")
TOTAL_FAILED=$(grep "^\[31mFailed : \[0m" test-results/raw_output.txt | tail -1 | awk '{print $4}' || echo "0")
TOTAL_ERRORS=$(grep "^\[31mErrors : \[0m" test-results/raw_output.txt | tail -1 | awk '{print $4}' || echo "0")

# Calculate totals
TOTAL_TESTS=$((TOTAL_SUCCESS + TOTAL_FAILED + TOTAL_ERRORS))

# Create summary file
cat > test-results/summary.txt << EOF
Test Results Summary
====================
Total Tests: ${TOTAL_TESTS}
Passed: ${TOTAL_SUCCESS}
Failed: ${TOTAL_FAILED}
Errors: ${TOTAL_ERRORS}
Success Rate: $(awk "BEGIN {printf \"%.1f\", ${TOTAL_SUCCESS}*100/(${TOTAL_TESTS}+0.0001)}")%
Timestamp: $(date '+%Y-%m-%d %H:%M:%S')
EOF

# Extract failed tests if any
if [ "${TOTAL_FAILED}" -gt "0" ] || [ "${TOTAL_ERRORS}" -gt "0" ]; then
    echo "" >> test-results/summary.txt
    echo "Failed/Error Tests:" >> test-results/summary.txt
    grep "^\[31mFailed\|^\[31mError" test-results/raw_output.txt >> test-results/summary.txt || true
fi

# Create JSON results
cat > test-results/results.json << EOF
{
  "total": ${TOTAL_TESTS},
  "passed": ${TOTAL_SUCCESS},
  "failed": ${TOTAL_FAILED},
  "errors": ${TOTAL_ERRORS},
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

# Create JUnit XML format for better GitHub Actions integration
cat > test-results/junit.xml << EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites name="ecolog.nvim" tests="${TOTAL_TESTS}" failures="${TOTAL_FAILED}" errors="${TOTAL_ERRORS}" time="0">
  <testsuite name="ecolog.nvim" tests="${TOTAL_TESTS}" failures="${TOTAL_FAILED}" errors="${TOTAL_ERRORS}" time="0">
EOF

# Parse individual test results and add to XML
while IFS= read -r line; do
    if [[ $line =~ \[32mSuccess\[0m.*\|\|.*(.+) ]]; then
        TEST_NAME=$(echo "$line" | sed 's/.*||[[:space:]]*//')
        echo "    <testcase classname=\"ecolog\" name=\"${TEST_NAME}\" time=\"0\"/>" >> test-results/junit.xml
    elif [[ $line =~ \[31mFailed.*\|\|.*(.+) ]]; then
        TEST_NAME=$(echo "$line" | sed 's/.*||[[:space:]]*//')
        echo "    <testcase classname=\"ecolog\" name=\"${TEST_NAME}\" time=\"0\">" >> test-results/junit.xml
        echo "      <failure message=\"Test failed\" type=\"AssertionError\">Test failed</failure>" >> test-results/junit.xml
        echo "    </testcase>" >> test-results/junit.xml
    fi
done < test-results/raw_output.txt

cat >> test-results/junit.xml << EOF
  </testsuite>
</testsuites>
EOF

# Display summary
cat test-results/summary.txt

# Exit with failure if tests failed
if [ "${TOTAL_FAILED}" -gt "0" ] || [ "${TOTAL_ERRORS}" -gt "0" ]; then
    exit 1
fi