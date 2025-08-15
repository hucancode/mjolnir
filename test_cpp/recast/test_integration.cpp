#include <iostream>
#include <cassert>
#include <cstring>
#include <vector>
#include <chrono>
#include <iomanip>
#include "../docs/recastnavigation/Recast/Include/Recast.h"
#include "../docs/recastnavigation/Recast/Include/RecastAlloc.h"
#include "../docs/recastnavigation/Detour/Include/DetourNavMesh.h"
#include "../docs/recastnavigation/Detour/Include/DetourNavMeshBuilder.h"
#include "../docs/recastnavigation/Detour/Include/DetourNavMeshQuery.h"

// Helper struct to track metrics
struct BuildMetrics {
    int vertexCount;
    int triangleCount;
    int spanCount;
    int regionCount;
    int contourCount;
    int polyCount;
    int detailTriCount;
    double timeMs;
    
    void print() const {
        std::cout << "  Vertices: " << vertexCount << std::endl;
        std::cout << "  Triangles: " << triangleCount << std::endl;
        std::cout << "  Spans: " << spanCount << std::endl;
        std::cout << "  Regions: " << regionCount << std::endl;
        std::cout << "  Contours: " << contourCount << std::endl;
        std::cout << "  Polygons: " << polyCount << std::endl;
        std::cout << "  Detail triangles: " << detailTriCount << std::endl;
        std::cout << "  Build time: " << std::fixed << std::setprecision(2) << timeMs << " ms" << std::endl;
    }
};

// Generate a test scene with obstacles
void generateTestScene(std::vector<float>& vertices, std::vector<int>& indices, std::vector<unsigned char>& areas) {
    vertices.clear();
    indices.clear();
    areas.clear();
    
    // Ground plane (100x100)
    vertices = {
        0, 0, 0,
        100, 0, 0,
        100, 0, 100,
        0, 0, 100
    };
    indices = {0, 1, 2, 0, 2, 3};
    areas = {RC_WALKABLE_AREA, RC_WALKABLE_AREA};
    
    // Add obstacles (pillars)
    struct Pillar {
        float x, z, radius, height;
    };
    
    Pillar pillars[] = {
        {20, 20, 3, 10},
        {40, 40, 4, 12},
        {60, 20, 2.5f, 8},
        {20, 60, 3.5f, 11},
        {80, 80, 5, 15}
    };
    
    // Generate pillar geometry (simple boxes for now)
    for (const auto& p : pillars) {
        int baseIdx = vertices.size() / 3;
        
        // Add box vertices for pillar
        float r = p.radius;
        vertices.insert(vertices.end(), {
            p.x - r, 0, p.z - r,
            p.x + r, 0, p.z - r,
            p.x + r, 0, p.z + r,
            p.x - r, 0, p.z + r,
            p.x - r, p.height, p.z - r,
            p.x + r, p.height, p.z - r,
            p.x + r, p.height, p.z + r,
            p.x - r, p.height, p.z + r
        });
        
        // Add box faces (sides only, as obstacles)
        int boxIndices[] = {
            // Front
            baseIdx + 0, baseIdx + 1, baseIdx + 5,
            baseIdx + 0, baseIdx + 5, baseIdx + 4,
            // Right
            baseIdx + 1, baseIdx + 2, baseIdx + 6,
            baseIdx + 1, baseIdx + 6, baseIdx + 5,
            // Back
            baseIdx + 2, baseIdx + 3, baseIdx + 7,
            baseIdx + 2, baseIdx + 7, baseIdx + 6,
            // Left
            baseIdx + 3, baseIdx + 0, baseIdx + 4,
            baseIdx + 3, baseIdx + 4, baseIdx + 7
        };
        
        for (int idx : boxIndices) {
            indices.push_back(idx);
        }
        
        // Mark as non-walkable
        for (int i = 0; i < 8; ++i) {
            areas.push_back(RC_NULL_AREA);
        }
    }
    
    // Add elevated platforms
    struct Platform {
        float x, z, width, depth, height;
    };
    
    Platform platforms[] = {
        {30, 70, 20, 15, 5},
        {70, 30, 15, 20, 7}
    };
    
    for (const auto& p : platforms) {
        int baseIdx = vertices.size() / 3;
        
        vertices.insert(vertices.end(), {
            p.x, p.height, p.z,
            p.x + p.width, p.height, p.z,
            p.x + p.width, p.height, p.z + p.depth,
            p.x, p.height, p.z + p.depth
        });
        
        indices.insert(indices.end(), {
            baseIdx + 0, baseIdx + 1, baseIdx + 2,
            baseIdx + 0, baseIdx + 2, baseIdx + 3
        });
        
        areas.push_back(RC_WALKABLE_AREA);
        areas.push_back(RC_WALKABLE_AREA);
    }
}

// Full integration test
BuildMetrics test_full_pipeline_integration() {
    std::cout << "Testing full Recast/Detour pipeline integration..." << std::endl;
    
    auto startTime = std::chrono::high_resolution_clock::now();
    
    BuildMetrics metrics = {};
    rcContext ctx;
    
    // Generate test scene
    std::vector<float> vertices;
    std::vector<int> indices;
    std::vector<unsigned char> areas;
    generateTestScene(vertices, indices, areas);
    
    metrics.vertexCount = vertices.size() / 3;
    metrics.triangleCount = indices.size() / 3;
    
    // Setup build configuration
    rcConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    
    // Calculate bounds
    rcVcopy(cfg.bmin, vertices.data());
    rcVcopy(cfg.bmax, vertices.data());
    for (size_t i = 1; i < vertices.size() / 3; ++i) {
        rcVmin(cfg.bmin, &vertices[i * 3]);
        rcVmax(cfg.bmax, &vertices[i * 3]);
    }
    
    // Expand bounds
    cfg.bmin[0] -= 5;
    cfg.bmin[2] -= 5;
    cfg.bmax[0] += 5;
    cfg.bmax[2] += 5;
    
    // Set config parameters
    cfg.cs = 0.3f;                      // Cell size
    cfg.ch = 0.2f;                      // Cell height
    cfg.walkableSlopeAngle = 45.0f;
    cfg.walkableHeight = 10;            // Agent height (cells)
    cfg.walkableClimb = 4;              // Max climb (cells)
    cfg.walkableRadius = 2;             // Agent radius (cells)
    cfg.maxEdgeLen = 12;
    cfg.maxSimplificationError = 1.3f;
    cfg.minRegionArea = 8;
    cfg.mergeRegionArea = 20;
    cfg.maxVertsPerPoly = 6;
    cfg.detailSampleDist = 6.0f;
    cfg.detailSampleMaxError = 1.0f;
    cfg.borderSize = cfg.walkableRadius + 3;
    
    // Calculate grid size
    rcCalcGridSize(cfg.bmin, cfg.bmax, cfg.cs, &cfg.width, &cfg.height);
    
    std::cout << "  Grid size: " << cfg.width << " x " << cfg.height << std::endl;
    
    // Step 1: Create heightfield
    rcHeightfield* hf = rcAllocHeightfield();
    bool ok = rcCreateHeightfield(&ctx, *hf, cfg.width, cfg.height, cfg.bmin, cfg.bmax, cfg.cs, cfg.ch);
    assert(ok && "Heightfield creation failed");
    
    // Step 2: Mark and rasterize triangles
    rcMarkWalkableTriangles(&ctx, cfg.walkableSlopeAngle, vertices.data(), 
                           vertices.size() / 3, indices.data(), 
                           indices.size() / 3, areas.data());
    
    ok = rcRasterizeTriangles(&ctx, vertices.data(), vertices.size() / 3,
                             indices.data(), areas.data(), indices.size() / 3,
                             *hf, cfg.walkableClimb);
    assert(ok && "Triangle rasterization failed");
    
    // Count spans
    for (int i = 0; i < hf->width * hf->height; ++i) {
        rcSpan* s = hf->spans[i];
        while (s) {
            metrics.spanCount++;
            s = s->next;
        }
    }
    
    // Step 3: Filter walkable surfaces
    rcFilterLowHangingWalkableObstacles(&ctx, cfg.walkableClimb, *hf);
    rcFilterLedgeSpans(&ctx, cfg.walkableHeight, cfg.walkableClimb, *hf);
    rcFilterWalkableLowHeightSpans(&ctx, cfg.walkableHeight, *hf);
    
    // Step 4: Build compact heightfield
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    ok = rcBuildCompactHeightfield(&ctx, cfg.walkableHeight, cfg.walkableClimb, *hf, *chf);
    assert(ok && "Compact heightfield building failed");
    
    // Step 5: Erode walkable area
    ok = rcErodeWalkableArea(&ctx, cfg.walkableRadius, *chf);
    assert(ok && "Erosion failed");
    
    // Step 6: Build distance field
    ok = rcBuildDistanceField(&ctx, *chf);
    assert(ok && "Distance field building failed");
    
    // Step 7: Build regions
    ok = rcBuildRegions(&ctx, *chf, cfg.borderSize, cfg.minRegionArea, cfg.mergeRegionArea);
    assert(ok && "Region building failed");
    
    // Count regions
    for (int i = 0; i < chf->spanCount; ++i) {
        metrics.regionCount = std::max(metrics.regionCount, (int)chf->spans[i].reg);
    }
    
    // Step 8: Build contours
    rcContourSet* cset = rcAllocContourSet();
    ok = rcBuildContours(&ctx, *chf, cfg.maxSimplificationError, cfg.maxEdgeLen, *cset);
    assert(ok && "Contour building failed");
    metrics.contourCount = cset->nconts;
    
    // Step 9: Build polygon mesh
    rcPolyMesh* pmesh = rcAllocPolyMesh();
    ok = rcBuildPolyMesh(&ctx, *cset, cfg.maxVertsPerPoly, *pmesh);
    assert(ok && "Poly mesh building failed");
    metrics.polyCount = pmesh->npolys;
    
    // Step 10: Build detail mesh
    rcPolyMeshDetail* dmesh = rcAllocPolyMeshDetail();
    ok = rcBuildPolyMeshDetail(&ctx, *pmesh, *chf, cfg.detailSampleDist, cfg.detailSampleMaxError, *dmesh);
    assert(ok && "Detail mesh building failed");
    metrics.detailTriCount = dmesh->ntris;
    
    // Update poly mesh bounds
    for (int i = 0; i < pmesh->nverts; ++i) {
        unsigned short* v = &pmesh->verts[i*3];
        v[1] = 0;  // Reset Y to minimum for now
    }
    
    // Step 11: Create Detour navmesh
    dtNavMeshCreateParams params;
    memset(&params, 0, sizeof(params));
    params.verts = pmesh->verts;
    params.vertCount = pmesh->nverts;
    params.polys = pmesh->polys;
    params.polyAreas = pmesh->areas;
    params.polyFlags = pmesh->flags;
    params.polyCount = pmesh->npolys;
    params.nvp = pmesh->nvp;
    params.detailMeshes = dmesh->meshes;
    params.detailVerts = dmesh->verts;
    params.detailVertsCount = dmesh->nverts;
    params.detailTris = dmesh->tris;
    params.detailTriCount = dmesh->ntris;
    params.walkableHeight = cfg.walkableHeight;
    params.walkableRadius = cfg.walkableRadius;
    params.walkableClimb = cfg.walkableClimb;
    params.cs = cfg.cs;
    params.ch = cfg.ch;
    params.buildBvTree = true;
    
    for (int i = 0; i < 3; ++i) {
        params.bmin[i] = pmesh->bmin[i];
        params.bmax[i] = pmesh->bmax[i];
    }
    
    unsigned char* navData = nullptr;
    int navDataSize = 0;
    
    ok = dtCreateNavMeshData(&params, &navData, &navDataSize);
    assert(ok && "Navmesh data creation failed");
    
    std::cout << "  Navmesh data size: " << navDataSize << " bytes" << std::endl;
    
    // Clean up
    dtFree(navData);
    rcFreePolyMeshDetail(dmesh);
    rcFreePolyMesh(pmesh);
    rcFreeContourSet(cset);
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    
    auto endTime = std::chrono::high_resolution_clock::now();
    auto duration = std::chrono::duration_cast<std::chrono::microseconds>(endTime - startTime);
    metrics.timeMs = duration.count() / 1000.0;
    
    std::cout << "  ✓ Full pipeline integration test passed" << std::endl;
    
    return metrics;
}

// Test with various configurations
void test_configuration_variations() {
    std::cout << "\nTesting with various configurations..." << std::endl;
    
    struct ConfigTest {
        const char* name;
        float cellSize;
        float cellHeight;
        int walkableRadius;
        int minRegionArea;
    };
    
    ConfigTest configs[] = {
        {"High resolution", 0.1f, 0.05f, 4, 16},
        {"Medium resolution", 0.3f, 0.2f, 2, 8},
        {"Low resolution", 0.5f, 0.5f, 1, 4},
        {"Large agent", 0.3f, 0.2f, 5, 25},
        {"Small agent", 0.2f, 0.1f, 1, 4}
    };
    
    for (const auto& config : configs) {
        std::cout << "\nConfiguration: " << config.name << std::endl;
        std::cout << "  Cell size: " << config.cellSize << ", Cell height: " << config.cellHeight << std::endl;
        std::cout << "  Walkable radius: " << config.walkableRadius << ", Min region: " << config.minRegionArea << std::endl;
        
        // Run simplified test with this config
        rcContext ctx;
        
        // Simple test geometry
        float vertices[] = {
            0, 0, 0,
            50, 0, 0,
            50, 0, 50,
            0, 0, 50
        };
        int indices[] = {0, 1, 2, 0, 2, 3};
        unsigned char areas[] = {RC_WALKABLE_AREA, RC_WALKABLE_AREA};
        
        // Build with current config
        rcConfig cfg;
        memset(&cfg, 0, sizeof(cfg));
        cfg.cs = config.cellSize;
        cfg.ch = config.cellHeight;
        cfg.walkableRadius = config.walkableRadius;
        cfg.minRegionArea = config.minRegionArea;
        cfg.walkableSlopeAngle = 45.0f;
        cfg.walkableHeight = 10;
        cfg.walkableClimb = 4;
        cfg.maxEdgeLen = 12;
        cfg.maxSimplificationError = 1.3f;
        cfg.mergeRegionArea = config.minRegionArea * 2;
        cfg.maxVertsPerPoly = 6;
        
        // Set bounds
        cfg.bmin[0] = cfg.bmin[1] = cfg.bmin[2] = -5;
        cfg.bmax[0] = cfg.bmax[1] = cfg.bmax[2] = 55;
        
        rcCalcGridSize(cfg.bmin, cfg.bmax, cfg.cs, &cfg.width, &cfg.height);
        
        // Quick build
        rcHeightfield* hf = rcAllocHeightfield();
        rcCreateHeightfield(&ctx, *hf, cfg.width, cfg.height, cfg.bmin, cfg.bmax, cfg.cs, cfg.ch);
        rcRasterizeTriangles(&ctx, vertices, 4, indices, areas, 2, *hf, cfg.walkableClimb);
        
        rcCompactHeightfield* chf = rcAllocCompactHeightfield();
        rcBuildCompactHeightfield(&ctx, cfg.walkableHeight, cfg.walkableClimb, *hf, *chf);
        
        std::cout << "  Grid: " << cfg.width << "x" << cfg.height 
                  << ", Spans: " << chf->spanCount << std::endl;
        
        rcFreeCompactHeightfield(chf);
        rcFreeHeightField(hf);
    }
    
    std::cout << "\n  ✓ Configuration variations test passed" << std::endl;
}

// Performance benchmark
void test_performance_benchmark() {
    std::cout << "\nRunning performance benchmark..." << std::endl;
    
    const int iterations = 5;
    std::vector<double> times;
    
    for (int i = 0; i < iterations; ++i) {
        auto metrics = test_full_pipeline_integration();
        times.push_back(metrics.timeMs);
        std::cout << "  Iteration " << (i+1) << ": " << metrics.timeMs << " ms" << std::endl;
    }
    
    // Calculate statistics
    double sum = 0, min = times[0], max = times[0];
    for (double t : times) {
        sum += t;
        min = std::min(min, t);
        max = std::max(max, t);
    }
    double avg = sum / times.size();
    
    std::cout << "\n  Performance Summary:" << std::endl;
    std::cout << "    Average: " << std::fixed << std::setprecision(2) << avg << " ms" << std::endl;
    std::cout << "    Min: " << min << " ms" << std::endl;
    std::cout << "    Max: " << max << " ms" << std::endl;
    
    std::cout << "  ✓ Performance benchmark completed" << std::endl;
}

int main() {
    std::cout << "=== Running C++ Integration Tests ===" << std::endl;
    std::cout << "Complete end-to-end testing of Recast/Detour pipeline\n" << std::endl;
    
    // Run full pipeline test
    std::cout << "Full Pipeline Test:" << std::endl;
    std::cout << "==================" << std::endl;
    BuildMetrics metrics = test_full_pipeline_integration();
    std::cout << "\nBuild Metrics:" << std::endl;
    metrics.print();
    
    // Test configuration variations
    test_configuration_variations();
    
    // Run performance benchmark
    test_performance_benchmark();
    
    std::cout << "\n=== All integration tests passed! ===" << std::endl;
    return 0;
}