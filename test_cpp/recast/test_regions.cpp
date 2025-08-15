#include <iostream>
#include <cassert>
#include <cstring>
#include <vector>
#include <algorithm>
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

// Test compact heightfield building
void test_compact_heightfield_building() {
    std::cout << "Testing compact heightfield building..." << std::endl;
    
    rcContext ctx;
    
    // Create a regular heightfield
    rcHeightfield* hf = rcAllocHeightfield();
    assert(hf != nullptr && "Heightfield allocation should succeed");
    
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {10, 10, 10};
    bool ok = rcCreateHeightfield(&ctx, *hf, 10, 10, bmin, bmax, 1.0f, 0.5f);
    assert(ok && "Heightfield creation should succeed");
    
    // Add some spans to create a simple floor
    for (int x = 0; x < 10; ++x) {
        for (int z = 0; z < 10; ++z) {
            ok = addSpan(*hf, x, z, 0, 10, RC_WALKABLE_AREA, 1);
            assert(ok && "Adding span should succeed");
        }
    }
    
    // Build compact heightfield
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    ok = rcBuildCompactHeightfield(&ctx, 2, 1, *hf, *chf);
    assert(ok && "Building compact heightfield should succeed");
    
    // Verify results
    assert(chf->width == 10);
    assert(chf->height == 10);
    assert(chf->spanCount == 100);
    assert(chf->walkableHeight == 2);
    assert(chf->walkableClimb == 1);
    
    // Check that spans were created
    assert(chf->spans != nullptr && "Spans should be allocated");
    assert(chf->areas != nullptr && "Areas should be allocated");
    
    // Verify all areas are walkable
    bool all_walkable = true;
    for (int i = 0; i < chf->spanCount; ++i) {
        if (chf->areas[i] != RC_WALKABLE_AREA) {
            all_walkable = false;
            break;
        }
    }
    assert(all_walkable && "All areas should be walkable");
    
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    std::cout << "  ✓ Compact heightfield building test passed" << std::endl;
}

// Test erode walkable area
void test_erode_walkable_area() {
    std::cout << "Testing erode walkable area..." << std::endl;
    
    rcContext ctx;
    
    // Create a heightfield with a 10x10 floor
    rcHeightfield* hf = rcAllocHeightfield();
    assert(hf != nullptr && "Heightfield allocation should succeed");
    
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {10, 10, 10};
    bool ok = rcCreateHeightfield(&ctx, *hf, 10, 10, bmin, bmax, 1.0f, 0.5f);
    assert(ok && "Heightfield creation should succeed");
    
    // Add a floor
    for (int x = 0; x < 10; ++x) {
        for (int z = 0; z < 10; ++z) {
            ok = addSpan(*hf, x, z, 0, 10, RC_WALKABLE_AREA, 1);
            assert(ok && "Adding span should succeed");
        }
    }
    
    // Build compact heightfield
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    ok = rcBuildCompactHeightfield(&ctx, 2, 1, *hf, *chf);
    assert(ok && "Building compact heightfield should succeed");
    
    // Erode with radius 1
    ok = rcErodeWalkableArea(&ctx, 1, *chf);
    assert(ok && "Eroding walkable area should succeed");
    
    // Check that border areas were eroded
    for (int y = 0; y < 10; ++y) {
        for (int x = 0; x < 10; ++x) {
            const rcCompactCell& c = chf->cells[x + y * chf->width];
            if (c.count > 0) {
                unsigned int end_idx = std::min((unsigned int)(c.index + c.count), (unsigned int)chf->spanCount);
                for (unsigned int i = c.index; i < end_idx; ++i) {
                    // Border cells should be null area
                    if (x == 0 || x == 9 || y == 0 || y == 9) {
                        assert(chf->areas[i] == RC_NULL_AREA && "Border should be eroded");
                    } else {
                        // Inner cells should still be walkable
                        assert(chf->areas[i] == RC_WALKABLE_AREA && "Inner area should be walkable");
                    }
                }
            }
        }
    }
    
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    std::cout << "  ✓ Erode walkable area test passed" << std::endl;
}

// Test distance field building
void test_distance_field_building() {
    std::cout << "Testing distance field building..." << std::endl;
    
    rcContext ctx;
    
    // Create heightfield
    rcHeightfield* hf = rcAllocHeightfield();
    assert(hf != nullptr);
    
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {20, 10, 20};
    bool ok = rcCreateHeightfield(&ctx, *hf, 20, 20, bmin, bmax, 1.0f, 0.5f);
    assert(ok);
    
    // Create a square platform with hole in middle
    for (int x = 5; x < 15; ++x) {
        for (int z = 5; z < 15; ++z) {
            // Skip center to create hole
            if (x >= 9 && x <= 10 && z >= 9 && z <= 10) {
                continue;
            }
            addSpan(*hf, x, z, 0, 10, RC_WALKABLE_AREA, 1);
        }
    }
    
    // Build compact heightfield
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    ok = rcBuildCompactHeightfield(&ctx, 2, 1, *hf, *chf);
    assert(ok);
    
    // Build distance field
    ok = rcBuildDistanceField(&ctx, *chf);
    assert(ok && "Distance field building should succeed");
    
    // Check that distance values were computed
    assert(chf->dist != nullptr && "Distance field should be allocated");
    
    // Check some distance values
    int max_dist = 0;
    int min_dist = 65535;
    for (int i = 0; i < chf->spanCount; ++i) {
        if (chf->areas[i] == RC_WALKABLE_AREA) {
            max_dist = std::max(max_dist, (int)chf->dist[i]);
            min_dist = std::min(min_dist, (int)chf->dist[i]);
        }
    }
    
    std::cout << "  Distance field range: " << min_dist << " to " << max_dist << std::endl;
    assert(max_dist > min_dist && "Should have varying distances");
    
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    std::cout << "  ✓ Distance field building test passed" << std::endl;
}

// Test watershed region building
void test_watershed_regions() {
    std::cout << "Testing watershed region building..." << std::endl;
    
    rcContext ctx;
    
    // Create heightfield
    rcHeightfield* hf = rcAllocHeightfield();
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {30, 10, 30};
    rcCreateHeightfield(&ctx, *hf, 30, 30, bmin, bmax, 0.5f, 0.5f);
    
    // Create two separate platforms
    // Platform 1
    for (int x = 5; x < 12; ++x) {
        for (int z = 5; z < 12; ++z) {
            addSpan(*hf, x, z, 0, 10, RC_WALKABLE_AREA, 1);
        }
    }
    
    // Platform 2
    for (int x = 18; x < 25; ++x) {
        for (int z = 18; z < 25; ++z) {
            addSpan(*hf, x, z, 0, 10, RC_WALKABLE_AREA, 1);
        }
    }
    
    // Build compact heightfield
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    rcBuildCompactHeightfield(&ctx, 2, 1, *hf, *chf);
    
    // Erode and build distance field
    rcErodeWalkableArea(&ctx, 1, *chf);
    rcBuildDistanceField(&ctx, *chf);
    
    // Build regions using watershed
    int borderSize = 0;
    int minRegionArea = 8;
    int mergeRegionArea = 20;
    bool ok = rcBuildRegions(&ctx, *chf, borderSize, minRegionArea, mergeRegionArea);
    assert(ok && "Region building should succeed");
    
    // Count unique regions
    std::vector<int> regions;
    for (int i = 0; i < chf->spanCount; ++i) {
        if (chf->spans[i].reg > 0) {
            if (std::find(regions.begin(), regions.end(), chf->spans[i].reg) == regions.end()) {
                regions.push_back(chf->spans[i].reg);
            }
        }
    }
    
    std::cout << "  Found " << regions.size() << " regions" << std::endl;
    assert(regions.size() == 2 && "Should have exactly 2 regions for 2 platforms");
    
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    std::cout << "  ✓ Watershed regions test passed" << std::endl;
}

// Test monotone region building
void test_monotone_regions() {
    std::cout << "Testing monotone region building..." << std::endl;
    
    rcContext ctx;
    
    // Create heightfield
    rcHeightfield* hf = rcAllocHeightfield();
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {20, 10, 20};
    rcCreateHeightfield(&ctx, *hf, 20, 20, bmin, bmax, 0.5f, 0.5f);
    
    // Create a single large platform
    for (int x = 2; x < 18; ++x) {
        for (int z = 2; z < 18; ++z) {
            addSpan(*hf, x, z, 0, 10, RC_WALKABLE_AREA, 1);
        }
    }
    
    // Build compact heightfield
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    rcBuildCompactHeightfield(&ctx, 2, 1, *hf, *chf);
    
    // Erode and build distance field
    rcErodeWalkableArea(&ctx, 2, *chf);
    rcBuildDistanceField(&ctx, *chf);
    
    // Build regions using monotone partitioning
    int borderSize = 0;
    int minRegionArea = 8;
    int mergeRegionArea = 20;
    bool ok = rcBuildRegionsMonotone(&ctx, *chf, borderSize, minRegionArea, mergeRegionArea);
    assert(ok && "Monotone region building should succeed");
    
    // Check that regions were created
    int maxRegion = 0;
    for (int i = 0; i < chf->spanCount; ++i) {
        if (chf->spans[i].reg > maxRegion) {
            maxRegion = chf->spans[i].reg;
        }
    }
    
    std::cout << "  Maximum region ID: " << maxRegion << std::endl;
    assert(maxRegion > 0 && "Should have created at least one region");
    
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    std::cout << "  ✓ Monotone regions test passed" << std::endl;
}

// Test layer region building
void test_layer_regions() {
    std::cout << "Testing layer region building..." << std::endl;
    
    rcContext ctx;
    
    // Create heightfield with multiple layers
    rcHeightfield* hf = rcAllocHeightfield();
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {20, 20, 20};
    rcCreateHeightfield(&ctx, *hf, 20, 20, bmin, bmax, 0.5f, 0.5f);
    
    // Create bottom layer
    for (int x = 2; x < 18; ++x) {
        for (int z = 2; z < 18; ++z) {
            addSpan(*hf, x, z, 0, 5, RC_WALKABLE_AREA, 1);
        }
    }
    
    // Create top layer (smaller platform)
    for (int x = 6; x < 14; ++x) {
        for (int z = 6; z < 14; ++z) {
            addSpan(*hf, x, z, 10, 15, RC_WALKABLE_AREA, 1);
        }
    }
    
    // Build compact heightfield
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    rcBuildCompactHeightfield(&ctx, 2, 1, *hf, *chf);
    
    // Build distance field
    rcBuildDistanceField(&ctx, *chf);
    
    // Build regions with layers
    int borderSize = 0;
    int minRegionArea = 4;
    int mergeRegionArea = 12;
    bool ok = rcBuildLayerRegions(&ctx, *chf, borderSize, minRegionArea);
    assert(ok && "Layer region building should succeed");
    
    // Count unique regions
    std::vector<int> regions;
    for (int i = 0; i < chf->spanCount; ++i) {
        if (chf->spans[i].reg > 0) {
            if (std::find(regions.begin(), regions.end(), chf->spans[i].reg) == regions.end()) {
                regions.push_back(chf->spans[i].reg);
            }
        }
    }
    
    std::cout << "  Found " << regions.size() << " layer regions" << std::endl;
    assert(regions.size() >= 2 && "Should have at least 2 regions for 2 layers");
    
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    std::cout << "  ✓ Layer regions test passed" << std::endl;
}

// Test region merging
void test_region_merging() {
    std::cout << "Testing region merging..." << std::endl;
    
    rcContext ctx;
    
    // Create heightfield
    rcHeightfield* hf = rcAllocHeightfield();
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {30, 10, 30};
    rcCreateHeightfield(&ctx, *hf, 30, 30, bmin, bmax, 0.5f, 0.5f);
    
    // Create many small adjacent platforms that should merge
    for (int px = 0; px < 3; ++px) {
        for (int pz = 0; pz < 3; ++pz) {
            int startX = 5 + px * 7;
            int startZ = 5 + pz * 7;
            for (int x = startX; x < startX + 5; ++x) {
                for (int z = startZ; z < startZ + 5; ++z) {
                    addSpan(*hf, x, z, 0, 10, RC_WALKABLE_AREA, 1);
                }
            }
        }
    }
    
    // Build compact heightfield
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    rcBuildCompactHeightfield(&ctx, 2, 1, *hf, *chf);
    
    // Build distance field
    rcBuildDistanceField(&ctx, *chf);
    
    // Build regions with small min area (should create many regions initially)
    int borderSize = 0;
    int minRegionArea = 4;
    int mergeRegionArea = 50;  // Large merge area to force merging
    bool ok = rcBuildRegions(&ctx, *chf, borderSize, minRegionArea, mergeRegionArea);
    assert(ok && "Region building should succeed");
    
    // Count final regions after merging
    std::vector<int> regions;
    for (int i = 0; i < chf->spanCount; ++i) {
        if (chf->spans[i].reg > 0) {
            if (std::find(regions.begin(), regions.end(), chf->spans[i].reg) == regions.end()) {
                regions.push_back(chf->spans[i].reg);
            }
        }
    }
    
    std::cout << "  Final region count after merging: " << regions.size() << std::endl;
    // Should have created regions (exact count may vary based on implementation)
    assert(regions.size() > 0 && regions.size() <= 9 && "Should have created regions");
    
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    std::cout << "  ✓ Region merging test passed" << std::endl;
}

int main() {
    std::cout << "=== Running C++ Region Tests ===" << std::endl;
    std::cout << "These tests verify region building operations\n" << std::endl;
    
    test_compact_heightfield_building();
    test_erode_walkable_area();
    test_distance_field_building();
    test_watershed_regions();
    test_monotone_regions();
    test_layer_regions();
    test_region_merging();
    
    std::cout << "\n=== All region tests passed! ===" << std::endl;
    return 0;
}