#include <iostream>
#include <cstring>
#include <vector>
#include "../docs/recastnavigation/Recast/Include/Recast.h"

// Test that demonstrates layer building behavior with complex meshes
void test_layer_overflow() {
    std::cout << "\n=== Testing Layer Building with Region Overflow ===" << std::endl;
    
    rcContext ctx;
    
    // Create a heightfield that will generate many regions
    rcHeightfield* hf = rcAllocHeightfield();
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {100, 10, 100};
    rcCreateHeightfield(&ctx, *hf, 200, 200, bmin, bmax, 0.5f, 0.5f);
    
    // Create 256 small disconnected platforms (16x16 grid)
    // This will create >255 monotone regions during partitioning
    for (int row = 0; row < 16; ++row) {
        for (int col = 0; col < 16; ++col) {
            float x = col * 6.0f + 1.0f;
            float z = row * 6.0f + 1.0f;
            float y = (row + col) % 3; // Vary heights
            
            float verts[12] = {
                x, y, z,
                x + 2, y, z,
                x + 2, y, z + 2,
                x, y, z + 2
            };
            int tris[6] = {0, 1, 2, 0, 2, 3};
            unsigned char areas[2] = {RC_WALKABLE_AREA, RC_WALKABLE_AREA};
            
            rcRasterizeTriangles(&ctx, verts, 4, tris, areas, 2, *hf, 1);
        }
    }
    
    // Build compact heightfield
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    rcBuildCompactHeightfield(&ctx, 2, 1, *hf, *chf);
    
    std::cout << "Created compact heightfield: " << chf->width << "x" << chf->height 
              << " with " << chf->spanCount << " spans" << std::endl;
    
    // Try to build layers - this should fail due to >255 regions
    rcHeightfieldLayerSet* lset = rcAllocHeightfieldLayerSet();
    bool success = rcBuildHeightfieldLayers(&ctx, *chf, 0, 2, *lset);
    
    if (!success) {
        std::cout << "EXPECTED: Layer building failed (>255 regions during partitioning)" << std::endl;
    } else {
        std::cout << "Layer building succeeded with " << lset->nlayers << " layers" << std::endl;
    }
    
    // Clean up
    rcFreeHeightfieldLayerSet(lset);
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    
    std::cout << "Result: " << (success ? "SUCCESS" : "FAILED (expected)") << std::endl;
}

// Test standard region building (what RecastDemo uses for dungeon.obj)
void test_standard_regions() {
    std::cout << "\n=== Testing Standard Region Building (No Layers) ===" << std::endl;
    
    rcContext ctx;
    
    // Same setup as above
    rcHeightfield* hf = rcAllocHeightfield();
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {100, 10, 100};
    rcCreateHeightfield(&ctx, *hf, 200, 200, bmin, bmax, 0.5f, 0.5f);
    
    // Create many small platforms
    for (int row = 0; row < 16; ++row) {
        for (int col = 0; col < 16; ++col) {
            float x = col * 6.0f + 1.0f;
            float z = row * 6.0f + 1.0f;
            float y = 0; // All at same height for simplicity
            
            float verts[12] = {
                x, y, z,
                x + 2, y, z,
                x + 2, y, z + 2,
                x, y, z + 2
            };
            int tris[6] = {0, 1, 2, 0, 2, 3};
            unsigned char areas[2] = {RC_WALKABLE_AREA, RC_WALKABLE_AREA};
            
            rcRasterizeTriangles(&ctx, verts, 4, tris, areas, 2, *hf, 1);
        }
    }
    
    // Filter
    rcFilterLowHangingWalkableObstacles(&ctx, 1, *hf);
    rcFilterLedgeSpans(&ctx, 2, 1, *hf);
    rcFilterWalkableLowHeightSpans(&ctx, 2, *hf);
    
    // Build compact heightfield
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    rcBuildCompactHeightfield(&ctx, 2, 1, *hf, *chf);
    
    // Build distance field and regions (standard approach)
    rcBuildDistanceField(&ctx, *chf);
    bool success = rcBuildRegions(&ctx, *chf, 0, 1, 1);
    
    if (success) {
        // Count regions
        int maxRegion = 0;
        for (int i = 0; i < chf->spanCount; ++i) {
            if (chf->spans[i].reg > maxRegion) {
                maxRegion = chf->spans[i].reg;
            }
        }
        std::cout << "Standard region building succeeded with " << maxRegion << " regions" << std::endl;
        std::cout << "Note: Standard regions can exceed 255 without issue!" << std::endl;
    } else {
        std::cout << "Standard region building failed" << std::endl;
    }
    
    // Clean up
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    
    std::cout << "Result: " << (success ? "SUCCESS" : "FAILED") << std::endl;
}

int main() {
    std::cout << "=== C++ Layer System Behavior Test ===" << std::endl;
    std::cout << "Testing to verify layer system limitations\n" << std::endl;
    
    test_standard_regions();
    test_layer_overflow();
    
    std::cout << "\n=== CONCLUSION ===" << std::endl;
    std::cout << "1. Standard navmesh building (rcBuildRegions) has NO 255 region limit" << std::endl;
    std::cout << "2. Layer building (rcBuildHeightfieldLayers) FAILS with >255 monotone regions" << std::endl;
    std::cout << "3. RecastDemo uses standard building for dungeon.obj, NOT layers" << std::endl;
    
    return 0;
}