#include <iostream>
#include <cassert>
#include <cstring>
#include <vector>
#include <cmath>
#include "../docs/recastnavigation/Recast/Include/Recast.h"
#include "../docs/recastnavigation/Recast/Include/RecastAlloc.h"

// Test heightfield allocation
void test_heightfield_allocation() {
    std::cout << "Testing heightfield allocation..." << std::endl;
    
    rcContext ctx;
    rcHeightfield* hf = rcAllocHeightfield();
    assert(hf != nullptr && "Heightfield allocation should succeed");
    
    // Test initial state
    assert(hf->width == 0);
    assert(hf->height == 0);
    assert(hf->spans == nullptr && "Spans should be null initially");
    assert(hf->pools == nullptr && "Pools should be null initially");
    assert(hf->freelist == nullptr && "Freelist should be null initially");
    
    rcFreeHeightField(hf);
    std::cout << "  ✓ Heightfield allocation test passed" << std::endl;
}

// Test heightfield creation
void test_heightfield_creation() {
    std::cout << "Testing heightfield creation..." << std::endl;
    
    rcContext ctx;
    rcHeightfield* hf = rcAllocHeightfield();
    assert(hf != nullptr && "Heightfield allocation should succeed");
    
    // Test creation with specific parameters
    int width = 50;
    int height = 50;
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {100, 20, 100};
    float cs = 2.0f;
    float ch = 0.5f;
    
    bool ok = rcCreateHeightfield(&ctx, *hf, width, height, bmin, bmax, cs, ch);
    assert(ok && "Heightfield creation should succeed");
    
    // Verify parameters
    assert(hf->width == width);
    assert(hf->height == height);
    assert(hf->cs == cs);
    assert(hf->ch == ch);
    assert(hf->bmin[0] == bmin[0]);
    assert(hf->bmin[1] == bmin[1]);
    assert(hf->bmin[2] == bmin[2]);
    assert(hf->bmax[0] == bmax[0]);
    assert(hf->bmax[1] == bmax[1]);
    assert(hf->bmax[2] == bmax[2]);
    
    // Verify spans array
    assert(hf->spans != nullptr && "Spans array should be allocated");
    
    // All spans should be null initially
    for (int i = 0; i < width * height; ++i) {
        assert(hf->spans[i] == nullptr && "Initial spans should be null");
    }
    
    rcFreeHeightField(hf);
    std::cout << "  ✓ Heightfield creation test passed" << std::endl;
}

// Test compact heightfield allocation
void test_compact_heightfield_allocation() {
    std::cout << "Testing compact heightfield allocation..." << std::endl;
    
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    assert(chf != nullptr && "Compact heightfield allocation should succeed");
    
    // Test initial state
    assert(chf->width == 0);
    assert(chf->height == 0);
    assert(chf->spanCount == 0);
    assert(chf->cells == nullptr && "Cells should be null initially");
    assert(chf->spans == nullptr && "Spans should be null initially");
    assert(chf->dist == nullptr && "Dist should be null initially");
    assert(chf->areas == nullptr && "Areas should be null initially");
    
    rcFreeCompactHeightfield(chf);
    std::cout << "  ✓ Compact heightfield allocation test passed" << std::endl;
}

// Test heightfield bounds
void test_heightfield_bounds() {
    std::cout << "Testing heightfield bounds..." << std::endl;
    
    rcContext ctx;
    rcHeightfield* hf = rcAllocHeightfield();
    assert(hf != nullptr && "Heightfield allocation should succeed");
    
    struct TestCase {
        float bmin[3];
        float bmax[3];
        float cs;
        int expected_width;
        int expected_height;
    };
    
    TestCase test_cases[] = {
        // Simple case
        {{0, 0, 0}, {10, 5, 10}, 1.0f, 10, 10},
        // Non-zero origin
        {{10, 0, 10}, {20, 5, 20}, 1.0f, 10, 10},
        // Fractional cell size
        {{0, 0, 0}, {10, 5, 10}, 0.5f, 20, 20},
        // Large area
        {{0, 0, 0}, {100, 10, 100}, 2.0f, 50, 50},
    };
    
    for (const auto& tc : test_cases) {
        int width = (int)((tc.bmax[0] - tc.bmin[0]) / tc.cs);
        int height = (int)((tc.bmax[2] - tc.bmin[2]) / tc.cs);
        
        bool ok = rcCreateHeightfield(&ctx, *hf, width, height, tc.bmin, tc.bmax, tc.cs, 0.5f);
        assert(ok && "Heightfield creation should succeed");
        
        assert(hf->width == tc.expected_width);
        assert(hf->height == tc.expected_height);
        
        // Clean up for next test - recreate the heightfield
        rcFreeHeightField(hf);
        hf = rcAllocHeightfield();
    }
    
    rcFreeHeightField(hf);
    std::cout << "  ✓ Heightfield bounds test passed" << std::endl;
}

// Test heightfield edge cases
void test_heightfield_edge_cases() {
    std::cout << "Testing heightfield edge cases..." << std::endl;
    
    rcContext ctx;
    rcHeightfield* hf = rcAllocHeightfield();
    assert(hf != nullptr && "Heightfield allocation should succeed");
    
    // Test minimum size (1x1)
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {1, 1, 1};
    bool ok = rcCreateHeightfield(&ctx, *hf, 1, 1, bmin, bmax, 1.0f, 1.0f);
    assert(ok && "1x1 heightfield should succeed");
    
    // Clean up
    rcFreeHeightField(hf);
    hf = rcAllocHeightfield();
    
    // Test zero width/height (should fail or handle gracefully)
    ok = rcCreateHeightfield(&ctx, *hf, 0, 0, bmin, bmax, 1.0f, 1.0f);
    // In C++ version, this might return false or create an empty heightfield
    // We just check it doesn't crash
    
    rcFreeHeightField(hf);
    std::cout << "  ✓ Heightfield edge cases test passed" << std::endl;
}

// Test rasterization of a simple triangle
void test_rasterize_triangle() {
    std::cout << "Testing triangle rasterization..." << std::endl;
    
    rcContext ctx;
    rcHeightfield* hf = rcAllocHeightfield();
    
    // Create a simple flat triangle at y=2
    float vertices[] = {
        0, 2, 0,   // v0
        4, 2, 0,   // v1
        2, 2, 4    // v2
    };
    int indices[] = {0, 1, 2};
    unsigned char areas[] = {RC_WALKABLE_AREA};
    
    // Create heightfield
    float bmin[3] = {-1, 0, -1};
    float bmax[3] = {5, 5, 5};
    float cs = 0.5f;
    float ch = 0.5f;
    int width = (int)((bmax[0] - bmin[0]) / cs);
    int height = (int)((bmax[2] - bmin[2]) / cs);
    
    bool ok = rcCreateHeightfield(&ctx, *hf, width, height, bmin, bmax, cs, ch);
    assert(ok && "Heightfield creation should succeed");
    
    // Mark walkable triangles (45 degree slope threshold)
    float walkableSlopeAngle = 45.0f;
    rcMarkWalkableTriangles(&ctx, walkableSlopeAngle, vertices, 3, indices, 1, areas);
    
    // Rasterize
    float walkableClimb = 0.5f;
    rcRasterizeTriangles(&ctx, vertices, 3, indices, areas, 1, *hf, 1);
    
    // Count non-empty cells
    int nonEmptyCells = 0;
    for (int y = 0; y < hf->height; ++y) {
        for (int x = 0; x < hf->width; ++x) {
            if (hf->spans[x + y * hf->width] != nullptr) {
                nonEmptyCells++;
            }
        }
    }
    
    std::cout << "  Non-empty cells after rasterization: " << nonEmptyCells << std::endl;
    assert(nonEmptyCells > 0 && "Should have rasterized some cells");
    
    rcFreeHeightField(hf);
    std::cout << "  ✓ Triangle rasterization test passed" << std::endl;
}

// Test building compact heightfield
void test_build_compact_heightfield() {
    std::cout << "Testing compact heightfield building..." << std::endl;
    
    rcContext ctx;
    
    // First create and rasterize a regular heightfield
    rcHeightfield* hf = rcAllocHeightfield();
    
    float vertices[] = {
        0, 0, 0,
        10, 0, 0,
        10, 0, 10,
        0, 0, 10
    };
    int indices[] = {0, 1, 2, 0, 2, 3};
    unsigned char areas[] = {RC_WALKABLE_AREA, RC_WALKABLE_AREA};
    
    float bmin[3] = {-1, -1, -1};
    float bmax[3] = {11, 5, 11};
    float cs = 0.5f;
    float ch = 0.5f;
    int width = (int)((bmax[0] - bmin[0]) / cs);
    int height = (int)((bmax[2] - bmin[2]) / cs);
    
    rcCreateHeightfield(&ctx, *hf, width, height, bmin, bmax, cs, ch);
    
    float walkableSlopeAngle = 45.0f;
    rcMarkWalkableTriangles(&ctx, walkableSlopeAngle, vertices, 4, indices, 2, areas);
    rcRasterizeTriangles(&ctx, vertices, 4, indices, areas, 2, *hf, 1);
    
    // Filter walkable surfaces
    int walkableHeight = 2;
    int walkableClimb = 1;
    rcFilterLowHangingWalkableObstacles(&ctx, walkableClimb, *hf);
    rcFilterLedgeSpans(&ctx, walkableHeight, walkableClimb, *hf);
    rcFilterWalkableLowHeightSpans(&ctx, walkableHeight, *hf);
    
    // Build compact heightfield
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    bool ok = rcBuildCompactHeightfield(&ctx, walkableHeight, walkableClimb, *hf, *chf);
    assert(ok && "Building compact heightfield should succeed");
    
    assert(chf->width > 0);
    assert(chf->height > 0);
    assert(chf->spanCount > 0);
    std::cout << "  Compact heightfield: " << chf->width << "x" << chf->height 
              << " with " << chf->spanCount << " spans" << std::endl;
    
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    std::cout << "  ✓ Compact heightfield building test passed" << std::endl;
}

// Test distance field building
void test_build_distance_field() {
    std::cout << "Testing distance field building..." << std::endl;
    
    rcContext ctx;
    
    // Create a simple compact heightfield first
    rcHeightfield* hf = rcAllocHeightfield();
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    
    float vertices[] = {
        0, 0, 0,
        10, 0, 0,
        10, 0, 10,
        0, 0, 10
    };
    int indices[] = {0, 1, 2, 0, 2, 3};
    unsigned char areas[] = {RC_WALKABLE_AREA, RC_WALKABLE_AREA};
    
    float bmin[3] = {-1, -1, -1};
    float bmax[3] = {11, 5, 11};
    float cs = 0.5f;
    float ch = 0.5f;
    int width = (int)((bmax[0] - bmin[0]) / cs);
    int height = (int)((bmax[2] - bmin[2]) / cs);
    
    rcCreateHeightfield(&ctx, *hf, width, height, bmin, bmax, cs, ch);
    rcMarkWalkableTriangles(&ctx, 45.0f, vertices, 4, indices, 2, areas);
    rcRasterizeTriangles(&ctx, vertices, 4, indices, areas, 2, *hf, 1);
    
    int walkableHeight = 2;
    int walkableClimb = 1;
    rcFilterLowHangingWalkableObstacles(&ctx, walkableClimb, *hf);
    rcFilterLedgeSpans(&ctx, walkableHeight, walkableClimb, *hf);
    rcFilterWalkableLowHeightSpans(&ctx, walkableHeight, *hf);
    
    rcBuildCompactHeightfield(&ctx, walkableHeight, walkableClimb, *hf, *chf);
    
    // Erode walkable area
    int walkableRadius = 2;
    bool ok = rcErodeWalkableArea(&ctx, walkableRadius, *chf);
    assert(ok && "Erosion should succeed");
    
    // Build distance field
    ok = rcBuildDistanceField(&ctx, *chf);
    assert(ok && "Distance field building should succeed");
    
    // Check that distance values were set
    bool hasDistances = false;
    for (int i = 0; i < chf->spanCount; ++i) {
        if (chf->dist && chf->dist[i] > 0) {
            hasDistances = true;
            break;
        }
    }
    assert(hasDistances && "Should have computed some distances");
    
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    std::cout << "  ✓ Distance field building test passed" << std::endl;
}

// Test region building
void test_build_regions() {
    std::cout << "Testing region building..." << std::endl;
    
    rcContext ctx;
    
    // Setup
    rcHeightfield* hf = rcAllocHeightfield();
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    
    float vertices[] = {
        0, 0, 0,
        20, 0, 0,
        20, 0, 20,
        0, 0, 20
    };
    int indices[] = {0, 1, 2, 0, 2, 3};
    unsigned char areas[] = {RC_WALKABLE_AREA, RC_WALKABLE_AREA};
    
    float bmin[3] = {-1, -1, -1};
    float bmax[3] = {21, 5, 21};
    float cs = 0.5f;
    float ch = 0.5f;
    int width = (int)((bmax[0] - bmin[0]) / cs);
    int height = (int)((bmax[2] - bmin[2]) / cs);
    
    rcCreateHeightfield(&ctx, *hf, width, height, bmin, bmax, cs, ch);
    rcMarkWalkableTriangles(&ctx, 45.0f, vertices, 4, indices, 2, areas);
    rcRasterizeTriangles(&ctx, vertices, 4, indices, areas, 2, *hf, 1);
    
    int walkableHeight = 2;
    int walkableClimb = 1;
    rcFilterLowHangingWalkableObstacles(&ctx, walkableClimb, *hf);
    rcFilterLedgeSpans(&ctx, walkableHeight, walkableClimb, *hf);
    rcFilterWalkableLowHeightSpans(&ctx, walkableHeight, *hf);
    
    rcBuildCompactHeightfield(&ctx, walkableHeight, walkableClimb, *hf, *chf);
    rcErodeWalkableArea(&ctx, 2, *chf);
    rcBuildDistanceField(&ctx, *chf);
    
    // Build regions
    int borderSize = 0;
    int minRegionArea = 8;
    int mergeRegionArea = 20;
    bool ok = rcBuildRegions(&ctx, *chf, borderSize, minRegionArea, mergeRegionArea);
    assert(ok && "Region building should succeed");
    
    // Check for regions
    int maxRegion = 0;
    for (int i = 0; i < chf->spanCount; ++i) {
        if (chf->spans[i].reg > maxRegion) {
            maxRegion = chf->spans[i].reg;
        }
    }
    std::cout << "  Built " << maxRegion << " regions" << std::endl;
    assert(maxRegion > 0 && "Should have created at least one region");
    
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    std::cout << "  ✓ Region building test passed" << std::endl;
}

// Test contour building
void test_build_contours() {
    std::cout << "Testing contour building..." << std::endl;
    
    rcContext ctx;
    
    // Setup heightfield and compact heightfield with regions
    rcHeightfield* hf = rcAllocHeightfield();
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    
    float vertices[] = {
        0, 0, 0,
        20, 0, 0,
        20, 0, 20,
        0, 0, 20
    };
    int indices[] = {0, 1, 2, 0, 2, 3};
    unsigned char areas[] = {RC_WALKABLE_AREA, RC_WALKABLE_AREA};
    
    float bmin[3] = {-1, -1, -1};
    float bmax[3] = {21, 5, 21};
    float cs = 0.5f;
    float ch = 0.5f;
    int width = (int)((bmax[0] - bmin[0]) / cs);
    int height = (int)((bmax[2] - bmin[2]) / cs);
    
    rcCreateHeightfield(&ctx, *hf, width, height, bmin, bmax, cs, ch);
    rcMarkWalkableTriangles(&ctx, 45.0f, vertices, 4, indices, 2, areas);
    rcRasterizeTriangles(&ctx, vertices, 4, indices, areas, 2, *hf, 1);
    
    int walkableHeight = 2;
    int walkableClimb = 1;
    rcFilterLowHangingWalkableObstacles(&ctx, walkableClimb, *hf);
    rcFilterLedgeSpans(&ctx, walkableHeight, walkableClimb, *hf);
    rcFilterWalkableLowHeightSpans(&ctx, walkableHeight, *hf);
    
    rcBuildCompactHeightfield(&ctx, walkableHeight, walkableClimb, *hf, *chf);
    rcErodeWalkableArea(&ctx, 2, *chf);
    rcBuildDistanceField(&ctx, *chf);
    rcBuildRegions(&ctx, *chf, 0, 8, 20);
    
    // Build contours
    rcContourSet* cset = rcAllocContourSet();
    float maxError = 1.3f;
    int maxEdgeLen = 12;
    int buildFlags = RC_CONTOUR_TESS_WALL_EDGES;
    
    bool ok = rcBuildContours(&ctx, *chf, maxError, maxEdgeLen, *cset, buildFlags);
    assert(ok && "Contour building should succeed");
    assert(cset->nconts > 0 && "Should have created at least one contour");
    
    std::cout << "  Built " << cset->nconts << " contours" << std::endl;
    
    rcFreeContourSet(cset);
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    std::cout << "  ✓ Contour building test passed" << std::endl;
}

// Test poly mesh building
void test_build_poly_mesh() {
    std::cout << "Testing poly mesh building..." << std::endl;
    
    rcContext ctx;
    
    // Complete pipeline setup
    rcHeightfield* hf = rcAllocHeightfield();
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    rcContourSet* cset = rcAllocContourSet();
    rcPolyMesh* pmesh = rcAllocPolyMesh();
    
    float vertices[] = {
        0, 0, 0,
        20, 0, 0,
        20, 0, 20,
        0, 0, 20
    };
    int indices[] = {0, 1, 2, 0, 2, 3};
    unsigned char areas[] = {RC_WALKABLE_AREA, RC_WALKABLE_AREA};
    
    float bmin[3] = {-1, -1, -1};
    float bmax[3] = {21, 5, 21};
    float cs = 0.5f;
    float ch = 0.5f;
    int width = (int)((bmax[0] - bmin[0]) / cs);
    int height = (int)((bmax[2] - bmin[2]) / cs);
    
    rcCreateHeightfield(&ctx, *hf, width, height, bmin, bmax, cs, ch);
    rcMarkWalkableTriangles(&ctx, 45.0f, vertices, 4, indices, 2, areas);
    rcRasterizeTriangles(&ctx, vertices, 4, indices, areas, 2, *hf, 1);
    
    int walkableHeight = 2;
    int walkableClimb = 1;
    rcFilterLowHangingWalkableObstacles(&ctx, walkableClimb, *hf);
    rcFilterLedgeSpans(&ctx, walkableHeight, walkableClimb, *hf);
    rcFilterWalkableLowHeightSpans(&ctx, walkableHeight, *hf);
    
    rcBuildCompactHeightfield(&ctx, walkableHeight, walkableClimb, *hf, *chf);
    rcErodeWalkableArea(&ctx, 2, *chf);
    rcBuildDistanceField(&ctx, *chf);
    rcBuildRegions(&ctx, *chf, 0, 8, 20);
    rcBuildContours(&ctx, *chf, 1.3f, 12, *cset, RC_CONTOUR_TESS_WALL_EDGES);
    
    // Build poly mesh
    int nvp = 6; // Max vertices per polygon
    bool ok = rcBuildPolyMesh(&ctx, *cset, nvp, *pmesh);
    assert(ok && "Poly mesh building should succeed");
    assert(pmesh->nverts > 0 && "Should have vertices");
    assert(pmesh->npolys > 0 && "Should have polygons");
    
    std::cout << "  Built poly mesh with " << pmesh->nverts << " vertices and " 
              << pmesh->npolys << " polygons" << std::endl;
    
    rcFreePolyMesh(pmesh);
    rcFreeContourSet(cset);
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    std::cout << "  ✓ Poly mesh building test passed" << std::endl;
}

// Test complete navmesh generation pipeline
void test_complete_pipeline() {
    std::cout << "Testing complete navmesh generation pipeline..." << std::endl;
    
    rcContext ctx;
    
    // Create a more complex mesh - a room with a pillar
    std::vector<float> vertices = {
        // Floor
        0, 0, 0,
        30, 0, 0,
        30, 0, 30,
        0, 0, 30,
        // Pillar (raised platform)
        10, 0, 10,
        15, 0, 10,
        15, 0, 15,
        10, 0, 15,
        10, 2, 10,
        15, 2, 10,
        15, 2, 15,
        10, 2, 15
    };
    
    std::vector<int> indices = {
        // Floor
        0, 1, 2,
        0, 2, 3,
        // Pillar sides
        4, 5, 9,
        4, 9, 8,
        5, 6, 10,
        5, 10, 9,
        6, 7, 11,
        6, 11, 10,
        7, 4, 8,
        7, 8, 11,
        // Pillar top
        8, 9, 10,
        8, 10, 11
    };
    
    std::vector<unsigned char> areas(indices.size() / 3, RC_WALKABLE_AREA);
    
    // Build configuration
    rcConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.cs = 0.3f;                    // Cell size
    cfg.ch = 0.2f;                    // Cell height
    cfg.walkableSlopeAngle = 45.0f;  // Max slope
    cfg.walkableHeight = 10;         // Agent height in cells
    cfg.walkableClimb = 4;           // Max climb in cells
    cfg.walkableRadius = 2;          // Agent radius in cells
    cfg.maxEdgeLen = 12;             // Max edge length
    cfg.maxSimplificationError = 1.3f;
    cfg.minRegionArea = 8;
    cfg.mergeRegionArea = 20;
    cfg.maxVertsPerPoly = 6;
    cfg.detailSampleDist = 6.0f;
    cfg.detailSampleMaxError = 1.0f;
    
    // Calculate grid bounds
    rcVcopy(cfg.bmin, vertices.data());
    rcVcopy(cfg.bmax, vertices.data());
    for (size_t i = 1; i < vertices.size() / 3; ++i) {
        rcVmin(cfg.bmin, &vertices[i * 3]);
        rcVmax(cfg.bmax, &vertices[i * 3]);
    }
    cfg.bmin[0] -= cfg.borderSize * cfg.cs;
    cfg.bmin[2] -= cfg.borderSize * cfg.cs;
    cfg.bmax[0] += cfg.borderSize * cfg.cs;
    cfg.bmax[2] += cfg.borderSize * cfg.cs;
    
    rcCalcGridSize(cfg.bmin, cfg.bmax, cfg.cs, &cfg.width, &cfg.height);
    
    // Allocate structures
    rcHeightfield* hf = rcAllocHeightfield();
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    rcContourSet* cset = rcAllocContourSet();
    rcPolyMesh* pmesh = rcAllocPolyMesh();
    rcPolyMeshDetail* dmesh = rcAllocPolyMeshDetail();
    
    // Build pipeline
    bool ok = true;
    ok = ok && rcCreateHeightfield(&ctx, *hf, cfg.width, cfg.height, cfg.bmin, cfg.bmax, cfg.cs, cfg.ch);
    
    // Mark and rasterize triangles
    rcMarkWalkableTriangles(&ctx, cfg.walkableSlopeAngle, vertices.data(), vertices.size() / 3,
                           indices.data(), indices.size() / 3, areas.data());
    ok = ok && rcRasterizeTriangles(&ctx, vertices.data(), vertices.size() / 3,
                                    indices.data(), areas.data(), indices.size() / 3,
                                    *hf, cfg.walkableClimb);
    
    // Filter
    rcFilterLowHangingWalkableObstacles(&ctx, cfg.walkableClimb, *hf);
    rcFilterLedgeSpans(&ctx, cfg.walkableHeight, cfg.walkableClimb, *hf);
    rcFilterWalkableLowHeightSpans(&ctx, cfg.walkableHeight, *hf);
    
    // Compact
    ok = ok && rcBuildCompactHeightfield(&ctx, cfg.walkableHeight, cfg.walkableClimb, *hf, *chf);
    
    // Erode
    ok = ok && rcErodeWalkableArea(&ctx, cfg.walkableRadius, *chf);
    
    // Build distance field and regions
    ok = ok && rcBuildDistanceField(&ctx, *chf);
    ok = ok && rcBuildRegions(&ctx, *chf, cfg.borderSize, cfg.minRegionArea, cfg.mergeRegionArea);
    
    // Build contours
    ok = ok && rcBuildContours(&ctx, *chf, cfg.maxSimplificationError, cfg.maxEdgeLen, *cset);
    
    // Build poly mesh
    ok = ok && rcBuildPolyMesh(&ctx, *cset, cfg.maxVertsPerPoly, *pmesh);
    
    // Build detail mesh
    ok = ok && rcBuildPolyMeshDetail(&ctx, *pmesh, *chf, cfg.detailSampleDist, cfg.detailSampleMaxError, *dmesh);
    
    assert(ok && "Complete pipeline should succeed");
    
    std::cout << "  Complete pipeline results:" << std::endl;
    std::cout << "    Heightfield: " << hf->width << "x" << hf->height << std::endl;
    std::cout << "    Compact heightfield spans: " << chf->spanCount << std::endl;
    std::cout << "    Contours: " << cset->nconts << std::endl;
    std::cout << "    Poly mesh: " << pmesh->nverts << " verts, " << pmesh->npolys << " polys" << std::endl;
    std::cout << "    Detail mesh: " << dmesh->nverts << " verts, " << dmesh->ntris << " tris" << std::endl;
    
    // Cleanup
    rcFreePolyMeshDetail(dmesh);
    rcFreePolyMesh(pmesh);
    rcFreeContourSet(cset);
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    
    std::cout << "  ✓ Complete pipeline test passed" << std::endl;
}

int main() {
    std::cout << "=== Running C++ Recast Tests ===" << std::endl;
    std::cout << "These tests mirror the Odin implementation to verify correctness\n" << std::endl;
    
    // Run all tests
    test_heightfield_allocation();
    test_heightfield_creation();
    test_compact_heightfield_allocation();
    test_heightfield_bounds();
    test_heightfield_edge_cases();
    test_rasterize_triangle();
    test_build_compact_heightfield();
    test_build_distance_field();
    test_build_regions();
    test_build_contours();
    test_build_poly_mesh();
    test_complete_pipeline();
    
    std::cout << "\n=== All tests passed! ===" << std::endl;
    return 0;
}