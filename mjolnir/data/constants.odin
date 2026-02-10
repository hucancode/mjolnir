package data

import cont "../containers"

FRAMES_IN_FLIGHT :: #config(FRAMES_IN_FLIGHT, 2)
// Bone matrix buffer capacity (default: 60MB per frame × 2 frames = 120MB total)
// Override at build time: -define:BONE_BUFFER_CAPACITY_MB=80
BONE_BUFFER_CAPACITY_MB :: #config(BONE_BUFFER_CAPACITY_MB, 60)
MAX_TEXTURES :: 1000
MAX_CUBE_TEXTURES :: 200
MAX_NODES_IN_SCENE :: 65536
MAX_ACTIVE_CAMERAS :: 128
MAX_EMITTERS :: 64
MAX_FORCE_FIELDS :: 32
MAX_LIGHTS :: 256
MAX_SHADOW_MAPS :: 16
SHADOW_MAP_SIZE :: 512
MAX_MESHES :: 65536
MAX_MATERIALS :: 4096
MAX_SPRITES :: 4096
BINDLESS_VERTEX_BUFFER_SIZE :: 128 * 1024 * 1024 // 128MB
BINDLESS_INDEX_BUFFER_SIZE :: 64 * 1024 * 1024 // 64MB
BINDLESS_SKINNING_BUFFER_SIZE :: 128 * 1024 * 1024 // 128MB

// Configuration for different allocation sizes
// Total capacity MUST equal buffer capacity: 128MB / 64 bytes = 2,097,152 vertices
// Current: 256*512 + 1024*128 + 4096*64 + 16384*16 + 65536*8 + 131072*4 = 2,097,152 vertices
VERTEX_SLAB_CONFIG :: [cont.MAX_SLAB_CLASSES]struct {
	block_size, block_count: u32,
} {
	{block_size = 256, block_count = 512},    // Small meshes: 131,072 vertices, range [0, 131K)
	{block_size = 1024, block_count = 128},   // Medium meshes: 131,072 vertices, range [131K, 262K)
	{block_size = 4096, block_count = 64},    // Large meshes: 262,144 vertices, range [262K, 524K)
	{block_size = 16384, block_count = 16},   // Very large meshes: 262,144 vertices, range [524K, 786K)
	{block_size = 65536, block_count = 8},    // Huge meshes: 524,288 vertices, range [786K, 1310K)
	{block_size = 131072, block_count = 4},   // Massive meshes: 524,288 vertices, range [1310K, 1835K)
	{block_size = 262144, block_count = 1},   // Giant meshes: 262,144 vertices, range [1835K, 2097K)
	{block_size = 0, block_count = 0},        // Unused
}

// Total capacity: 128*2048 + 512*1024 + 2048*512 + 8192*256 + 32768*128 + 131072*32 + 524288*8 + 2097152*4 = 16,777,216 indices
INDEX_SLAB_CONFIG :: [cont.MAX_SLAB_CLASSES]struct {
	block_size, block_count: u32,
} {
	{block_size = 128, block_count = 2048}, // Small index counts: 262,144 indices
	{block_size = 512, block_count = 1024}, // Medium index counts: 524,288 indices
	{block_size = 2048, block_count = 512}, // Large index counts: 1,048,576 indices
	{block_size = 8192, block_count = 256}, // Very large index counts: 2,097,152 indices
	{block_size = 32768, block_count = 128}, // Huge index counts: 4,194,304 indices
	{block_size = 131072, block_count = 32}, // Massive index counts: 4,194,304 indices
	{block_size = 524288, block_count = 8}, // Giant index counts: 4,194,304 indices
	{block_size = 2097152, block_count = 4}, // Enormous index counts: 8,388,608 indices
}
