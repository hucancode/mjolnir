package resources

MAX_TEXTURES :: 90
MAX_CUBE_TEXTURES :: 20
MAX_FRAMES_IN_FLIGHT :: 2
MAX_NODES_IN_SCENE :: 65536
MAX_ACTIVE_CAMERAS :: 128
MAX_EMITTERS :: 64
MAX_FORCE_FIELDS :: 32
MAX_LIGHTS :: 256
SHADOW_MAP_SIZE :: 512
WORLD_MATRIX_CAPACITY :: MAX_NODES_IN_SCENE
NODE_DATA_CAPACITY :: MAX_NODES_IN_SCENE
BINDLESS_VERTEX_BUFFER_SIZE :: 128 * 1024 * 1024 // 128MB
BINDLESS_INDEX_BUFFER_SIZE :: 64 * 1024 * 1024 // 64MB
BINDLESS_SKINNING_BUFFER_SIZE :: 128 * 1024 * 1024 // 128MB
// Configuration for different allocation sizes
// Total capacity: 256*512 + 1024*256 + 4096*128 + 16384*64 + 65536*16 + 262144*4 + 1048576*1 + 0*0 = 2,097,152 vertices
VERTEX_SLAB_CONFIG :: [MAX_SLAB_CLASSES]struct {
  block_size, block_count: u32,
} {
  {block_size = 256, block_count = 512}, // Small meshes: 131,072 vertices
  {block_size = 1024, block_count = 256}, // Medium meshes: 262,144 vertices
  {block_size = 4096, block_count = 128}, // Large meshes: 524,288 vertices
  {block_size = 16384, block_count = 64}, // Very large meshes: 1,048,576 vertices
  {block_size = 65536, block_count = 16}, // Huge meshes: 1,048,576 vertices
  {block_size = 262144, block_count = 4}, // Massive meshes: 1,048,576 vertices
  {block_size = 1048576, block_count = 1}, // Giant meshes: 1,048,576 vertices
  {block_size = 0, block_count = 0}, // Unused - disabled to fit within buffer
}

// Total capacity: 128*2048 + 512*1024 + 2048*512 + 8192*256 + 32768*128 + 131072*32 + 524288*8 + 2097152*4 = 16,777,216 indices
INDEX_SLAB_CONFIG :: [MAX_SLAB_CLASSES]struct {
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
