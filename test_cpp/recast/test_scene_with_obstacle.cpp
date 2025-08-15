#include <iostream>
#include <cassert>
#include <cstring>
#include <vector>
#include "../docs/recastnavigation/Recast/Include/Recast.h"
#include "../docs/recastnavigation/Recast/Include/RecastAlloc.h"

// Test scene with obstacle - matches test_scene_with_obstacle in Odin
void test_scene_with_obstacle() {
    std::cout << "Testing complete navmesh generation with walkable field and obstacle..." << std::endl;
    
    rcContext ctx;
    
    // Create configuration for a 20x20 unit field (matching Odin exactly)
    rcConfig config;
    memset(&config, 0, sizeof(config));
    
    config.cs = 0.3f;  // Cell size
    config.ch = 0.2f;  // Cell height
    config.bmin[0] = -10.0f;
    config.bmin[1] = 0.0f;
    config.bmin[2] = -10.0f;
    config.bmax[0] = 10.0f;
    config.bmax[1] = 5.0f;
    config.bmax[2] = 10.0f;
    config.walkableSlopeAngle = 45.0f;
    config.walkableHeight = 10;  // 2 meters
    config.walkableClimb = 4;    // 0.8 meters
    config.walkableRadius = 2;   // 0.6 meters
    config.maxEdgeLen = 12;
    config.maxSimplificationError = 1.3f;
    config.minRegionArea = 64;
    config.mergeRegionArea = 400;
    config.maxVertsPerPoly = 6;
    config.detailSampleDist = 6.0f;
    config.detailSampleMaxError = 1.0f;
    config.borderSize = 4;
    config.tileSize = 0;
    
    // Calculate grid dimensions
    rcCalcGridSize(config.bmin, config.bmax, config.cs, &config.width, &config.height);
    
    // Create input mesh: flat ground with a box obstacle in the middle
    std::vector<float> vertices;
    std::vector<int> triangles;
    
    // Ground plane (large square from -10 to 10 in X and Z)
    float groundY = 0.0f;
    vertices.insert(vertices.end(), {-10.0f, groundY, -10.0f});  // 0
    vertices.insert(vertices.end(), { 10.0f, groundY, -10.0f});  // 1
    vertices.insert(vertices.end(), { 10.0f, groundY,  10.0f});  // 2
    vertices.insert(vertices.end(), {-10.0f, groundY,  10.0f});  // 3
    
    // Ground triangles
    triangles.insert(triangles.end(), {0, 1, 2});
    triangles.insert(triangles.end(), {0, 2, 3});
    
    // Box obstacle in the center (2x2x3 units)
    float boxMinX = -1.0f, boxMaxX = 1.0f;
    float boxMinZ = -1.0f, boxMaxZ = 1.0f;
    float boxMinY = 0.0f, boxMaxY = 3.0f;
    
    int baseIdx = vertices.size() / 3;
    
    // Box vertices (8 vertices)
    vertices.insert(vertices.end(), {boxMinX, boxMinY, boxMinZ});  // 4: bottom-front-left
    vertices.insert(vertices.end(), {boxMaxX, boxMinY, boxMinZ});  // 5: bottom-front-right
    vertices.insert(vertices.end(), {boxMaxX, boxMinY, boxMaxZ});  // 6: bottom-back-right
    vertices.insert(vertices.end(), {boxMinX, boxMinY, boxMaxZ});  // 7: bottom-back-left
    vertices.insert(vertices.end(), {boxMinX, boxMaxY, boxMinZ});  // 8: top-front-left
    vertices.insert(vertices.end(), {boxMaxX, boxMaxY, boxMinZ});  // 9: top-front-right
    vertices.insert(vertices.end(), {boxMaxX, boxMaxY, boxMaxZ});  // 10: top-back-right
    vertices.insert(vertices.end(), {boxMinX, boxMaxY, boxMaxZ});  // 11: top-back-left
    
    // Box faces (12 triangles, 2 per face)
    // Bottom face
    triangles.insert(triangles.end(), {baseIdx+0, baseIdx+2, baseIdx+1});
    triangles.insert(triangles.end(), {baseIdx+0, baseIdx+3, baseIdx+2});
    
    // Top face
    triangles.insert(triangles.end(), {baseIdx+4, baseIdx+5, baseIdx+6});
    triangles.insert(triangles.end(), {baseIdx+4, baseIdx+6, baseIdx+7});
    
    // Front face
    triangles.insert(triangles.end(), {baseIdx+0, baseIdx+1, baseIdx+5});
    triangles.insert(triangles.end(), {baseIdx+0, baseIdx+5, baseIdx+4});
    
    // Back face
    triangles.insert(triangles.end(), {baseIdx+2, baseIdx+3, baseIdx+7});
    triangles.insert(triangles.end(), {baseIdx+2, baseIdx+7, baseIdx+6});
    
    // Left face
    triangles.insert(triangles.end(), {baseIdx+0, baseIdx+4, baseIdx+7});
    triangles.insert(triangles.end(), {baseIdx+0, baseIdx+7, baseIdx+3});
    
    // Right face
    triangles.insert(triangles.end(), {baseIdx+1, baseIdx+2, baseIdx+6});
    triangles.insert(triangles.end(), {baseIdx+1, baseIdx+6, baseIdx+5});
    
    std::cout << "  Created scene mesh: " << vertices.size()/3 << " vertices, " 
              << triangles.size()/3 << " triangles" << std::endl;
    
    // Step 1: Create solid heightfield
    rcHeightfield* solid = rcAllocHeightfield();
    assert(solid && "Failed to allocate heightfield");
    
    bool ok = rcCreateHeightfield(&ctx, *solid, config.width, config.height,
                                  config.bmin, config.bmax, config.cs, config.ch);
    assert(ok && "Failed to create heightfield");
    
    // Step 2: Rasterize triangles
    std::vector<unsigned char> areas(triangles.size()/3);
    
    // Mark all triangles as walkable initially
    for (size_t i = 0; i < areas.size(); ++i) {
        areas[i] = RC_WALKABLE_AREA;
    }
    
    rcMarkWalkableTriangles(&ctx, config.walkableSlopeAngle, 
                           vertices.data(), vertices.size()/3,
                           triangles.data(), triangles.size()/3, areas.data());
    
    rcRasterizeTriangles(&ctx, vertices.data(), vertices.size()/3,
                        triangles.data(), areas.data(), triangles.size()/3,
                        *solid, config.walkableClimb);
    
    // Step 3: Filter walkable surfaces
    rcFilterLowHangingWalkableObstacles(&ctx, config.walkableClimb, *solid);
    rcFilterLedgeSpans(&ctx, config.walkableHeight, config.walkableClimb, *solid);
    rcFilterWalkableLowHeightSpans(&ctx, config.walkableHeight, *solid);
    
    // Step 4: Create compact heightfield
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    assert(chf && "Failed to allocate compact heightfield");
    
    ok = rcBuildCompactHeightfield(&ctx, config.walkableHeight, config.walkableClimb, *solid, *chf);
    assert(ok && "Failed to build compact heightfield");
    
    // Step 5: Erode walkable area
    ok = rcErodeWalkableArea(&ctx, config.walkableRadius, *chf);
    assert(ok && "Failed to erode walkable area");
    
    // Step 6: Build distance field
    ok = rcBuildDistanceField(&ctx, *chf);
    assert(ok && "Failed to build distance field");
    
    // Step 7: Build regions
    ok = rcBuildRegions(&ctx, *chf, config.borderSize,
                       config.minRegionArea, config.mergeRegionArea);
    assert(ok && "Failed to build regions");
    
    // Step 8: Build contours
    rcContourSet* cset = rcAllocContourSet();
    assert(cset && "Failed to allocate contour set");
    
    ok = rcBuildContours(&ctx, *chf, config.maxSimplificationError, config.maxEdgeLen, 
                        *cset, RC_CONTOUR_TESS_WALL_EDGES);
    assert(ok && "Failed to build contours");
    
    // Step 9: Build polygon mesh
    rcPolyMesh* pmesh = rcAllocPolyMesh();
    assert(pmesh && "Failed to allocate poly mesh");
    
    ok = rcBuildPolyMesh(&ctx, *cset, config.maxVertsPerPoly, *pmesh);
    assert(ok && "Failed to build poly mesh");
    
    // Step 10: Build detail mesh
    rcPolyMeshDetail* dmesh = rcAllocPolyMeshDetail();
    assert(dmesh && "Failed to allocate detail mesh");
    
    ok = rcBuildPolyMeshDetail(&ctx, *pmesh, *chf, config.detailSampleDist, 
                              config.detailSampleMaxError, *dmesh);
    assert(ok && "Failed to build detail mesh");
    
    // Verify results
    assert(pmesh->npolys > 0 && "Should generate polygons for walkable area");
    assert(dmesh->nmeshes > 0 && "Should generate detail meshes");
    
    std::cout << "  ✓ Scene with obstacle test passed - Generated navmesh with:" << std::endl;
    std::cout << "    - " << pmesh->npolys << " polygons" << std::endl;
    std::cout << "    - " << pmesh->nverts << " vertices" << std::endl;
    std::cout << "    - " << dmesh->nmeshes << " detail meshes" << std::endl;
    
    // Clean up
    rcFreePolyMeshDetail(dmesh);
    rcFreePolyMesh(pmesh);
    rcFreeContourSet(cset);
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(solid);
}

int main() {
    std::cout << "=== Running C++ Scene With Obstacle Test ===" << std::endl;
    std::cout << "This test verifies complete navmesh generation with obstacles\n" << std::endl;
    
    test_scene_with_obstacle();
    
    std::cout << "\n=== Scene with obstacle test passed! ===" << std::endl;
    return 0;
}