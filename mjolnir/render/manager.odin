package render

import cont "../containers"
import "gpu"
import vk "vendor:vulkan"

MAX_NODES_IN_SCENE :: 65536
MAX_ACTIVE_CAMERAS :: 128
// direct_light packs camera indices into 16 bits
#assert(MAX_ACTIVE_CAMERAS < 0xFFFF)
MAX_LIGHTS :: 256
MAX_MESHES :: 65536
MAX_MATERIALS :: 4096
MAX_SHADOW_MAPS :: 16
SHADOW_MAP_SIZE :: 512
// Shadow casters ranked by screen coverage get a map; the rest of the maps go
// to casters that ranked within the last SHADOW_GRACE_FRAMES frames.
SHADOW_RANKED_CASTERS :: 12
SHADOW_GRACE_FRAMES :: 30
#assert(SHADOW_RANKED_CASTERS <= MAX_SHADOW_MAPS)
// A cube map renders six views, any other map one.
MAX_SHADOW_VIEWS :: MAX_SHADOW_MAPS * 6
// Draw list capacity of all shadow views together.
SHADOW_MAX_DRAWS :: 4096 * MAX_SHADOW_VIEWS

Handle :: cont.Handle
MaterialHandle :: distinct Handle
EmitterHandle :: distinct Handle
ForceFieldHandle :: distinct Handle
CameraHandle :: distinct Handle

Primitive :: enum {
  CUBE,
  SPHERE,
  QUAD_XZ,
  QUAD_XY,
  CONE,
  CYLINDER,
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

// How a material is drawn; MATERIAL_PIPELINES holds each type's pipeline.
// Every camera has one draw list per type, drawn in this order.
MaterialType :: enum u32 {
  PBR,
  TRANSPARENT,
  WIREFRAME,
  RANDOM_COLOR,
  // camera-facing billboard showing one cell of the albedo sprite sheet
  SPRITE,
}

@(private)
MeshFlag :: enum u32 {
  SKINNED,
}

@(private)
MeshFlagSet :: bit_set[MeshFlag;u32]

@(private)
NodeFlag :: enum u32 {
  VISIBLE,
  CASTS_SHADOW,
}

@(private)
NodeFlagSet :: bit_set[NodeFlag;u32]

@(private)
NodeData :: struct #packed {
  world_matrix:          matrix[4, 4]f32,
  material_id:           u32,
  mesh_id:               u32,
  attachment_data_index: u32,
  flags:                 NodeFlagSet,
}

@(private)
MeshData :: struct {
  aabb_min:        [3]f32,
  index_count:     u32,
  aabb_max:        [3]f32,
  first_index:     u32,
  vertex_offset:   i32,
  skinning_offset: u32,
  flags:           MeshFlagSet,
  vertex_count:    u32,
}

// A material, stored as the shaders read it. A texture index (texture_index)
// of NO_TEXTURE leaves that texture out.
Material :: struct {
  albedo_index:             u32,
  metallic_roughness_index: u32,
  normal_index:             u32,
  emissive_index:           u32,
  metallic_value:           f32,
  roughness_value:          f32,
  emissive_value:           f32,
  _:                        u32,
  base_color_factor:        [4]f32,
  // .SPRITE: sheet size in cells and the cell shown, row-major
  frame_columns:            u32,
  frame_rows:               u32,
  frame_index:              u32,
  type:                     MaterialType,
}

// Pipelines with a single variant; the material, light and post-process
// pipelines are indexed by their own enums.
@(private)
PipelineId :: enum {
  CULL,
  DEPTH_REDUCE,
  SHADOW_DEPTH,
  PARTICLE_EMIT,
  PARTICLE_SIMULATE,
  PARTICLE_DRAW,
  DEBUG_LINE,
  OVERLAY,
}

// Callers outside the render package use the fields listed here and the
// public procs; every other field is render's own state.
//   * meshes / materials / emitters / forcefields: resources, stored as the
//     shaders read them. Create and change them through the procs in
//     resources.odin; changes reach the GPU through staging.
//   * instances: per-slot looks (mesh, light, emitter, ...), indexed by
//     transform slot. A slot is whatever index the caller uses to identify a
//     transform; the engine uses world node indices.
//   * cameras: views with their GPU targets. `main_camera` is presented.
//   * builtin_meshes / builtin_materials: builtin primitives and solid
//     colors, created by init.
//   * ambient: environment lighting; write ibl_intensity, skybox_blur and
//     skybox_intensity (0 hides the skybox) directly.
//   * post_process: the effect stack; append to effect_stack, empty with
//     clear(&r.post_process.effect_stack).
// The microui debug context is reached through debug_ui (overlay.odin).
//
// Lifecycle, in pairs:
//   init / shutdown: device, swapchain, pipelines, pools.
//   setup / teardown: level resources (cameras, slots, textures).
// setup and teardown may be called any number of times between init and
// shutdown, from any point outside frame.
Manager :: struct {
  gctx:                    gpu.GPUContext,
  swapchain:               gpu.Swapchain,
  meshes:                  cont.Pool(MeshData),
  materials:               cont.Pool(Material),
  emitters:                cont.Pool(Emitter),
  forcefields:             cont.Pool(ForceField),
  instances:               [dynamic]Instance,
  builtin_materials:       [Color]MaterialHandle,
  builtin_meshes:          [Primitive]MeshHandle,
  cameras:                 cont.Pool(Camera),
  main_camera:             CameraHandle,
  // Single source of truth for active scene node count. Drives compute
  // dispatch sizing across visibility, depth pyramid, and both shadow culls.
  node_count:              u32,
  ambient:                 AmbientRenderer,
  post_process:            PostProcessRenderer,
  // ---------- render's own state ----------
  command_buffers:         [gpu.FRAMES_IN_FLIGHT]vk.CommandBuffer,
  compute_command_buffers: [gpu.FRAMES_IN_FLIGHT]vk.CommandBuffer,
  // Set by setup, cleared by teardown; frame renders nothing while false.
  level_ready:             bool,
  scene:                   SceneDescriptors,
  pipelines:               [PipelineId]vk.Pipeline,
  material_pipelines:      [MaterialType]vk.Pipeline,
  light_pipelines:         [LightType]vk.Pipeline,
  // bindless arrays: textures (level lifetime) and samplers
  textures:                cont.Pool(gpu.Image),
  samplers:                [SamplerType]vk.Sampler,
  // the mesh arena: shared vertex, index and skinning buffers
  mesh_buffers:            [MeshStream]gpu.Buffer,
  mesh_slabs:              [MeshStream]cont.SlabAllocator,
  // Scene storage buffers, bound together through `scene`: the per-frame
  // tables in one arena per frame in flight, and the mesh table.
  frame_arena:             [gpu.FRAMES_IN_FLIGHT]gpu.Buffer,
  arena_layout:            ArenaLayout,
  mesh_data_buffer:        gpu.Buffer,
  // the main camera's draw counts of each frame, copied back for stats
  draw_count_readback:     [gpu.FRAMES_IN_FLIGHT]gpu.Buffer,
  bone_matrix_slab:        cont.SlabAllocator,
  bones:                   map[u32]BonePalette,
  // one per pyramid slot: groups done this dispatch; the last one resets it
  pyramid_counters:        gpu.Buffer,
  // particles: the ring, the alive list (an indirect draw header followed by
  // one particle index per vertex) and this frame's simulation inputs
  particle_buffer:         gpu.Buffer,
  particle_alive_buffer:   gpu.Buffer,
  particle_params:         ParticleSystemParams,
  debug_line_renderer:     DebugLineRenderer,
  ui:                      OverlayRenderer,
  // This frame's lights per type, written by collect_lights in type order.
  light_count:             [LightType]u32,
  // holders of the shadow maps, selected by collect_lights
  shadow_casters:          [MAX_SHADOW_MAPS]Caster,
  // shadow views, one per atlas layer, the frame's shadow maps take
  // (pack_lights)
  shadow_view_count:       u32,
  shadow_atlas:            [gpu.FRAMES_IN_FLIGHT]ShadowAtlas,
  // the shadow views' shared draw list
  shadow_draws:            DrawLists,
  staging:                 Staging,
}

AttachmentType :: enum {
  FINAL_IMAGE        = 0,
  NORMAL             = 1,
  ALBEDO             = 2,
  METALLIC_ROUGHNESS = 3,
  EMISSIVE           = 4,
  DEPTH              = 5,
}

// The aspect ratio follows the camera's extent.
PerspectiveProjection :: struct {
  fov: f32,
}

OrthographicProjection :: struct {
  width:  f32,
  height: f32,
}

CameraProjection :: union {
  PerspectiveProjection,
  OrthographicProjection,
}

// A view into the scene: pose + projection, plus the GPU resources it renders
// into (attachments, indirect draw buffers, depth pyramid, descriptor sets)
Camera :: struct {
  position:                     [3]f32,
  rotation:                     quaternion128,
  projection:                   CameraProjection,
  // clip planes, shared by both projections
  near, far:                    f32,
  extent:                       [2]u32, // width, height
  attachments:                  [AttachmentType][gpu.FRAMES_IN_FLIGHT]TextureHandle,
  // One indirect draw list per MaterialType per frame in flight. Frame N's
  // culling writes the lists frame N+1 draws; frame N draws the lists frame
  // N-1's culling wrote.
  draws:                        DrawLists,
  depth_pyramid:                [gpu.FRAMES_IN_FLIGHT]DepthPyramid,
  // First frame serial whose compute work may read the camera's depth and
  // pyramids: the frame before it moved them out of UNDEFINED and rendered
  // depth. Until then the camera is culled without occlusion, and frames
  // before it draw none of its lists.
  ready_serial:                 u64,
}
