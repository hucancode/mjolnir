#!/bin/bash

echo "=== Running Comparison of C++ and Odin Standard Mesh Tests ==="
echo ""

# Run C++ test
echo "Running C++ test..."
cd /steam/projects/mjolnir-odin/test_cpp
./test_standard_meshes > cpp_results.txt 2>&1
echo "C++ test completed. Results saved to cpp_results.txt"

# Run Odin test with correct path
echo ""
echo "Running Odin test..."
cd /steam/projects/mjolnir-odin
odin test test/recast/test_standard_meshes.odin -file > odin_results.txt 2>&1
echo "Odin test completed. Results saved to odin_results.txt"

# Compare key metrics
echo ""
echo "=== Comparison Summary ==="
echo ""

echo "C++ Results for nav_test.obj:"
grep -A 20 "Testing with nav_test.obj" /steam/projects/mjolnir-odin/test_cpp/cpp_results.txt | head -25

echo ""
echo "Odin Results for nav_test.obj:"
grep -A 20 "Testing with nav_test.obj" /steam/projects/mjolnir-odin/odin_results.txt | head -25

echo ""
echo "=== Key Metrics Comparison ==="
echo ""

# Extract key numbers
echo "Grid size comparison:"
echo -n "  C++:  "
grep "Grid size:" /steam/projects/mjolnir-odin/test_cpp/cpp_results.txt | head -1
echo -n "  Odin: "
grep "Grid size:" /steam/projects/mjolnir-odin/odin_results.txt | head -1

echo ""
echo "Polygon count comparison:"
echo -n "  C++:  "
grep "Total polygons:" /steam/projects/mjolnir-odin/test_cpp/cpp_results.txt | head -1
echo -n "  Odin: "
grep "Total polygons:" /steam/projects/mjolnir-odin/odin_results.txt | head -1

echo ""
echo "Region count comparison:"
echo -n "  C++:  "
grep "Total regions:" /steam/projects/mjolnir-odin/test_cpp/cpp_results.txt | head -1
echo -n "  Odin: "
grep "Total regions:" /steam/projects/mjolnir-odin/odin_results.txt | head -1

echo ""
echo "=== Full results saved to cpp_results.txt and odin_results.txt ===
"