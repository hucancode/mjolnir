package render_data

import cont "../../containers"
import "../../gpu"

Handle :: cont.Handle

NodeHandle :: distinct Handle
MeshHandle :: gpu.MeshHandle
MaterialHandle :: distinct Handle
CameraHandle :: distinct Handle
EmitterHandle :: distinct Handle
ForceFieldHandle :: distinct Handle
SpriteHandle :: distinct Handle
LightHandle :: distinct Handle

FRAMES_IN_FLIGHT :: #config(FRAMES_IN_FLIGHT, 2)
BONE_BUFFER_CAPACITY_MB :: #config(BONE_BUFFER_CAPACITY_MB, 60)
MAX_TEXTURES :: 1000
MAX_CUBE_TEXTURES :: 200
MAX_NODES_IN_SCENE :: 65536
MAX_ACTIVE_CAMERAS :: 128
MAX_EMITTERS :: 64
MAX_FORCE_FIELDS :: 32
MAX_LIGHTS :: 256
MAX_MESHES :: 65536
MAX_MATERIALS :: 4096
MAX_SPRITES :: 4096
MAX_CAMERAS :: 64
BINDLESS_VERTEX_BUFFER_SIZE :: 128 * 1024 * 1024
BINDLESS_INDEX_BUFFER_SIZE :: 64 * 1024 * 1024
BINDLESS_SKINNING_BUFFER_SIZE :: 128 * 1024 * 1024

VERTEX_SLAB_CONFIG :: [cont.MAX_SLAB_CLASSES]struct {
  block_size, block_count: u32,
} {
  {block_size = 256, block_count = 512},
  {block_size = 1024, block_count = 128},
  {block_size = 4096, block_count = 64},
  {block_size = 16384, block_count = 16},
  {block_size = 65536, block_count = 8},
  {block_size = 131072, block_count = 4},
  {block_size = 262144, block_count = 1},
  {block_size = 0, block_count = 0},
}

INDEX_SLAB_CONFIG :: [cont.MAX_SLAB_CLASSES]struct {
  block_size, block_count: u32,
} {
  {block_size = 128, block_count = 2048},
  {block_size = 512, block_count = 1024},
  {block_size = 2048, block_count = 512},
  {block_size = 8192, block_count = 256},
  {block_size = 32768, block_count = 128},
  {block_size = 131072, block_count = 32},
  {block_size = 524288, block_count = 8},
  {block_size = 2097152, block_count = 4},
}

BufferAllocation :: gpu.BufferAllocation

Primitive :: enum {
  CUBE,
  SPHERE,
  QUAD_XZ,
  QUAD_XY,
  CONE,
  CAPSULE,
  CYLINDER,
  TORUS,
}

MeshFlag :: enum u32 {
  SKINNED,
}

MeshFlagSet :: bit_set[MeshFlag;u32]

ShaderFeature :: enum {
  ALBEDO_TEXTURE             = 0,
  METALLIC_ROUGHNESS_TEXTURE = 1,
  NORMAL_TEXTURE             = 2,
  EMISSIVE_TEXTURE           = 3,
  OCCLUSION_TEXTURE          = 4,
}

ShaderFeatureSet :: bit_set[ShaderFeature;u32]

NodeFlag :: enum u32 {
  VISIBLE,
  CULLING_ENABLED,
  MATERIAL_TRANSPARENT,
  MATERIAL_WIREFRAME,
  MATERIAL_SPRITE,
  MATERIAL_RANDOM_COLOR,
  MATERIAL_LINE_STRIP,
  CASTS_SHADOW,
  NAVIGATION_OBSTACLE,
}

NodeFlagSet :: bit_set[NodeFlag;u32]

Node :: struct {
  material_id:           u32,
  mesh_id:               u32,
  attachment_data_index: u32,
  flags:                 NodeFlagSet,
}

Mesh :: struct {
  aabb_min:        [3]f32,
  index_count:     u32,
  aabb_max:        [3]f32,
  first_index:     u32,
  vertex_offset:   i32,
  skinning_offset: u32,
  flags:           MeshFlagSet,
  padding:         u32,
}

Material :: struct {
  albedo_index:             u32,
  metallic_roughness_index: u32,
  normal_index:             u32,
  emissive_index:           u32,
  metallic_value:           f32,
  roughness_value:          f32,
  emissive_value:           f32,
  features:                 ShaderFeatureSet,
  base_color_factor:        [4]f32,
}

Emitter :: struct {
  initial_velocity:  [3]f32,
  size_start:        f32,
  color_start:       [4]f32,
  color_end:         [4]f32,
  aabb_min:          [3]f32,
  emission_rate:     f32,
  aabb_max:          [3]f32,
  particle_lifetime: f32,
  position_spread:   f32,
  velocity_spread:   f32,
  time_accumulator:  f32,
  size_end:          f32,
  weight:            f32,
  weight_spread:     f32,
  texture_index:     u32,
  node_index:        u32,
}

ForceField :: struct {
  tangent_strength: f32,
  strength:         f32,
  area_of_effect:   f32,
  node_index:       u32,
}

Sprite :: struct {
  texture_index: u32,
  frame_columns: u32,
  frame_rows:    u32,
  frame_index:   u32,
}

LightType :: enum u32 {
  POINT       = 0,
  DIRECTIONAL = 1,
  SPOT        = 2,
}

Light :: struct {
  color:        [4]f32, // RGB + intensity
  position:     [4]f32, // xyz world position
  direction:    [4]f32, // xyz world forward direction
  radius:       f32, // range for point/spot lights
  angle_inner:  f32, // inner cone angle for spot lights
  angle_outer:  f32, // outer cone angle for spot lights
  type:         LightType, // LightType
  cast_shadow:  b32, // 0 = no shadow, 1 = cast shadow
  shadow_index: u32, // index into shadow buffers
  _padding:     [2]u32, // Maintain 16-byte alignment
}
