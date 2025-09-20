package mjolnir

// Central constants file for bindless rendering system
// All bindless buffer sizes and limits are defined here to ensure consistency

// Scene and Node Limits
MAX_NODES_IN_SCENE :: 65536         // Maximum nodes in the entire scene
MAX_ACTIVE_CAMERAS :: 128           // Maximum cameras for culling (main + shadows + user-defined)

// Material System
MAX_MATERIALS :: 1000               // Maximum materials in the material buffer

// Mesh System
MAX_MESH_DATA :: 2048               // Maximum unique meshes in the mesh data buffer

// Vertex and Index Buffers (Bindless with Slab Allocation)
BINDLESS_VERTEX_BUFFER_SIZE :: 128 * 1024 * 1024    // 128MB for all vertices
BINDLESS_INDEX_BUFFER_SIZE :: 64 * 1024 * 1024      // 64MB for all indices

// Vertex Skinning System
MAX_VERTEX_SKINNING_DATA :: 1024 * 1024             // Maximum vertex skinning entries

// Indirect Drawing
MAX_DRAWS_PER_BATCH :: 1024         // Maximum draws per indirect batch

// Animation System
MAX_BONE_MATRICES_PER_FRAME :: 4 * 1024 * 1024     // 4M matrices per frame for all animated models

// Texture System (already defined in engine.odin, but listed here for reference)
// MAX_TEXTURES :: 90
// MAX_CUBE_TEXTURES :: 20

// Double Buffering (already defined in engine.odin)
// MAX_FRAMES_IN_FLIGHT :: 2