#!/bin/bash

# Complete C++ Recast/Detour/Crowd Test Suite Runner
# This script runs all tests and generates a comprehensive report

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     C++ Recast/Detour/Crowd Complete Test Suite             ║"
echo "║     Verification Tests for Odin Port                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
SKIPPED_TESTS=0

# Test categories
declare -A TEST_CATEGORIES
TEST_CATEGORIES["Core Recast"]="test_recast_heightfield test_filter test_regions"
TEST_CATEGORIES["Mesh Generation"]="test_contour_simplification test_mesh_detail"
TEST_CATEGORIES["Area Operations"]="test_area_marking"
TEST_CATEGORIES["Edge Cases"]="test_rasterization_edge_cases"
TEST_CATEGORIES["Advanced Features"]="test_layer_generation"
TEST_CATEGORIES["Integration"]="test_integration"
TEST_CATEGORIES["Detour Navigation"]="test_detour_navmesh"
TEST_CATEGORIES["Crowd Simulation"]="test_crowd_simulation"

# Function to run a single test
run_single_test() {
    local test_name=$1
    local test_exec=$2
    local test_output="/tmp/test_${test_name}_$$.txt"
    
    ((TOTAL_TESTS++))
    
    if [ ! -f "$test_exec" ]; then
        echo -e "  ${YELLOW}⊗${NC} $test_name - ${YELLOW}NOT BUILT${NC}"
        ((SKIPPED_TESTS++))
        return
    fi
    
    if ./"$test_exec" > "$test_output" 2>&1; then
        # Count sub-tests
        local subtests=$(grep -c "✓" "$test_output" || echo "0")
        echo -e "  ${GREEN}✓${NC} $test_name ${GREEN}PASS${NC} ($subtests sub-tests)"
        ((PASSED_TESTS++))
    else
        echo -e "  ${RED}✗${NC} $test_name ${RED}FAIL${NC}"
        echo "      Error details:"
        tail -5 "$test_output" | sed 's/^/        /'
        ((FAILED_TESTS++))
    fi
    
    rm -f "$test_output"
}

# Build tests
echo -e "${BLUE}Building test suite...${NC}"
echo "════════════════════════════════════════════════════════════════"
make -j4 all > /tmp/build_output_$$.txt 2>&1
if [ $? -eq 0 ]; then
    echo -e "${GREEN}Build successful${NC}"
else
    echo -e "${RED}Build failed. See /tmp/build_output_$$.txt for details${NC}"
fi
echo ""

# Run tests by category
echo -e "${BLUE}Running tests by category...${NC}"
echo "════════════════════════════════════════════════════════════════"

for category in "Core Recast" "Mesh Generation" "Area Operations" "Edge Cases" \
                "Advanced Features" "Integration" "Detour Navigation" "Crowd Simulation"; do
    
    echo ""
    echo -e "${BLUE}▶ $category Tests${NC}"
    echo "  ────────────────────────────────────"
    
    for test_exec in ${TEST_CATEGORIES["$category"]}; do
        test_name=$(echo $test_exec | sed 's/test_//' | sed 's/_/ /g' | sed 's/\b\(.\)/\u\1/g')
        run_single_test "$test_name" "$test_exec"
    done
done

# Generate summary report
echo ""
echo "════════════════════════════════════════════════════════════════"
echo -e "${BLUE}Test Summary Report${NC}"
echo "════════════════════════════════════════════════════════════════"
echo ""

# Calculate percentages
if [ $TOTAL_TESTS -gt 0 ]; then
    PASS_PERCENT=$((PASSED_TESTS * 100 / TOTAL_TESTS))
    FAIL_PERCENT=$((FAILED_TESTS * 100 / TOTAL_TESTS))
    SKIP_PERCENT=$((SKIPPED_TESTS * 100 / TOTAL_TESTS))
else
    PASS_PERCENT=0
    FAIL_PERCENT=0
    SKIP_PERCENT=0
fi

# Display statistics
echo "  Total Tests:    $TOTAL_TESTS"
echo -e "  ${GREEN}Passed:${NC}         $PASSED_TESTS ($PASS_PERCENT%)"
echo -e "  ${RED}Failed:${NC}         $FAILED_TESTS ($FAIL_PERCENT%)"
echo -e "  ${YELLOW}Skipped:${NC}        $SKIPPED_TESTS ($SKIP_PERCENT%)"
echo ""

# Success bar visualization
echo -n "  Success Rate: ["
for i in $(seq 1 20); do
    if [ $i -le $((PASS_PERCENT / 5)) ]; then
        echo -n "█"
    else
        echo -n "░"
    fi
done
echo "] $PASS_PERCENT%"
echo ""

# Final verdict
echo "════════════════════════════════════════════════════════════════"
if [ $FAILED_TESTS -eq 0 ] && [ $SKIPPED_TESTS -eq 0 ]; then
    echo -e "${GREEN}✓ ALL TESTS PASSED!${NC}"
    echo "The C++ reference implementation is fully functional."
    echo "Ready for comparison with Odin implementation."
    EXIT_CODE=0
elif [ $FAILED_TESTS -eq 0 ]; then
    echo -e "${YELLOW}⚠ TESTS INCOMPLETE${NC}"
    echo "All built tests passed, but some tests were not built."
    EXIT_CODE=1
else
    echo -e "${RED}✗ TESTS FAILED${NC}"
    echo "Some tests failed. Review the output above for details."
    EXIT_CODE=2
fi
echo "════════════════════════════════════════════════════════════════"

# Generate detailed report file
REPORT_FILE="test_report_$(date +%Y%m%d_%H%M%S).txt"
echo "Generating detailed report: $REPORT_FILE"
{
    echo "C++ Recast/Detour/Crowd Test Suite Report"
    echo "Generated: $(date)"
    echo ""
    echo "Summary:"
    echo "  Total: $TOTAL_TESTS"
    echo "  Passed: $PASSED_TESTS"
    echo "  Failed: $FAILED_TESTS"
    echo "  Skipped: $SKIPPED_TESTS"
    echo ""
    echo "Test Details:"
    
    for category in "Core Recast" "Mesh Generation" "Area Operations" "Edge Cases" \
                    "Advanced Features" "Integration" "Detour Navigation" "Crowd Simulation"; do
        echo ""
        echo "Category: $category"
        for test_exec in ${TEST_CATEGORIES["$category"]}; do
            if [ -f "$test_exec" ]; then
                echo "  - $test_exec: EXISTS"
            else
                echo "  - $test_exec: NOT BUILT"
            fi
        done
    done
} > "$REPORT_FILE"

echo ""
echo "Report saved to: $REPORT_FILE"
echo ""

# Cleanup
rm -f /tmp/build_output_$$.txt

exit $EXIT_CODE