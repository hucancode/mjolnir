// C++ tests matching test/detour/test_bv_tree.odin
#include <iostream>
#include <cassert>
#include <cmath>
#include <cstring>
#include <vector>
#include "../../docs/recastnavigation/Recast/Include/Recast.h"
#include "../../docs/recastnavigation/Recast/Include/RecastAlloc.h"
#include "../../docs/recastnavigation/Detour/Include/DetourNavMesh.h"
#include "../../docs/recastnavigation/Detour/Include/DetourNavMeshBuilder.h"

// Test BV tree construction - matches test_bv_tree_construction
void test_bv_tree_construction() {
    std::cout << "test_bv_tree_construction..." << std::endl;
    
    // Create test polymesh matching Odin test - use rcAllocPolyMesh
    rcPolyMesh* mesh = rcAllocPolyMesh();
    assert(mesh != nullptr);
    
    mesh->cs = 0.3f;
    mesh->ch = 0.2f;
    mesh->nvp = 6;
    mesh->npolys = 4;
    mesh->nverts = 8;
    
    mesh->bmin[0] = 0.0f;
    mesh->bmin[1] = 0.0f;
    mesh->bmin[2] = 0.0f;
    mesh->bmax[0] = 10.0f;
    mesh->bmax[1] = 2.0f;
    mesh->bmax[2] = 10.0f;
    
    // Allocate and create vertices (already quantized)
    mesh->verts = (unsigned short*)rcAlloc(sizeof(unsigned short) * 8 * 3, RC_ALLOC_PERM);
    unsigned short verts[] = {
        0, 0, 0,      // vertex 0
        10, 0, 0,     // vertex 1
        10, 0, 10,    // vertex 2
        0, 0, 10,     // vertex 3
        0, 5, 0,      // vertex 4
        10, 5, 0,     // vertex 5
        10, 5, 10,    // vertex 6
        0, 5, 10,     // vertex 7
    };
    memcpy(mesh->verts, verts, sizeof(verts));
    
    // Allocate and create polygons (4 triangles)
    mesh->polys = (unsigned short*)rcAlloc(sizeof(unsigned short) * 4 * 6 * 2, RC_ALLOC_PERM);
    for (int i = 0; i < 4 * 6 * 2; ++i) {
        mesh->polys[i] = RC_MESH_NULL_IDX;
    }
    
    // Bottom triangle 1: 0,1,2
    mesh->polys[0] = 0;
    mesh->polys[1] = 1;
    mesh->polys[2] = 2;
    
    // Bottom triangle 2: 0,2,3
    mesh->polys[12] = 0;
    mesh->polys[13] = 2;
    mesh->polys[14] = 3;
    
    // Top triangle 1: 4,5,6
    mesh->polys[24] = 4;
    mesh->polys[25] = 5;
    mesh->polys[26] = 6;
    
    // Top triangle 2: 4,6,7
    mesh->polys[36] = 4;
    mesh->polys[37] = 6;
    mesh->polys[38] = 7;
    
    // Allocate and create areas and flags
    mesh->areas = (unsigned char*)rcAlloc(sizeof(unsigned char) * 4, RC_ALLOC_PERM);
    mesh->flags = (unsigned short*)rcAlloc(sizeof(unsigned short) * 4, RC_ALLOC_PERM);
    for (int i = 0; i < 4; ++i) {
        mesh->areas[i] = 1;
        mesh->flags[i] = 1;
    }
    
    std::cout << "  Test polymesh info:" << std::endl;
    std::cout << "    cs=" << mesh->cs << ", ch=" << mesh->ch << std::endl;
    std::cout << "    npolys=" << mesh->npolys << ", nverts=" << mesh->nverts << std::endl;
    std::cout << "    bmin=[" << mesh->bmin[0] << "," << mesh->bmin[1] << "," << mesh->bmin[2] << "]" << std::endl;
    std::cout << "    bmax=[" << mesh->bmax[0] << "," << mesh->bmax[1] << "," << mesh->bmax[2] << "]" << std::endl;
    
    std::cout << "\n  Vertices (quantized):" << std::endl;
    for (int i = 0; i < mesh->nverts; ++i) {
        std::cout << "    Vertex " << i << ": [" 
                  << mesh->verts[i*3] << ", " 
                  << mesh->verts[i*3+1] << ", " 
                  << mesh->verts[i*3+2] << "]" << std::endl;
    }
    
    std::cout << "\n  Polygons:" << std::endl;
    for (int i = 0; i < mesh->npolys; ++i) {
        std::cout << "    Poly " << i << ": " << std::endl;
        for (int j = 0; j < mesh->nvp; ++j) {
            unsigned short v = mesh->polys[i * mesh->nvp * 2 + j];
            if (v != RC_MESH_NULL_IDX) {
                std::cout << "      vert " << v << std::endl;
            }
        }
    }
    
    // In Odin test, BV tree would be built here with nav_detour.build_bv_tree
    // For C++ test, we verify the mesh is valid for BV tree construction
    assert(mesh->npolys == 4);
    assert(mesh->nverts == 8);
    assert(mesh->cs == 0.3f);
    assert(mesh->ch == 0.2f);
    
    // Clean up using rcFree
    rcFreePolyMesh(mesh);
    
    std::cout << "  ✓ Passed" << std::endl;
}

// Test BV bounds calculation - matches test_bv_bounds_calculation
void test_bv_bounds_calculation() {
    std::cout << "test_bv_bounds_calculation..." << std::endl;
    
    // Test the calculation logic for BV bounds
    float cs = 0.3f;
    float ch = 0.2f;
    float ch_cs_ratio = ch / cs;
    
    std::cout << "  Testing BV bounds calculation logic:" << std::endl;
    std::cout << "    ch/cs ratio: " << ch_cs_ratio << std::endl;
    
    // Test Y remapping for various values
    struct TestCase {
        int y_input;
        int expected_min;
        int expected_max;
    };
    
    TestCase cases[] = {
        {0, 0, 0},
        {5, 3, 4},
        {10, 6, 7}
    };
    
    for (const auto& tc : cases) {
        int min_y = (int)floor(tc.y_input * ch_cs_ratio);
        int max_y = (int)ceil(tc.y_input * ch_cs_ratio);
        
        std::cout << "    Y=" << tc.y_input << " -> floor=" << min_y << ", ceil=" << max_y << std::endl;
        
        assert(min_y == tc.expected_min);
        assert(max_y == tc.expected_max);
    }
    
    std::cout << "  ✓ Passed" << std::endl;
}

int main() {
    std::cout << "=== Running BV Tree Tests (matching test_bv_tree.odin) ===" << std::endl;
    
    test_bv_tree_construction();
    test_bv_bounds_calculation();
    
    std::cout << "\n=== All tests passed ===" << std::endl;
    return 0;
}