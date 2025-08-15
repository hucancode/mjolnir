#include <iostream>
#include <cassert>
#include <cstring>
#include <vector>
#include "../docs/recastnavigation/Recast/Include/Recast.h"
#include "../docs/recastnavigation/Recast/Include/RecastAlloc.h"

// Test layer assignment with multi-level structures
void test_simple_layers() {
    std::cout << "Testing simple layer assignment..." << std::endl;
    
    rcContext ctx;
    
    // Create a simple multi-level structure
    rcHeightfield* hf = rcAllocHeightfield();
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {10, 10, 10};
    rcCreateHeightfield(&ctx, *hf, 20, 20, bmin, bmax, 0.5f, 0.5f);
    
    // Create two levels - ground and elevated platform
    // Ground level
    float groundVerts[] = {
        0, 0, 0,
        10, 0, 0,
        10, 0, 10,
        0, 0, 10
    };
    int groundTris[] = {0, 1, 2, 0, 2, 3};
    unsigned char groundAreas[] = {RC_WALKABLE_AREA, RC_WALKABLE_AREA};
    
    rcRasterizeTriangles(&ctx, groundVerts, 4, groundTris, groundAreas, 2, *hf, 1);
    
    // Elevated platform
    float platformVerts[] = {
        3, 3, 3,
        7, 3, 3,
        7, 3, 7,
        3, 3, 7
    };
    int platformTris[] = {0, 1, 2, 0, 2, 3};
    unsigned char platformAreas[] = {RC_WALKABLE_AREA, RC_WALKABLE_AREA};
    
    rcRasterizeTriangles(&ctx, platformVerts, 4, platformTris, platformAreas, 2, *hf, 1);
    
    // Build compact heightfield
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    rcBuildCompactHeightfield(&ctx, 2, 1, *hf, *chf);
    
    // Check for layers
    int maxLayers = 0;
    int cellsWithLayers = 0;
    for (int i = 0; i < chf->width * chf->height; ++i) {
        int layers = chf->cells[i].count;
        if (layers > maxLayers) maxLayers = layers;
        if (layers > 1) cellsWithLayers++;
    }
    
    std::cout << "  Grid: " << chf->width << "x" << chf->height << std::endl;
    std::cout << "  Max layers in cell: " << maxLayers << std::endl;
    std::cout << "  Cells with multiple layers: " << cellsWithLayers << std::endl;
    
    // Build heightfield layers
    rcHeightfieldLayerSet* lset = rcAllocHeightfieldLayerSet();
    bool ok = rcBuildHeightfieldLayers(&ctx, *chf, 0, 2, *lset);
    
    if (ok) {
        std::cout << "  Generated " << lset->nlayers << " navigation layers" << std::endl;
        for (int i = 0; i < lset->nlayers; ++i) {
            rcHeightfieldLayer& layer = lset->layers[i];
            std::cout << "    Layer " << i << ": " 
                      << layer.width << "x" << layer.height 
                      << " at height [" << layer.miny << "-" << layer.maxy << "]" << std::endl;
        }
    } else {
        std::cout << "  ERROR: Failed to build layers!" << std::endl;
    }
    
    // Clean up
    rcFreeHeightfieldLayerSet(lset);
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    
    std::cout << "  ✓ Simple layer test completed" << std::endl;
}

// Test with many small regions to check overflow
void test_region_overflow() {
    std::cout << "\nTesting region overflow handling..." << std::endl;
    
    rcContext ctx;
    
    // Create a heightfield with many small disconnected regions
    rcHeightfield* hf = rcAllocHeightfield();
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {100, 10, 100};
    rcCreateHeightfield(&ctx, *hf, 200, 200, bmin, bmax, 0.5f, 0.5f);
    
    // Create a grid of small platforms (16x16 = 256 platforms)
    for (int row = 0; row < 16; ++row) {
        for (int col = 0; col < 16; ++col) {
            float x = col * 6.0f + 1.0f;
            float z = row * 6.0f + 1.0f;
            float y = (row + col) % 3; // Vary heights
            
            float verts[] = {
                x, y, z,
                x + 2, y, z,
                x + 2, y, z + 2,
                x, y, z + 2
            };
            int tris[] = {0, 1, 2, 0, 2, 3};
            unsigned char areas[] = {RC_WALKABLE_AREA, RC_WALKABLE_AREA};
            
            rcRasterizeTriangles(&ctx, verts, 4, tris, areas, 2, *hf, 1);
        }
    }
    
    // Build compact heightfield
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    rcBuildCompactHeightfield(&ctx, 2, 1, *hf, *chf);
    
    // Build regions
    rcBuildDistanceField(&ctx, *chf);
    rcBuildRegions(&ctx, *chf, 0, 1, 1); // Min area = 1 to keep all small regions
    
    // Count unique regions
    int maxRegion = 0;
    for (int i = 0; i < chf->spanCount; ++i) {
        if (chf->spans[i].reg > maxRegion) {
            maxRegion = chf->spans[i].reg;
        }
    }
    
    std::cout << "  Created " << maxRegion << " regions" << std::endl;
    
    // Try to build layers - this might fail if too many regions
    rcHeightfieldLayerSet* lset = rcAllocHeightfieldLayerSet();
    bool ok = rcBuildHeightfieldLayers(&ctx, *chf, 0, 2, *lset);
    
    if (ok) {
        std::cout << "  SUCCESS: Generated " << lset->nlayers << " layers from " 
                  << maxRegion << " regions" << std::endl;
    } else {
        std::cout << "  EXPECTED: Layer building failed due to region overflow (>255 regions)" << std::endl;
    }
    
    // Clean up
    rcFreeHeightfieldLayerSet(lset);
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    
    std::cout << "  ✓ Region overflow test completed" << std::endl;
}

// Test actual nav_test.obj layer detection
void test_navtest_layers() {
    std::cout << "\nTesting nav_test.obj layer characteristics..." << std::endl;
    
    rcContext ctx;
    
    // Simulate the nav_test.obj structure with known multi-level areas
    rcHeightfield* hf = rcAllocHeightfield();
    float bmin[3] = {-30, -5, -50};
    float bmax[3] = {65, 20, 35};
    
    // Use same grid size as nav_test.obj
    rcCreateHeightfield(&ctx, *hf, 305, 258, bmin, bmax, 0.3f, 0.2f);
    
    // Create multiple overlapping levels at different heights
    for (int level = 0; level < 4; ++level) {
        float y = level * 4.0f;
        float offset = level * 10.0f;
        
        float verts[] = {
            -20 + offset, y, -40 + offset,
            50 - offset, y, -40 + offset,
            50 - offset, y, 20 - offset,
            -20 + offset, y, 20 - offset
        };
        int tris[] = {0, 1, 2, 0, 2, 3};
        unsigned char areas[] = {RC_WALKABLE_AREA, RC_WALKABLE_AREA};
        
        rcRasterizeTriangles(&ctx, verts, 4, tris, areas, 2, *hf, 4);
    }
    
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    rcBuildCompactHeightfield(&ctx, 10, 4, *hf, *chf);
    
    // Count layers per cell
    int histogram[10] = {0}; // Count cells with 0-9 layers
    int maxLayers = 0;
    
    for (int i = 0; i < chf->width * chf->height; ++i) {
        int layers = chf->cells[i].count;
        if (layers < 10) histogram[layers]++;
        if (layers > maxLayers) maxLayers = layers;
    }
    
    std::cout << "  Layer distribution in cells:" << std::endl;
    for (int i = 0; i <= maxLayers && i < 10; ++i) {
        if (histogram[i] > 0) {
            std::cout << "    " << i << " layers: " << histogram[i] << " cells" << std::endl;
        }
    }
    std::cout << "  Maximum layers: " << maxLayers << std::endl;
    
    // Build regions before layers
    rcErodeWalkableArea(&ctx, 2, *chf);
    rcBuildDistanceField(&ctx, *chf);
    rcBuildRegions(&ctx, *chf, 0, 8, 20);
    
    // Count regions
    int maxRegion = 0;
    for (int i = 0; i < chf->spanCount; ++i) {
        if (chf->spans[i].reg > maxRegion) {
            maxRegion = chf->spans[i].reg;
        }
    }
    std::cout << "  Total regions: " << maxRegion << std::endl;
    
    // Build layers
    rcHeightfieldLayerSet* lset = rcAllocHeightfieldLayerSet();
    bool ok = rcBuildHeightfieldLayers(&ctx, *chf, 0, 10, *lset);
    
    if (ok) {
        std::cout << "  Generated " << lset->nlayers << " heightfield layers" << std::endl;
        for (int i = 0; i < lset->nlayers && i < 5; ++i) {
            rcHeightfieldLayer& layer = lset->layers[i];
            std::cout << "    Layer " << i << ": size=" 
                      << layer.width << "x" << layer.height 
                      << ", height=[" << layer.miny << "-" << layer.maxy << "]" << std::endl;
        }
    } else {
        std::cout << "  ERROR: Failed to build layers (likely region overflow)" << std::endl;
    }
    
    rcFreeHeightfieldLayerSet(lset);
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    
    std::cout << "  ✓ nav_test.obj simulation completed" << std::endl;
}

int main() {
    std::cout << "=== C++ Layer Assignment Tests ===" << std::endl;
    std::cout << "Testing how Recast handles layer assignment and region limits\n" << std::endl;
    
    test_simple_layers();
    test_region_overflow();
    test_navtest_layers();
    
    std::cout << "\n=== Tests completed ===" << std::endl;
    return 0;
}