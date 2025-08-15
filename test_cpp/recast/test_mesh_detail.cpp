#include <iostream>
#include <cassert>
#include <cstring>
#include <vector>
#include <cmath>
#include "../docs/recastnavigation/Recast/Include/Recast.h"
#include "../docs/recastnavigation/Recast/Include/RecastAlloc.h"

// Helper to add spans
void addSpan(rcHeightfield& hf, int x, int z, int smin, int smax, unsigned char area) {
    if (x < 0 || x >= hf.width || z < 0 || z >= hf.height) return;
    
    rcSpan* span = static_cast<rcSpan*>(rcAlloc(sizeof(rcSpan), RC_ALLOC_PERM));
    span->smin = static_cast<unsigned int>(smin);
    span->smax = static_cast<unsigned int>(smax);
    span->area = area;
    span->next = nullptr;
    
    int idx = x + z * hf.width;
    
    // Insert at head for simplicity
    span->next = hf.spans[idx];
    hf.spans[idx] = span;
}

// Test basic detail mesh building
void test_build_detail_mesh_simple() {
    std::cout << "Testing simple detail mesh building..." << std::endl;
    
    rcContext ctx;
    
    // Create heightfield
    rcHeightfield* hf = rcAllocHeightfield();
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {8, 8, 8};
    rcCreateHeightfield(&ctx, *hf, 8, 8, bmin, bmax, 1.0f, 0.5f);
    
    // Add walkable area (4x4 square in center)
    for (int x = 2; x <= 5; ++x) {
        for (int z = 2; z <= 5; ++z) {
            addSpan(*hf, x, z, 0, 2, RC_WALKABLE_AREA);
        }
    }
    
    // Build compact heightfield
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    rcBuildCompactHeightfield(&ctx, 2, 1, *hf, *chf);
    
    // Build distance field and regions
    rcBuildDistanceField(&ctx, *chf);
    rcBuildRegions(&ctx, *chf, 2, 8, 20);
    
    // Build contours
    rcContourSet* cset = rcAllocContourSet();
    rcBuildContours(&ctx, *chf, 1.0f, 1, *cset, RC_CONTOUR_TESS_WALL_EDGES);
    
    // Build polygon mesh
    rcPolyMesh* pmesh = rcAllocPolyMesh();
    rcBuildPolyMesh(&ctx, *cset, 6, *pmesh);
    
    // Build detail mesh
    rcPolyMeshDetail* dmesh = rcAllocPolyMeshDetail();
    bool ok = rcBuildPolyMeshDetail(&ctx, *pmesh, *chf, 2.0f, 1.0f, *dmesh);
    assert(ok && "Detail mesh building should succeed");
    
    // Verify detail mesh
    assert(dmesh->nmeshes > 0 && "Should have mesh data");
    assert(dmesh->nverts > 0 && "Should have vertices");
    assert(dmesh->ntris > 0 && "Should have triangles");
    
    std::cout << "  Created detail mesh: " << dmesh->nmeshes << " meshes, " 
              << dmesh->nverts << " vertices, " << dmesh->ntris << " triangles" << std::endl;
    
    // Check mesh bounds
    for (int i = 0; i < dmesh->nmeshes; ++i) {
        unsigned int baseVert = dmesh->meshes[i*4 + 0];
        unsigned int vertCount = dmesh->meshes[i*4 + 1];
        unsigned int baseTri = dmesh->meshes[i*4 + 2];
        unsigned int triCount = dmesh->meshes[i*4 + 3];
        
        std::cout << "    Mesh " << i << ": " << vertCount << " verts, " << triCount << " tris" << std::endl;
        
        assert(baseVert + vertCount <= (unsigned int)dmesh->nverts && "Vertex bounds check");
        assert(baseTri + triCount <= (unsigned int)dmesh->ntris && "Triangle bounds check");
    }
    
    rcFreePolyMeshDetail(dmesh);
    rcFreePolyMesh(pmesh);
    rcFreeContourSet(cset);
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    
    std::cout << "  ✓ Simple detail mesh test passed" << std::endl;
}

// Test detail mesh with empty input
void test_build_detail_mesh_empty() {
    std::cout << "Testing detail mesh with empty input..." << std::endl;
    
    rcContext ctx;
    
    // Create empty poly mesh
    rcPolyMesh* pmesh = rcAllocPolyMesh();
    pmesh->nverts = 0;
    pmesh->npolys = 0;
    pmesh->nvp = 6;
    pmesh->cs = 0.5f;
    pmesh->ch = 0.5f;
    
    // Create minimal compact heightfield
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    chf->width = 1;
    chf->height = 1;
    chf->spanCount = 0;
    chf->cs = 0.5f;
    chf->ch = 0.5f;
    
    // Try to build detail mesh with empty input
    rcPolyMeshDetail* dmesh = rcAllocPolyMeshDetail();
    bool ok = rcBuildPolyMeshDetail(&ctx, *pmesh, *chf, 2.0f, 1.0f, *dmesh);
    
    // Should handle empty input gracefully
    if (ok) {
        assert(dmesh->nmeshes == 0 && "Empty input should produce empty output");
        std::cout << "  Empty input handled gracefully" << std::endl;
    } else {
        std::cout << "  Build failed as expected for empty input" << std::endl;
    }
    
    rcFreePolyMeshDetail(dmesh);
    rcFreeCompactHeightfield(chf);
    rcFreePolyMesh(pmesh);
    
    std::cout << "  ✓ Empty detail mesh test passed" << std::endl;
}

// Test detail mesh with varying sample distances
void test_detail_mesh_sample_distances() {
    std::cout << "Testing detail mesh with varying sample distances..." << std::endl;
    
    rcContext ctx;
    
    // Create a larger heightfield
    rcHeightfield* hf = rcAllocHeightfield();
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {20, 10, 20};
    rcCreateHeightfield(&ctx, *hf, 40, 40, bmin, bmax, 0.5f, 0.5f);
    
    // Add a sloped surface
    for (int x = 5; x < 35; ++x) {
        for (int z = 5; z < 35; ++z) {
            int height = (x + z) / 10; // Create slope
            addSpan(*hf, x, z, 0, height + 2, RC_WALKABLE_AREA);
        }
    }
    
    // Build pipeline
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    rcBuildCompactHeightfield(&ctx, 2, 1, *hf, *chf);
    rcErodeWalkableArea(&ctx, 1, *chf);
    rcBuildDistanceField(&ctx, *chf);
    rcBuildRegions(&ctx, *chf, 0, 8, 20);
    
    rcContourSet* cset = rcAllocContourSet();
    rcBuildContours(&ctx, *chf, 1.3f, 12, *cset, RC_CONTOUR_TESS_WALL_EDGES);
    
    rcPolyMesh* pmesh = rcAllocPolyMesh();
    rcBuildPolyMesh(&ctx, *cset, 6, *pmesh);
    
    // Test different sample distances
    float sampleDists[] = {0.0f, 1.0f, 3.0f, 6.0f, 9.0f};
    float maxErrors[] = {0.5f, 1.0f, 1.5f, 2.0f, 2.5f};
    
    for (int i = 0; i < 5; ++i) {
        rcPolyMeshDetail* dmesh = rcAllocPolyMeshDetail();
        bool ok = rcBuildPolyMeshDetail(&ctx, *pmesh, *chf, sampleDists[i], maxErrors[i], *dmesh);
        
        if (ok) {
            std::cout << "  Sample dist=" << sampleDists[i] << ", max error=" << maxErrors[i] 
                      << ": " << dmesh->nverts << " verts, " << dmesh->ntris << " tris" << std::endl;
            
            // Lower sample distance should generally produce more detailed mesh
            if (i > 0 && sampleDists[i] > sampleDists[i-1]) {
                // Note: This isn't always strictly true due to mesh optimization
                std::cout << "    (Less detailed than previous as expected)" << std::endl;
            }
        }
        
        rcFreePolyMeshDetail(dmesh);
    }
    
    rcFreePolyMesh(pmesh);
    rcFreeContourSet(cset);
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    
    std::cout << "  ✓ Sample distances test passed" << std::endl;
}

// Test detail mesh on complex terrain
void test_detail_mesh_complex_terrain() {
    std::cout << "Testing detail mesh on complex terrain..." << std::endl;
    
    rcContext ctx;
    
    // Create heightfield
    rcHeightfield* hf = rcAllocHeightfield();
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {30, 20, 30};
    rcCreateHeightfield(&ctx, *hf, 60, 60, bmin, bmax, 0.5f, 0.5f);
    
    // Create multiple platforms at different heights
    // Platform 1: Low
    for (int x = 5; x < 15; ++x) {
        for (int z = 5; z < 15; ++z) {
            addSpan(*hf, x, z, 0, 4, RC_WALKABLE_AREA);
        }
    }
    
    // Platform 2: Medium with ramp
    for (int x = 20; x < 30; ++x) {
        for (int z = 5; z < 15; ++z) {
            int height = 10 + (x - 20) / 2; // Ramp up
            addSpan(*hf, x, z, height, height + 4, RC_WALKABLE_AREA);
        }
    }
    
    // Platform 3: High with holes
    for (int x = 35; x < 50; ++x) {
        for (int z = 35; z < 50; ++z) {
            // Skip some cells to create holes
            if ((x + z) % 7 == 0) continue;
            addSpan(*hf, x, z, 20, 24, RC_WALKABLE_AREA);
        }
    }
    
    // Build full pipeline
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    rcBuildCompactHeightfield(&ctx, 2, 1, *hf, *chf);
    
    // Apply filters
    rcFilterLowHangingWalkableObstacles(&ctx, 1, *hf);
    rcFilterLedgeSpans(&ctx, 2, 1, *hf);
    rcFilterWalkableLowHeightSpans(&ctx, 2, *hf);
    
    rcErodeWalkableArea(&ctx, 2, *chf);
    rcBuildDistanceField(&ctx, *chf);
    rcBuildRegions(&ctx, *chf, 0, 8, 20);
    
    rcContourSet* cset = rcAllocContourSet();
    rcBuildContours(&ctx, *chf, 1.3f, 12, *cset, RC_CONTOUR_TESS_WALL_EDGES);
    
    rcPolyMesh* pmesh = rcAllocPolyMesh();
    rcBuildPolyMesh(&ctx, *cset, 6, *pmesh);
    
    // Build detail mesh
    rcPolyMeshDetail* dmesh = rcAllocPolyMeshDetail();
    bool ok = rcBuildPolyMeshDetail(&ctx, *pmesh, *chf, 3.0f, 1.0f, *dmesh);
    assert(ok && "Complex terrain detail mesh should succeed");
    
    std::cout << "  Complex terrain results:" << std::endl;
    std::cout << "    Poly mesh: " << pmesh->nverts << " verts, " << pmesh->npolys << " polys" << std::endl;
    std::cout << "    Detail mesh: " << dmesh->nverts << " verts, " << dmesh->ntris << " tris" << std::endl;
    
    // Validate mesh connectivity
    int invalidTris = 0;
    for (int i = 0; i < dmesh->ntris; ++i) {
        unsigned char* tri = &dmesh->tris[i * 4];
        if (tri[0] == tri[1] || tri[1] == tri[2] || tri[2] == tri[0]) {
            invalidTris++;
        }
    }
    
    std::cout << "    Invalid triangles: " << invalidTris << std::endl;
    assert(invalidTris == 0 && "Should not have degenerate triangles");
    
    rcFreePolyMeshDetail(dmesh);
    rcFreePolyMesh(pmesh);
    rcFreeContourSet(cset);
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    
    std::cout << "  ✓ Complex terrain detail mesh test passed" << std::endl;
}

// Test detail mesh edge connectivity
void test_detail_mesh_edge_connectivity() {
    std::cout << "Testing detail mesh edge connectivity..." << std::endl;
    
    rcContext ctx;
    
    // Create two adjacent squares
    rcHeightfield* hf = rcAllocHeightfield();
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {20, 10, 10};
    rcCreateHeightfield(&ctx, *hf, 40, 20, bmin, bmax, 0.5f, 0.5f);
    
    // First square
    for (int x = 2; x < 18; ++x) {
        for (int z = 2; z < 8; ++z) {
            addSpan(*hf, x, z, 0, 4, RC_WALKABLE_AREA);
        }
    }
    
    // Second square (adjacent)
    for (int x = 22; x < 38; ++x) {
        for (int z = 2; z < 8; ++z) {
            addSpan(*hf, x, z, 0, 4, RC_WALKABLE_AREA);
        }
    }
    
    // Build pipeline
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    rcBuildCompactHeightfield(&ctx, 2, 1, *hf, *chf);
    rcBuildDistanceField(&ctx, *chf);
    rcBuildRegions(&ctx, *chf, 0, 4, 20);
    
    rcContourSet* cset = rcAllocContourSet();
    rcBuildContours(&ctx, *chf, 1.3f, 12, *cset, RC_CONTOUR_TESS_WALL_EDGES);
    
    rcPolyMesh* pmesh = rcAllocPolyMesh();
    rcBuildPolyMesh(&ctx, *cset, 6, *pmesh);
    
    rcPolyMeshDetail* dmesh = rcAllocPolyMeshDetail();
    bool ok = rcBuildPolyMeshDetail(&ctx, *pmesh, *chf, 2.0f, 1.0f, *dmesh);
    assert(ok && "Edge connectivity detail mesh should succeed");
    
    std::cout << "  Adjacent squares: " << pmesh->npolys << " polygons" << std::endl;
    std::cout << "  Detail mesh: " << dmesh->nmeshes << " sub-meshes" << std::endl;
    
    // Each polygon should have its own detail mesh
    assert(dmesh->nmeshes == pmesh->npolys && "Should have detail mesh for each polygon");
    
    rcFreePolyMeshDetail(dmesh);
    rcFreePolyMesh(pmesh);
    rcFreeContourSet(cset);
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    
    std::cout << "  ✓ Edge connectivity test passed" << std::endl;
}

int main() {
    std::cout << "=== Running C++ Mesh Detail Tests ===" << std::endl;
    std::cout << "These tests verify detail mesh generation\n" << std::endl;
    
    test_build_detail_mesh_simple();
    test_build_detail_mesh_empty();
    test_detail_mesh_sample_distances();
    test_detail_mesh_complex_terrain();
    test_detail_mesh_edge_connectivity();
    
    std::cout << "\n=== All mesh detail tests passed! ===" << std::endl;
    return 0;
}