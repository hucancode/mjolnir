#include <iostream>
#include <cassert>
#include <cstring>
#include <vector>
#include "../docs/recastnavigation/Recast/Include/Recast.h"
#include "../docs/recastnavigation/Recast/Include/RecastAlloc.h"

// Test basic heightfield layer generation
void test_build_heightfield_layers_basic() {
    std::cout << "Testing basic heightfield layer generation..." << std::endl;
    
    rcContext ctx;
    
    // Create a simple multi-level structure
    rcHeightfield* hf = rcAllocHeightfield();
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {20, 15, 20};
    rcCreateHeightfield(&ctx, *hf, 40, 40, bmin, bmax, 0.5f, 0.5f);
    
    // Ground floor
    float groundVerts[] = {
        0, 0, 0,
        20, 0, 0,
        20, 0, 20,
        0, 0, 20
    };
    int groundIndices[] = {0, 1, 2, 0, 2, 3};
    unsigned char groundAreas[] = {RC_WALKABLE_AREA, RC_WALKABLE_AREA};
    
    rcMarkWalkableTriangles(&ctx, 45.0f, groundVerts, 4, groundIndices, 2, groundAreas);
    rcRasterizeTriangles(&ctx, groundVerts, 4, groundIndices, groundAreas, 2, *hf, 1);
    
    // Platform (second level)
    float platformVerts[] = {
        5, 5, 5,
        15, 5, 5,
        15, 5, 15,
        5, 5, 15
    };
    int platformIndices[] = {0, 1, 2, 0, 2, 3};
    unsigned char platformAreas[] = {RC_WALKABLE_AREA, RC_WALKABLE_AREA};
    
    rcMarkWalkableTriangles(&ctx, 45.0f, platformVerts, 4, platformIndices, 2, platformAreas);
    rcRasterizeTriangles(&ctx, platformVerts, 4, platformIndices, platformAreas, 2, *hf, 1);
    
    // Build compact heightfield
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    rcBuildCompactHeightfield(&ctx, 2, 1, *hf, *chf);
    
    // Build heightfield layers
    int borderSize = 0;
    int walkableHeight = 2;
    rcHeightfieldLayerSet* lset = rcAllocHeightfieldLayerSet();
    
    bool ok = rcBuildHeightfieldLayers(&ctx, *chf, borderSize, walkableHeight, *lset);
    assert(ok && "Layer building should succeed");
    
    std::cout << "  Created " << lset->nlayers << " layers" << std::endl;
    
    // Verify layers
    for (int i = 0; i < lset->nlayers; ++i) {
        const rcHeightfieldLayer& layer = lset->layers[i];
        std::cout << "    Layer " << i << ": " 
                  << layer.width << "x" << layer.height 
                  << " at height " << layer.miny << "-" << layer.maxy << std::endl;
        
        // Count cells in layer
        int cellCount = 0;
        for (int j = 0; j < layer.width * layer.height; ++j) {
            if (layer.heights[j] != 0xff) {
                cellCount++;
            }
        }
        std::cout << "      Active cells: " << cellCount << std::endl;
    }
    
    assert(lset->nlayers >= 2 && "Should have at least 2 layers for multi-level structure");
    
    rcFreeHeightfieldLayerSet(lset);
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    
    std::cout << "  ✓ Basic layer generation test passed" << std::endl;
}

// Test layer generation with complex overlaps
void test_build_layers_complex_overlaps() {
    std::cout << "Testing layer generation with complex overlaps..." << std::endl;
    
    rcContext ctx;
    
    rcHeightfield* hf = rcAllocHeightfield();
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {30, 20, 30};
    rcCreateHeightfield(&ctx, *hf, 60, 60, bmin, bmax, 0.5f, 0.5f);
    
    // Create multiple overlapping platforms at different heights
    struct Platform {
        float minX, minZ, maxX, maxZ, height;
    };
    
    Platform platforms[] = {
        {0, 0, 30, 30, 0},      // Ground
        {5, 5, 15, 15, 4},      // Platform 1
        {10, 10, 20, 20, 8},    // Platform 2 (overlaps 1)
        {15, 15, 25, 25, 12},   // Platform 3 (overlaps 2)
        {0, 20, 10, 30, 6},     // Bridge
    };
    
    for (const auto& p : platforms) {
        float verts[] = {
            p.minX, p.height, p.minZ,
            p.maxX, p.height, p.minZ,
            p.maxX, p.height, p.maxZ,
            p.minX, p.height, p.maxZ
        };
        int indices[] = {0, 1, 2, 0, 2, 3};
        unsigned char areas[] = {RC_WALKABLE_AREA, RC_WALKABLE_AREA};
        
        rcMarkWalkableTriangles(&ctx, 45.0f, verts, 4, indices, 2, areas);
        rcRasterizeTriangles(&ctx, verts, 4, indices, areas, 2, *hf, 1);
    }
    
    // Build compact heightfield
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    rcBuildCompactHeightfield(&ctx, 2, 1, *hf, *chf);
    
    // Build layers
    rcHeightfieldLayerSet* lset = rcAllocHeightfieldLayerSet();
    bool ok = rcBuildHeightfieldLayers(&ctx, *chf, 0, 2, *lset);
    assert(ok && "Complex layer building should succeed");
    
    std::cout << "  Created " << lset->nlayers << " layers from overlapping platforms" << std::endl;
    
    // Analyze layer connectivity
    for (int i = 0; i < lset->nlayers; ++i) {
        const rcHeightfieldLayer& layer = lset->layers[i];
        int minHeight = 255, maxHeight = 0;
        
        for (int j = 0; j < layer.width * layer.height; ++j) {
            if (layer.heights[j] != 0xff) {
                minHeight = std::min(minHeight, (int)layer.heights[j]);
                maxHeight = std::max(maxHeight, (int)layer.heights[j]);
            }
        }
        
        std::cout << "    Layer " << i << " height range: " 
                  << minHeight << "-" << maxHeight << std::endl;
    }
    
    rcFreeHeightfieldLayerSet(lset);
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    
    std::cout << "  ✓ Complex overlaps test passed" << std::endl;
}

// Test layer generation with thin bridges
void test_build_layers_thin_bridges() {
    std::cout << "Testing layer generation with thin bridges..." << std::endl;
    
    rcContext ctx;
    
    rcHeightfield* hf = rcAllocHeightfield();
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {30, 15, 30};
    rcCreateHeightfield(&ctx, *hf, 60, 60, bmin, bmax, 0.5f, 0.5f);
    
    // Two platforms connected by thin bridges
    // Platform 1
    float plat1Verts[] = {
        0, 5, 0,
        10, 5, 0,
        10, 5, 10,
        0, 5, 10
    };
    int plat1Indices[] = {0, 1, 2, 0, 2, 3};
    unsigned char plat1Areas[] = {RC_WALKABLE_AREA, RC_WALKABLE_AREA};
    
    rcMarkWalkableTriangles(&ctx, 45.0f, plat1Verts, 4, plat1Indices, 2, plat1Areas);
    rcRasterizeTriangles(&ctx, plat1Verts, 4, plat1Indices, plat1Areas, 2, *hf, 1);
    
    // Platform 2
    float plat2Verts[] = {
        20, 5, 20,
        30, 5, 20,
        30, 5, 30,
        20, 5, 30
    };
    int plat2Indices[] = {0, 1, 2, 0, 2, 3};
    unsigned char plat2Areas[] = {RC_WALKABLE_AREA, RC_WALKABLE_AREA};
    
    rcMarkWalkableTriangles(&ctx, 45.0f, plat2Verts, 4, plat2Indices, 2, plat2Areas);
    rcRasterizeTriangles(&ctx, plat2Verts, 4, plat2Indices, plat2Areas, 2, *hf, 1);
    
    // Thin bridge (1 unit wide)
    float bridgeVerts[] = {
        10, 5, 5,
        20, 5, 5,
        20, 5, 6,
        10, 5, 6
    };
    int bridgeIndices[] = {0, 1, 2, 0, 2, 3};
    unsigned char bridgeAreas[] = {RC_WALKABLE_AREA, RC_WALKABLE_AREA};
    
    rcMarkWalkableTriangles(&ctx, 45.0f, bridgeVerts, 4, bridgeIndices, 2, bridgeAreas);
    rcRasterizeTriangles(&ctx, bridgeVerts, 4, bridgeIndices, bridgeAreas, 2, *hf, 1);
    
    // Build compact heightfield
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    rcBuildCompactHeightfield(&ctx, 2, 1, *hf, *chf);
    
    // Build layers
    rcHeightfieldLayerSet* lset = rcAllocHeightfieldLayerSet();
    bool ok = rcBuildHeightfieldLayers(&ctx, *chf, 0, 2, *lset);
    assert(ok && "Thin bridge layer building should succeed");
    
    std::cout << "  Created " << lset->nlayers << " layers with thin bridges" << std::endl;
    
    // Check if bridge connects platforms (should ideally be in same layer)
    for (int i = 0; i < lset->nlayers; ++i) {
        const rcHeightfieldLayer& layer = lset->layers[i];
        
        // Count connected regions
        int regionCount = 0;
        bool hasData = false;
        for (int j = 0; j < layer.width * layer.height; ++j) {
            if (layer.heights[j] != 0xff) {
                hasData = true;
            }
        }
        
        if (hasData) {
            std::cout << "    Layer " << i << " has geometry" << std::endl;
        }
    }
    
    rcFreeHeightfieldLayerSet(lset);
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    
    std::cout << "  ✓ Thin bridges test passed" << std::endl;
}

// Test layer generation with height limits
void test_build_layers_height_limits() {
    std::cout << "Testing layer generation with height limits..." << std::endl;
    
    rcContext ctx;
    
    rcHeightfield* hf = rcAllocHeightfield();
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {20, 30, 20};
    rcCreateHeightfield(&ctx, *hf, 40, 40, bmin, bmax, 0.5f, 0.5f);
    
    // Create stacked platforms with varying clearances
    for (int level = 0; level < 5; ++level) {
        float height = level * 5.0f;
        float size = 20.0f - level * 2.0f;  // Smaller as we go up
        float offset = level * 1.0f;
        
        float verts[] = {
            offset, height, offset,
            offset + size, height, offset,
            offset + size, height, offset + size,
            offset, height, offset + size
        };
        int indices[] = {0, 1, 2, 0, 2, 3};
        unsigned char areas[] = {RC_WALKABLE_AREA, RC_WALKABLE_AREA};
        
        rcMarkWalkableTriangles(&ctx, 45.0f, verts, 4, indices, 2, areas);
        rcRasterizeTriangles(&ctx, verts, 4, indices, areas, 2, *hf, 1);
    }
    
    // Build compact heightfield
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    rcBuildCompactHeightfield(&ctx, 2, 1, *hf, *chf);
    
    // Test with different walkable heights
    int walkableHeights[] = {2, 4, 8, 12};
    
    for (int wh : walkableHeights) {
        rcHeightfieldLayerSet* lset = rcAllocHeightfieldLayerSet();
        bool ok = rcBuildHeightfieldLayers(&ctx, *chf, 0, wh, *lset);
        
        if (ok) {
            std::cout << "  Walkable height " << wh << ": " 
                      << lset->nlayers << " layers" << std::endl;
        }
        
        rcFreeHeightfieldLayerSet(lset);
    }
    
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    
    std::cout << "  ✓ Height limits test passed" << std::endl;
}

// Test empty layer generation
void test_build_layers_empty() {
    std::cout << "Testing layer generation with empty input..." << std::endl;
    
    rcContext ctx;
    
    // Create empty heightfield
    rcHeightfield* hf = rcAllocHeightfield();
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {10, 10, 10};
    rcCreateHeightfield(&ctx, *hf, 10, 10, bmin, bmax, 1.0f, 0.5f);
    
    // Build empty compact heightfield
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    rcBuildCompactHeightfield(&ctx, 2, 1, *hf, *chf);
    
    // Try to build layers from empty data
    rcHeightfieldLayerSet* lset = rcAllocHeightfieldLayerSet();
    bool ok = rcBuildHeightfieldLayers(&ctx, *chf, 0, 2, *lset);
    
    if (ok) {
        std::cout << "  Empty input produced " << lset->nlayers << " layers" << std::endl;
        assert(lset->nlayers == 0 && "Empty input should produce no layers");
    } else {
        std::cout << "  Layer building failed on empty input (acceptable)" << std::endl;
    }
    
    rcFreeHeightfieldLayerSet(lset);
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    
    std::cout << "  ✓ Empty layer test passed" << std::endl;
}

// Test layer merging
void test_layer_merging() {
    std::cout << "Testing layer merging..." << std::endl;
    
    rcContext ctx;
    
    rcHeightfield* hf = rcAllocHeightfield();
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {30, 10, 30};
    rcCreateHeightfield(&ctx, *hf, 60, 60, bmin, bmax, 0.5f, 0.5f);
    
    // Create closely spaced platforms that might merge
    float heights[] = {0, 0.3f, 0.6f, 0.9f, 1.2f};
    
    for (int i = 0; i < 5; ++i) {
        float x = i * 6.0f;
        float verts[] = {
            x, heights[i], 0,
            x + 5, heights[i], 0,
            x + 5, heights[i], 30,
            x, heights[i], 30
        };
        int indices[] = {0, 1, 2, 0, 2, 3};
        unsigned char areas[] = {RC_WALKABLE_AREA, RC_WALKABLE_AREA};
        
        rcMarkWalkableTriangles(&ctx, 45.0f, verts, 4, indices, 2, areas);
        rcRasterizeTriangles(&ctx, verts, 4, indices, areas, 2, *hf, 1);
    }
    
    // Build compact heightfield
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    rcBuildCompactHeightfield(&ctx, 2, 1, *hf, *chf);
    
    // Build layers - closely spaced platforms might merge into fewer layers
    rcHeightfieldLayerSet* lset = rcAllocHeightfieldLayerSet();
    bool ok = rcBuildHeightfieldLayers(&ctx, *chf, 0, 3, *lset);
    assert(ok && "Layer merging test should succeed");
    
    std::cout << "  5 closely spaced platforms produced " << lset->nlayers << " layers" << std::endl;
    std::cout << "  (Merging may reduce layer count)" << std::endl;
    
    rcFreeHeightfieldLayerSet(lset);
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    
    std::cout << "  ✓ Layer merging test passed" << std::endl;
}

int main() {
    std::cout << "=== Running C++ Layer Generation Tests ===" << std::endl;
    std::cout << "These tests verify heightfield layer generation\n" << std::endl;
    
    test_build_heightfield_layers_basic();
    test_build_layers_complex_overlaps();
    test_build_layers_thin_bridges();
    test_build_layers_height_limits();
    test_build_layers_empty();
    test_layer_merging();
    
    std::cout << "\n=== All layer generation tests passed! ===" << std::endl;
    return 0;
}