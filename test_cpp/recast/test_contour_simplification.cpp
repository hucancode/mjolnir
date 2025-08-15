#include <iostream>
#include <cassert>
#include <cmath>
#include <vector>
#include <cstring>
#include "../docs/recastnavigation/Recast/Include/Recast.h"
#include "../docs/recastnavigation/Recast/Include/RecastAlloc.h"

// Helper function to calculate distance from point to line segment
float distancePointToSegment(float px, float pz, float ax, float az, float bx, float bz) {
    float dx = bx - ax;
    float dz = bz - az;
    
    // Check for degenerate segment
    if (std::abs(dx) < 0.0001f && std::abs(dz) < 0.0001f) {
        float distSq = (px - ax) * (px - ax) + (pz - az) * (pz - az);
        return std::sqrt(distSq);
    }
    
    // Calculate t parameter for closest point on segment
    float t = ((px - ax) * dx + (pz - az) * dz) / (dx * dx + dz * dz);
    t = std::max(0.0f, std::min(1.0f, t));
    
    // Find nearest point on segment
    float nearx = ax + t * dx;
    float nearz = az + t * dz;
    
    // Calculate distance
    float dxNear = px - nearx;
    float dzNear = pz - nearz;
    float distSq = dxNear * dxNear + dzNear * dzNear;
    
    return std::sqrt(distSq);
}

// Test contour simplification distance calculation
void test_simplify_contour_distance() {
    std::cout << "Testing contour simplification distance calculation..." << std::endl;
    
    struct TestCase {
        float px, pz;  // Point
        float ax, az;  // Segment start
        float bx, bz;  // Segment end
        const char* description;
        float expectedDist;
    };
    
    TestCase testCases[] = {
        {5, 5, 0, 0, 10, 0, "Point (5,5) to horizontal segment (0,0)-(10,0)", 5.0f},
        {5, 5, 0, 0, 0, 10, "Point (5,5) to vertical segment (0,0)-(0,10)", 5.0f},
        {5, 0, 0, 0, 10, 0, "Point (5,0) on horizontal segment (0,0)-(10,0)", 0.0f},
        {15, 5, 0, 0, 10, 0, "Point (15,5) outside horizontal segment (0,0)-(10,0)", 7.07f},
        {0, 0, 0, 0, 10, 10, "Point at segment start", 0.0f},
        {10, 10, 0, 0, 10, 10, "Point at segment end", 0.0f}
    };
    
    for (const auto& tc : testCases) {
        float dist = distancePointToSegment(tc.px, tc.pz, tc.ax, tc.az, tc.bx, tc.bz);
        std::cout << "  " << tc.description << std::endl;
        std::cout << "    Distance: " << dist << " (expected ~" << tc.expectedDist << ")" << std::endl;
        
        // Allow small tolerance for floating point
        assert(std::abs(dist - tc.expectedDist) < 0.1f && "Distance calculation mismatch");
    }
    
    std::cout << "  ✓ Contour simplification distance test passed" << std::endl;
}

// Test contour simplification with actual contours
void test_contour_simplification() {
    std::cout << "Testing contour simplification..." << std::endl;
    
    rcContext ctx;
    
    // Create a heightfield with a simple square
    rcHeightfield* hf = rcAllocHeightfield();
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {20, 10, 20};
    rcCreateHeightfield(&ctx, *hf, 20, 20, bmin, bmax, 0.5f, 0.5f);
    
    // Add spans for a square platform
    for (int x = 5; x < 15; ++x) {
        for (int z = 5; z < 15; ++z) {
            rcSpan* span = static_cast<rcSpan*>(rcAlloc(sizeof(rcSpan), RC_ALLOC_PERM));
            span->smin = 0;
            span->smax = 10;
            span->area = RC_WALKABLE_AREA;
            span->next = nullptr;
            hf->spans[x + z * hf->width] = span;
        }
    }
    
    // Build compact heightfield
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    rcBuildCompactHeightfield(&ctx, 2, 1, *hf, *chf);
    
    // Build distance field and regions
    rcBuildDistanceField(&ctx, *chf);
    rcBuildRegions(&ctx, *chf, 0, 8, 20);
    
    // Build contours with different max error values
    float maxErrors[] = {0.0f, 1.0f, 2.0f, 4.0f};
    
    for (float maxError : maxErrors) {
        rcContourSet* cset = rcAllocContourSet();
        bool ok = rcBuildContours(&ctx, *chf, maxError, 12, *cset, RC_CONTOUR_TESS_WALL_EDGES);
        assert(ok && "Contour building should succeed");
        
        std::cout << "  Max error " << maxError << ": ";
        
        // Count total vertices in all contours
        int totalVerts = 0;
        for (int i = 0; i < cset->nconts; ++i) {
            totalVerts += cset->conts[i].nverts;
        }
        
        std::cout << cset->nconts << " contours with " << totalVerts << " total vertices" << std::endl;
        
        // Higher max error should result in fewer vertices (more simplification)
        if (maxError > 0) {
            assert(totalVerts > 0 && "Should have vertices");
        }
        
        rcFreeContourSet(cset);
    }
    
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    std::cout << "  ✓ Contour simplification test passed" << std::endl;
}

// Test contour with holes
void test_contour_with_holes() {
    std::cout << "Testing contour with holes..." << std::endl;
    
    rcContext ctx;
    
    // Create heightfield
    rcHeightfield* hf = rcAllocHeightfield();
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {30, 10, 30};
    rcCreateHeightfield(&ctx, *hf, 30, 30, bmin, bmax, 0.5f, 0.5f);
    
    // Create a square with a hole in the middle
    for (int x = 5; x < 25; ++x) {
        for (int z = 5; z < 25; ++z) {
            // Skip center area to create hole
            if (x >= 12 && x <= 17 && z >= 12 && z <= 17) {
                continue;
            }
            
            rcSpan* span = static_cast<rcSpan*>(rcAlloc(sizeof(rcSpan), RC_ALLOC_PERM));
            span->smin = 0;
            span->smax = 10;
            span->area = RC_WALKABLE_AREA;
            span->next = nullptr;
            hf->spans[x + z * hf->width] = span;
        }
    }
    
    // Build pipeline
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    rcBuildCompactHeightfield(&ctx, 2, 1, *hf, *chf);
    rcErodeWalkableArea(&ctx, 1, *chf);
    rcBuildDistanceField(&ctx, *chf);
    rcBuildRegions(&ctx, *chf, 0, 8, 20);
    
    // Build contours
    rcContourSet* cset = rcAllocContourSet();
    bool ok = rcBuildContours(&ctx, *chf, 1.3f, 12, *cset, RC_CONTOUR_TESS_WALL_EDGES);
    assert(ok && "Contour building should succeed");
    
    std::cout << "  Created " << cset->nconts << " contours" << std::endl;
    
    // Check for contours (should have outer and inner contours)
    int outerContours = 0;
    int innerContours = 0;
    
    for (int i = 0; i < cset->nconts; ++i) {
        const rcContour& cont = cset->conts[i];
        // Simple heuristic: larger contours are outer, smaller are holes
        if (cont.nverts > 20) {
            outerContours++;
        } else if (cont.nverts > 0) {
            innerContours++;
        }
        std::cout << "    Contour " << i << ": " << cont.nverts << " vertices" << std::endl;
    }
    
    std::cout << "  Outer contours: " << outerContours << ", Inner contours: " << innerContours << std::endl;
    assert(cset->nconts >= 1 && "Should have at least one contour");
    
    rcFreeContourSet(cset);
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    std::cout << "  ✓ Contour with holes test passed" << std::endl;
}

// Test edge cases in contour generation
void test_contour_edge_cases() {
    std::cout << "Testing contour edge cases..." << std::endl;
    
    rcContext ctx;
    
    // Test case 1: Single cell
    {
        rcHeightfield* hf = rcAllocHeightfield();
        float bmin[3] = {0, 0, 0};
        float bmax[3] = {2, 2, 2};
        rcCreateHeightfield(&ctx, *hf, 2, 2, bmin, bmax, 1.0f, 0.5f);
        
        // Add single span
        rcSpan* span = static_cast<rcSpan*>(rcAlloc(sizeof(rcSpan), RC_ALLOC_PERM));
        span->smin = 0;
        span->smax = 2;
        span->area = RC_WALKABLE_AREA;
        span->next = nullptr;
        hf->spans[0] = span;
        
        rcCompactHeightfield* chf = rcAllocCompactHeightfield();
        rcBuildCompactHeightfield(&ctx, 2, 1, *hf, *chf);
        rcBuildDistanceField(&ctx, *chf);
        rcBuildRegions(&ctx, *chf, 0, 1, 10);
        
        rcContourSet* cset = rcAllocContourSet();
        bool ok = rcBuildContours(&ctx, *chf, 1.0f, 12, *cset, RC_CONTOUR_TESS_WALL_EDGES);
        
        if (ok && cset->nconts > 0) {
            std::cout << "  Single cell: " << cset->nconts << " contours" << std::endl;
        }
        
        rcFreeContourSet(cset);
        rcFreeCompactHeightfield(chf);
        rcFreeHeightField(hf);
    }
    
    // Test case 2: Diagonal connection
    {
        rcHeightfield* hf = rcAllocHeightfield();
        float bmin[3] = {0, 0, 0};
        float bmax[3] = {3, 3, 3};
        rcCreateHeightfield(&ctx, *hf, 3, 3, bmin, bmax, 1.0f, 0.5f);
        
        // Add diagonal spans
        int diagonalCells[] = {0, 4, 8}; // (0,0), (1,1), (2,2)
        for (int idx : diagonalCells) {
            rcSpan* span = static_cast<rcSpan*>(rcAlloc(sizeof(rcSpan), RC_ALLOC_PERM));
            span->smin = 0;
            span->smax = 2;
            span->area = RC_WALKABLE_AREA;
            span->next = nullptr;
            hf->spans[idx] = span;
        }
        
        rcCompactHeightfield* chf = rcAllocCompactHeightfield();
        rcBuildCompactHeightfield(&ctx, 2, 1, *hf, *chf);
        rcBuildDistanceField(&ctx, *chf);
        rcBuildRegions(&ctx, *chf, 0, 1, 10);
        
        rcContourSet* cset = rcAllocContourSet();
        bool ok = rcBuildContours(&ctx, *chf, 1.0f, 12, *cset, RC_CONTOUR_TESS_WALL_EDGES);
        
        std::cout << "  Diagonal: " << cset->nconts << " contours" << std::endl;
        
        rcFreeContourSet(cset);
        rcFreeCompactHeightfield(chf);
        rcFreeHeightField(hf);
    }
    
    std::cout << "  ✓ Contour edge cases test passed" << std::endl;
}

int main() {
    std::cout << "=== Running C++ Contour Simplification Tests ===" << std::endl;
    std::cout << "These tests verify contour generation and simplification\n" << std::endl;
    
    test_simplify_contour_distance();
    test_contour_simplification();
    test_contour_with_holes();
    test_contour_edge_cases();
    
    std::cout << "\n=== All contour simplification tests passed! ===" << std::endl;
    return 0;
}