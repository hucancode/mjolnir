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

// Test build detail mesh simple - matches test_build_detail_mesh_simple in Odin
void test_build_detail_mesh_simple() {
    std::cout << "Testing build detail mesh simple..." << std::endl;
    
    rcContext ctx;
    
    // Create simple scenario for detail mesh building
    rcHeightfield* hf = rcAllocHeightfield();
    assert(hf != nullptr && "Failed to allocate heightfield");
    
    bool ok = rcCreateHeightfield(&ctx, *hf, 8, 8, 
                                  (float[]){0,0,0}, (float[]){8,8,8}, 1.0f, 0.5f);
    assert(ok && "Failed to create heightfield");
    
    // Add walkable area (matching Odin test: 2..=5 for both x and z)
    for (int x = 2; x <= 5; ++x) {
        for (int z = 2; z <= 5; ++z) {
            ok = addSpan(*hf, x, z, 0, 2, RC_WALKABLE_AREA, 1);
            assert(ok && "Failed to add walkable span");
        }
    }
    
    // Build compact heightfield
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    assert(chf != nullptr && "Failed to allocate compact heightfield");
    
    ok = rcBuildCompactHeightfield(&ctx, 2, 1, *hf, *chf);
    assert(ok && "Failed to build compact heightfield");
    
    // Build regions and contours
    ok = rcBuildDistanceField(&ctx, *chf);
    assert(ok && "Failed to build distance field");
    
    ok = rcBuildRegions(&ctx, *chf, 2, 8, 20);
    assert(ok && "Failed to build regions");
    
    rcContourSet* contourSet = rcAllocContourSet();
    assert(contourSet != nullptr && "Failed to allocate contour set");
    
    ok = rcBuildContours(&ctx, *chf, 1.0f, 1, *contourSet, RC_CONTOUR_TESS_WALL_EDGES);
    assert(ok && "Failed to build contours");
    
    // Build polygon mesh
    rcPolyMesh* polyMesh = rcAllocPolyMesh();
    assert(polyMesh != nullptr && "Failed to allocate poly mesh");
    
    ok = rcBuildPolyMesh(&ctx, *contourSet, 6, *polyMesh);
    assert(ok && "Failed to build poly mesh");
    
    // Build detail mesh
    rcPolyMeshDetail* detailMesh = rcAllocPolyMeshDetail();
    assert(detailMesh != nullptr && "Failed to allocate detail mesh");
    
    ok = rcBuildPolyMeshDetail(&ctx, *polyMesh, *chf, 2.0f, 1.0f, *detailMesh);
    assert(ok && "Failed to build detail mesh");
    
    // Verify detail mesh was created
    assert(detailMesh->nmeshes > 0 && "Detail mesh should have mesh data");
    assert(detailMesh->nverts > 0 && "Detail mesh should have vertices");
    assert(detailMesh->ntris > 0 && "Detail mesh should have triangles");
    
    std::cout << "  ✓ Simple detail mesh test passed - " 
              << detailMesh->nverts << " vertices, " 
              << detailMesh->ntris << " triangles" << std::endl;
    
    // Clean up
    rcFreePolyMeshDetail(detailMesh);
    rcFreePolyMesh(polyMesh);
    rcFreeContourSet(contourSet);
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
}

// Test build detail mesh empty input - matches test_build_detail_mesh_empty_input in Odin
void test_build_detail_mesh_empty_input() {
    std::cout << "Testing build detail mesh empty input..." << std::endl;
    
    rcContext ctx;
    
    // Test detail mesh building with empty polygon mesh
    rcPolyMesh* polyMesh = rcAllocPolyMesh();
    assert(polyMesh != nullptr && "Failed to allocate poly mesh");
    
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    assert(chf != nullptr && "Failed to allocate compact heightfield");
    
    rcPolyMeshDetail* detailMesh = rcAllocPolyMeshDetail();
    assert(detailMesh != nullptr && "Failed to allocate detail mesh");
    
    // Should handle empty input gracefully
    bool ok = rcBuildPolyMeshDetail(&ctx, *polyMesh, *chf, 2.0f, 1.0f, *detailMesh);
    assert(ok && "Should handle empty input gracefully");
    
    // Empty input should result in empty detail mesh
    assert(detailMesh->nmeshes == 0 && "Empty input should have no meshes");
    assert(detailMesh->nverts == 0 && "Empty input should have no vertices");
    assert(detailMesh->ntris == 0 && "Empty input should have no triangles");
    
    std::cout << "  ✓ Empty input detail mesh test passed" << std::endl;
    
    // Clean up
    rcFreePolyMeshDetail(detailMesh);
    rcFreeCompactHeightfield(chf);
    rcFreePolyMesh(polyMesh);
}

// Test detail mesh sample distance variations - matches Odin test
void test_detail_mesh_sample_distance_variations() {
    std::cout << "Testing detail mesh sample distance variations..." << std::endl;
    
    rcContext ctx;
    
    // Create base scenario
    rcHeightfield* hf = rcAllocHeightfield();
    assert(hf != nullptr && "Failed to allocate heightfield");
    
    bool ok = rcCreateHeightfield(&ctx, *hf, 10, 10, 
                                  (float[]){0,0,0}, (float[]){10,10,10}, 1.0f, 0.5f);
    assert(ok && "Failed to create heightfield");
    
    // Create larger walkable area for better testing (2..=7 for both x and z)
    for (int x = 2; x <= 7; ++x) {
        for (int z = 2; z <= 7; ++z) {
            ok = addSpan(*hf, x, z, 0, 2, RC_WALKABLE_AREA, 1);
            assert(ok && "Failed to add walkable span");
        }
    }
    
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    ok = rcBuildCompactHeightfield(&ctx, 2, 1, *hf, *chf);
    ok = rcBuildDistanceField(&ctx, *chf);
    ok = rcBuildRegions(&ctx, *chf, 2, 8, 20);
    
    rcContourSet* contourSet = rcAllocContourSet();
    ok = rcBuildContours(&ctx, *chf, 1.0f, 1, *contourSet, RC_CONTOUR_TESS_WALL_EDGES);
    
    rcPolyMesh* polyMesh = rcAllocPolyMesh();
    ok = rcBuildPolyMesh(&ctx, *contourSet, 6, *polyMesh);
    
    // Test different sample distances
    float sampleDistances[] = {1.0f, 2.0f, 4.0f};
    int prevVertCount = -1;
    
    for (float sampleDist : sampleDistances) {
        rcPolyMeshDetail* detailMesh = rcAllocPolyMeshDetail();
        ok = rcBuildPolyMeshDetail(&ctx, *polyMesh, *chf, sampleDist, 1.0f, *detailMesh);
        assert(ok && "Failed to build detail mesh with varying sample distance");
        
        std::cout << "    Sample distance " << sampleDist 
                  << ": " << detailMesh->nverts << " vertices" << std::endl;
        
        // Higher sample distance should generally result in fewer vertices
        if (prevVertCount > 0) {
            assert(detailMesh->nverts <= prevVertCount + 10 && 
                   "Higher sample distance should not significantly increase vertex count");
        }
        prevVertCount = detailMesh->nverts;
        
        rcFreePolyMeshDetail(detailMesh);
    }
    
    // Clean up
    rcFreePolyMesh(polyMesh);
    rcFreeContourSet(contourSet);
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    
    std::cout << "  ✓ Detail mesh sample distance variations test passed" << std::endl;
}

// Test detail mesh with complex terrain
void test_detail_mesh_complex_terrain() {
    std::cout << "Testing detail mesh with complex terrain..." << std::endl;
    
    rcContext ctx;
    
    // Create a heightfield with varying heights
    rcHeightfield* hf = rcAllocHeightfield();
    assert(hf != nullptr && "Failed to allocate heightfield");
    
    bool ok = rcCreateHeightfield(&ctx, *hf, 20, 20, 
                                  (float[]){0,0,0}, (float[]){20,20,20}, 0.5f, 0.5f);
    assert(ok && "Failed to create heightfield");
    
    // Create terrain with varying heights
    for (int x = 2; x < 18; ++x) {
        for (int z = 2; z < 18; ++z) {
            // Create height variation based on position
            int height = (x + z) % 5;
            ok = addSpan(*hf, x, z, height, height + 2, RC_WALKABLE_AREA, 1);
            assert(ok && "Failed to add terrain span");
        }
    }
    
    // Build compact heightfield
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    ok = rcBuildCompactHeightfield(&ctx, 2, 1, *hf, *chf);
    assert(ok && "Failed to build compact heightfield");
    
    // Build regions
    ok = rcBuildDistanceField(&ctx, *chf);
    ok = rcBuildRegions(&ctx, *chf, 2, 8, 20);
    
    // Build contours
    rcContourSet* contourSet = rcAllocContourSet();
    ok = rcBuildContours(&ctx, *chf, 1.0f, 2, *contourSet, RC_CONTOUR_TESS_WALL_EDGES);
    assert(ok && "Failed to build contours for complex terrain");
    
    // Build polygon mesh
    rcPolyMesh* polyMesh = rcAllocPolyMesh();
    ok = rcBuildPolyMesh(&ctx, *contourSet, 6, *polyMesh);
    assert(ok && "Failed to build poly mesh for complex terrain");
    
    // Build detail mesh
    rcPolyMeshDetail* detailMesh = rcAllocPolyMeshDetail();
    ok = rcBuildPolyMeshDetail(&ctx, *polyMesh, *chf, 1.0f, 0.5f, *detailMesh);
    assert(ok && "Failed to build detail mesh for complex terrain");
    
    // Verify detail mesh handles complex terrain
    assert(detailMesh->nmeshes > 0 && "Complex terrain should have detail meshes");
    assert(detailMesh->nverts > polyMesh->nverts && 
           "Detail mesh should add vertices for terrain details");
    
    std::cout << "  ✓ Complex terrain detail mesh test passed - " 
              << detailMesh->nmeshes << " meshes, "
              << detailMesh->nverts << " detail vertices" << std::endl;
    
    // Clean up
    rcFreePolyMeshDetail(detailMesh);
    rcFreePolyMesh(polyMesh);
    rcFreeContourSet(contourSet);
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
}

int main() {
    std::cout << "=== Running C++ Detail Mesh Comprehensive Tests ===" << std::endl;
    std::cout << "These tests verify detail mesh generation matches Odin implementation\n" << std::endl;
    
    test_build_detail_mesh_simple();
    test_build_detail_mesh_empty_input();
    test_detail_mesh_sample_distance_variations();
    test_detail_mesh_complex_terrain();
    
    std::cout << "\n=== All detail mesh comprehensive tests passed! ===" << std::endl;
    return 0;
}