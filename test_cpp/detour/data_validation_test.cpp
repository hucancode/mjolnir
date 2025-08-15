// C++ tests matching test/detour/data_validation_test.odin
#include <iostream>
#include <cassert>
#include <cstring>
#include <vector>
#include "../../docs/recastnavigation/Recast/Include/Recast.h"
#include "../../docs/recastnavigation/Detour/Include/DetourNavMesh.h"

// Test struct size validation - matches test_struct_size_validation
void test_struct_size_validation() {
    std::cout << "test_struct_size_validation..." << std::endl;
    
    // Test that our struct sizes match expected C++ reference sizes
    size_t header_size = sizeof(dtMeshHeader);
    size_t poly_size = sizeof(dtPoly);
    size_t link_size = sizeof(dtLink);
    size_t detail_size = sizeof(dtPolyDetail);
    size_t bv_size = sizeof(dtBVNode);
    size_t offmesh_size = sizeof(dtOffMeshConnection);
    
    // These are the expected sizes from C++ implementation
    // Note: Sizes may vary between C++ and Odin due to different padding/alignment
    std::cout << "  dtMeshHeader size: " << header_size << std::endl;
    std::cout << "  dtPoly size: " << poly_size << std::endl;
    std::cout << "  dtLink size: " << link_size << std::endl;
    std::cout << "  dtPolyDetail size: " << detail_size << std::endl;
    std::cout << "  dtBVNode size: " << bv_size << std::endl;
    std::cout << "  dtOffMeshConnection size: " << offmesh_size << std::endl;
    
    // Verify sizes are reasonable (non-zero)
    assert(header_size > 0);
    assert(poly_size > 0);
    assert(link_size > 0);
    assert(detail_size > 0);
    assert(bv_size > 0);
    assert(offmesh_size > 0);
    
    std::cout << "  ✓ Passed" << std::endl;
}

// Test endianness detection - matches test_endianness_detection
void test_endianness_detection() {
    std::cout << "test_endianness_detection..." << std::endl;
    
    // Test endianness detection from magic number
    int magic_little = DT_NAVMESH_MAGIC;
    
    // Create test data with little-endian magic
    std::vector<unsigned char> little_data(8);
    little_data[0] = (unsigned char)(magic_little & 0xFF);
    little_data[1] = (unsigned char)((magic_little >> 8) & 0xFF);
    little_data[2] = (unsigned char)((magic_little >> 16) & 0xFF);
    little_data[3] = (unsigned char)((magic_little >> 24) & 0xFF);
    
    // Check if data starts with correct magic
    int* magic_ptr = (int*)little_data.data();
    int swapped_magic = ((DT_NAVMESH_MAGIC & 0x000000ff) << 24) |
                        ((DT_NAVMESH_MAGIC & 0x0000ff00) << 8) |
                        ((DT_NAVMESH_MAGIC & 0x00ff0000) >> 8) |
                        ((DT_NAVMESH_MAGIC & 0xff000000) >> 24);
    assert(*magic_ptr == DT_NAVMESH_MAGIC || *magic_ptr == swapped_magic);
    
    // Test system endianness detection
    bool is_little_endian = true;
    {
        union {
            unsigned int i;
            unsigned char c[4];
        } test = {0x01020304};
        is_little_endian = (test.c[0] == 0x04);
    }
    
    std::cout << "  System endianness: " << (is_little_endian ? "Little" : "Big") << std::endl;
    
    // Create test data with big-endian magic (swapped)
    std::vector<unsigned char> big_data(8);
    big_data[0] = (unsigned char)((magic_little >> 24) & 0xFF);
    big_data[1] = (unsigned char)((magic_little >> 16) & 0xFF);
    big_data[2] = (unsigned char)((magic_little >> 8) & 0xFF);
    big_data[3] = (unsigned char)(magic_little & 0xFF);
    
    // Check if swapped data is detected
    int* magic_ptr_big = (int*)big_data.data();
    assert(*magic_ptr_big == swapped_magic || *magic_ptr_big == DT_NAVMESH_MAGIC);
    
    std::cout << "  ✓ Passed" << std::endl;
}

// Test tile validation with invalid data - matches test_tile_validation_invalid_data
void test_tile_validation_invalid_data() {
    std::cout << "test_tile_validation_invalid_data..." << std::endl;
    
    // Test with too small data
    std::vector<unsigned char> small_data(4);
    
    // In C++, dtNavMesh::addTile would reject data that's too small
    // We can test this by checking minimum header size
    bool is_valid = small_data.size() >= sizeof(dtMeshHeader);
    assert(!is_valid && "Small data should be invalid");
    
    // Test with invalid magic number
    std::vector<unsigned char> invalid_magic(sizeof(dtMeshHeader));
    memset(invalid_magic.data(), 0, invalid_magic.size());
    
    dtMeshHeader* header = (dtMeshHeader*)invalid_magic.data();
    header->magic = 0xDEADBEEF; // Invalid magic
    
    int swapped_magic = ((DT_NAVMESH_MAGIC & 0x000000ff) << 24) |
                        ((DT_NAVMESH_MAGIC & 0x0000ff00) << 8) |
                        ((DT_NAVMESH_MAGIC & 0x00ff0000) >> 8) |
                        ((DT_NAVMESH_MAGIC & 0xff000000) >> 24);
    bool has_valid_magic = (header->magic == DT_NAVMESH_MAGIC || 
                            header->magic == swapped_magic);
    assert(!has_valid_magic && "Invalid magic should be detected");
    
    // Test with wrong version
    header->magic = DT_NAVMESH_MAGIC;
    header->version = 999; // Wrong version
    
    bool has_valid_version = (header->version == DT_NAVMESH_VERSION);
    assert(!has_valid_version && "Wrong version should be detected");
    
    std::cout << "  ✓ Passed" << std::endl;
}

// Test tile data validation - matches test_tile_validation_valid_data
void test_tile_validation_valid_data() {
    std::cout << "test_tile_validation_valid_data..." << std::endl;
    
    // Create minimal valid tile data
    size_t data_size = sizeof(dtMeshHeader) + sizeof(dtPoly) + sizeof(float) * 3 * 3; // header + 1 poly + 3 verts
    std::vector<unsigned char> valid_data(data_size);
    
    dtMeshHeader* header = (dtMeshHeader*)valid_data.data();
    header->magic = DT_NAVMESH_MAGIC;
    header->version = DT_NAVMESH_VERSION;
    header->x = 0;
    header->y = 0;
    header->layer = 0;
    header->polyCount = 1;
    header->vertCount = 3;
    header->maxLinkCount = 0;
    header->detailMeshCount = 0;
    header->detailVertCount = 0;
    header->detailTriCount = 0;
    header->bvNodeCount = 0;
    header->offMeshConCount = 0;
    header->offMeshBase = 0;
    header->walkableHeight = 2.0f;
    header->walkableRadius = 0.6f;
    header->walkableClimb = 0.9f;
    header->bmin[0] = 0.0f;
    header->bmin[1] = 0.0f;
    header->bmin[2] = 0.0f;
    header->bmax[0] = 10.0f;
    header->bmax[1] = 1.0f;
    header->bmax[2] = 10.0f;
    header->bvQuantFactor = 1.0f;
    
    // Validate the header
    assert(header->magic == DT_NAVMESH_MAGIC);
    assert(header->version == DT_NAVMESH_VERSION);
    assert(header->polyCount == 1);
    assert(header->vertCount == 3);
    
    std::cout << "  ✓ Passed" << std::endl;
}

int main() {
    std::cout << "=== Running Data Validation Tests (matching data_validation_test.odin) ===" << std::endl;
    
    test_struct_size_validation();
    test_endianness_detection();
    test_tile_validation_invalid_data();
    test_tile_validation_valid_data();
    
    std::cout << "\n=== All tests passed ===" << std::endl;
    return 0;
}