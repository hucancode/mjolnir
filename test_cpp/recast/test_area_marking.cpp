#include <iostream>
#include <cassert>
#include <cstring>
#include <vector>
#include <cmath>
#include "../docs/recastnavigation/Recast/Include/Recast.h"
#include "../docs/recastnavigation/Recast/Include/RecastAlloc.h"

// Test marking walkable triangles based on slope
void test_mark_walkable_triangles() {
    std::cout << "Testing mark walkable triangles..." << std::endl;
    
    rcContext ctx;
    
    // Test triangles with different slopes
    struct TestCase {
        float verts[9];  // 3 vertices * 3 coords
        float slopeAngle;
        bool expectedWalkable;
        const char* description;
    };
    
    TestCase testCases[] = {
        // Flat horizontal triangle (correct winding for upward normal)
        {{0,0,0, 5,0,10, 10,0,0}, 45.0f, true, "Flat horizontal triangle"},
        
        // 30 degree slope
        {{0,0,0, 5,2.5f,10, 10,5,0}, 45.0f, true, "30 degree slope (walkable)"},
        
        // 50 degree slope (steeper than 45)
        {{0,0,0, 5,6,10, 10,12,0}, 45.0f, false, "50 degree slope (not walkable)"},
        
        // Vertical wall
        {{0,0,0, 0,5,10, 0,10,0}, 45.0f, false, "Vertical wall"},
        
        // Inverted triangle (ceiling)
        {{0,10,0, 10,10,0, 5,10,10}, 45.0f, false, "Ceiling (inverted)"}
    };
    
    for (const auto& tc : testCases) {
        // Single triangle
        int indices[] = {0, 1, 2};
        unsigned char areas[] = {RC_NULL_AREA};
        
        // Mark walkable triangles
        rcMarkWalkableTriangles(&ctx, tc.slopeAngle, tc.verts, 3, indices, 1, areas);
        
        bool isWalkable = (areas[0] == RC_WALKABLE_AREA);
        std::cout << "  " << tc.description << ": " 
                  << (isWalkable ? "WALKABLE" : "NOT WALKABLE") << std::endl;
        
        // Calculate actual slope for verification
        float v0[3] = {tc.verts[0], tc.verts[1], tc.verts[2]};
        float v1[3] = {tc.verts[3], tc.verts[4], tc.verts[5]};
        float v2[3] = {tc.verts[6], tc.verts[7], tc.verts[8]};
        
        float e0[3], e1[3], norm[3];
        rcVsub(e0, v1, v0);
        rcVsub(e1, v2, v0);
        rcVcross(norm, e0, e1);
        rcVnormalize(norm);
        
        float angle = std::acos(norm[1]) * 180.0f / M_PI;
        std::cout << "    Normal Y: " << norm[1] << ", Angle: " << angle << " degrees" << std::endl;
        
        assert(isWalkable == tc.expectedWalkable && "Walkable marking mismatch");
    }
    
    std::cout << "  ✓ Mark walkable triangles test passed" << std::endl;
}

// Test area assignment with convex volumes
void test_convex_volume_areas() {
    std::cout << "Testing convex volume area assignment..." << std::endl;
    
    rcContext ctx;
    
    // Create heightfield
    rcHeightfield* hf = rcAllocHeightfield();
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {20, 10, 20};
    rcCreateHeightfield(&ctx, *hf, 40, 40, bmin, bmax, 0.5f, 0.5f);
    
    // Create a floor mesh
    float verts[] = {
        0, 0, 0,
        20, 0, 0,
        20, 0, 20,
        0, 0, 20
    };
    int indices[] = {0, 1, 2, 0, 2, 3};
    unsigned char areas[] = {RC_WALKABLE_AREA, RC_WALKABLE_AREA};
    
    // Mark and rasterize
    rcMarkWalkableTriangles(&ctx, 45.0f, verts, 4, indices, 2, areas);
    rcRasterizeTriangles(&ctx, verts, 4, indices, areas, 2, *hf, 1);
    
    // Define convex volume areas (simulate water, grass, road areas)
    struct ConvexVolume {
        float verts[12];  // 4 vertices for a box (2D projection)
        float hmin, hmax;
        unsigned char area;
        const char* name;
    };
    
    ConvexVolume volumes[] = {
        {{5,0,5, 10,0,5, 10,0,10, 5,0,10}, -1, 5, RC_WALKABLE_AREA + 1, "Water area"},
        {{12,0,5, 18,0,5, 18,0,10, 12,0,10}, -1, 5, RC_WALKABLE_AREA + 2, "Grass area"},
        {{5,0,12, 15,0,12, 15,0,18, 5,0,18}, -1, 5, RC_WALKABLE_AREA + 3, "Road area"}
    };
    
    // Build compact heightfield first (needed for area marking)
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    rcBuildCompactHeightfield(&ctx, 2, 1, *hf, *chf);
    
    // Apply convex volumes
    for (const auto& vol : volumes) {
        rcMarkConvexPolyArea(&ctx, vol.verts, 4, vol.hmin, vol.hmax, vol.area, *chf);
        std::cout << "  Applied " << vol.name << " (area " << (int)vol.area << ")" << std::endl;
    }
    
    // Count areas in compact heightfield
    int areaCounts[256] = {0};
    for (int i = 0; i < chf->spanCount; ++i) {
        if (chf->areas[i] < 256) {
            areaCounts[chf->areas[i]]++;
        }
    }
    
    // Report area distribution
    std::cout << "  Area distribution:" << std::endl;
    for (int i = 0; i < 256; ++i) {
        if (areaCounts[i] > 0) {
            std::cout << "    Area " << i << ": " << areaCounts[i] << " spans" << std::endl;
        }
    }
    
    // Should have multiple area types
    int nonZeroAreas = 0;
    for (int i = RC_WALKABLE_AREA; i < 256; ++i) {
        if (areaCounts[i] > 0) nonZeroAreas++;
    }
    assert(nonZeroAreas >= 2 && "Should have multiple area types after convex volume marking");
    
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    std::cout << "  ✓ Convex volume areas test passed" << std::endl;
}

// Test cylindrical area marking
void test_cylinder_area_marking() {
    std::cout << "Testing cylinder area marking..." << std::endl;
    
    rcContext ctx;
    
    // Create heightfield
    rcHeightfield* hf = rcAllocHeightfield();
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {20, 10, 20};
    rcCreateHeightfield(&ctx, *hf, 40, 40, bmin, bmax, 0.5f, 0.5f);
    
    // Create floor
    float verts[] = {
        0, 0, 0,
        20, 0, 0,
        20, 0, 20,
        0, 0, 20
    };
    int indices[] = {0, 1, 2, 0, 2, 3};
    unsigned char areas[] = {RC_WALKABLE_AREA, RC_WALKABLE_AREA};
    
    rcMarkWalkableTriangles(&ctx, 45.0f, verts, 4, indices, 2, areas);
    rcRasterizeTriangles(&ctx, verts, 4, indices, areas, 2, *hf, 1);
    
    // Build compact heightfield
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    rcBuildCompactHeightfield(&ctx, 2, 1, *hf, *chf);
    
    // Mark cylindrical areas (e.g., for pillars, trees, etc.)
    struct Cylinder {
        float pos[3];
        float radius;
        unsigned char area;
        const char* name;
    };
    
    Cylinder cylinders[] = {
        {{10, 0, 10}, 3.0f, RC_NULL_AREA, "Pillar (non-walkable)"},
        {{5, 0, 5}, 2.0f, RC_WALKABLE_AREA + 10, "Tree area"},
        {{15, 0, 15}, 2.5f, RC_WALKABLE_AREA + 11, "Fountain area"}
    };
    
    for (const auto& cyl : cylinders) {
        rcMarkCylinderArea(&ctx, cyl.pos, cyl.radius, 10.0f, cyl.area, *chf);
        std::cout << "  Marked " << cyl.name << " at (" 
                  << cyl.pos[0] << ", " << cyl.pos[2] << ") radius " << cyl.radius << std::endl;
    }
    
    // Check that cylindrical areas were marked
    int markedCells = 0;
    for (int i = 0; i < chf->spanCount; ++i) {
        if (chf->areas[i] == RC_NULL_AREA || chf->areas[i] >= RC_WALKABLE_AREA + 10) {
            markedCells++;
        }
    }
    
    std::cout << "  Cells affected by cylinder marking: " << markedCells << std::endl;
    assert(markedCells > 0 && "Cylinder marking should affect some cells");
    
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    std::cout << "  ✓ Cylinder area marking test passed" << std::endl;
}

// Test box area marking
void test_box_area_marking() {
    std::cout << "Testing box area marking..." << std::endl;
    
    rcContext ctx;
    
    // Create heightfield
    rcHeightfield* hf = rcAllocHeightfield();
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {30, 15, 30};
    rcCreateHeightfield(&ctx, *hf, 60, 60, bmin, bmax, 0.5f, 0.5f);
    
    // Create multi-level structure
    // Ground floor
    float groundVerts[] = {
        0, 0, 0,
        30, 0, 0,
        30, 0, 30,
        0, 0, 30
    };
    int groundIndices[] = {0, 1, 2, 0, 2, 3};
    unsigned char groundAreas[] = {RC_WALKABLE_AREA, RC_WALKABLE_AREA};
    
    rcMarkWalkableTriangles(&ctx, 45.0f, groundVerts, 4, groundIndices, 2, groundAreas);
    rcRasterizeTriangles(&ctx, groundVerts, 4, groundIndices, groundAreas, 2, *hf, 1);
    
    // Second floor
    float upperVerts[] = {
        5, 5, 5,
        25, 5, 5,
        25, 5, 25,
        5, 5, 25
    };
    int upperIndices[] = {0, 1, 2, 0, 2, 3};
    unsigned char upperAreas[] = {RC_WALKABLE_AREA, RC_WALKABLE_AREA};
    
    rcMarkWalkableTriangles(&ctx, 45.0f, upperVerts, 4, upperIndices, 2, upperAreas);
    rcRasterizeTriangles(&ctx, upperVerts, 4, upperIndices, upperAreas, 2, *hf, 1);
    
    // Build compact heightfield
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    rcBuildCompactHeightfield(&ctx, 2, 1, *hf, *chf);
    
    // Mark box areas (e.g., danger zones, special areas)
    struct Box {
        float bmin[3];
        float bmax[3];
        unsigned char area;
        const char* name;
    };
    
    Box boxes[] = {
        {{8, 0, 8}, {12, 3, 12}, RC_NULL_AREA, "Obstacle box"},
        {{15, 0, 15}, {20, 8, 20}, RC_WALKABLE_AREA + 20, "Special zone"},
        {{22, 5, 22}, {27, 10, 27}, RC_WALKABLE_AREA + 21, "Upper level zone"}
    };
    
    for (const auto& box : boxes) {
        rcMarkBoxArea(&ctx, box.bmin, box.bmax, box.area, *chf);
        std::cout << "  Marked " << box.name << " from (" 
                  << box.bmin[0] << "," << box.bmin[1] << "," << box.bmin[2] << ") to ("
                  << box.bmax[0] << "," << box.bmax[1] << "," << box.bmax[2] << ")" << std::endl;
    }
    
    // Verify box marking affected areas
    int markedCount = 0;
    for (int i = 0; i < chf->spanCount; ++i) {
        if (chf->areas[i] >= RC_WALKABLE_AREA + 20 || chf->areas[i] == RC_NULL_AREA) {
            markedCount++;
        }
    }
    
    std::cout << "  Total marked cells: " << markedCount << std::endl;
    assert(markedCount > 0 && "Should mark some cells");
    
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    std::cout << "  ✓ Box area marking test passed" << std::endl;
}

// Test area filtering and replacement
void test_area_filtering() {
    std::cout << "Testing area filtering and replacement..." << std::endl;
    
    rcContext ctx;
    
    // Create compact heightfield with various areas
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    chf->width = 10;
    chf->height = 10;
    chf->spanCount = 100;
    chf->walkableHeight = 2;
    chf->walkableClimb = 1;
    chf->cs = 0.5f;
    chf->ch = 0.5f;
    
    // Allocate arrays
    chf->cells = (rcCompactCell*)rcAlloc(sizeof(rcCompactCell) * chf->width * chf->height, RC_ALLOC_PERM);
    chf->spans = (rcCompactSpan*)rcAlloc(sizeof(rcCompactSpan) * chf->spanCount, RC_ALLOC_PERM);
    chf->areas = (unsigned char*)rcAlloc(sizeof(unsigned char) * chf->spanCount, RC_ALLOC_PERM);
    
    // Initialize with mixed areas
    int spanIdx = 0;
    for (int y = 0; y < chf->height; ++y) {
        for (int x = 0; x < chf->width; ++x) {
            rcCompactCell& c = chf->cells[x + y * chf->width];
            c.index = spanIdx;
            c.count = 1;
            
            if (spanIdx < chf->spanCount) {
                chf->spans[spanIdx].y = 0;
                chf->spans[spanIdx].reg = 0;
                chf->spans[spanIdx].con = 0;
                chf->spans[spanIdx].h = 10;
                
                // Assign varied areas
                if (x < 3 && y < 3) {
                    chf->areas[spanIdx] = RC_NULL_AREA;
                } else if (x >= 7 && y >= 7) {
                    chf->areas[spanIdx] = RC_WALKABLE_AREA + 5;
                } else {
                    chf->areas[spanIdx] = RC_WALKABLE_AREA;
                }
                
                spanIdx++;
            }
        }
    }
    
    // Count initial area distribution
    int initialCounts[256] = {0};
    for (int i = 0; i < chf->spanCount; ++i) {
        initialCounts[chf->areas[i]]++;
    }
    
    std::cout << "  Initial area distribution:" << std::endl;
    std::cout << "    NULL_AREA: " << initialCounts[RC_NULL_AREA] << std::endl;
    std::cout << "    WALKABLE_AREA: " << initialCounts[RC_WALKABLE_AREA] << std::endl;
    std::cout << "    WALKABLE_AREA+5: " << initialCounts[RC_WALKABLE_AREA + 5] << std::endl;
    
    // Test median filter
    rcMedianFilterWalkableArea(&ctx, *chf);
    
    // Count after filtering
    int filteredCounts[256] = {0};
    for (int i = 0; i < chf->spanCount; ++i) {
        filteredCounts[chf->areas[i]]++;
    }
    
    std::cout << "  After median filter:" << std::endl;
    std::cout << "    NULL_AREA: " << filteredCounts[RC_NULL_AREA] << std::endl;
    std::cout << "    WALKABLE_AREA: " << filteredCounts[RC_WALKABLE_AREA] << std::endl;
    std::cout << "    WALKABLE_AREA+5: " << filteredCounts[RC_WALKABLE_AREA + 5] << std::endl;
    
    // Clean up
    rcFree(chf->cells);
    rcFree(chf->spans);
    rcFree(chf->areas);
    rcFreeCompactHeightfield(chf);
    
    std::cout << "  ✓ Area filtering test passed" << std::endl;
}

int main() {
    std::cout << "=== Running C++ Area Marking Tests ===" << std::endl;
    std::cout << "These tests verify area marking and filtering operations\n" << std::endl;
    
    test_mark_walkable_triangles();
    test_convex_volume_areas();
    test_cylinder_area_marking();
    test_box_area_marking();
    test_area_filtering();
    
    std::cout << "\n=== All area marking tests passed! ===" << std::endl;
    return 0;
}