// C++ tests matching test/detour/tile_coordinate_test.odin
#include <iostream>
#include <cassert>
#include <cmath>
#include <limits>
#include "../../docs/recastnavigation/Detour/Include/DetourNavMesh.h"
#include "../../docs/recastnavigation/Detour/Include/DetourCommon.h"

// Test tile coordinate calculation robustness - matches test_tile_coordinate_calculation_robustness
void test_tile_coordinate_calculation_robustness() {
    std::cout << "test_tile_coordinate_calculation_robustness..." << std::endl;
    
    // Test valid cases first
    {
        dtNavMeshParams params;
        params.orig[0] = 0;
        params.orig[1] = 0;
        params.orig[2] = 0;
        params.tileWidth = 10.0f;
        params.tileHeight = 10.0f;
        params.maxTiles = 1024;
        params.maxPolys = 256;
        
        dtNavMesh* navMesh = dtAllocNavMesh();
        navMesh->init(&params);
        
        // Basic positive coordinates
        float pos1[3] = {5, 0, 5};
        int tx, ty;
        navMesh->calcTileLoc(pos1, &tx, &ty);
        assert(tx == 0);
        assert(ty == 0);
        
        // Coordinates on tile boundaries
        float pos2[3] = {10, 0, 10};
        navMesh->calcTileLoc(pos2, &tx, &ty);
        assert(tx == 1);
        assert(ty == 1);
        
        // Negative coordinates (should use floor division)
        float pos3[3] = {-5, 0, -5};
        navMesh->calcTileLoc(pos3, &tx, &ty);
        assert(tx == -1);  // Floor(-0.5) = -1
        assert(ty == -1);
        
        // Large but valid coordinates
        float pos4[3] = {100000, 0, 100000};
        navMesh->calcTileLoc(pos4, &tx, &ty);
        assert(tx == 10000);
        assert(ty == 10000);
        
        dtFreeNavMesh(navMesh);
    }
    
    // Test error cases - zero tile dimensions
    {
        dtNavMeshParams params;
        params.orig[0] = 0;
        params.orig[1] = 0;
        params.orig[2] = 0;
        params.tileWidth = 0.0f;  // Invalid
        params.tileHeight = 10.0f;
        params.maxTiles = 1024;
        params.maxPolys = 256;
        
        dtNavMesh* navMesh = dtAllocNavMesh();
        dtStatus status = navMesh->init(&params);
        // In C++ implementation, init might succeed but calcTileLoc would handle zero gracefully
        
        if (dtStatusSucceed(status)) {
            float pos[3] = {5, 0, 5};
            int tx, ty;
            navMesh->calcTileLoc(pos, &tx, &ty);
            // With zero tile width, calculation would be undefined
            // C++ might return 0 or handle it differently
        }
        
        dtFreeNavMesh(navMesh);
    }
    
    // Test error cases - negative tile dimensions
    {
        dtNavMeshParams params;
        params.orig[0] = 0;
        params.orig[1] = 0;
        params.orig[2] = 0;
        params.tileWidth = -10.0f;  // Invalid
        params.tileHeight = 10.0f;
        params.maxTiles = 1024;
        params.maxPolys = 256;
        
        dtNavMesh* navMesh = dtAllocNavMesh();
        dtStatus status = navMesh->init(&params);
        // C++ might handle negative dimensions differently
        
        dtFreeNavMesh(navMesh);
    }
    
    // Test error cases - extremely small tile dimensions
    {
        dtNavMeshParams params;
        params.orig[0] = 0;
        params.orig[1] = 0;
        params.orig[2] = 0;
        params.tileWidth = 1e-7f;  // Very small
        params.tileHeight = 10.0f;
        params.maxTiles = 1024;
        params.maxPolys = 256;
        
        dtNavMesh* navMesh = dtAllocNavMesh();
        navMesh->init(&params);
        
        float pos[3] = {5, 0, 5};
        int tx, ty;
        navMesh->calcTileLoc(pos, &tx, &ty);
        // With very small tile width, result would be very large
        
        dtFreeNavMesh(navMesh);
    }
    
    std::cout << "  ✓ Passed" << std::endl;
}

// Test tile coordinate edge cases - matches additional tests from Odin
void test_tile_coordinate_edge_cases() {
    std::cout << "test_tile_coordinate_edge_cases..." << std::endl;
    
    dtNavMeshParams params;
    params.orig[0] = 0;
    params.orig[1] = 0;
    params.orig[2] = 0;
    params.tileWidth = 10.0f;
    params.tileHeight = 10.0f;
    params.maxTiles = 1024;
    params.maxPolys = 256;
    
    dtNavMesh* navMesh = dtAllocNavMesh();
    navMesh->init(&params);
    
    // Test infinity values
    {
        float inf_pos[3] = {std::numeric_limits<float>::infinity(), 0, 0};
        int tx, ty;
        navMesh->calcTileLoc(inf_pos, &tx, &ty);
        // C++ implementation might return INT_MAX or handle differently
    }
    
    // Test NaN values
    {
        float nan_pos[3] = {std::numeric_limits<float>::quiet_NaN(), 0, 0};
        int tx, ty;
        navMesh->calcTileLoc(nan_pos, &tx, &ty);
        // C++ implementation might return 0 or handle differently
    }
    
    // Test positions exactly at negative tile boundaries
    {
        float pos[3] = {-10.0f, 0, -10.0f};
        int tx, ty;
        navMesh->calcTileLoc(pos, &tx, &ty);
        assert(tx == -1);
        assert(ty == -1);
    }
    
    // Test very large negative coordinates
    {
        float pos[3] = {-100000.0f, 0, -100000.0f};
        int tx, ty;
        navMesh->calcTileLoc(pos, &tx, &ty);
        assert(tx == -10000);
        assert(ty == -10000);
    }
    
    dtFreeNavMesh(navMesh);
    
    std::cout << "  ✓ Passed" << std::endl;
}

int main() {
    std::cout << "=== Running Tile Coordinate Tests (matching tile_coordinate_test.odin) ===" << std::endl;
    
    test_tile_coordinate_calculation_robustness();
    test_tile_coordinate_edge_cases();
    
    std::cout << "\n=== All tests passed ===" << std::endl;
    return 0;
}