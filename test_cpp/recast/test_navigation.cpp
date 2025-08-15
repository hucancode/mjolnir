#include <iostream>
#include <cassert>
#include <cstring>
#include <vector>
#include "../docs/recastnavigation/Recast/Include/Recast.h"
#include "../docs/recastnavigation/Recast/Include/RecastAlloc.h"

// Helper to add spans
bool addSpan(rcHeightfield& hf, int x, int y, int smin, int smax, unsigned char area, int flagMergeThr) {
    if (x < 0 || x >= hf.width || y < 0 || y >= hf.height) {
        return false;
    }
    
    rcSpan* span = static_cast<rcSpan*>(rcAlloc(sizeof(rcSpan), RC_ALLOC_PERM));
    if (!span) return false;
    
    span->smin = static_cast<unsigned int>(smin);
    span->smax = static_cast<unsigned int>(smax);
    span->area = area;
    span->next = nullptr;
    
    int idx = x + y * hf.width;
    
    // Insert span in sorted order
    rcSpan* prev = nullptr;
    rcSpan* cur = hf.spans[idx];
    
    while (cur && cur->smin < span->smin) {
        prev = cur;
        cur = cur->next;
    }
    
    if (prev) {
        span->next = prev->next;
        prev->next = span;
    } else {
        span->next = hf.spans[idx];
        hf.spans[idx] = span;
    }
    
    return true;
}

// Test bounds calculation - matches test_bounds_calculation in Odin
void test_bounds_calculation() {
    std::cout << "Testing bounds calculation..." << std::endl;
    
    // Test with a simple cube (matching Odin test exactly)
    float verts[] = {
        0, 0, 0,
        1, 0, 0,
        1, 1, 0,
        0, 1, 0,
        0, 0, 1,
        1, 0, 1,
        1, 1, 1,
        0, 1, 1
    };
    
    float bmin[3], bmax[3];
    rcCalcBounds(verts, 8, bmin, bmax);
    
    assert(bmin[0] == 0.0f && "bmin.x should be 0.0");
    assert(bmin[1] == 0.0f && "bmin.y should be 0.0");
    assert(bmin[2] == 0.0f && "bmin.z should be 0.0");
    assert(bmax[0] == 1.0f && "bmax.x should be 1.0");
    assert(bmax[1] == 1.0f && "bmax.y should be 1.0");
    assert(bmax[2] == 1.0f && "bmax.z should be 1.0");
    
    std::cout << "  ✓ Bounds calculation test passed" << std::endl;
}

// Test grid size calculation - matches test_grid_size_calculation in Odin
void test_grid_size_calculation() {
    std::cout << "Testing grid size calculation..." << std::endl;
    
    float bmin[] = {0, 0, 0};
    float bmax[] = {10, 5, 20};
    int width, height;
    
    // Test with cell size 1.0
    rcCalcGridSize(bmin, bmax, 1.0f, &width, &height);
    assert(width == 10 && "Width should be 10 with cell size 1.0");
    assert(height == 20 && "Height should be 20 with cell size 1.0");
    
    // Test with cell size 0.5
    rcCalcGridSize(bmin, bmax, 0.5f, &width, &height);
    assert(width == 20 && "Width should be 20 with cell size 0.5");
    assert(height == 40 && "Height should be 40 with cell size 0.5");
    
    std::cout << "  ✓ Grid size calculation test passed" << std::endl;
}

// Test compact heightfield spans - matches test_compact_heightfield_spans in Odin
void test_compact_heightfield_spans() {
    std::cout << "Testing compact heightfield spans..." << std::endl;
    
    rcContext ctx;
    
    // Create a simple heightfield with one span
    rcHeightfield* hf = rcAllocHeightfield();
    assert(hf != nullptr && "Failed to allocate heightfield");
    
    float bmin[] = {0, 0, 0};
    float bmax[] = {1, 1, 1};
    bool ok = rcCreateHeightfield(&ctx, *hf, 1, 1, bmin, bmax, 1.0f, 0.1f);
    assert(ok && "Failed to create heightfield");
    
    // Add a span manually (matching Odin test)
    ok = addSpan(*hf, 0, 0, 0, 10, RC_WALKABLE_AREA, 1);
    assert(ok && "Failed to add span");
    
    // Build compact heightfield
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    ok = rcBuildCompactHeightfield(&ctx, 2, 1, *hf, *chf);
    assert(ok && "Failed to build compact heightfield");
    assert(chf->spanCount == 1 && "Span count should be 1");
    
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    
    std::cout << "  ✓ Compact heightfield spans test passed" << std::endl;
}

int main() {
    std::cout << "=== Running C++ Navigation Tests ===" << std::endl;
    std::cout << "These tests verify navigation utility functions match Odin implementation\n" << std::endl;
    
    test_bounds_calculation();
    test_grid_size_calculation();
    test_compact_heightfield_spans();
    
    std::cout << "\n=== All navigation tests passed! ===" << std::endl;
    return 0;
}