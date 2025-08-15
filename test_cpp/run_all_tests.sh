#!/bin/bash

# Script to run all C++ tests and compare with Odin implementation
# These tests verify that the Odin port matches the original C++ Recast/Detour behavior

echo "============================================"
echo "Running C++ Recast/Detour/Crowd Test Suite"
echo "============================================"
echo ""
echo "These tests verify the Odin implementation against"
echo "the original C++ Recast/Detour library behavior."
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Counter for passed/failed tests
PASSED=0
FAILED=0

# Function to run a test
run_test() {
    local test_name=$1
    local test_exec=$2
    
    echo -e "${YELLOW}Running: $test_name${NC}"
    
    if [ -f "$test_exec" ]; then
        if ./"$test_exec" > /tmp/test_output_$$.txt 2>&1; then
            echo -e "${GREEN}✓ $test_name passed${NC}"
            cat /tmp/test_output_$$.txt | grep "✓" | sed 's/^/  /'
            ((PASSED++))
        else
            echo -e "${RED}✗ $test_name failed${NC}"
            echo "  Error output:"
            tail -10 /tmp/test_output_$$.txt | sed 's/^/    /'
            ((FAILED++))
        fi
        rm -f /tmp/test_output_$$.txt
    else
        echo -e "${RED}✗ $test_name not found (needs to be built)${NC}"
        ((FAILED++))
    fi
    echo ""
}

# Build tests if needed
echo "Building tests..."
make -j4 test_recast_heightfield test_filter test_regions test_detour_navmesh \
         test_contour_simplification test_area_marking > /dev/null 2>&1

echo ""
echo "Starting test execution..."
echo "=========================="
echo ""

# Run all tests
run_test "Recast Heightfield Tests" "test_recast_heightfield"
run_test "Recast Filter Tests" "test_filter"
run_test "Recast Region Tests" "test_regions"
run_test "Recast Contour Simplification Tests" "test_contour_simplification"
run_test "Recast Area Marking Tests" "test_area_marking"
run_test "Detour NavMesh Tests" "test_detour_navmesh"

# Summary
echo "=========================="
echo "Test Summary"
echo "=========================="
echo -e "${GREEN}Passed: $PASSED${NC}"
echo -e "${RED}Failed: $FAILED${NC}"
echo ""

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed! The C++ reference implementation is working correctly.${NC}"
    echo "You can now compare these results with the Odin implementation."
    exit 0
else
    echo -e "${RED}Some tests failed. Please review the output above.${NC}"
    exit 1
fi