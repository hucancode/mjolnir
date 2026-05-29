package render

import alg "../algebra"
import cont "../containers"
import "../gpu"
import "ambient"
import "debug_line"
import "debug_ui"
import depth_pyramid_system "depth_pyramid"
import "direct_light"
import "geometry"
import "line_strip"
import "occlusion_culling"
import particles_compute "particles_compute"
import particles_render "particles_render"
import "post_process"
import "random_color"
import shadow_culling_system "shadow_culling"
import shadow_render_system "shadow_render"
import shadow_sphere_culling_system "shadow_sphere_culling"
import shadow_sphere_render_system "shadow_sphere_render"
import "sprite"
import "transparent"
import ui_render "ui"
import vk "vendor:vulkan"
import "wireframe"

FRAMES_IN_FLIGHT :: #config(FRAMES_IN_FLIGHT, 2)
MAX_NODES_IN_SCENE :: 65536
MAX_ACTIVE_CAMERAS :: 128
MAX_LIGHTS :: 256
MAX_MESHES :: 65536
MAX_MATERIALS :: 4096
MAX_SPRITES :: 4096
MAX_CAMERAS :: 64
MAX_SHADOW_MAPS :: 16
INVALID_SHADOW_INDEX :: 0xFFFFFFFF
SHADOW_MAP_SIZE :: 512

@(private)
frame_next :: #force_inline proc(frame_index: u32) -> u32 {
  return alg.next(frame_index, FRAMES_IN_FLIGHT)
}

@(private)
frame_prev :: #force_inline proc(frame_index: u32) -> u32 {
  return alg.prev(frame_index, FRAMES_IN_FLIGHT)
}

Handle :: cont.Handle
MeshHandle :: gpu.MeshHandle
MaterialHandle :: distinct Handle
LightHandle :: distinct Handle
Image2DHandle :: gpu.Texture2DHandle
ImageCubeHandle :: gpu.TextureCubeHandle

BufferAllocation :: gpu.BufferAllocation
DrawPipeline :: occlusion_culling.DrawPipeline
DrawBuffers :: occlusion_culling.DrawBuffers
Particle :: particles_compute.Particle

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

Node :: struct #packed {
  world_matrix:          matrix[4, 4]f32,
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

Sprite :: struct {
  texture_index: u32,
  frame_columns: u32,
  frame_rows:    u32,
  frame_index:   u32,
}

// CameraGPU is the SSBO layout uploaded each frame to camera_buffer; rendered
// shaders read it. `frustum_planes` is derived from `projection * view`; kept
// here so the GPU-side culling pass need not recompute it per node.
CameraGPU :: struct {
  view:            matrix[4, 4]f32,
  projection:      matrix[4, 4]f32,
  viewport_extent: [2]f32,
  near:            f32,
  far:             f32,
  position:        [4]f32,
  frustum_planes:  [6][4]f32,
}

Emitter :: particles_compute.Emitter
ForceField :: particles_compute.ForceField
MAX_EMITTERS :: particles_compute.MAX_EMITTERS
MAX_FORCE_FIELDS :: particles_compute.MAX_FORCE_FIELDS

// Shadow resources are stored in side maps keyed by light node index.
// View/projection/near/far/frustum are derived from light state and recomputed
// per frame at use sites; storing them would duplicate Light fields.
@(private)
ShadowMap :: struct {
  shadow_map_2d:   [FRAMES_IN_FLIGHT]gpu.Texture2DHandle,
  draw_commands:   [FRAMES_IN_FLIGHT]gpu.MutableBuffer(
    vk.DrawIndexedIndirectCommand,
  ),
  draw_count:      [FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  descriptor_sets: [FRAMES_IN_FLIGHT]vk.DescriptorSet,
}

@(private)
ShadowMapCube :: struct {
  shadow_map_cube: [FRAMES_IN_FLIGHT]gpu.TextureCubeHandle,
  draw_commands:   [FRAMES_IN_FLIGHT]gpu.MutableBuffer(
    vk.DrawIndexedIndirectCommand,
  ),
  draw_count:      [FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  descriptor_sets: [FRAMES_IN_FLIGHT]vk.DescriptorSet,
}

PointLight :: struct {
  color:    [4]f32, // RGB + intensity
  position: [3]f32,
  radius:   f32,
}

SpotLight :: struct {
  color:       [4]f32,
  position:    [3]f32,
  direction:   [3]f32,
  radius:      f32,
  angle_inner: f32,
  angle_outer: f32,
}

DirectionalLight :: struct {
  color:     [4]f32,
  position:  [3]f32,
  direction: [3]f32,
  radius:    f32,
}

Light :: union {
  PointLight,
  SpotLight,
  DirectionalLight,
}

// Internal owns GPU primitives and CPU-side bookkeeping. The engine package
// reaches into specific subrenderer fields (debug_renderer, ui, command
// buffers); external user code should not.
@(private)
Internal :: struct {
  command_buffers:              [FRAMES_IN_FLIGHT]vk.CommandBuffer,
  compute_command_buffers:      [FRAMES_IN_FLIGHT]vk.CommandBuffer,
  linear_repeat_sampler:        vk.Sampler,
  linear_clamp_sampler:         vk.Sampler,
  nearest_repeat_sampler:       vk.Sampler,
  nearest_clamp_sampler:        vk.Sampler,
  bone_buffer:                  gpu.PerFrameBindlessBuffer(
    matrix[4, 4]f32,
    FRAMES_IN_FLIGHT,
  ),
  camera_buffer:                gpu.PerFrameBindlessBuffer(
    CameraGPU,
    FRAMES_IN_FLIGHT,
  ),
  material_buffer:              gpu.BindlessBuffer(Material),
  node_data_buffer:             gpu.BindlessBuffer(Node),
  mesh_data_buffer:             gpu.BindlessBuffer(Mesh),
  emitter_buffer:               gpu.BindlessBuffer(Emitter),
  forcefield_buffer:            gpu.BindlessBuffer(ForceField),
  sprite_buffer:                gpu.BindlessBuffer(Sprite),
  bone_matrix_slab:             cont.SlabAllocator,
  bone_matrix_offsets:          map[u32]u32,
  // Pass renderers - never accessed from outside the render package.
  geometry:                     geometry.Renderer,
  ambient:                      ambient.Renderer,
  direct_light:                 direct_light.Renderer,
  transparent_renderer:         transparent.Renderer,
  sprite_renderer:              sprite.Renderer,
  wireframe_renderer:           wireframe.Renderer,
  line_strip_renderer:          line_strip.Renderer,
  random_color_renderer:        random_color.Renderer,
  particles_compute:            particles_compute.Renderer,
  particles_render:             particles_render.Renderer,
  debug_line_renderer:          debug_line.Renderer,
  ui:                           ui_render.Renderer,
  // Compute / culling / shadow systems.
  visibility:                   occlusion_culling.System,
  depth_pyramid:                depth_pyramid_system.System,
  shadow_culling:               shadow_culling_system.System,
  shadow_sphere_culling:        shadow_sphere_culling_system.System,
  shadow_render:                shadow_render_system.System,
  shadow_sphere_render:         shadow_sphere_render_system.System,
  // Per-light render-side state. Indexed by light node index.
  lights:                       map[u32]Light,
  shadow_maps:                  map[u32]ShadowMap,
  shadow_map_cubes:             map[u32]ShadowMapCube,
}

// Public Manager surface. Anything outside the render package goes through
// these fields or the public procs below.
//   * cameras: per-camera GPU resources, keyed by camera node index. Engine
//     manages lifecycle (insert / init / destroy).
//   * mesh_manager / texture_manager: gpu-package asset pools, exposed so
//     callers can allocate textures and meshes directly via gpu.* helpers.
//   * post_process: user-facing effects stack (callers add fog, bloom, etc).
//   * debug_ui: microui input target. Inputs go directly into debug_ui.ctx.
Manager :: struct {
  internal:        Internal,
  cameras:         map[u32]CameraTarget,
  // Single source of truth for active scene node count. Drives compute
  // dispatch sizing across visibility, depth pyramid, and both shadow culls.
  // Clamped to MAX_NODES_IN_SCENE by set_node_count.
  node_count:      u32,
  mesh_manager:    gpu.MeshManager,
  texture_manager: gpu.TextureManager,
  post_process:    post_process.Renderer,
  debug_ui:        debug_ui.Renderer,
}

AttachmentType :: enum {
  FINAL_IMAGE        = 0,
  POSITION           = 1,
  NORMAL             = 2,
  ALBEDO             = 3,
  METALLIC_ROUGHNESS = 4,
  EMISSIVE           = 5,
  DEPTH              = 6,
}

PassType :: enum {
  SHADOW,
  GEOMETRY,
  LIGHTING,
  TRANSPARENCY,
  PARTICLES,
  POST_PROCESS,
  SPRITE,
  WIREFRAME,
  LINE_STRIP,
  RANDOM_COLOR,
  DEBUG_UI,
  DEBUG_LINE,
  UI,
}

PassTypeSet :: bit_set[PassType;u32]

DEFAULT_ENABLED_PASSES :: PassTypeSet{
  .SHADOW,
  .GEOMETRY,
  .LIGHTING,
  .TRANSPARENCY,
  .PARTICLES,
  .POST_PROCESS,
  .SPRITE,
  .WIREFRAME,
  .LINE_STRIP,
  .RANDOM_COLOR,
  .DEBUG_UI,
  .DEBUG_LINE,
  .UI,
}

// CameraTarget owns render-side GPU resources for one camera (attachments,
// indirect draw buffers, depth pyramid, descriptor sets) and the per-camera
// pass enable/culling flags. The world-side `Camera` carries only spatial
// state; engine layer translates high-level config into these flags.
CameraTarget :: struct {
  attachments:                  [AttachmentType][FRAMES_IN_FLIGHT]gpu.Texture2DHandle,
  // Indirect draw buffers per pipeline (double-buffered for async compute).
  // Frame N compute writes to buffers[N], Frame N graphics reads from buffers[N-1].
  draws:                        [DrawPipeline]DrawBuffers,
  depth_pyramid:                [FRAMES_IN_FLIGHT]depth_pyramid_system.DepthPyramid,
  descriptor_set:               [FRAMES_IN_FLIGHT]vk.DescriptorSet,
  depth_reduce_descriptor_sets: [FRAMES_IN_FLIGHT][depth_pyramid_system.MAX_DEPTH_MIPS_LEVEL]vk.DescriptorSet,
  enabled_passes:               PassTypeSet,
  enable_culling:               bool,
}

VisibilityStats :: struct {
  node_count:        u32,
  opaque_draw_count: u32,
}
