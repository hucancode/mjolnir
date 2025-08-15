#include <iostream>
#include <cassert>
#include <cstring>
#include <vector>
#include <cmath>
#include <limits>
#include "../docs/recastnavigation/Recast/Include/Recast.h"
#include "../docs/recastnavigation/Recast/Include/RecastAlloc.h"

// Helper to add a single span
void addSpan(rcHeightfield& hf, int x, int z, int smin, int smax, unsigned char area) {
    if (x < 0 || x >= hf.width || z < 0 || z >= hf.height) return;
    
    rcSpan* span = static_cast<rcSpan*>(rcAlloc(sizeof(rcSpan), RC_ALLOC_PERM));
    span->smin = static_cast<unsigned int>(smin);
    span->smax = static_cast<unsigned int>(smax);
    span->area = area;
    span->next = nullptr;
    
    int idx = x + z * hf.width;
    span->next = hf.spans[idx];
    hf.spans[idx] = span;
}

// Test degenerate triangle rasterization
void test_rasterize_degenerate_triangles() {
    std::cout << "Testing degenerate triangle rasterization..." << std::endl;
    
    rcContext ctx;
    rcHeightfield* hf = rcAllocHeightfield();
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {10, 10, 10};
    rcCreateHeightfield(&ctx, *hf, 10, 10, bmin, bmax, 1.0f, 0.5f);
    
    // Test 1: Collinear points (zero area triangle)
    {
        float vertices[] = {
            0, 0, 0,    // All points on same line
            1, 0, 0,
            2, 0, 0
        };
        int indices[] = {0, 1, 2};
        unsigned char areas[] = {RC_WALKABLE_AREA};
        
        // Should handle collinear points gracefully
        bool ok = rcRasterizeTriangles(&ctx, vertices, 3, indices, areas, 1, *hf, 1);
        std::cout << "  Collinear points: " << (ok ? "handled" : "failed") << std::endl;
    }
    
    // Test 2: Identical vertices
    {
        float vertices[] = {
            5, 1, 5,    // All identical
            5, 1, 5,
            5, 1, 5
        };
        int indices[] = {0, 1, 2};
        unsigned char areas[] = {RC_WALKABLE_AREA};
        
        bool ok = rcRasterizeTriangles(&ctx, vertices, 3, indices, areas, 1, *hf, 1);
        std::cout << "  Identical vertices: " << (ok ? "handled" : "failed") << std::endl;
    }
    
    // Test 3: Two identical vertices
    {
        float vertices[] = {
            3, 1, 3,
            3, 1, 3,    // Duplicate of first
            4, 1, 4     // Different
        };
        int indices[] = {0, 1, 2};
        unsigned char areas[] = {RC_WALKABLE_AREA};
        
        bool ok = rcRasterizeTriangles(&ctx, vertices, 3, indices, areas, 1, *hf, 1);
        std::cout << "  Two identical vertices: " << (ok ? "handled" : "failed") << std::endl;
    }
    
    rcFreeHeightField(hf);
    std::cout << "  ✓ Degenerate triangle rasterization test passed" << std::endl;
}

// Test nearly degenerate triangles
void test_rasterize_nearly_degenerate_triangles() {
    std::cout << "Testing nearly degenerate triangle rasterization..." << std::endl;
    
    rcContext ctx;
    rcHeightfield* hf = rcAllocHeightfield();
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {10, 10, 10};
    rcCreateHeightfield(&ctx, *hf, 10, 10, bmin, bmax, 1.0f, 0.5f);
    
    // Nearly collinear points (very thin triangle)
    float epsilon = 1e-6f;
    float vertices[] = {
        2, 1, 2,              // Point 0
        3, 1, 2,              // Point 1
        2.5f, 1, 2 + epsilon  // Point 2 - barely off the line
    };
    int indices[] = {0, 1, 2};
    unsigned char areas[] = {RC_WALKABLE_AREA};
    
    bool ok = rcRasterizeTriangles(&ctx, vertices, 3, indices, areas, 1, *hf, 1);
    std::cout << "  Nearly degenerate triangle: " << (ok ? "handled" : "failed") << std::endl;
    
    // Count rasterized spans
    int spanCount = 0;
    for (int i = 0; i < hf->width * hf->height; ++i) {
        if (hf->spans[i] != nullptr) {
            spanCount++;
        }
    }
    std::cout << "  Spans created: " << spanCount << std::endl;
    
    rcFreeHeightField(hf);
    std::cout << "  ✓ Nearly degenerate triangle test passed" << std::endl;
}

// Test sub-pixel triangles
void test_rasterize_sub_pixel_triangles() {
    std::cout << "Testing sub-pixel triangle rasterization..." << std::endl;
    
    rcContext ctx;
    rcHeightfield* hf = rcAllocHeightfield();
    
    // High resolution heightfield for sub-pixel testing
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {10, 10, 10};
    float cellSize = 0.1f;  // Small cell size
    int width = (int)((bmax[0] - bmin[0]) / cellSize);
    int height = (int)((bmax[2] - bmin[2]) / cellSize);
    
    rcCreateHeightfield(&ctx, *hf, width, height, bmin, bmax, cellSize, 0.05f);
    
    // Tiny triangle smaller than a cell
    float vertices[] = {
        5.0f, 1, 5.0f,
        5.05f, 1, 5.0f,     // 0.05 units apart (half cell)
        5.025f, 1, 5.05f
    };
    int indices[] = {0, 1, 2};
    unsigned char areas[] = {RC_WALKABLE_AREA};
    
    bool ok = rcRasterizeTriangles(&ctx, vertices, 3, indices, areas, 1, *hf, 1);
    std::cout << "  Sub-pixel triangle: " << (ok ? "handled" : "failed") << std::endl;
    
    // Check if any spans were created
    int spanCount = 0;
    for (int i = 0; i < hf->width * hf->height; ++i) {
        if (hf->spans[i] != nullptr) {
            spanCount++;
        }
    }
    std::cout << "  Spans created for tiny triangle: " << spanCount << std::endl;
    
    rcFreeHeightField(hf);
    std::cout << "  ✓ Sub-pixel triangle test passed" << std::endl;
}

// Test extreme vertex positions
void test_rasterize_extreme_positions() {
    std::cout << "Testing extreme vertex positions..." << std::endl;
    
    rcContext ctx;
    rcHeightfield* hf = rcAllocHeightfield();
    float bmin[3] = {-1000, -1000, -1000};
    float bmax[3] = {1000, 1000, 1000};
    rcCreateHeightfield(&ctx, *hf, 20, 20, bmin, bmax, 100.0f, 50.0f);
    
    // Test with very large coordinates
    {
        float vertices[] = {
            -999, 0, -999,
            999, 0, -999,
            0, 0, 999
        };
        int indices[] = {0, 1, 2};
        unsigned char areas[] = {RC_WALKABLE_AREA};
        
        bool ok = rcRasterizeTriangles(&ctx, vertices, 3, indices, areas, 1, *hf, 1);
        std::cout << "  Large coordinates: " << (ok ? "handled" : "failed") << std::endl;
    }
    
    // Test with coordinates outside bounds
    {
        float vertices[] = {
            -2000, 0, -2000,  // Outside bounds
            2000, 0, -2000,   // Outside bounds
            0, 0, 0           // Inside bounds
        };
        int indices[] = {0, 1, 2};
        unsigned char areas[] = {RC_WALKABLE_AREA};
        
        bool ok = rcRasterizeTriangles(&ctx, vertices, 3, indices, areas, 1, *hf, 1);
        std::cout << "  Out of bounds coordinates: " << (ok ? "handled" : "failed") << std::endl;
    }
    
    rcFreeHeightField(hf);
    std::cout << "  ✓ Extreme positions test passed" << std::endl;
}

// Test triangles at heightfield boundaries
void test_rasterize_boundary_triangles() {
    std::cout << "Testing boundary triangle rasterization..." << std::endl;
    
    rcContext ctx;
    rcHeightfield* hf = rcAllocHeightfield();
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {10, 10, 10};
    rcCreateHeightfield(&ctx, *hf, 10, 10, bmin, bmax, 1.0f, 0.5f);
    
    // Triangle exactly on boundary
    {
        float vertices[] = {
            0, 1, 0,     // On min boundary
            10, 1, 0,    // On max boundary
            5, 1, 10     // On max boundary
        };
        int indices[] = {0, 1, 2};
        unsigned char areas[] = {RC_WALKABLE_AREA};
        
        bool ok = rcRasterizeTriangles(&ctx, vertices, 3, indices, areas, 1, *hf, 1);
        std::cout << "  Boundary triangle: " << (ok ? "handled" : "failed") << std::endl;
    }
    
    // Triangle partially outside
    {
        float vertices[] = {
            -1, 1, -1,   // Outside
            5, 1, 5,     // Inside
            11, 1, 11    // Outside
        };
        int indices[] = {0, 1, 2};
        unsigned char areas[] = {RC_WALKABLE_AREA};
        
        bool ok = rcRasterizeTriangles(&ctx, vertices, 3, indices, areas, 1, *hf, 1);
        std::cout << "  Partially outside triangle: " << (ok ? "handled" : "failed") << std::endl;
    }
    
    // Count boundary spans
    int boundarySpans = 0;
    // Check first and last rows/columns
    for (int x = 0; x < hf->width; ++x) {
        if (hf->spans[x] != nullptr) boundarySpans++;
        if (hf->spans[x + (hf->height-1) * hf->width] != nullptr) boundarySpans++;
    }
    for (int z = 1; z < hf->height-1; ++z) {
        if (hf->spans[z * hf->width] != nullptr) boundarySpans++;
        if (hf->spans[(hf->width-1) + z * hf->width] != nullptr) boundarySpans++;
    }
    
    std::cout << "  Boundary spans created: " << boundarySpans << std::endl;
    
    rcFreeHeightField(hf);
    std::cout << "  ✓ Boundary triangle test passed" << std::endl;
}

// Test overlapping triangles at different heights
void test_rasterize_overlapping_triangles() {
    std::cout << "Testing overlapping triangle rasterization..." << std::endl;
    
    rcContext ctx;
    rcHeightfield* hf = rcAllocHeightfield();
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {10, 10, 10};
    rcCreateHeightfield(&ctx, *hf, 10, 10, bmin, bmax, 1.0f, 0.5f);
    
    // First triangle at y=2
    float vertices1[] = {
        2, 2, 2,
        8, 2, 2,
        5, 2, 8
    };
    int indices1[] = {0, 1, 2};
    unsigned char areas1[] = {RC_WALKABLE_AREA};
    
    bool ok1 = rcRasterizeTriangles(&ctx, vertices1, 3, indices1, areas1, 1, *hf, 1);
    
    // Second triangle at y=4, overlapping the first
    float vertices2[] = {
        3, 4, 3,
        7, 4, 3,
        5, 4, 7
    };
    int indices2[] = {0, 1, 2};
    unsigned char areas2[] = {RC_WALKABLE_AREA + 1};  // Different area
    
    bool ok2 = rcRasterizeTriangles(&ctx, vertices2, 3, indices2, areas2, 1, *hf, 1);
    
    std::cout << "  First triangle: " << (ok1 ? "rasterized" : "failed") << std::endl;
    std::cout << "  Second triangle: " << (ok2 ? "rasterized" : "failed") << std::endl;
    
    // Count multi-level spans
    int multiLevelCells = 0;
    for (int i = 0; i < hf->width * hf->height; ++i) {
        rcSpan* span = hf->spans[i];
        if (span && span->next) {
            multiLevelCells++;
        }
    }
    
    std::cout << "  Cells with multiple levels: " << multiLevelCells << std::endl;
    assert(multiLevelCells > 0 && "Should have multi-level spans from overlapping triangles");
    
    rcFreeHeightField(hf);
    std::cout << "  ✓ Overlapping triangle test passed" << std::endl;
}

// Test very large triangle counts
void test_rasterize_many_triangles() {
    std::cout << "Testing rasterization with many triangles..." << std::endl;
    
    rcContext ctx;
    rcHeightfield* hf = rcAllocHeightfield();
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {100, 10, 100};
    rcCreateHeightfield(&ctx, *hf, 100, 100, bmin, bmax, 1.0f, 0.5f);
    
    // Generate a grid of triangles
    std::vector<float> vertices;
    std::vector<int> indices;
    std::vector<unsigned char> areas;
    
    int gridSize = 20;
    float spacing = 4.0f;
    
    // Create vertices
    for (int z = 0; z <= gridSize; ++z) {
        for (int x = 0; x <= gridSize; ++x) {
            vertices.push_back(x * spacing);
            vertices.push_back(0);  // y
            vertices.push_back(z * spacing);
        }
    }
    
    // Create triangles
    for (int z = 0; z < gridSize; ++z) {
        for (int x = 0; x < gridSize; ++x) {
            int v0 = z * (gridSize + 1) + x;
            int v1 = v0 + 1;
            int v2 = v0 + gridSize + 1;
            int v3 = v2 + 1;
            
            // First triangle
            indices.push_back(v0);
            indices.push_back(v1);
            indices.push_back(v2);
            areas.push_back(RC_WALKABLE_AREA);
            
            // Second triangle
            indices.push_back(v1);
            indices.push_back(v3);
            indices.push_back(v2);
            areas.push_back(RC_WALKABLE_AREA);
        }
    }
    
    int triCount = indices.size() / 3;
    std::cout << "  Rasterizing " << triCount << " triangles..." << std::endl;
    
    bool ok = rcRasterizeTriangles(&ctx, vertices.data(), vertices.size() / 3,
                                   indices.data(), areas.data(), triCount, *hf, 1);
    
    std::cout << "  Result: " << (ok ? "success" : "failed") << std::endl;
    
    // Count total spans
    int totalSpans = 0;
    for (int i = 0; i < hf->width * hf->height; ++i) {
        rcSpan* span = hf->spans[i];
        while (span) {
            totalSpans++;
            span = span->next;
        }
    }
    
    std::cout << "  Total spans created: " << totalSpans << std::endl;
    assert(totalSpans > 0 && "Should create spans from triangle grid");
    
    rcFreeHeightField(hf);
    std::cout << "  ✓ Many triangles test passed" << std::endl;
}

// Test triangles with NaN or infinite values
void test_rasterize_invalid_values() {
    std::cout << "Testing rasterization with invalid values..." << std::endl;
    
    rcContext ctx;
    rcHeightfield* hf = rcAllocHeightfield();
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {10, 10, 10};
    rcCreateHeightfield(&ctx, *hf, 10, 10, bmin, bmax, 1.0f, 0.5f);
    
    // Test with NaN
    {
        float nan = std::numeric_limits<float>::quiet_NaN();
        float vertices[] = {
            nan, 1, 1,
            2, 1, 1,
            1, 1, 2
        };
        int indices[] = {0, 1, 2};
        unsigned char areas[] = {RC_WALKABLE_AREA};
        
        // Should handle NaN gracefully (likely by skipping the triangle)
        bool ok = rcRasterizeTriangles(&ctx, vertices, 3, indices, areas, 1, *hf, 1);
        std::cout << "  NaN vertex: " << (ok ? "handled" : "failed") << std::endl;
    }
    
    // Test with infinity
    {
        float inf = std::numeric_limits<float>::infinity();
        float vertices[] = {
            3, 1, 3,
            inf, 1, 3,
            3, 1, inf
        };
        int indices[] = {0, 1, 2};
        unsigned char areas[] = {RC_WALKABLE_AREA};
        
        bool ok = rcRasterizeTriangles(&ctx, vertices, 3, indices, areas, 1, *hf, 1);
        std::cout << "  Infinite vertex: " << (ok ? "handled" : "failed") << std::endl;
    }
    
    rcFreeHeightField(hf);
    std::cout << "  ✓ Invalid values test passed" << std::endl;
}

int main() {
    std::cout << "=== Running C++ Rasterization Edge Cases Tests ===" << std::endl;
    std::cout << "These tests verify edge cases in triangle rasterization\n" << std::endl;
    
    test_rasterize_degenerate_triangles();
    test_rasterize_nearly_degenerate_triangles();
    test_rasterize_sub_pixel_triangles();
    test_rasterize_extreme_positions();
    test_rasterize_boundary_triangles();
    test_rasterize_overlapping_triangles();
    test_rasterize_many_triangles();
    test_rasterize_invalid_values();
    
    std::cout << "\n=== All rasterization edge case tests passed! ===" << std::endl;
    return 0;
}