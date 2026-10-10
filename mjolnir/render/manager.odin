package render

import "bindless"
import cont "../containers"
import "gpu"
import "ambient"
import "debug_line"
import depth_pyramid_system "depth_pyramid"
import "direct_light"
import "forward"
import "geometry"
import "occlusion_culling"
import "particles"
import "post_process"
import "shadow"
import ui_render "ui"
import vk "vendor:vulkan"

MAX_NODES_IN_SCENE :: 65536
MAX_ACTIVE_CAMERAS :: 128
MAX_LIGHTS :: 256
MAX_MESHES :: 65536
MAX_MATERIALS :: 4096
MAX_SPRITES :: 4096
MAX_SHADOW_MAPS :: 16
INVALID_SHADOW_INDEX :: 0xFFFFFFFF
SHADOW_MAP_SIZE :: 512
// Frames a freed CPU resource slot stays reserved before reuse, so in-flight
// frames never see a recycled index.
RETIRE_GRACE :: gpu.FRAMES_IN_FLIGHT + 1

Handle :: cont.Handle
MeshHandle :: bindless.MeshHandle
MaterialHandle :: distinct Handle
SpriteHandle :: distinct Handle
EmitterHandle :: distinct Handle
ForceFieldHandle :: distinct Handle
CameraHandle :: distinct Handle

BufferAllocation :: bindless.BufferAllocation

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

Color :: enum {
  WHITE,
  BLACK,
  GRAY,
  RED,
  GREEN,
  BLUE,
  YELLOW,
  CYAN,
  MAGENTA,
}

MaterialType :: enum {
  PBR,
  UNLIT,
  WIREFRAME,
  TRANSPARENT,
  RANDOM_COLOR,
  LINE_STRIP,
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
}

NodeFlagSet :: bit_set[NodeFlag;u32]

NodeData :: struct #packed {
  world_matrix:          matrix[4, 4]f32,
  material_id:           u32,
  mesh_id:               u32,
  attachment_data_index: u32,
  flags:                 NodeFlagSet,
}

MeshData :: struct {
  aabb_min:        [3]f32,
  index_count:     u32,
  aabb_max:        [3]f32,
  first_index:     u32,
  vertex_offset:   i32,
  skinning_offset: u32,
  flags:           MeshFlagSet,
  padding:         u32,
}

MaterialData :: struct {
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

SpriteData :: struct {
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

EmitterData :: particles.Emitter
ForceFieldData :: particles.ForceField
MAX_EMITTERS :: particles.MAX_EMITTERS
MAX_FORCE_FIELDS :: particles.MAX_FORCE_FIELDS

// Per-light shadow resources, keyed by light node index. Point lights render
// a cube map, spot and directional lights a 2D map; `textures` holds the
// matching bindless handle. View/projection are derived from light state per
// frame (see build_shadow_cache).
@(private)
ShadowMap :: struct {
  cube:            bool,
  textures:        [gpu.FRAMES_IN_FLIGHT]Handle,
  draws:           bindless.DrawBuffers,
  descriptor_sets: [gpu.FRAMES_IN_FLIGHT]vk.DescriptorSet,
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

// Internal owns GPU primitives and CPU-side bookkeeping. Private to render.
@(private)
Internal :: struct {
  command_buffers:              [gpu.FRAMES_IN_FLIGHT]vk.CommandBuffer,
  compute_command_buffers:      [gpu.FRAMES_IN_FLIGHT]vk.CommandBuffer,
  // Set by setup, cleared by teardown; frame renders nothing while false.
  level_ready:                  bool,
  bone_buffer:                  gpu.PerFrameBindlessBuffer(
    matrix[4, 4]f32,
    gpu.FRAMES_IN_FLIGHT,
  ),
  camera_buffer:                gpu.PerFrameBindlessBuffer(
    CameraGPU,
    gpu.FRAMES_IN_FLIGHT,
  ),
  material_buffer:              gpu.BindlessBuffer(MaterialData),
  node_data_buffer:             gpu.BindlessBuffer(NodeData),
  mesh_data_buffer:             gpu.BindlessBuffer(MeshData),
  emitter_buffer:               gpu.BindlessBuffer(EmitterData),
  forcefield_buffer:            gpu.BindlessBuffer(ForceFieldData),
  sprite_buffer:                gpu.BindlessBuffer(SpriteData),
  bone_matrix_slab:             cont.SlabAllocator,
  bone_matrix_offsets:          map[u32]u32,
  // CPU copy of each slot's skin palette; re-uploaded to every per-frame
  // bone buffer until all frames in flight hold it.
  bone_matrices:                map[u32][]matrix[4, 4]f32,
  // Pass renderers - never accessed from outside the render package.
  geometry:                     geometry.Renderer,
  direct_light:                 direct_light.Renderer,
  forward:                      forward.Renderer,
  particles:                    particles.Renderer,
  debug_line_renderer:          debug_line.Renderer,
  ui:                           ui_render.Renderer,
  // Compute / culling / shadow systems.
  visibility:                   occlusion_culling.System,
  depth_pyramid:                depth_pyramid_system.System,
  shadow:                       shadow.System,
  // Per-light render-side state. Indexed by light node index.
  lights:                       map[u32]Light,
  shadow_maps:                  map[u32]ShadowMap,
  staging:                      Staging,
  // Pending overlay font atlas upload, applied by flush on the render thread.
  ui_atlas_pixels:              []u8,
  ui_atlas_extent:              [2]u32,
  ui_atlas_dirty:               bool,
}

// Public Manager surface. Anything outside the render package goes through
// these fields or the public procs below.
//   * meshes / materials / sprites / emitters / forcefields: CPU-side
//     resources. Create and mutate them through the procs in resources.odin;
//     changes reach the GPU through staging.
//   * instances: per-slot looks (mesh, light, emitter, ...), indexed by
//     transform slot. A slot is whatever index the caller uses to identify a
//     transform; the engine uses world node indices.
//   * cameras: views with their GPU targets. `main_camera` is presented.
//   * mesh_manager / texture_manager: the bindless mesh arena and texture
//     arrays; create textures through create_texture_* in resources.odin.
//   * post_process: user-facing effects stack (callers add fog, bloom, etc).
// The microui debug context is reached through debug_ui (overlay.odin).
//
// Lifecycle, in pairs:
//   create_instance + init / shutdown: device, swapchain, pipelines, pools.
//   setup / teardown: level resources (descriptors, cameras, slots, textures).
// setup and teardown may be called any number of times between init and
// shutdown, from any point outside frame.
Manager :: struct {
  gctx:              gpu.GPUContext,
  swapchain:         gpu.Swapchain,
  frame_index:       u32, // frame in flight recorded next
  internal:          Internal,
  meshes:            cont.Pool(Mesh),
  materials:         cont.Pool(Material),
  sprites:           cont.Pool(Sprite),
  emitters:          cont.Pool(Emitter),
  forcefields:       cont.Pool(ForceField),
  instances:         [dynamic]Instance,
  builtin_materials: [Color]MaterialHandle,
  builtin_meshes:    [Primitive]MeshHandle,
  cameras:           cont.Pool(Camera),
  main_camera:       CameraHandle,
  color_format:      vk.Format,
  // Single source of truth for active scene node count. Drives compute
  // dispatch sizing across visibility, depth pyramid, and both shadow culls.
  node_count:        u32,
  mesh_manager:      bindless.MeshManager,
  texture_manager:   bindless.TextureManager,
  ambient:           ambient.Renderer,
  post_process:      post_process.Renderer,
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
  .DEBUG_LINE,
  .UI,
}

PerspectiveProjection :: struct {
  fov:          f32,
  aspect_ratio: f32,
  near:         f32,
  far:          f32,
}

OrthographicProjection :: struct {
  width:  f32,
  height: f32,
  near:   f32,
  far:    f32,
}

CameraProjection :: union {
  PerspectiveProjection,
  OrthographicProjection,
}

// A view into the scene: pose + projection, plus the GPU resources it renders
// into (attachments, indirect draw buffers, depth pyramid, descriptor sets)
// and the per-camera pass enable/culling flags.
Camera :: struct {
  position:                     [3]f32,
  rotation:                     quaternion128,
  projection:                   CameraProjection,
  extent:                       [2]u32, // width, height
  attachments:                  [AttachmentType][gpu.FRAMES_IN_FLIGHT]bindless.Texture2DHandle,
  // Indirect draw buffers per pipeline (double-buffered for async compute).
  // Frame N compute writes to buffers[N], Frame N graphics reads from buffers[N-1].
  draws:                        [bindless.DrawPipeline]bindless.DrawBuffers,
  depth_pyramid:                [gpu.FRAMES_IN_FLIGHT]depth_pyramid_system.DepthPyramid,
  descriptor_set:               [gpu.FRAMES_IN_FLIGHT]vk.DescriptorSet,
  depth_reduce_descriptor_sets: [gpu.FRAMES_IN_FLIGHT][depth_pyramid_system.MAX_DEPTH_MIPS_LEVEL]vk.DescriptorSet,
  enabled_passes:               PassTypeSet,
  enable_culling:               bool,
}

VisibilityStats :: struct {
  node_count:        u32,
  opaque_draw_count: u32,
}
