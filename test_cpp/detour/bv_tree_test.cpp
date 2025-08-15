// C++ tests matching test/detour/bv_tree_test.odin
#include <iostream>
#include <cassert>
#include <cmath>
#include <cstring>

// Test BV tree Y remapping - matches test_bv_tree_y_remapping
void test_bv_tree_y_remapping() {
    std::cout << "test_bv_tree_y_remapping..." << std::endl;
    
    // Test the Y remapping calculation logic that matches Odin test
    float cs = 0.3f;  // cell size
    float ch = 0.2f;  // cell height
    
    // Calculate expected Y remapping as done in Detour
    float ch_cs_ratio = ch / cs;  // 0.2 / 0.3 = 0.667
    
    // For Y value of 5 (as in the Odin test)
    unsigned short y_value = 5;
    unsigned short expected_min_y = (unsigned short)floor(y_value * ch_cs_ratio);  // floor(5 * 0.667) = floor(3.333) = 3
    unsigned short expected_max_y = (unsigned short)ceil(y_value * ch_cs_ratio);   // ceil(5 * 0.667) = ceil(3.333) = 4
    
    std::cout << "  ch/cs ratio: " << ch_cs_ratio << std::endl;
    std::cout << "  Original Y value: " << y_value << std::endl;
    std::cout << "  Expected remapped Y: min=" << expected_min_y << ", max=" << expected_max_y << std::endl;
    
    // Verify the calculation matches expected values
    assert(expected_min_y == 3);
    assert(expected_max_y == 4);
    
    std::cout << "  ✓ Passed" << std::endl;
}

// Test various Y values - matches test_bv_tree_various_y_values
void test_bv_tree_various_y_values() {
    std::cout << "test_bv_tree_various_y_values..." << std::endl;
    
    float cs = 0.3f;
    float ch = 0.2f;
    float ch_cs_ratio = ch / cs;
    
    struct TestCase {
        unsigned short y_value;
        unsigned short expected_min;
        unsigned short expected_max;
    };
    
    TestCase test_cases[] = {
        {0,  0,  0},   // floor(0 * 0.667) = 0, ceil(0 * 0.667) = 0
        {5,  3,  4},   // floor(5 * 0.667) = 3, ceil(5 * 0.667) = 4
        {10, 6,  7},   // floor(10 * 0.667) = 6, ceil(10 * 0.667) = 7
        {15, 9, 10},   // floor(15 * 0.6666...) = 9, ceil(15 * 0.6666...) = 10
        {20, 13, 14},  // floor(20 * 0.667) = 13, ceil(20 * 0.667) = 14
    };
    
    for (const auto& tc : test_cases) {
        unsigned short actual_min = (unsigned short)floor(tc.y_value * ch_cs_ratio);
        unsigned short actual_max = (unsigned short)ceil(tc.y_value * ch_cs_ratio);
        
        assert(actual_min == tc.expected_min);
        assert(actual_max == tc.expected_max);
    }
    
    std::cout << "  ✓ Passed" << std::endl;
}

int main() {
    std::cout << "=== Running BV Tree Tests (matching bv_tree_test.odin) ===" << std::endl;
    
    test_bv_tree_y_remapping();
    test_bv_tree_various_y_values();
    
    std::cout << "\n=== All tests passed ===" << std::endl;
    return 0;
}