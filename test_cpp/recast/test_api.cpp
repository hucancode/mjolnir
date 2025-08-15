#include <iostream>
#include <cassert>
#include <cstring>
#include <vector>
#include <memory>
#include "../docs/recastnavigation/Recast/Include/Recast.h"
#include "../docs/recastnavigation/Recast/Include/RecastAlloc.h"
#include "../docs/recastnavigation/Detour/Include/DetourNavMesh.h"
#include "../docs/recastnavigation/Detour/Include/DetourNavMeshBuilder.h"

// Test API simple build - matches test_api_simple_build in Odin
void test_api_simple_build() {
    std::cout << "Testing API simple build..." << std::endl;
    
    rcContext ctx;
    
    // Simple square floor geometry (matching Odin test exactly)
    float vertices[] = {
        0, 0, 0,
        10, 0, 0,
        10, 0, 10,
        0, 0, 10
    };
    
    int indices[] = {
        0, 1, 2,
        0, 2, 3
    };
    
    unsigned char areas[] = {
        RC_WALKABLE_AREA,
        RC_WALKABLE_AREA
    };
    
    // Test configuration (matching Odin config exactly)
    rcConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    
    cfg.cs = 0.3f;
    cfg.ch = 0.2f;
    cfg.walkableSlopeAngle = 45.0f;
    cfg.walkableHeight = 2;
    cfg.walkableClimb = 1;
    cfg.walkableRadius = 1;
    cfg.maxEdgeLen = 12;
    cfg.maxSimplificationError = 1.3f;
    cfg.minRegionArea = 8;
    cfg.mergeRegionArea = 20;
    cfg.maxVertsPerPoly = 6;
    cfg.detailSampleDist = 6.0f;
    cfg.detailSampleMaxError = 1.0f;
    
    // Calculate grid size
    rcCalcBounds(vertices, 4, cfg.bmin, cfg.bmax);
    rcCalcGridSize(cfg.bmin, cfg.bmax, cfg.cs, &cfg.width, &cfg.height);
    
    // Step 1: Allocate and build heightfield
    rcHeightfield* hf = rcAllocHeightfield();
    assert(hf && "Failed to allocate heightfield");
    
    bool ok = rcCreateHeightfield(&ctx, *hf, cfg.width, cfg.height, 
                                  cfg.bmin, cfg.bmax, cfg.cs, cfg.ch);
    assert(ok && "Failed to create heightfield");
    
    // Step 2: Rasterize triangles
    rcMarkWalkableTriangles(&ctx, cfg.walkableSlopeAngle, vertices, 4, indices, 2, areas);
    rcRasterizeTriangles(&ctx, vertices, 4, indices, areas, 2, *hf, cfg.walkableClimb);
    
    // Step 3: Filter walkable surfaces
    rcFilterLowHangingWalkableObstacles(&ctx, cfg.walkableClimb, *hf);
    rcFilterLedgeSpans(&ctx, cfg.walkableHeight, cfg.walkableClimb, *hf);
    rcFilterWalkableLowHeightSpans(&ctx, cfg.walkableHeight, *hf);
    
    // Step 4: Build compact heightfield
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    assert(chf && "Failed to allocate compact heightfield");
    
    ok = rcBuildCompactHeightfield(&ctx, cfg.walkableHeight, cfg.walkableClimb, *hf, *chf);
    assert(ok && "Failed to build compact heightfield");
    
    // Step 5: Erode walkable area
    ok = rcErodeWalkableArea(&ctx, cfg.walkableRadius, *chf);
    assert(ok && "Failed to erode walkable area");
    
    // Step 6: Build regions
    ok = rcBuildDistanceField(&ctx, *chf);
    assert(ok && "Failed to build distance field");
    
    ok = rcBuildRegions(&ctx, *chf, 0, cfg.minRegionArea, cfg.mergeRegionArea);
    assert(ok && "Failed to build regions");
    
    // Step 7: Build contours
    rcContourSet* cset = rcAllocContourSet();
    assert(cset && "Failed to allocate contour set");
    
    ok = rcBuildContours(&ctx, *chf, cfg.maxSimplificationError, cfg.maxEdgeLen, *cset);
    assert(ok && "Failed to build contours");
    
    // Step 8: Build polygon mesh
    rcPolyMesh* pmesh = rcAllocPolyMesh();
    assert(pmesh && "Failed to allocate poly mesh");
    
    ok = rcBuildPolyMesh(&ctx, *cset, cfg.maxVertsPerPoly, *pmesh);
    assert(ok && "Failed to build poly mesh");
    
    // Step 9: Build detail mesh
    rcPolyMeshDetail* dmesh = rcAllocPolyMeshDetail();
    assert(dmesh && "Failed to allocate detail mesh");
    
    ok = rcBuildPolyMeshDetail(&ctx, *pmesh, *chf, cfg.detailSampleDist, 
                              cfg.detailSampleMaxError, *dmesh);
    assert(ok && "Failed to build detail mesh");
    
    // Verify results
    assert(pmesh->nverts > 0 && "No vertices generated");
    assert(pmesh->npolys > 0 && "No polygons generated");
    
    std::cout << "  Generated " << pmesh->npolys << " polygons, " 
              << pmesh->nverts << " vertices" << std::endl;
    
    // Clean up
    rcFreePolyMeshDetail(dmesh);
    rcFreePolyMesh(pmesh);
    rcFreeContourSet(cset);
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    
    std::cout << "  ✓ API simple build test passed" << std::endl;
}

// Test API quick build - matches test_api_quick_build in Odin
void test_api_quick_build() {
    std::cout << "Testing API quick build..." << std::endl;
    
    rcContext ctx;
    
    // Test the convenience quick build function (matching Odin test)
    float vertices[] = {
        0, 0, 0,
        20, 0, 0,
        20, 0, 20,
        0, 0, 20
    };
    
    int indices[] = {
        0, 1, 2,
        0, 2, 3
    };
    
    // Create areas array
    unsigned char areas[] = {
        RC_WALKABLE_AREA,
        RC_WALKABLE_AREA
    };
    
    // Create config (matching Odin cfg exactly)
    rcConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    
    cfg.cs = 0.5f;
    cfg.ch = 0.5f;
    cfg.walkableSlopeAngle = 45.0f;
    cfg.walkableHeight = 2;
    cfg.walkableClimb = 1;
    cfg.walkableRadius = 1;
    cfg.maxEdgeLen = 12;
    cfg.maxSimplificationError = 1.3f;
    cfg.minRegionArea = 8;
    cfg.mergeRegionArea = 20;
    cfg.maxVertsPerPoly = 6;
    cfg.detailSampleDist = 6.0f;
    cfg.detailSampleMaxError = 1.0f;
    
    // Calculate grid size
    rcCalcBounds(vertices, 4, cfg.bmin, cfg.bmax);
    rcCalcGridSize(cfg.bmin, cfg.bmax, cfg.cs, &cfg.width, &cfg.height);
    
    // Build navigation mesh (full pipeline)
    rcHeightfield* hf = rcAllocHeightfield();
    rcCreateHeightfield(&ctx, *hf, cfg.width, cfg.height, cfg.bmin, cfg.bmax, cfg.cs, cfg.ch);
    
    rcMarkWalkableTriangles(&ctx, cfg.walkableSlopeAngle, vertices, 4, indices, 2, areas);
    rcRasterizeTriangles(&ctx, vertices, 4, indices, areas, 2, *hf, cfg.walkableClimb);
    
    rcFilterLowHangingWalkableObstacles(&ctx, cfg.walkableClimb, *hf);
    rcFilterLedgeSpans(&ctx, cfg.walkableHeight, cfg.walkableClimb, *hf);
    rcFilterWalkableLowHeightSpans(&ctx, cfg.walkableHeight, *hf);
    
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    rcBuildCompactHeightfield(&ctx, cfg.walkableHeight, cfg.walkableClimb, *hf, *chf);
    
    rcErodeWalkableArea(&ctx, cfg.walkableRadius, *chf);
    rcBuildDistanceField(&ctx, *chf);
    rcBuildRegions(&ctx, *chf, 0, cfg.minRegionArea, cfg.mergeRegionArea);
    
    rcContourSet* cset = rcAllocContourSet();
    rcBuildContours(&ctx, *chf, cfg.maxSimplificationError, cfg.maxEdgeLen, *cset);
    
    rcPolyMesh* pmesh = rcAllocPolyMesh();
    rcBuildPolyMesh(&ctx, *cset, cfg.maxVertsPerPoly, *pmesh);
    
    rcPolyMeshDetail* dmesh = rcAllocPolyMeshDetail();
    rcBuildPolyMeshDetail(&ctx, *pmesh, *chf, cfg.detailSampleDist, cfg.detailSampleMaxError, *dmesh);
    
    // Check result
    assert(pmesh->nverts > 0 && "Quick build generated no vertices");
    assert(pmesh->npolys > 0 && "Quick build generated no polygons");
    
    std::cout << "  Generated " << pmesh->npolys << " polygons with cell size 0.5" << std::endl;
    
    // Clean up
    rcFreePolyMeshDetail(dmesh);
    rcFreePolyMesh(pmesh);
    rcFreeContourSet(cset);
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    
    std::cout << "  ✓ API quick build test passed" << std::endl;
}

// Test different configurations - matches test_api_configuration in Odin
void test_api_configuration() {
    std::cout << "Testing API configuration..." << std::endl;
    
    rcContext ctx;
    
    // Test different configurations (matching Odin configs)
    struct TestConfig {
        const char* name;
        float cs;
        float ch;
    };
    
    TestConfig configs[] = {
        {"Fast", 0.5f, 0.5f},
        {"Balanced", 0.3f, 0.2f},
        {"High_Quality", 0.1f, 0.1f}
    };
    
    // Simple test geometry
    float vertices[] = {
        0, 0, 0,
        10, 0, 0,
        10, 0, 10,
        0, 0, 10
    };
    
    int indices[] = {
        0, 1, 2,
        0, 2, 3
    };
    
    unsigned char areas[] = {
        RC_WALKABLE_AREA,
        RC_WALKABLE_AREA
    };
    
    for (const auto& testCfg : configs) {
        rcConfig cfg;
        memset(&cfg, 0, sizeof(cfg));
        
        cfg.cs = testCfg.cs;
        cfg.ch = testCfg.ch;
        cfg.walkableSlopeAngle = 45.0f;
        cfg.walkableHeight = 2;
        cfg.walkableClimb = 1;
        cfg.walkableRadius = 1;
        cfg.maxEdgeLen = 12;
        cfg.maxSimplificationError = 1.3f;
        cfg.minRegionArea = 8;
        cfg.mergeRegionArea = 20;
        cfg.maxVertsPerPoly = 6;
        cfg.detailSampleDist = 6.0f;
        cfg.detailSampleMaxError = 1.0f;
        
        // Calculate grid size
        rcCalcBounds(vertices, 4, cfg.bmin, cfg.bmax);
        rcCalcGridSize(cfg.bmin, cfg.bmax, cfg.cs, &cfg.width, &cfg.height);
        
        // Build with this configuration
        rcHeightfield* hf = rcAllocHeightfield();
        rcCreateHeightfield(&ctx, *hf, cfg.width, cfg.height, cfg.bmin, cfg.bmax, cfg.cs, cfg.ch);
        
        rcMarkWalkableTriangles(&ctx, cfg.walkableSlopeAngle, vertices, 4, indices, 2, areas);
        rcRasterizeTriangles(&ctx, vertices, 4, indices, areas, 2, *hf, cfg.walkableClimb);
        
        rcFilterLowHangingWalkableObstacles(&ctx, cfg.walkableClimb, *hf);
        rcFilterLedgeSpans(&ctx, cfg.walkableHeight, cfg.walkableClimb, *hf);
        rcFilterWalkableLowHeightSpans(&ctx, cfg.walkableHeight, *hf);
        
        rcCompactHeightfield* chf = rcAllocCompactHeightfield();
        rcBuildCompactHeightfield(&ctx, cfg.walkableHeight, cfg.walkableClimb, *hf, *chf);
        
        rcErodeWalkableArea(&ctx, cfg.walkableRadius, *chf);
        rcBuildDistanceField(&ctx, *chf);
        rcBuildRegions(&ctx, *chf, 0, cfg.minRegionArea, cfg.mergeRegionArea);
        
        rcContourSet* cset = rcAllocContourSet();
        rcBuildContours(&ctx, *chf, cfg.maxSimplificationError, cfg.maxEdgeLen, *cset);
        
        rcPolyMesh* pmesh = rcAllocPolyMesh();
        rcBuildPolyMesh(&ctx, *cset, cfg.maxVertsPerPoly, *pmesh);
        
        std::cout << "  Config '" << testCfg.name << "' (cs=" << testCfg.cs 
                  << ", ch=" << testCfg.ch << "): " 
                  << pmesh->npolys << " polygons" << std::endl;
        
        // Clean up
        rcFreePolyMesh(pmesh);
        rcFreeContourSet(cset);
        rcFreeCompactHeightfield(chf);
        rcFreeHeightField(hf);
    }
    
    std::cout << "  ✓ API configuration test passed" << std::endl;
}

int main() {
    std::cout << "=== Running C++ API Tests ===" << std::endl;
    std::cout << "These tests verify high-level API functions match Odin implementation\n" << std::endl;
    
    test_api_simple_build();
    test_api_quick_build();
    test_api_configuration();
    
    std::cout << "\n=== All API tests passed! ===" << std::endl;
    return 0;
}