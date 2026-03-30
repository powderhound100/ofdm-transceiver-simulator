#!/usr/bin/env bash
# =============================================================================
# run_all_tests.sh — Run all FPGA LDPC decoder testbenches and report results
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors for output (if terminal supports it)
if [ -t 1 ]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[0;33m'
    NC='\033[0m'
else
    GREEN=''
    RED=''
    YELLOW=''
    NC=''
fi

# Counters
TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0

# Run a single testbench and check result
run_test() {
    local name="$1"
    local target="$2"
    TOTAL=$((TOTAL + 1))

    echo ""
    echo "============================================"
    echo "Running: $name"
    echo "============================================"

    # Build
    if ! make "$target" 2>&1; then
        echo -e "${RED}BUILD FAILED: $name${NC}"
        FAILED=$((FAILED + 1))
        return
    fi

    # Check output for PASS/FAIL
    local output
    output=$(make "$target" 2>&1) || true

    if echo "$output" | grep -q "^PASS:"; then
        echo -e "${GREEN}PASSED: $name${NC}"
        PASSED=$((PASSED + 1))
    elif echo "$output" | grep -q "^FAIL:"; then
        echo -e "${RED}FAILED: $name${NC}"
        FAILED=$((FAILED + 1))
    else
        echo -e "${YELLOW}UNKNOWN: $name (no PASS/FAIL in output)${NC}"
        FAILED=$((FAILED + 1))
    fi
}

echo "============================================"
echo "LDPC Decoder FPGA Testbench Suite"
echo "============================================"

# Clean first
make clean

# Run all testbenches
run_test "Barrel Shifter"       tb_barrel_shifter
run_test "Min2 Finder"          tb_min2
run_test "Check Node Unit"      tb_cnu
run_test "Variable Node Unit"   tb_vnu
run_test "Top-Level Integration" tb_top

# Summary
echo ""
echo "============================================"
echo "SUMMARY"
echo "============================================"
echo "Total:   $TOTAL"
echo -e "Passed:  ${GREEN}$PASSED${NC}"
echo -e "Failed:  ${RED}$FAILED${NC}"
echo -e "Skipped: ${YELLOW}$SKIPPED${NC}"
echo "============================================"

if [ "$FAILED" -eq 0 ]; then
    echo -e "${GREEN}ALL TESTS PASSED${NC}"
    exit 0
else
    echo -e "${RED}SOME TESTS FAILED${NC}"
    exit 1
fi
