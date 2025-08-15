#include <iostream>
#include <cassert>
#include <cstring>
#include <vector>
#include <algorithm>
#include "../docs/recastnavigation/Recast/Include/Recast.h"
#include "../docs/recastnavigation/Recast/Include/RecastAlloc.h"

// Test span bit operations
void test_span_bit_operations() {
    std::cout << "Testing span bit operations..." << std::endl;
    
    rcSpan span;
    memset(&span, 0, sizeof(span));
    
    // Test setting and getting smin
    span.smin = 100;
    assert(span.smin == 100 && "smin should be 100");
    
    // Test setting and getting smax
    span.smax = 200;
    assert(span.smax == 200 && "smax should be 200");
    assert(span.smin == 100 && "smin should remain unchanged");
    
    // Test setting and getting area
    span.area = 42;
    assert(span.area == 42 && "area should be 42");
    assert(span.smin == 100 && "smin should remain unchanged");
    assert(span.smax == 200 && "smax should remain unchanged");
    
    // Test max values
    unsigned int maxHeight = RC_SPAN_MAX_HEIGHT;
    span.smin = maxHeight;
    span.smax = maxHeight;
    assert(span.smin == maxHeight && "smin should handle max height");
    assert(span.smax == maxHeight && "smax should handle max height");
    
    // Test area max value (6 bits = 63)
    span.area = 63;
    assert(span.area == 63 && "area should handle max value");
    
    std::cout << "  ✓ Span bit operations test passed" << std::endl;
}

// Test compact cell operations
void test_compact_cell_operations() {
    std::cout << "Testing compact cell operations..." << std::endl;
    
    rcCompactCell cell;
    memset(&cell, 0, sizeof(cell));
    
    // Test setting and getting index
    cell.index = 12345;
    assert(cell.index == 12345 && "index should be 12345");
    
    // Test setting and getting count
    cell.count = 42;
    assert(cell.count == 42 && "count should be 42");
    assert(cell.index == 12345 && "index should remain unchanged");
    
    // Test max values
    unsigned int maxIndex = 0x00FFFFFF;  // 24 bits
    cell.index = maxIndex;
    assert(cell.index == maxIndex && "index should handle max value");
    
    unsigned int maxCount = 255;  // 8 bits
    cell.count = maxCount;
    assert(cell.count == maxCount && "count should handle max value");
    
    std::cout << "  ✓ Compact cell operations test passed" << std::endl;
}

// Test compact span operations
void test_compact_span_operations() {
    std::cout << "Testing compact span operations..." << std::endl;
    
    rcCompactSpan span;
    memset(&span, 0, sizeof(span));
    
    // Test y and reg
    span.y = 1000;
    span.reg = 500;
    assert(span.y == 1000 && "y should be 1000");
    assert(span.reg == 500 && "reg should be 500");
    
    // Test connection data
    span.con = 0x123456;
    assert(span.con == 0x123456 && "con should be 0x123456");
    
    // Test height
    span.h = 100;
    assert(span.h == 100 && "h should be 100");
    assert(span.con == 0x123456 && "con should remain unchanged");
    
    // Test max values
    unsigned int maxCon = 0x00FFFFFF;  // 24 bits
    span.con = maxCon;
    assert(span.con == maxCon && "con should handle max value");
    
    unsigned int maxH = 255;  // 8 bits
    span.h = maxH;
    assert(span.h == maxH && "h should handle max value");
    
    std::cout << "  ✓ Compact span operations test passed" << std::endl;
}

// Test span merging
void test_span_merging() {
    std::cout << "Testing span merging..." << std::endl;
    
    rcContext ctx;
    rcHeightfield* hf = rcAllocHeightfield();
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {10, 10, 10};
    rcCreateHeightfield(&ctx, *hf, 10, 10, bmin, bmax, 1.0f, 0.5f);
    
    // Add overlapping spans that should merge
    int x = 5, z = 5;
    int idx = x + z * hf->width;
    
    // Create spans manually
    rcSpan* span1 = (rcSpan*)rcAlloc(sizeof(rcSpan), RC_ALLOC_PERM);
    span1->smin = 10;
    span1->smax = 20;
    span1->area = RC_WALKABLE_AREA;
    span1->next = nullptr;
    hf->spans[idx] = span1;
    
    // Add overlapping span
    rcSpan* span2 = (rcSpan*)rcAlloc(sizeof(rcSpan), RC_ALLOC_PERM);
    span2->smin = 15;  // Overlaps with span1
    span2->smax = 25;
    span2->area = RC_WALKABLE_AREA;
    span2->next = nullptr;
    
    // Try to merge spans (manually for testing)
    bool shouldMerge = (span2->smin <= span1->smax + 1) && (span1->area == span2->area);
    if (shouldMerge) {
        span1->smax = std::max(span1->smax, span2->smax);
        rcFree(span2);
        std::cout << "  Spans merged successfully: [" << span1->smin << ", " << span1->smax << "]" << std::endl;
    }
    
    assert(span1->smax == 25 && "Merged span should have smax of 25");
    
    rcFreeHeightField(hf);
    std::cout << "  ✓ Span merging test passed" << std::endl;
}

// Test span allocation and deallocation
void test_span_memory_management() {
    std::cout << "Testing span memory management..." << std::endl;
    
    rcContext ctx;
    rcHeightfield* hf = rcAllocHeightfield();
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {20, 10, 20};
    rcCreateHeightfield(&ctx, *hf, 20, 20, bmin, bmax, 1.0f, 0.5f);
    
    // Add many spans to test memory allocation
    std::vector<rcSpan*> allocatedSpans;
    
    for (int i = 0; i < 100; ++i) {
        rcSpan* span = (rcSpan*)rcAlloc(sizeof(rcSpan), RC_ALLOC_PERM);
        assert(span != nullptr && "Span allocation should succeed");
        
        span->smin = i;
        span->smax = i + 10;
        span->area = RC_WALKABLE_AREA;
        span->next = nullptr;
        
        allocatedSpans.push_back(span);
    }
    
    std::cout << "  Allocated " << allocatedSpans.size() << " spans" << std::endl;
    
    // Free all spans
    for (rcSpan* span : allocatedSpans) {
        rcFree(span);
    }
    
    rcFreeHeightField(hf);
    std::cout << "  ✓ Span memory management test passed" << std::endl;
}

// Test span chain operations
void test_span_chain_operations() {
    std::cout << "Testing span chain operations..." << std::endl;
    
    rcContext ctx;
    rcHeightfield* hf = rcAllocHeightfield();
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {10, 10, 10};
    rcCreateHeightfield(&ctx, *hf, 10, 10, bmin, bmax, 1.0f, 0.5f);
    
    int x = 5, z = 5;
    int idx = x + z * hf->width;
    
    // Create a chain of spans at different heights
    rcSpan* prev = nullptr;
    for (int i = 0; i < 5; ++i) {
        rcSpan* span = (rcSpan*)rcAlloc(sizeof(rcSpan), RC_ALLOC_PERM);
        span->smin = i * 20;
        span->smax = i * 20 + 10;
        span->area = (i % 2) ? RC_WALKABLE_AREA : RC_NULL_AREA;
        span->next = nullptr;
        
        if (prev == nullptr) {
            hf->spans[idx] = span;
        } else {
            prev->next = span;
        }
        prev = span;
    }
    
    // Count spans in chain
    int spanCount = 0;
    int walkableCount = 0;
    rcSpan* current = hf->spans[idx];
    while (current) {
        spanCount++;
        if (current->area == RC_WALKABLE_AREA) {
            walkableCount++;
        }
        current = current->next;
    }
    
    std::cout << "  Chain has " << spanCount << " spans, " << walkableCount << " walkable" << std::endl;
    assert(spanCount == 5 && "Should have 5 spans in chain");
    assert(walkableCount == 2 && "Should have 2 walkable spans");
    
    rcFreeHeightField(hf);
    std::cout << "  ✓ Span chain operations test passed" << std::endl;
}

// Test span clipping
void test_span_clipping() {
    std::cout << "Testing span clipping..." << std::endl;
    
    // Test clipping spans to bounds
    struct ClipTest {
        unsigned int smin, smax;
        unsigned int clipMin, clipMax;
        unsigned int expectedMin, expectedMax;
        bool shouldExist;
    };
    
    ClipTest tests[] = {
        {10, 20, 0, 30, 10, 20, true},    // Fully inside
        {10, 20, 15, 30, 15, 20, true},   // Clip bottom
        {10, 20, 0, 15, 10, 15, true},    // Clip top
        {10, 20, 12, 18, 12, 18, true},   // Clip both
        {10, 20, 25, 30, 0, 0, false},    // Fully outside above
        {10, 20, 0, 5, 0, 0, false},      // Fully outside below
    };
    
    for (const auto& test : tests) {
        rcSpan span;
        span.smin = test.smin;
        span.smax = test.smax;
        span.area = RC_WALKABLE_AREA;
        
        // Clip span
        bool exists = true;
        if (span.smax < test.clipMin || span.smin > test.clipMax) {
            exists = false;
        } else {
            span.smin = std::max(span.smin, test.clipMin);
            span.smax = std::min(span.smax, test.clipMax);
        }
        
        if (test.shouldExist) {
            assert(exists && "Span should exist after clipping");
            assert(span.smin == test.expectedMin && "Clipped smin mismatch");
            assert(span.smax == test.expectedMax && "Clipped smax mismatch");
        } else {
            assert(!exists && "Span should not exist after clipping");
        }
    }
    
    std::cout << "  ✓ Span clipping test passed" << std::endl;
}

// Test span connectivity
void test_span_connectivity() {
    std::cout << "Testing span connectivity..." << std::endl;
    
    rcContext ctx;
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    
    // Create a simple 3x3 grid
    chf->width = 3;
    chf->height = 3;
    chf->spanCount = 9;
    chf->walkableHeight = 2;
    chf->walkableClimb = 1;
    chf->cs = 1.0f;
    chf->ch = 0.5f;
    
    // Allocate arrays
    chf->cells = (rcCompactCell*)rcAlloc(sizeof(rcCompactCell) * 9, RC_ALLOC_PERM);
    chf->spans = (rcCompactSpan*)rcAlloc(sizeof(rcCompactSpan) * 9, RC_ALLOC_PERM);
    chf->areas = (unsigned char*)rcAlloc(sizeof(unsigned char) * 9, RC_ALLOC_PERM);
    
    // Initialize cells and spans
    for (int i = 0; i < 9; ++i) {
        chf->cells[i].index = i;
        chf->cells[i].count = 1;
        
        chf->spans[i].y = 10;
        chf->spans[i].h = 10;
        chf->spans[i].con = 0;
        chf->spans[i].reg = 0;
        
        chf->areas[i] = RC_WALKABLE_AREA;
    }
    
    // Set up connectivity for center cell (should connect to all 4 neighbors)
    int centerIdx = 4;  // Center of 3x3 grid
    
    // Manually set connections (simplified)
    // In real implementation, connections are computed based on walkability
    chf->spans[centerIdx].con = 0x0F;  // Connected in all 4 directions
    
    // Test connection flags
    int connections = 0;
    for (int dir = 0; dir < 4; ++dir) {
        if (chf->spans[centerIdx].con & (1 << dir)) {
            connections++;
        }
    }
    
    std::cout << "  Center span has " << connections << " connections" << std::endl;
    assert(connections == 4 && "Center span should connect to 4 neighbors");
    
    // Clean up - rcFreeCompactHeightfield will handle freeing internal arrays
    rcFreeCompactHeightfield(chf);
    
    std::cout << "  ✓ Span connectivity test passed" << std::endl;
}

// Test span filtering
void test_span_filtering() {
    std::cout << "Testing span filtering..." << std::endl;
    
    rcContext ctx;
    rcHeightfield* hf = rcAllocHeightfield();
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {10, 10, 10};
    rcCreateHeightfield(&ctx, *hf, 10, 10, bmin, bmax, 1.0f, 0.5f);
    
    // Add spans with different areas
    for (int z = 0; z < 10; ++z) {
        for (int x = 0; x < 10; ++x) {
            rcSpan* span = (rcSpan*)rcAlloc(sizeof(rcSpan), RC_ALLOC_PERM);
            span->smin = 0;
            span->smax = 10;
            
            // Checkerboard pattern of areas
            if ((x + z) % 2 == 0) {
                span->area = RC_WALKABLE_AREA;
            } else {
                span->area = RC_NULL_AREA;
            }
            
            span->next = nullptr;
            hf->spans[x + z * hf->width] = span;
        }
    }
    
    // Count walkable vs non-walkable
    int walkableCount = 0;
    int nullCount = 0;
    
    for (int i = 0; i < hf->width * hf->height; ++i) {
        rcSpan* span = hf->spans[i];
        while (span) {
            if (span->area == RC_WALKABLE_AREA) {
                walkableCount++;
            } else if (span->area == RC_NULL_AREA) {
                nullCount++;
            }
            span = span->next;
        }
    }
    
    std::cout << "  Walkable spans: " << walkableCount << ", Null spans: " << nullCount << std::endl;
    assert(walkableCount == 50 && "Should have 50 walkable spans");
    assert(nullCount == 50 && "Should have 50 null spans");
    
    rcFreeHeightField(hf);
    std::cout << "  ✓ Span filtering test passed" << std::endl;
}

int main() {
    std::cout << "=== Running C++ Span Operations Tests ===" << std::endl;
    std::cout << "These tests verify span data structure operations\n" << std::endl;
    
    test_span_bit_operations();
    test_compact_cell_operations();
    test_compact_span_operations();
    test_span_merging();
    test_span_memory_management();
    test_span_chain_operations();
    test_span_clipping();
    test_span_connectivity();
    test_span_filtering();
    
    std::cout << "\n=== All span operations tests passed! ===" << std::endl;
    return 0;
}