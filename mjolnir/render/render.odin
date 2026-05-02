package render

import alg "../algebra"
import cont "../containers"
import geom "../geometry"
import "../gpu"
import cmd "../gpu/ui"
import "../world"
import "ambient"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "debug_bone"
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
BoneInstance :: debug_bone.BoneInstance
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
ShadowMap :: struct {
  shadow_map_2d:   [FRAMES_IN_FLIGHT]gpu.Texture2DHandle,
  draw_commands:   [FRAMES_IN_FLIGHT]gpu.MutableBuffer(
    vk.DrawIndexedIndirectCommand,
  ),
  draw_count:      [FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  descriptor_sets: [FRAMES_IN_FLIGHT]vk.DescriptorSet,
}

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

DEBUG_SHOW_BONES :: #config(DEBUG_SHOW_BONES, false)
DEBUG_BONE_SCALE :: #config(DEBUG_BONE_SCALE, 0.15)
DEBUG_BONE_PALETTE :: [6][4]f32 {
  {1.0, 0.0, 0.0, 1.0}, // Level 0: Red (root bones)
  {0.0, 1.0, 0.0, 1.0}, // Level 1: Green
  {0.0, 0.0, 1.0, 1.0}, // Level 2: Blue
  {1.0, 1.0, 1.0, 1.0}, // Level 3: White
  {1.0, 0.5, 0.0, 1.0}, // Level 4: Orange
  {0.0, 1.0, 1.0, 1.0}, // Level 5: Cyan
}

// Internal owns GPU primitives and CPU-side bookkeeping. The engine package
// reaches into specific subrenderer fields (debug_renderer, ui, command
// buffers); external user code should not.
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
  debug_renderer:               debug_bone.Renderer,
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
  mesh_manager:    gpu.MeshManager,
  texture_manager: gpu.TextureManager,
  post_process:    post_process.Renderer,
  debug_ui:        debug_ui.Renderer,
}

init :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
  swapchain_extent: vk.Extent2D,
  swapchain_format: vk.Format,
  dpi_scale: f32,
) -> (
  ret: vk.Result,
) {
  self.cameras = make(map[u32]CameraTarget)
  self.internal.lights = make(map[u32]Light)
  self.internal.shadow_maps = make(map[u32]ShadowMap)
  self.internal.shadow_map_cubes = make(map[u32]ShadowMapCube)
  gpu.allocate_command_buffer(gctx, self.internal.command_buffers[:]) or_return
  defer if ret != .SUCCESS {
    gpu.free_command_buffer(gctx, ..self.internal.command_buffers[:])
  }
  if gctx.has_async_compute {
    gpu.allocate_compute_command_buffer(
      gctx,
      self.internal.compute_command_buffers[:],
    ) or_return
    defer if ret != .SUCCESS {
      gpu.free_compute_command_buffer(gctx, self.internal.compute_command_buffers[:])
    }
  }
  // Initialize geometry/bone/camera/scene buffers (survive teardown/setup cycles)
  gpu.mesh_manager_init(&self.mesh_manager, gctx)
  defer if ret != .SUCCESS {
    gpu.mesh_manager_shutdown(&self.mesh_manager, gctx)
  }
  cont.slab_init(
    &self.internal.bone_matrix_slab,
    {
      {32, 64},
      {64, 128},
      {128, 4096},
      {256, 1792},
      {512, 0},
      {1024, 0},
      {2048, 0},
      {4096, 0},
    },
  )
  gpu.per_frame_bindless_buffer_init(
    &self.internal.bone_buffer,
    gctx,
    int(self.internal.bone_matrix_slab.capacity),
    {.VERTEX},
  ) or_return
  self.internal.bone_matrix_offsets = make(map[u32]u32)
  defer if ret != .SUCCESS {
    delete(self.internal.bone_matrix_offsets)
    gpu.per_frame_bindless_buffer_destroy(&self.internal.bone_buffer, gctx.device)
    cont.slab_destroy(&self.internal.bone_matrix_slab)
  }
  gpu.per_frame_bindless_buffer_init(
    &self.internal.camera_buffer,
    gctx,
    MAX_ACTIVE_CAMERAS,
    {.VERTEX, .FRAGMENT, .COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.per_frame_bindless_buffer_destroy(&self.internal.camera_buffer, gctx.device)
  }
  gpu.bindless_buffer_init(
    &self.internal.material_buffer,
    gctx,
    MAX_MATERIALS,
    {.VERTEX, .FRAGMENT},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.internal.material_buffer, gctx.device)
  }
  gpu.bindless_buffer_init(
    &self.internal.node_data_buffer,
    gctx,
    MAX_NODES_IN_SCENE,
    {.VERTEX, .FRAGMENT, .COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.internal.node_data_buffer, gctx.device)
  }
  gpu.bindless_buffer_init(
    &self.internal.mesh_data_buffer,
    gctx,
    MAX_MESHES,
    {.VERTEX},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.internal.mesh_data_buffer, gctx.device)
  }
  gpu.bindless_buffer_init(
    &self.internal.emitter_buffer,
    gctx,
    MAX_EMITTERS,
    {.COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.internal.emitter_buffer, gctx.device)
  }
  gpu.bindless_buffer_init(
    &self.internal.forcefield_buffer,
    gctx,
    MAX_FORCE_FIELDS,
    {.COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.internal.forcefield_buffer, gctx.device)
  }
  gpu.bindless_buffer_init(
    &self.internal.sprite_buffer,
    gctx,
    MAX_SPRITES,
    {.VERTEX, .FRAGMENT},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.internal.sprite_buffer, gctx.device)
  }
  // Initialize texture manager layout (must precede pipeline layout creation)
  gpu.texture_manager_init(&self.texture_manager, gctx) or_return
  defer if ret != .SUCCESS {
    gpu.texture_manager_shutdown(&self.texture_manager, gctx)
  }
  info := vk.SamplerCreateInfo {
    sType        = .SAMPLER_CREATE_INFO,
    magFilter    = .LINEAR,
    minFilter    = .LINEAR,
    addressModeU = .REPEAT,
    addressModeV = .REPEAT,
    addressModeW = .REPEAT,
    mipmapMode   = .LINEAR,
    maxLod       = 1000,
  }
  vk.CreateSampler(
    gctx.device,
    &info,
    nil,
    &self.internal.linear_repeat_sampler,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroySampler(gctx.device, self.internal.linear_repeat_sampler, nil)
    self.internal.linear_repeat_sampler = 0
  }
  info.addressModeU, info.addressModeV, info.addressModeW =
    .CLAMP_TO_EDGE, .CLAMP_TO_EDGE, .CLAMP_TO_EDGE
  vk.CreateSampler(
    gctx.device,
    &info,
    nil,
    &self.internal.linear_clamp_sampler,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroySampler(gctx.device, self.internal.linear_clamp_sampler, nil)
    self.internal.linear_clamp_sampler = 0
  }
  info.magFilter, info.minFilter = .NEAREST, .NEAREST
  info.addressModeU, info.addressModeV, info.addressModeW =
    .REPEAT, .REPEAT, .REPEAT
  vk.CreateSampler(
    gctx.device,
    &info,
    nil,
    &self.internal.nearest_repeat_sampler,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroySampler(gctx.device, self.internal.nearest_repeat_sampler, nil)
    self.internal.nearest_repeat_sampler = 0
  }
  info.addressModeU, info.addressModeV, info.addressModeW =
    .CLAMP_TO_EDGE, .CLAMP_TO_EDGE, .CLAMP_TO_EDGE
  vk.CreateSampler(
    gctx.device,
    &info,
    nil,
    &self.internal.nearest_clamp_sampler,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroySampler(gctx.device, self.internal.nearest_clamp_sampler, nil)
    self.internal.nearest_clamp_sampler = 0
  }
  // Initialize all subsystems (pipeline creation only)
  shadow_include := transmute(u32)NodeFlagSet{.VISIBLE}
  shadow_exclude := transmute(u32)NodeFlagSet{
    .MATERIAL_TRANSPARENT,
    .MATERIAL_WIREFRAME,
    .MATERIAL_RANDOM_COLOR,
    .MATERIAL_LINE_STRIP,
  }
  occlusion_culling.init(&self.internal.visibility, gctx, MAX_NODES_IN_SCENE) or_return
  depth_pyramid_system.init(&self.internal.depth_pyramid, gctx) or_return
  shadow_culling_system.init(
    &self.internal.shadow_culling,
    gctx,
    MAX_NODES_IN_SCENE,
    shadow_include,
    shadow_exclude,
  ) or_return
  shadow_sphere_culling_system.init(
    &self.internal.shadow_sphere_culling,
    gctx,
    MAX_NODES_IN_SCENE,
    shadow_include,
    shadow_exclude,
  ) or_return
  shadow_render_system.init(
    &self.internal.shadow_render,
    gctx,
    self.texture_manager.set_layout,
    self.internal.bone_buffer.set_layout,
    self.internal.material_buffer.set_layout,
    self.internal.node_data_buffer.set_layout,
    self.internal.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
    MAX_NODES_IN_SCENE,
    SHADOW_MAP_SIZE,
  ) or_return
  shadow_sphere_render_system.init(
    &self.internal.shadow_sphere_render,
    gctx,
    self.texture_manager.set_layout,
    self.internal.bone_buffer.set_layout,
    self.internal.material_buffer.set_layout,
    self.internal.node_data_buffer.set_layout,
    self.internal.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
    MAX_NODES_IN_SCENE,
    SHADOW_MAP_SIZE,
  ) or_return
  ambient.init(
    &self.internal.ambient,
    gctx,
    self.internal.camera_buffer.set_layout,
    self.texture_manager.set_layout,
  ) or_return
  direct_light.init(
    &self.internal.direct_light,
    gctx,
    self.internal.camera_buffer.set_layout,
    self.texture_manager.set_layout,
  ) or_return
  geometry.init(
    &self.internal.geometry,
    gctx,
    self.internal.camera_buffer.set_layout,
    self.texture_manager.set_layout,
    self.internal.bone_buffer.set_layout,
    self.internal.material_buffer.set_layout,
    self.internal.node_data_buffer.set_layout,
    self.internal.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
  ) or_return
  particles_compute.init(
    &self.internal.particles_compute,
    gctx,
    self.internal.emitter_buffer.set_layout,
    self.internal.forcefield_buffer.set_layout,
    self.internal.node_data_buffer.set_layout,
  ) or_return
  particles_render.init(
    &self.internal.particles_render,
    gctx,
    &self.texture_manager,
    self.internal.camera_buffer.set_layout,
    self.texture_manager.set_layout,
  ) or_return
  // Initialize transparency renderers
  transparent.init(
    &self.internal.transparent_renderer,
    gctx,
    self.internal.camera_buffer.set_layout,
    self.texture_manager.set_layout,
    self.internal.bone_buffer.set_layout,
    self.internal.material_buffer.set_layout,
    self.internal.node_data_buffer.set_layout,
    self.internal.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
  ) or_return
  sprite.init(
    &self.internal.sprite_renderer,
    gctx,
    self.internal.camera_buffer.set_layout,
    self.texture_manager.set_layout,
    self.internal.node_data_buffer.set_layout,
    self.internal.sprite_buffer.set_layout,
  ) or_return
  wireframe.init(
    &self.internal.wireframe_renderer,
    gctx,
    self.internal.camera_buffer.set_layout,
    self.texture_manager.set_layout,
    self.internal.bone_buffer.set_layout,
    self.internal.material_buffer.set_layout,
    self.internal.node_data_buffer.set_layout,
    self.internal.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
  ) or_return
  line_strip.init(
    &self.internal.line_strip_renderer,
    gctx,
    self.internal.camera_buffer.set_layout,
    self.texture_manager.set_layout,
    self.internal.bone_buffer.set_layout,
    self.internal.material_buffer.set_layout,
    self.internal.node_data_buffer.set_layout,
    self.internal.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
  ) or_return
  random_color.init(
    &self.internal.random_color_renderer,
    gctx,
    self.internal.camera_buffer.set_layout,
    self.texture_manager.set_layout,
    self.internal.bone_buffer.set_layout,
    self.internal.material_buffer.set_layout,
    self.internal.node_data_buffer.set_layout,
    self.internal.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
  ) or_return
  post_process.init(
    &self.post_process,
    gctx,
    swapchain_format,
    self.texture_manager.set_layout,
  ) or_return
  debug_ui.init(
    &self.debug_ui,
    gctx,
    swapchain_format,
    swapchain_extent,
    dpi_scale,
    self.texture_manager.set_layout,
  ) or_return
  debug_bone.init(
    &self.internal.debug_renderer,
    gctx,
    self.internal.camera_buffer.set_layout,
  ) or_return
  ui_render.init(
    &self.internal.ui,
    gctx,
    self.texture_manager.set_layout,
    swapchain_format,
  ) or_return
  return .SUCCESS
}

setup :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
  swapchain_extent: vk.Extent2D,
  swapchain_format: vk.Format,
) -> (
  ret: vk.Result,
) {
  // Allocate textures descriptor set and init texture pools
  gpu.texture_manager_setup(
    &self.texture_manager,
    gctx,
    {
      self.internal.nearest_clamp_sampler,
      self.internal.linear_clamp_sampler,
      self.internal.nearest_repeat_sampler,
      self.internal.linear_repeat_sampler,
    },
  ) or_return
  defer if ret != .SUCCESS {
    gpu.texture_manager_teardown(&self.texture_manager, gctx)
  }
  // Re-allocate descriptor sets for scene buffers (freed by previous ResetDescriptorPool)
  gpu.bindless_buffer_realloc_descriptor(&self.internal.material_buffer, gctx) or_return
  gpu.bindless_buffer_realloc_descriptor(
    &self.internal.node_data_buffer,
    gctx,
  ) or_return
  gpu.bindless_buffer_realloc_descriptor(
    &self.internal.mesh_data_buffer,
    gctx,
  ) or_return
  gpu.bindless_buffer_realloc_descriptor(&self.internal.emitter_buffer, gctx) or_return
  gpu.bindless_buffer_realloc_descriptor(
    &self.internal.forcefield_buffer,
    gctx,
  ) or_return
  gpu.bindless_buffer_realloc_descriptor(&self.internal.sprite_buffer, gctx) or_return
  gpu.per_frame_bindless_buffer_realloc_descriptors(
    &self.internal.bone_buffer,
    gctx,
  ) or_return
  gpu.per_frame_bindless_buffer_realloc_descriptors(
    &self.internal.camera_buffer,
    gctx,
  ) or_return
  gpu.mesh_manager_realloc_descriptors(&self.mesh_manager, gctx) or_return
  // Setup subsystem GPU resources
  ambient.setup(&self.internal.ambient, gctx, &self.texture_manager) or_return
  direct_light.setup(&self.internal.direct_light, gctx) or_return
  particles_compute.setup(
    &self.internal.particles_compute,
    gctx,
    self.internal.emitter_buffer.descriptor_set,
    self.internal.forcefield_buffer.descriptor_set,
  ) or_return
  post_process.setup(
    &self.post_process,
    gctx,
    &self.texture_manager,
    swapchain_extent,
    swapchain_format,
  ) or_return
  debug_ui.setup(&self.debug_ui, gctx, &self.texture_manager) or_return
  ui_render.setup(&self.internal.ui, gctx) or_return
  return .SUCCESS
}

teardown :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  // Destroy camera GPU resources (VkImages, draw command buffers) before texture_manager goes away
  for _, &cam in self.cameras {
    camera_destroy(gctx, &cam, &self.texture_manager)
  }
  clear(&self.cameras)
  for light_node_index, light in self.internal.lights {
    switch variant in light {
    case PointLight:
      release_shadow_cube(self, gctx, light_node_index)
    case SpotLight:
      release_shadow_2d(self, gctx, light_node_index)
    case DirectionalLight:
      release_shadow_2d(self, gctx, light_node_index)
    }
  }
  clear(&self.internal.lights)
  ui_render.teardown(&self.internal.ui, gctx)
  debug_ui.teardown(&self.debug_ui, gctx, &self.texture_manager)
  post_process.teardown(&self.post_process, gctx, &self.texture_manager)
  particles_compute.teardown(&self.internal.particles_compute, gctx)
  ambient.teardown(&self.internal.ambient, gctx, &self.texture_manager)
  direct_light.teardown(&self.internal.direct_light, gctx)
  gpu.texture_manager_teardown(&self.texture_manager, gctx)
  // Zero all descriptor set handles (freed in bulk below)
  self.internal.material_buffer.descriptor_set = 0
  self.internal.node_data_buffer.descriptor_set = 0
  self.internal.mesh_data_buffer.descriptor_set = 0
  self.internal.emitter_buffer.descriptor_set = 0
  self.internal.forcefield_buffer.descriptor_set = 0
  self.internal.sprite_buffer.descriptor_set = 0
  for &ds in self.internal.bone_buffer.descriptor_sets do ds = 0
  for &ds in self.internal.camera_buffer.descriptor_sets do ds = 0
  self.mesh_manager.vertex_skinning_buffer.descriptor_set = 0
  // Bulk-free all descriptor sets allocated from the pool
  vk.ResetDescriptorPool(gctx.device, gctx.descriptor_pool, {})
}

@(private)
record_compute_commands :: proc(
  self: ^Manager,
  frame_index: u32,
  gctx: ^gpu.GPUContext,
  cull_camera_indices: []u32,
) -> vk.Result {
  cmd :=
    gctx.has_async_compute ? self.internal.compute_command_buffers[frame_index] : self.internal.command_buffers[frame_index]
  // Compute for frame N prepares data for frame N+1
  // Buffer indices with FRAMES_IN_FLIGHT=2: frame N uses buffer [N], produces data for buffer [N+1]
  next_frame_index := frame_next(frame_index)
  for cam_index in cull_camera_indices {
    cam, ok := &self.cameras[cam_index]
    if !ok do continue
    depth_pyramid_system.build_pyramid(
      &self.internal.depth_pyramid,
      cmd,
      &cam.depth_pyramid[frame_index],
      cam.depth_reduce_descriptor_sets[frame_index][:],
    ) // Build pyramid[N]
    prev_frame := frame_prev(next_frame_index)
    occlusion_culling.perform_culling(
      &self.internal.visibility,
      cmd,
      cam_index,
      next_frame_index,
      &cam.draws,
      cam.descriptor_set[next_frame_index],
      cam.depth_pyramid[prev_frame].width,
      cam.depth_pyramid[prev_frame].height,
    ) // Write draw_list[N+1]
  }
  particles_compute.simulate(
    &self.internal.particles_compute,
    cmd,
    self.internal.node_data_buffer.descriptor_set,
  )
  return .SUCCESS
}

// set_node_count distributes the node count across every culling subsystem
// that needs it for compute dispatch sizing. Caller (engine) is the single
// source of truth.
set_node_count :: proc(self: ^Manager, node_count: u32) {
  n := min(node_count, self.internal.visibility.max_draws)
  self.internal.visibility.node_count = n
  self.internal.depth_pyramid.node_count = n
  self.internal.shadow_culling.node_count = n
  self.internal.shadow_sphere_culling.node_count = n
}

set_particle_params :: proc(
  self: ^Manager,
  params: particles_compute.ParticleSystemParams,
) {
  assert(
    params.emitter_count <= MAX_EMITTERS,
    "emitter_count exceeds MAX_EMITTERS",
  )
  assert(
    params.forcefield_count <= MAX_FORCE_FIELDS,
    "forcefield_count exceeds MAX_FORCE_FIELDS",
  )
  assert(
    params.particle_count <= particles_compute.MAX_PARTICLES,
    "particle_count exceeds MAX_PARTICLES",
  )
  assert(params.delta_time >= 0.0, "delta_time must be non-negative")
  ptr := gpu.get(&self.internal.particles_compute.params_buffer, 0)
  ptr^ = params
}

shutdown :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  gpu.free_command_buffer(gctx, ..self.internal.command_buffers[:])
  if gctx.has_async_compute {
    gpu.free_compute_command_buffer(gctx, self.internal.compute_command_buffers[:])
  }
  ui_render.shutdown(&self.internal.ui, gctx)
  debug_bone.shutdown(&self.internal.debug_renderer, gctx)
  debug_ui.shutdown(&self.debug_ui, gctx)
  post_process.shutdown(&self.post_process, gctx)
  particles_compute.shutdown(&self.internal.particles_compute, gctx)
  particles_render.shutdown(&self.internal.particles_render, gctx)
  // Cleanup transparency renderers
  transparent.shutdown(&self.internal.transparent_renderer, gctx)
  sprite.shutdown(&self.internal.sprite_renderer, gctx)
  wireframe.shutdown(&self.internal.wireframe_renderer, gctx)
  line_strip.shutdown(&self.internal.line_strip_renderer, gctx)
  random_color.shutdown(&self.internal.random_color_renderer, gctx)
  ambient.shutdown(&self.internal.ambient, gctx)
  direct_light.shutdown(&self.internal.direct_light, gctx)
  shadow_sphere_render_system.shutdown(&self.internal.shadow_sphere_render, gctx)
  shadow_render_system.shutdown(&self.internal.shadow_render, gctx)
  shadow_sphere_culling_system.shutdown(&self.internal.shadow_sphere_culling, gctx)
  shadow_culling_system.shutdown(&self.internal.shadow_culling, gctx)
  geometry.shutdown(&self.internal.geometry, gctx)
  depth_pyramid_system.shutdown(&self.internal.depth_pyramid, gctx)
  occlusion_culling.shutdown(&self.internal.visibility, gctx)
  vk.DestroySampler(gctx.device, self.internal.linear_repeat_sampler, nil)
  self.internal.linear_repeat_sampler = 0
  vk.DestroySampler(gctx.device, self.internal.linear_clamp_sampler, nil)
  self.internal.linear_clamp_sampler = 0
  vk.DestroySampler(gctx.device, self.internal.nearest_repeat_sampler, nil)
  self.internal.nearest_repeat_sampler = 0
  vk.DestroySampler(gctx.device, self.internal.nearest_clamp_sampler, nil)
  self.internal.nearest_clamp_sampler = 0
  gpu.texture_manager_shutdown(&self.texture_manager, gctx)
  gpu.bindless_buffer_destroy(&self.internal.material_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.internal.node_data_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.internal.mesh_data_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.internal.emitter_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.internal.forcefield_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.internal.sprite_buffer, gctx.device)
  gpu.per_frame_bindless_buffer_destroy(&self.internal.camera_buffer, gctx.device)
  delete(self.internal.bone_matrix_offsets)
  gpu.per_frame_bindless_buffer_destroy(&self.internal.bone_buffer, gctx.device)
  cont.slab_destroy(&self.internal.bone_matrix_slab)
  gpu.mesh_manager_shutdown(&self.mesh_manager, gctx)
  delete(self.cameras)
  delete(self.internal.lights)
  delete(self.internal.shadow_maps)
  delete(self.internal.shadow_map_cubes)
}

resize :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
  extent: vk.Extent2D,
  color_format: vk.Format,
  dpi_scale: f32,
) -> vk.Result {
  post_process.recreate_images(
    gctx,
    &self.post_process,
    &self.texture_manager,
    extent,
    color_format,
  ) or_return
  debug_ui.recreate_images(&self.debug_ui, color_format, extent, dpi_scale)
  return .SUCCESS
}

@(private)
shadow_safe_normalize :: proc(v: [3]f32, fallback: [3]f32) -> [3]f32 {
  len_sq := linalg.dot(v, v)
  if len_sq < 1e-6 do return fallback
  return linalg.normalize(v)
}

@(private)
shadow_make_light_view :: proc(
  position, direction: [3]f32,
) -> matrix[4, 4]f32 {
  forward := shadow_safe_normalize(direction, {0, -1, 0})
  up := [3]f32{0, 1, 0}
  if math.abs(linalg.dot(forward, up)) > 0.95 {
    up = {0, 0, 1}
  }
  target := position + forward
  return linalg.matrix4_look_at(position, target, up)
}

@(private)
shadow_matrices_spot :: proc(
  light: SpotLight,
) -> (
  view, projection: matrix[4, 4]f32,
  near, far: f32,
) {
  near = 0.1
  far = max(near + 0.1, light.radius)
  view = shadow_make_light_view(light.position, light.direction)
  fovy := max(light.angle_outer * 2.0, 0.001)
  projection = geom.make_perspective_matrix(fovy, 1.0, near, far)
  return
}

@(private)
shadow_matrices_directional :: proc(
  light: DirectionalLight,
) -> (
  view, projection: matrix[4, 4]f32,
  near, far: f32,
) {
  near = 0.1
  far = max(near + 0.1, light.radius * 2.0)
  camera_pos := light.position - light.direction * light.radius
  view = shadow_make_light_view(camera_pos, light.direction)
  half_extent := max(light.radius, 0.5)
  projection = geom.make_ortho_matrix(
    -half_extent,
    half_extent,
    -half_extent,
    half_extent,
    near,
    far,
  )
  return
}

@(private)
shadow_projection_point :: proc(
  light: PointLight,
) -> (
  projection: matrix[4, 4]f32,
  near, far: f32,
) {
  near = 0.1
  far = max(near + 0.1, light.radius)
  projection = linalg.matrix4_perspective(
    f32(math.PI * 0.5),
    1.0,
    near,
    far,
    flip_z_axis = false,
  )
  return
}

@(private)
render_shadow_depth :: proc(self: ^Manager, frame_index: u32) -> vk.Result {
  cmd := self.internal.command_buffers[frame_index]
  light_node_indices := make(
    [dynamic]u32,
    0,
    len(self.internal.lights),
    context.temp_allocator,
  )
  defer delete(light_node_indices)
  for light_node_index in self.internal.lights {
    append(&light_node_indices, light_node_index)
  }
  slice.sort(light_node_indices[:])
  for i in 0 ..< min(len(light_node_indices), int(MAX_LIGHTS)) {
    light_node_index := light_node_indices[i]
    light := self.internal.lights[light_node_index]
    switch variant in light {
    case SpotLight:
      shadow, has_shadow := &self.internal.shadow_maps[light_node_index]
      if !has_shadow do continue
      view, projection, _, _ := shadow_matrices_spot(variant)
      view_projection := projection * view
      frustum_planes := geom.make_frustum(view_projection).planes
      shadow_culling_system.execute(
        &self.internal.shadow_culling,
        cmd,
        frustum_planes,
        shadow.draw_count[frame_index].buffer,
        shadow.descriptor_sets[frame_index],
      )
      shadow_render_system.render(
        &self.internal.shadow_render,
        cmd,
        &self.texture_manager,
        view_projection,
        shadow.shadow_map_2d[frame_index],
        shadow.draw_commands[frame_index],
        shadow.draw_count[frame_index],
        self.texture_manager.descriptor_set,
        self.internal.bone_buffer.descriptor_sets[frame_index],
        self.internal.material_buffer.descriptor_set,
        self.internal.node_data_buffer.descriptor_set,
        self.internal.mesh_data_buffer.descriptor_set,
        self.mesh_manager.vertex_skinning_buffer.descriptor_set,
        self.mesh_manager.vertex_buffer.buffer,
        self.mesh_manager.index_buffer.buffer,
        frame_index,
      )
    case DirectionalLight:
      shadow, has_shadow := &self.internal.shadow_maps[light_node_index]
      if !has_shadow do continue
      view, projection, _, _ := shadow_matrices_directional(variant)
      view_projection := projection * view
      frustum_planes := geom.make_frustum(view_projection).planes
      shadow_culling_system.execute(
        &self.internal.shadow_culling,
        cmd,
        frustum_planes,
        shadow.draw_count[frame_index].buffer,
        shadow.descriptor_sets[frame_index],
      )
      shadow_render_system.render(
        &self.internal.shadow_render,
        cmd,
        &self.texture_manager,
        view_projection,
        shadow.shadow_map_2d[frame_index],
        shadow.draw_commands[frame_index],
        shadow.draw_count[frame_index],
        self.texture_manager.descriptor_set,
        self.internal.bone_buffer.descriptor_sets[frame_index],
        self.internal.material_buffer.descriptor_set,
        self.internal.node_data_buffer.descriptor_set,
        self.internal.mesh_data_buffer.descriptor_set,
        self.mesh_manager.vertex_skinning_buffer.descriptor_set,
        self.mesh_manager.vertex_buffer.buffer,
        self.mesh_manager.index_buffer.buffer,
        frame_index,
      )
    case PointLight:
      shadow, has_shadow := &self.internal.shadow_map_cubes[light_node_index]
      if !has_shadow do continue
      projection, near, far := shadow_projection_point(variant)
      shadow_sphere_culling_system.execute(
        &self.internal.shadow_sphere_culling,
        cmd,
        variant.position,
        variant.radius,
        shadow.draw_count[frame_index].buffer,
        shadow.descriptor_sets[frame_index],
      )
      shadow_sphere_render_system.render(
        &self.internal.shadow_sphere_render,
        cmd,
        &self.texture_manager,
        projection,
        near,
        far,
        variant.position,
        shadow.shadow_map_cube[frame_index],
        shadow.draw_commands[frame_index],
        shadow.draw_count[frame_index],
        self.texture_manager.descriptor_set,
        self.internal.bone_buffer.descriptor_sets[frame_index],
        self.internal.material_buffer.descriptor_set,
        self.internal.node_data_buffer.descriptor_set,
        self.internal.mesh_data_buffer.descriptor_set,
        self.mesh_manager.vertex_skinning_buffer.descriptor_set,
        self.mesh_manager.vertex_buffer.buffer,
        self.mesh_manager.index_buffer.buffer,
        frame_index,
      )
    }
  }
  return .SUCCESS
}

@(private)
record_geometry_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  cam_index: u32,
  cam: ^CameraTarget,
  enabled_passes: PassTypeSet,
) -> vk.Result {
  if .GEOMETRY not_in enabled_passes do return .SUCCESS
  geometry.record(
    &self.internal.geometry,
    cam_index,
    self.internal.command_buffers[frame_index],
    &self.texture_manager,
    cam.attachments[.POSITION][frame_index],
    cam.attachments[.NORMAL][frame_index],
    cam.attachments[.ALBEDO][frame_index],
    cam.attachments[.METALLIC_ROUGHNESS][frame_index],
    cam.attachments[.EMISSIVE][frame_index],
    cam.attachments[.FINAL_IMAGE][frame_index],
    cam.attachments[.DEPTH][frame_index],
    self.internal.camera_buffer.descriptor_sets[frame_index],
    self.texture_manager.descriptor_set,
    self.internal.bone_buffer.descriptor_sets[frame_index],
    self.internal.material_buffer.descriptor_set,
    self.internal.node_data_buffer.descriptor_set,
    self.internal.mesh_data_buffer.descriptor_set,
    self.mesh_manager.vertex_skinning_buffer.descriptor_set,
    self.mesh_manager.vertex_buffer.buffer,
    self.mesh_manager.index_buffer.buffer,
    cam.draws[.OPAQUE].commands[frame_index].buffer,
    cam.draws[.OPAQUE].count[frame_index].buffer,
    MAX_NODES_IN_SCENE,
  )
  return .SUCCESS
}

@(private)
record_lighting_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  cam_index: u32,
  cam: ^CameraTarget,
  enabled_passes: PassTypeSet,
) -> vk.Result {
  if .LIGHTING not_in enabled_passes do return .SUCCESS
  cmd := self.internal.command_buffers[frame_index]
  ambient.record(
    &self.internal.ambient,
    cam_index,
    cmd,
    &self.texture_manager,
    cam.attachments[.FINAL_IMAGE][frame_index],
    self.internal.camera_buffer.descriptor_sets[frame_index],
    cam.attachments[.POSITION][frame_index].index,
    cam.attachments[.NORMAL][frame_index].index,
    cam.attachments[.ALBEDO][frame_index].index,
    cam.attachments[.METALLIC_ROUGHNESS][frame_index].index,
    cam.attachments[.EMISSIVE][frame_index].index,
  )
  direct_light.begin_pass(
    &self.internal.direct_light,
    cam.attachments[.FINAL_IMAGE][frame_index],
    cam.attachments[.DEPTH][frame_index],
    &self.texture_manager,
    cmd,
    self.internal.camera_buffer.descriptor_sets[frame_index],
  )
  light_node_indices := make(
    [dynamic]u32,
    0,
    len(self.internal.lights),
    context.temp_allocator,
  )
  defer delete(light_node_indices)
  for light_node_index in self.internal.lights {
    append(&light_node_indices, light_node_index)
  }
  slice.sort(light_node_indices[:])
  for i in 0 ..< min(len(light_node_indices), int(MAX_LIGHTS)) {
    light_node_index := light_node_indices[i]
    light := self.internal.lights[light_node_index]
    switch variant in light {
    case PointLight:
      shadow_map_idx: u32 = 0xFFFFFFFF
      shadow_view_projection := matrix[4, 4]f32{}
      if sm, ok := self.internal.shadow_map_cubes[light_node_index]; ok {
        shadow_map_idx = sm.shadow_map_cube[frame_index].index
        projection, _, _ := shadow_projection_point(variant)
        shadow_view_projection = projection
      }
      direct_light.render_point_light(
        &self.internal.direct_light,
        cam_index,
        cam.attachments[.POSITION][frame_index].index,
        cam.attachments[.NORMAL][frame_index].index,
        cam.attachments[.ALBEDO][frame_index].index,
        cam.attachments[.METALLIC_ROUGHNESS][frame_index].index,
        variant.color,
        variant.position,
        variant.radius,
        shadow_map_idx,
        shadow_view_projection,
        cmd,
      )
    case SpotLight:
      shadow_map_idx: u32 = 0xFFFFFFFF
      shadow_view_projection := matrix[4, 4]f32{}
      if sm, ok := self.internal.shadow_maps[light_node_index]; ok {
        shadow_map_idx = sm.shadow_map_2d[frame_index].index
        view, projection, _, _ := shadow_matrices_spot(variant)
        shadow_view_projection = projection * view
      }
      direct_light.render_spot_light(
        &self.internal.direct_light,
        cam_index,
        cam.attachments[.POSITION][frame_index].index,
        cam.attachments[.NORMAL][frame_index].index,
        cam.attachments[.ALBEDO][frame_index].index,
        cam.attachments[.METALLIC_ROUGHNESS][frame_index].index,
        variant.color,
        variant.position,
        variant.direction,
        variant.radius,
        variant.angle_inner,
        variant.angle_outer,
        shadow_map_idx,
        shadow_view_projection,
        cmd,
      )
    case DirectionalLight:
      shadow_map_idx: u32 = 0xFFFFFFFF
      shadow_view_projection := matrix[4, 4]f32{}
      if sm, ok := self.internal.shadow_maps[light_node_index]; ok {
        shadow_map_idx = sm.shadow_map_2d[frame_index].index
        view, projection, _, _ := shadow_matrices_directional(variant)
        shadow_view_projection = projection * view
      }
      direct_light.render_directional_light(
        &self.internal.direct_light,
        cam_index,
        cam.attachments[.POSITION][frame_index].index,
        cam.attachments[.NORMAL][frame_index].index,
        cam.attachments[.ALBEDO][frame_index].index,
        cam.attachments[.METALLIC_ROUGHNESS][frame_index].index,
        variant.color,
        variant.direction,
        shadow_map_idx,
        shadow_view_projection,
        cmd,
      )
    }
  }
  direct_light.end_pass(cmd)
  return .SUCCESS
}

@(private)
record_particles_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  cam_index: u32,
  cam: ^CameraTarget,
  enabled_passes: PassTypeSet,
) -> vk.Result {
  if .PARTICLES not_in enabled_passes do return .SUCCESS
  particles_render.record(
    &self.internal.particles_render,
    self.internal.command_buffers[frame_index],
    cam_index,
    cam.attachments[.FINAL_IMAGE][frame_index],
    cam.attachments[.DEPTH][frame_index],
    &self.texture_manager,
    self.internal.camera_buffer.descriptor_sets[frame_index],
    self.texture_manager.descriptor_set,
    self.internal.particles_compute.compact_particle_buffer.buffer,
    self.internal.particles_compute.draw_command_buffer.buffer,
  )
  return .SUCCESS
}

@(private)
record_transparency_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  gctx: ^gpu.GPUContext,
  cam_index: u32,
  cam: ^CameraTarget,
  enabled_passes: PassTypeSet,
) -> vk.Result {
  if .TRANSPARENCY not_in enabled_passes do return .SUCCESS
  cmd := self.internal.command_buffers[frame_index]

  // Open a single render scope shared by all 5 sub-passes (transparent /
  // wireframe / random_color / line_strip / sprite). Each sub-pass owns its
  // own draw-buffer barriers (see transparent.record etc.).
  color_texture := gpu.get_texture_2d(
    &self.texture_manager,
    cam.attachments[.FINAL_IMAGE][frame_index],
  )
  depth_texture := gpu.get_texture_2d(
    &self.texture_manager,
    cam.attachments[.DEPTH][frame_index],
  )
  gpu.begin_rendering(
    cmd,
    depth_texture.spec.extent,
    gpu.create_depth_attachment(depth_texture, .LOAD, .STORE),
    gpu.create_color_attachment(color_texture, .LOAD, .STORE),
  )
  gpu.set_viewport_scissor(cmd, depth_texture.spec.extent)

  camera_set := self.internal.camera_buffer.descriptor_sets[frame_index]
  textures_set := self.texture_manager.descriptor_set
  bone_set := self.internal.bone_buffer.descriptor_sets[frame_index]
  material_set := self.internal.material_buffer.descriptor_set
  node_data_set := self.internal.node_data_buffer.descriptor_set
  mesh_data_set := self.internal.mesh_data_buffer.descriptor_set
  skinning_set := self.mesh_manager.vertex_skinning_buffer.descriptor_set
  vbuf := self.mesh_manager.vertex_buffer.buffer
  ibuf := self.mesh_manager.index_buffer.buffer

  transparent.record(
    &self.internal.transparent_renderer,
    cmd, cam_index,
    camera_set, textures_set, bone_set, material_set,
    node_data_set, mesh_data_set, skinning_set,
    vbuf, ibuf,
    &cam.draws[.TRANSPARENT].commands[frame_index],
    &cam.draws[.TRANSPARENT].count[frame_index],
    MAX_NODES_IN_SCENE,
  )
  if .WIREFRAME in enabled_passes {
    wireframe.record(
      &self.internal.wireframe_renderer,
      cmd, cam_index,
      camera_set, textures_set, bone_set, material_set,
      node_data_set, mesh_data_set, skinning_set,
      vbuf, ibuf,
      &cam.draws[.WIREFRAME].commands[frame_index],
      &cam.draws[.WIREFRAME].count[frame_index],
      MAX_NODES_IN_SCENE,
    )
  }
  if .RANDOM_COLOR in enabled_passes {
    random_color.record(
      &self.internal.random_color_renderer,
      cmd, cam_index,
      camera_set, textures_set, bone_set, material_set,
      node_data_set, mesh_data_set, skinning_set,
      vbuf, ibuf,
      &cam.draws[.RANDOM_COLOR].commands[frame_index],
      &cam.draws[.RANDOM_COLOR].count[frame_index],
      MAX_NODES_IN_SCENE,
    )
  }
  if .LINE_STRIP in enabled_passes {
    line_strip.record(
      &self.internal.line_strip_renderer,
      cmd, cam_index,
      camera_set, textures_set, bone_set, material_set,
      node_data_set, mesh_data_set, skinning_set,
      vbuf, ibuf,
      &cam.draws[.LINE_STRIP].commands[frame_index],
      &cam.draws[.LINE_STRIP].count[frame_index],
      MAX_NODES_IN_SCENE,
    )
  }
  if .SPRITE in enabled_passes {
    sprite.record(
      &self.internal.sprite_renderer,
      cmd, cam_index,
      camera_set, textures_set, node_data_set,
      self.internal.sprite_buffer.descriptor_set,
      vbuf, ibuf,
      &cam.draws[.SPRITE].commands[frame_index],
      &cam.draws[.SPRITE].count[frame_index],
      MAX_NODES_IN_SCENE,
    )
  }

  vk.CmdEndRendering(cmd)
  return .SUCCESS
}

@(private)
record_debug_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  cam_index: u32,
  cam: ^CameraTarget,
  enabled_passes: PassTypeSet,
) -> vk.Result {
  if .DEBUG_BONE not_in enabled_passes do return .SUCCESS
  return debug_bone.record(
    &self.internal.debug_renderer,
    self.internal.command_buffers[frame_index],
    cam.attachments[.FINAL_IMAGE][frame_index],
    cam.attachments[.DEPTH][frame_index],
    &self.texture_manager,
    self.internal.camera_buffer.descriptor_sets[frame_index],
    cam_index,
  )
}

@(private)
record_post_process_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  cam: ^CameraTarget,
  swapchain_extent: vk.Extent2D,
  swapchain_image: vk.Image,
  swapchain_view: vk.ImageView,
  enabled_passes: PassTypeSet,
) -> vk.Result {
  if .POST_PROCESS not_in enabled_passes do return .SUCCESS
  cmd := self.internal.command_buffers[frame_index]
  if final_image := gpu.get_texture_2d(
    &self.texture_manager,
    cam.attachments[.FINAL_IMAGE][frame_index],
  ); final_image != nil {
    gpu.image_barrier(
      cmd,
      final_image.image,
      .COLOR_ATTACHMENT_OPTIMAL,
      .SHADER_READ_ONLY_OPTIMAL,
      {.COLOR_ATTACHMENT_WRITE},
      {.SHADER_READ},
      {.COLOR_ATTACHMENT_OUTPUT},
      {.FRAGMENT_SHADER},
      {.COLOR},
    )
  }
  gpu.image_barrier(
    cmd,
    swapchain_image,
    .UNDEFINED,
    .COLOR_ATTACHMENT_OPTIMAL,
    {},
    {.COLOR_ATTACHMENT_WRITE},
    {.TOP_OF_PIPE},
    {.COLOR_ATTACHMENT_OUTPUT},
    {.COLOR},
  )
  post_process.record(
    &self.post_process,
    cmd,
    swapchain_extent,
    swapchain_view,
    cam.attachments[.FINAL_IMAGE][frame_index].index,
    cam.attachments[.POSITION][frame_index].index,
    cam.attachments[.NORMAL][frame_index].index,
    cam.attachments[.ALBEDO][frame_index].index,
    cam.attachments[.METALLIC_ROUGHNESS][frame_index].index,
    cam.attachments[.EMISSIVE][frame_index].index,
    cam.attachments[.DEPTH][frame_index].index,
    &self.texture_manager,
  )
  return .SUCCESS
}

@(private)
record_ui_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  gctx: ^gpu.GPUContext,
  swapchain_view: vk.ImageView,
  swapchain_extent: vk.Extent2D,
  enabled_passes: PassTypeSet,
) {
  if .UI not_in enabled_passes do return
  cmd := self.internal.command_buffers[frame_index]
  // UI rendering pass - renders on top of post-processed image
  rendering_attachment_info := vk.RenderingAttachmentInfo {
    sType       = .RENDERING_ATTACHMENT_INFO,
    imageView   = swapchain_view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp      = .LOAD,
    storeOp     = .STORE,
  }

  rendering_info := vk.RenderingInfo {
    sType = .RENDERING_INFO,
    renderArea = {extent = swapchain_extent},
    layerCount = 1,
    colorAttachmentCount = 1,
    pColorAttachments = &rendering_attachment_info,
  }

  vk.CmdBeginRendering(cmd, &rendering_info)

  // Set viewport and scissor
  viewport := vk.Viewport {
    x        = 0,
    y        = f32(swapchain_extent.height),
    width    = f32(swapchain_extent.width),
    height   = -f32(swapchain_extent.height),
    minDepth = 0.0,
    maxDepth = 1.0,
  }
  scissor := vk.Rect2D {
    offset = {0, 0},
    extent = swapchain_extent,
  }
  vk.CmdSetViewport(cmd, 0, 1, &viewport)
  vk.CmdSetScissor(cmd, 0, 1, &scissor)

  ui_render.render(
    &self.internal.ui,
    gctx,
    &self.texture_manager,
    cmd,
    swapchain_extent.width,
    swapchain_extent.height,
    frame_index,
  )

  vk.CmdEndRendering(cmd)
}

// CameraFrameConfig bundles per-camera flags for one frame. Built by the
// caller from world.Camera; rendering does not store these.
CameraFrameConfig :: struct {
  index:          u32,
  enabled_passes: PassTypeSet,
  enable_culling: bool,
}

VisibilityStats :: struct {
  node_count:        u32,
  opaque_draw_count: u32,
}

visibility_stats :: proc(
  self: ^Manager,
  camera_index: u32,
  frame_index: u32,
) -> VisibilityStats {
  cam, ok := &self.cameras[camera_index]
  if !ok do return {node_count = self.internal.visibility.node_count}
  st := occlusion_culling.stats(
    &self.internal.visibility,
    &cam.draws[.OPAQUE].count[frame_index],
    camera_index,
    frame_index,
  )
  return {
    node_count = self.internal.visibility.node_count,
    opaque_draw_count = st.opaque_draw_count,
  }
}

set_visibility_stats_enabled :: proc(self: ^Manager, enabled: bool) {
  self.internal.visibility.stats_enabled = enabled
}

// record_frame drives the entire per-frame command sequence: shadow maps,
// per-camera passes (geometry, lighting, particles, transparency), debug,
// post-process, UI, async compute, optional debug-UI overlay, and the
// final swapchain transition to PRESENT_SRC.
record_frame :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
  frame_index: u32,
  swapchain_image: vk.Image,
  swapchain_view: vk.ImageView,
  swapchain_extent: vk.Extent2D,
  main_camera_index: u32,
  main_camera_passes: PassTypeSet,
  cameras_config: []CameraFrameConfig,
  debug_ui_enabled: bool,
) -> vk.Result {
  cmd := self.internal.command_buffers[frame_index]
  gpu.begin_record(cmd) or_return
  render_shadow_depth(self, frame_index) or_return

  cull_indices := make(
    [dynamic]u32,
    0,
    len(cameras_config),
    context.temp_allocator,
  )
  defer delete(cull_indices)
  for cfg in cameras_config {
    if cfg.enable_culling do append(&cull_indices, cfg.index)
    cam, ok := &self.cameras[cfg.index]
    if !ok do continue
    record_geometry_pass(self, frame_index, cfg.index, cam, cfg.enabled_passes) or_return
    record_lighting_pass(self, frame_index, cfg.index, cam, cfg.enabled_passes) or_return
    record_particles_pass(self, frame_index, cfg.index, cam, cfg.enabled_passes) or_return
    record_transparency_pass(self, frame_index, gctx, cfg.index, cam, cfg.enabled_passes) or_return
  }

  if main_cam, ok := &self.cameras[main_camera_index]; ok {
    record_debug_pass(self, frame_index, main_camera_index, main_cam, main_camera_passes) or_return
    record_post_process_pass(
      self,
      frame_index,
      main_cam,
      swapchain_extent,
      swapchain_image,
      swapchain_view,
      main_camera_passes,
    ) or_return
  }
  record_ui_pass(self, frame_index, gctx, swapchain_view, swapchain_extent, main_camera_passes)

  // Compute (potentially on a separate async queue command buffer).
  compute_cmd := cmd
  if gctx.has_async_compute {
    compute_cmd = self.internal.compute_command_buffers[frame_index]
    gpu.begin_record(compute_cmd) or_return
  }
  record_compute_commands(self, frame_index, gctx, cull_indices[:]) or_return
  if gctx.has_async_compute {
    gpu.end_record(compute_cmd) or_return
  }

  if debug_ui_enabled {
    debug_ui.record(
      &self.debug_ui,
      cmd,
      swapchain_view,
      swapchain_extent,
      self.texture_manager.descriptor_set,
    )
  }

  present_barrier := vk.ImageMemoryBarrier {
    sType = .IMAGE_MEMORY_BARRIER,
    srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
    oldLayout = .COLOR_ATTACHMENT_OPTIMAL,
    newLayout = .PRESENT_SRC_KHR,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    image = swapchain_image,
    subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
  }
  vk.CmdPipelineBarrier(
    cmd,
    {.COLOR_ATTACHMENT_OUTPUT},
    {.BOTTOM_OF_PIPE},
    {},
    0,
    nil,
    0,
    nil,
    1,
    &present_barrier,
  )
  gpu.end_record(cmd) or_return
  return .SUCCESS
}

sync_mesh_geometry_for_handle :: proc(
  gctx: ^gpu.GPUContext,
  render: ^Manager,
  handle: u32,
  geometry_data: geom.Geometry,
) -> vk.Result {
  mesh := gpu.mutable_buffer_get(&render.internal.mesh_data_buffer.buffer, handle)
  if mesh.index_count > 0 {
    gpu.free_vertices(
      &render.mesh_manager,
      BufferAllocation{offset = u32(mesh.vertex_offset), count = 1},
    )
    gpu.free_indices(
      &render.mesh_manager,
      BufferAllocation{offset = mesh.first_index, count = 1},
    )
    if .SKINNED in mesh.flags {
      gpu.free_vertex_skinning(
        &render.mesh_manager,
        BufferAllocation{offset = mesh.skinning_offset, count = 1},
      )
    }
  }
  mesh.aabb_min = geometry_data.aabb.min
  mesh.aabb_max = geometry_data.aabb.max
  mesh.flags = {}
  mesh.index_count = u32(len(geometry_data.indices))
  vertex_allocation := gpu.allocate_vertices(
    &render.mesh_manager,
    gctx,
    geometry_data.vertices,
  ) or_return
  index_allocation := gpu.allocate_indices(
    &render.mesh_manager,
    gctx,
    geometry_data.indices,
  ) or_return
  mesh.first_index = index_allocation.offset
  mesh.vertex_offset = i32(vertex_allocation.offset)
  mesh.skinning_offset = 0
  if len(geometry_data.skinnings) > 0 {
    skinning_allocation := gpu.allocate_vertex_skinning(
      &render.mesh_manager,
      gctx,
      geometry_data.skinnings,
    ) or_return
    mesh.skinning_offset = skinning_allocation.offset
    mesh.flags |= {.SKINNED}
  }
  return .SUCCESS
}

mesh_destroy :: proc(render: ^Manager, handle: u32) {
  mesh := gpu.mutable_buffer_get(&render.internal.mesh_data_buffer.buffer, handle)
  if mesh.index_count > 0 {
    gpu.free_vertices(
      &render.mesh_manager,
      BufferAllocation{offset = u32(mesh.vertex_offset), count = 1},
    )
    gpu.free_indices(
      &render.mesh_manager,
      BufferAllocation{offset = mesh.first_index, count = 1},
    )
  }
  if .SKINNED in mesh.flags {
    gpu.free_vertex_skinning(
      &render.mesh_manager,
      BufferAllocation{offset = mesh.skinning_offset, count = 1},
    )
  }
  mesh^ = {}
}

@(private)
set_texture_2d_descriptor :: proc(
  gctx: ^gpu.GPUContext,
  textures_descriptor_set: vk.DescriptorSet,
  texture_index: u32,
  image_view: vk.ImageView,
) {
  if texture_index >= gpu.MAX_TEXTURES {
    log.warnf("Index %d out of bounds for bindless textures", texture_index)
    return
  }
  if textures_descriptor_set == 0 {
    log.error("textures_descriptor_set is not initialized")
    return
  }
  gpu.update_descriptor_set_array_offset(
    gctx,
    textures_descriptor_set,
    0,
    texture_index,
    {
      .SAMPLED_IMAGE,
      vk.DescriptorImageInfo {
        imageView = image_view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
      },
    },
  )
}

@(private)
set_texture_cube_descriptor :: proc(
  gctx: ^gpu.GPUContext,
  textures_descriptor_set: vk.DescriptorSet,
  texture_index: u32,
  image_view: vk.ImageView,
) {
  if texture_index >= gpu.MAX_CUBE_TEXTURES {
    log.warnf(
      "Index %d out of bounds for bindless cube textures",
      texture_index,
    )
    return
  }
  if textures_descriptor_set == 0 {
    log.error("textures_descriptor_set is not initialized")
    return
  }
  gpu.update_descriptor_set_array_offset(
    gctx,
    textures_descriptor_set,
    2,
    texture_index,
    {
      .SAMPLED_IMAGE,
      vk.DescriptorImageInfo {
        imageView = image_view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
      },
    },
  )
}

@(private)
release_shadow_2d :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
  light_node_index: u32,
) {
  shadow, ok := &render.internal.shadow_maps[light_node_index]
  if !ok do return
  for frame in 0 ..< FRAMES_IN_FLIGHT {
    gpu.free_texture_2d(
      &render.texture_manager,
      gctx,
      shadow.shadow_map_2d[frame],
    )
    gpu.mutable_buffer_destroy(gctx.device, &shadow.draw_count[frame])
    gpu.mutable_buffer_destroy(gctx.device, &shadow.draw_commands[frame])
    shadow.descriptor_sets[frame] = 0
  }
  delete_key(&render.internal.shadow_maps, light_node_index)
}

@(private)
release_shadow_cube :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
  light_node_index: u32,
) {
  shadow, ok := &render.internal.shadow_map_cubes[light_node_index]
  if !ok do return
  for frame in 0 ..< FRAMES_IN_FLIGHT {
    gpu.free_texture_cube(
      &render.texture_manager,
      gctx,
      shadow.shadow_map_cube[frame],
    )
    gpu.mutable_buffer_destroy(gctx.device, &shadow.draw_count[frame])
    gpu.mutable_buffer_destroy(gctx.device, &shadow.draw_commands[frame])
    shadow.descriptor_sets[frame] = 0
  }
  delete_key(&render.internal.shadow_map_cubes, light_node_index)
}

@(private)
ensure_shadow_2d_resource :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
  light_node_index: u32,
) -> vk.Result {
  if light_node_index in render.internal.shadow_maps do return .SUCCESS
  sm: ShadowMap
  for frame in 0 ..< FRAMES_IN_FLIGHT {
    sm.shadow_map_2d[frame] = gpu.allocate_texture_2d(
      &render.texture_manager,
      gctx,
      vk.Extent2D{SHADOW_MAP_SIZE, SHADOW_MAP_SIZE},
      .D32_SFLOAT,
      {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    ) or_return
    sm.draw_count[frame] = gpu.create_mutable_buffer(
      gctx,
      u32,
      1,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER},
    ) or_return
    sm.draw_commands[frame] = gpu.create_mutable_buffer(
      gctx,
      vk.DrawIndexedIndirectCommand,
      MAX_NODES_IN_SCENE,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER},
    ) or_return
    sm.descriptor_sets[frame] = shadow_culling_system.create_per_light_descriptor(
      &render.internal.shadow_culling,
      gctx,
      gpu.buffer_info(&render.internal.node_data_buffer.buffer),
      gpu.buffer_info(&render.internal.mesh_data_buffer.buffer),
      gpu.buffer_info(&sm.draw_count[frame]),
      gpu.buffer_info(&sm.draw_commands[frame]),
    ) or_return
  }
  render.internal.shadow_maps[light_node_index] = sm
  return .SUCCESS
}

@(private)
ensure_shadow_cube_resource :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
  light_node_index: u32,
) -> vk.Result {
  if light_node_index in render.internal.shadow_map_cubes do return .SUCCESS
  sm: ShadowMapCube
  for frame in 0 ..< FRAMES_IN_FLIGHT {
    sm.shadow_map_cube[frame] = gpu.allocate_texture_cube(
      &render.texture_manager,
      gctx,
      SHADOW_MAP_SIZE,
      .D32_SFLOAT,
      {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    ) or_return
    sm.draw_count[frame] = gpu.create_mutable_buffer(
      gctx,
      u32,
      1,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER},
    ) or_return
    sm.draw_commands[frame] = gpu.create_mutable_buffer(
      gctx,
      vk.DrawIndexedIndirectCommand,
      MAX_NODES_IN_SCENE,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER},
    ) or_return
    sm.descriptor_sets[frame] = shadow_sphere_culling_system.create_per_light_descriptor(
      &render.internal.shadow_sphere_culling,
      gctx,
      gpu.buffer_info(&render.internal.node_data_buffer.buffer),
      gpu.buffer_info(&render.internal.mesh_data_buffer.buffer),
      gpu.buffer_info(&sm.draw_count[frame]),
      gpu.buffer_info(&sm.draw_commands[frame]),
    ) or_return
  }
  render.internal.shadow_map_cubes[light_node_index] = sm
  return .SUCCESS
}

upsert_light_entry :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
  light_node_index: u32,
  light_data: ^Light,
  cast_shadow: bool,
) -> vk.Result {
  render.internal.lights[light_node_index] = light_data^
  if cast_shadow {
    shadow_result: vk.Result
    switch variant in light_data^ {
    case PointLight:
      shadow_result = ensure_shadow_cube_resource(render, gctx, light_node_index)
    case SpotLight:
      shadow_result = ensure_shadow_2d_resource(render, gctx, light_node_index)
    case DirectionalLight:
      shadow_result = ensure_shadow_2d_resource(render, gctx, light_node_index)
    }
    if shadow_result != .SUCCESS {
      log.warnf(
        "Failed to allocate shadow resources for light %d: %v (shadows disabled)",
        light_node_index,
        shadow_result,
      )
    }
  } else {
    switch variant in light_data^ {
    case PointLight:
      release_shadow_cube(render, gctx, light_node_index)
    case SpotLight:
      release_shadow_2d(render, gctx, light_node_index)
    case DirectionalLight:
      release_shadow_2d(render, gctx, light_node_index)
    }
  }
  return .SUCCESS
}

remove_light_entry :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
  light_node_index: u32,
) {
  light, ok := render.internal.lights[light_node_index]
  if !ok do return
  switch variant in light {
  case PointLight:
    release_shadow_cube(render, gctx, light_node_index)
  case SpotLight:
    release_shadow_2d(render, gctx, light_node_index)
  case DirectionalLight:
    release_shadow_2d(render, gctx, light_node_index)
  }
  delete_key(&render.internal.lights, light_node_index)
}

upload_node_data :: proc(render: ^Manager, index: u32, node_data: ^Node) {
  assert(index < MAX_NODES_IN_SCENE, "node index exceeds MAX_NODES_IN_SCENE")
  gpu.write(&render.internal.node_data_buffer.buffer, node_data, int(index))
}

upload_bone_matrices :: proc(
  render: ^Manager,
  frame_index: u32,
  offset: u32,
  matrices: []matrix[4, 4]f32,
) {
  assert(int(frame_index) < FRAMES_IN_FLIGHT, "frame_index out of range")
  assert(
    int(offset) + len(matrices) <= int(render.internal.bone_matrix_slab.capacity),
    "bone matrix range exceeds slab capacity",
  )
  frame_buffer := &render.internal.bone_buffer.buffers[frame_index]
  if frame_buffer.mapped == nil do return
  l := int(offset)
  r := l + len(matrices)
  gpu_slice := gpu.get_all(frame_buffer)
  copy(gpu_slice[l:r], matrices[:])
}

upload_sprite_data :: proc(
  render: ^Manager,
  index: u32,
  sprite_data: ^Sprite,
) {
  assert(index < MAX_SPRITES, "sprite index exceeds MAX_SPRITES")
  gpu.write(&render.internal.sprite_buffer.buffer, sprite_data, int(index))
}

upload_emitter_data :: proc(render: ^Manager, index: u32, emitter: ^Emitter) {
  assert(index < MAX_EMITTERS, "emitter index exceeds MAX_EMITTERS")
  gpu.write(&render.internal.emitter_buffer.buffer, emitter, int(index))
}

upload_forcefield_data :: proc(
  render: ^Manager,
  index: u32,
  forcefield: ^ForceField,
) {
  assert(index < MAX_FORCE_FIELDS, "forcefield index exceeds MAX_FORCE_FIELDS")
  gpu.write(&render.internal.forcefield_buffer.buffer, forcefield, int(index))
}

upload_mesh_data :: proc(render: ^Manager, index: u32, mesh: ^Mesh) {
  assert(index < MAX_MESHES, "mesh index exceeds MAX_MESHES")
  gpu.write(&render.internal.mesh_data_buffer.buffer, mesh, int(index))
}

upload_material_data :: proc(
  render: ^Manager,
  index: u32,
  material: ^Material,
) {
  assert(index < MAX_MATERIALS, "material index exceeds MAX_MATERIALS")
  gpu.write(&render.internal.material_buffer.buffer, material, int(index))
}

ensure_bone_matrix_range_for_node :: proc(
  render: ^Manager,
  handle: u32,
  bone_count: u32,
) -> u32 {
  if existing, ok := render.internal.bone_matrix_offsets[handle]; ok {
    return existing
  }
  offset := cont.slab_alloc(&render.internal.bone_matrix_slab, bone_count)
  if offset == 0xFFFFFFFF do return 0xFFFFFFFF
  render.internal.bone_matrix_offsets[handle] = offset
  return offset
}

release_bone_matrix_range_for_node :: proc(render: ^Manager, handle: u32) {
  if offset, ok := render.internal.bone_matrix_offsets[handle]; ok {
    cont.slab_free(&render.internal.bone_matrix_slab, offset)
    delete_key(&render.internal.bone_matrix_offsets, handle)
  }
}

// Upload camera CPU data to GPU per-frame buffer
upload_camera_data :: proc(
  render: ^Manager,
  camera_index: u32,
  view, projection: matrix[4, 4]f32,
  position: [3]f32,
  extent: [2]u32,
  near, far: f32,
  frame_index: u32,
) {
  assert(camera_index < MAX_ACTIVE_CAMERAS, "camera index exceeds MAX_ACTIVE_CAMERAS")
  assert(int(frame_index) < FRAMES_IN_FLIGHT, "frame_index out of range")
  camera_data: CameraGPU
  camera_data.view = view
  camera_data.projection = projection
  camera_data.viewport_extent = {f32(extent[0]), f32(extent[1])}
  camera_data.near = near
  camera_data.far = far
  camera_data.position = [4]f32{position.x, position.y, position.z, 1.0}
  frustum := geom.make_frustum(camera_data.projection * camera_data.view)
  camera_data.frustum_planes = frustum.planes
  gpu.write(
    &render.internal.camera_buffer.buffers[frame_index],
    &camera_data,
    int(camera_index),
  )
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

PassType :: world.PassType
PassTypeSet :: world.PassTypeSet

// CameraTarget owns render-side GPU resources for one camera (attachments,
// indirect draw buffers, depth pyramid, descriptor sets). Pass enable/culling
// configuration via call-site parameters; the world-side `world.Camera` is the
// single source of truth for those flags.
CameraTarget :: struct {
  attachments:                  [AttachmentType][FRAMES_IN_FLIGHT]gpu.Texture2DHandle,
  // Indirect draw buffers per pipeline (double-buffered for async compute).
  // Frame N compute writes to buffers[N], Frame N graphics reads from buffers[N-1].
  draws:                        [DrawPipeline]DrawBuffers,
  depth_pyramid:                [FRAMES_IN_FLIGHT]depth_pyramid_system.DepthPyramid,
  descriptor_set:               [FRAMES_IN_FLIGHT]vk.DescriptorSet,
  depth_reduce_descriptor_sets: [FRAMES_IN_FLIGHT][depth_pyramid_system.MAX_DEPTH_MIPS_LEVEL]vk.DescriptorSet,
}


camera_init :: proc(
  gctx: ^gpu.GPUContext,
  camera: ^CameraTarget,
  texture_manager: ^gpu.TextureManager,
  extent: vk.Extent2D,
  color_format, depth_format: vk.Format,
  enabled_passes: PassTypeSet = {
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
    .DEBUG_BONE,
    .UI,
  },
  enable_culling: bool = true,
  max_draws: u32,
) -> vk.Result {
  // Determine which attachments are needed based on enabled passes
  needs_gbuffer := .GEOMETRY in enabled_passes || .LIGHTING in enabled_passes
  needs_final :=
    .LIGHTING in enabled_passes ||
    .TRANSPARENCY in enabled_passes ||
    .PARTICLES in enabled_passes ||
    .POST_PROCESS in enabled_passes

  // Create render target attachments for each frame
  for frame in 0 ..< FRAMES_IN_FLIGHT {
    if needs_final {
      camera.attachments[.FINAL_IMAGE][frame] = gpu.allocate_texture_2d(
        texture_manager,
        gctx,
        extent,
        color_format,
        {.COLOR_ATTACHMENT, .SAMPLED},
      ) or_return
    }
    if needs_gbuffer {
      camera.attachments[.POSITION][frame] = gpu.allocate_texture_2d(
        texture_manager,
        gctx,
        extent,
        .R32G32B32A32_SFLOAT,
        {.COLOR_ATTACHMENT, .SAMPLED},
      ) or_return
      camera.attachments[.NORMAL][frame] = gpu.allocate_texture_2d(
        texture_manager,
        gctx,
        extent,
        .R8G8B8A8_UNORM,
        {.COLOR_ATTACHMENT, .SAMPLED},
      ) or_return
      camera.attachments[.ALBEDO][frame] = gpu.allocate_texture_2d(
        texture_manager,
        gctx,
        extent,
        .R8G8B8A8_UNORM,
        {.COLOR_ATTACHMENT, .SAMPLED},
      ) or_return
      camera.attachments[.METALLIC_ROUGHNESS][frame] = gpu.allocate_texture_2d(
        texture_manager,
        gctx,
        extent,
        .R8G8B8A8_UNORM,
        {.COLOR_ATTACHMENT, .SAMPLED},
      ) or_return
      camera.attachments[.EMISSIVE][frame] = gpu.allocate_texture_2d(
        texture_manager,
        gctx,
        extent,
        .R8G8B8A8_UNORM,
        {.COLOR_ATTACHMENT, .SAMPLED},
      ) or_return
    }
    camera.attachments[.DEPTH][frame] = gpu.allocate_texture_2d(
      texture_manager,
      gctx,
      extent,
      depth_format,
      {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    ) or_return

    // Transition depth image from UNDEFINED to DEPTH_STENCIL_READ_ONLY_OPTIMAL
    if depth := gpu.get_texture_2d(
      texture_manager,
      camera.attachments[.DEPTH][frame],
    ); depth != nil {
      cmd_buf := gpu.begin_single_time_command(gctx) or_return
      gpu.image_barrier(
        cmd_buf,
        depth.image,
        .UNDEFINED,
        .DEPTH_STENCIL_READ_ONLY_OPTIMAL,
        {},
        {.DEPTH_STENCIL_ATTACHMENT_READ},
        {.TOP_OF_PIPE},
        {.EARLY_FRAGMENT_TESTS},
        {.DEPTH},
      )
      gpu.end_single_time_command(gctx, &cmd_buf) or_return
    }
  }

  // Create indirect draw buffers (double-buffered) for each pipeline.
  for pipe in DrawPipeline {
    for frame in 0 ..< FRAMES_IN_FLIGHT {
      camera.draws[pipe].count[frame] = gpu.create_mutable_buffer(
        gctx,
        u32,
        1,
        {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
      ) or_return
      camera.draws[pipe].commands[frame] = gpu.create_mutable_buffer(
        gctx,
        vk.DrawIndexedIndirectCommand,
        int(max_draws),
        {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
      ) or_return
    }
  }

  if enable_culling {
    for frame in 0 ..< FRAMES_IN_FLIGHT {
      depth_pyramid_system.setup_pyramid(
        gctx,
        &camera.depth_pyramid[frame],
        texture_manager,
        extent,
      ) or_return
    }
  }

  return .SUCCESS
}

// Destroy GPU resources for perspective/orthographic camera
camera_destroy :: proc(
  gctx: ^gpu.GPUContext,
  camera: ^CameraTarget,
  texture_manager: ^gpu.TextureManager,
) {
  // Destroy all attachment textures
  for attachment_type in AttachmentType {
    for frame in 0 ..< FRAMES_IN_FLIGHT {
      handle := camera.attachments[attachment_type][frame]
      if handle.index == 0 do continue
      gpu.free_texture_2d(texture_manager, gctx, handle)
    }
  }

  // Destroy depth pyramids
  for frame in 0 ..< FRAMES_IN_FLIGHT {
    depth_pyramid_system.destroy_pyramid(
      gctx,
      &camera.depth_pyramid[frame],
      texture_manager,
    )
  }

  // Destroy indirect draw buffers
  for pipe in DrawPipeline {
    for frame in 0 ..< FRAMES_IN_FLIGHT {
      gpu.mutable_buffer_destroy(gctx.device, &camera.draws[pipe].count[frame])
      gpu.mutable_buffer_destroy(
        gctx.device,
        &camera.draws[pipe].commands[frame],
      )
    }
  }
  // Zero out the GPU struct
  camera^ = {}
}

// Allocate descriptor sets for perspective/orthographic camera culling pipelines
camera_allocate_descriptors :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
  camera: ^CameraTarget,
) -> vk.Result {
  texture_manager := &self.texture_manager
  normal_descriptor_layout := &self.internal.visibility.depth_descriptor_layout
  depth_reduce_descriptor_layout := &self.internal.depth_pyramid.depth_reduce_descriptor_layout
  node_data_buffer := &self.internal.node_data_buffer
  mesh_data_buffer := &self.internal.mesh_data_buffer
  camera_buffer := &self.internal.camera_buffer
  for frame_index in 0 ..< FRAMES_IN_FLIGHT {
    prev_frame_index := (frame_index + FRAMES_IN_FLIGHT - 1) % FRAMES_IN_FLIGHT
    pyramid := &camera.depth_pyramid[frame_index]
    prev_pyramid := &camera.depth_pyramid[prev_frame_index]
    prev_depth := gpu.get_texture_2d(
      texture_manager,
      camera.attachments[.DEPTH][prev_frame_index],
    )
    if prev_depth == nil {
      log.errorf(
        "allocate_descriptors: missing depth attachment for frame %d",
        prev_frame_index,
      )
      return .ERROR_INITIALIZATION_FAILED
    }
    if pyramid.mip_levels == 0 {
      log.errorf(
        "allocate_descriptors: missing depth pyramid for frame %d",
        frame_index,
      )
      return .ERROR_INITIALIZATION_FAILED
    }

    camera.descriptor_set[frame_index] = gpu.create_descriptor_set(
      gctx,
      normal_descriptor_layout,
      {.STORAGE_BUFFER, gpu.buffer_info(&node_data_buffer.buffer)},
      {.STORAGE_BUFFER, gpu.buffer_info(&mesh_data_buffer.buffer)},
      {.STORAGE_BUFFER, gpu.buffer_info(&camera_buffer.buffers[frame_index])},
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.draws[.OPAQUE].count[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.draws[.OPAQUE].commands[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.draws[.TRANSPARENT].count[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.draws[.TRANSPARENT].commands[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.draws[.SPRITE].count[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.draws[.SPRITE].commands[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.draws[.WIREFRAME].count[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.draws[.WIREFRAME].commands[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.draws[.RANDOM_COLOR].count[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.draws[.RANDOM_COLOR].commands[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.draws[.LINE_STRIP].count[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.draws[.LINE_STRIP].commands[frame_index]),
      },
      {
        .COMBINED_IMAGE_SAMPLER,
        vk.DescriptorImageInfo {
          sampler = prev_pyramid.sampler,
          imageView = prev_pyramid.full_view,
          imageLayout = .GENERAL,
        },
      },
    ) or_return

    for mip in 0 ..< pyramid.mip_levels {
      source_info: vk.DescriptorImageInfo
      if mip == 0 {
        source_info = {
          sampler     = pyramid.sampler,
          imageView   = prev_depth.view,
          imageLayout = .DEPTH_STENCIL_READ_ONLY_OPTIMAL,
        }
      } else {
        source_info = {
          sampler     = pyramid.sampler,
          imageView   = pyramid.views[mip - 1],
          imageLayout = .GENERAL,
        }
      }
      dest_info := vk.DescriptorImageInfo {
        imageView   = pyramid.views[mip],
        imageLayout = .GENERAL,
      }
      camera.depth_reduce_descriptor_sets[frame_index][mip] =
        gpu.create_descriptor_set(
          gctx,
          depth_reduce_descriptor_layout,
          {.COMBINED_IMAGE_SAMPLER, source_info},
          {.STORAGE_IMAGE, dest_info},
        ) or_return
    }
  }

  return .SUCCESS
}

// Resize camera render targets (called on window resize)
camera_resize :: proc(
  gctx: ^gpu.GPUContext,
  camera: ^CameraTarget,
  texture_manager: ^gpu.TextureManager,
  extent: vk.Extent2D,
  color_format, depth_format: vk.Format,
  enabled_passes: PassTypeSet,
  enable_culling: bool = true,
) -> vk.Result {
  // Destroy old attachments
  for attachment_type in AttachmentType {
    for frame in 0 ..< FRAMES_IN_FLIGHT {
      handle := camera.attachments[attachment_type][frame]
      if handle.index == 0 do continue
      gpu.free_texture_2d(texture_manager, gctx, handle)
      camera.attachments[attachment_type][frame] = {}
    }
  }

  // Destroy old depth pyramids
  for frame in 0 ..< FRAMES_IN_FLIGHT {
    pyramid := &camera.depth_pyramid[frame]
    if pyramid.mip_levels == 0 do continue

    for mip in 0 ..< pyramid.mip_levels {
      vk.DestroyImageView(gctx.device, pyramid.views[mip], nil)
    }
    vk.DestroyImageView(gctx.device, pyramid.full_view, nil)
    vk.DestroySampler(gctx.device, pyramid.sampler, nil)

    gpu.free_texture_2d(texture_manager, gctx, pyramid.texture)
    pyramid^ = {}
  }

  // Recreate attachments with new dimensions
  needs_gbuffer := .GEOMETRY in enabled_passes || .LIGHTING in enabled_passes
  needs_final :=
    .LIGHTING in enabled_passes ||
    .TRANSPARENCY in enabled_passes ||
    .PARTICLES in enabled_passes ||
    .POST_PROCESS in enabled_passes

  for frame in 0 ..< FRAMES_IN_FLIGHT {
    if needs_final {
      camera.attachments[.FINAL_IMAGE][frame] = gpu.allocate_texture_2d(
        texture_manager,
        gctx,
        extent,
        color_format,
        {.COLOR_ATTACHMENT, .SAMPLED},
      ) or_return
    }
    if needs_gbuffer {
      camera.attachments[.POSITION][frame] = gpu.allocate_texture_2d(
        texture_manager,
        gctx,
        extent,
        .R32G32B32A32_SFLOAT,
        {.COLOR_ATTACHMENT, .SAMPLED},
      ) or_return
      camera.attachments[.NORMAL][frame] = gpu.allocate_texture_2d(
        texture_manager,
        gctx,
        extent,
        .R8G8B8A8_UNORM,
        {.COLOR_ATTACHMENT, .SAMPLED},
      ) or_return
      camera.attachments[.ALBEDO][frame] = gpu.allocate_texture_2d(
        texture_manager,
        gctx,
        extent,
        .R8G8B8A8_UNORM,
        {.COLOR_ATTACHMENT, .SAMPLED},
      ) or_return
      camera.attachments[.METALLIC_ROUGHNESS][frame] = gpu.allocate_texture_2d(
        texture_manager,
        gctx,
        extent,
        .R8G8B8A8_UNORM,
        {.COLOR_ATTACHMENT, .SAMPLED},
      ) or_return
      camera.attachments[.EMISSIVE][frame] = gpu.allocate_texture_2d(
        texture_manager,
        gctx,
        extent,
        .R8G8B8A8_UNORM,
        {.COLOR_ATTACHMENT, .SAMPLED},
      ) or_return
    }
    camera.attachments[.DEPTH][frame] = gpu.allocate_texture_2d(
      texture_manager,
      gctx,
      extent,
      depth_format,
      {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    ) or_return

    if depth := gpu.get_texture_2d(
      texture_manager,
      camera.attachments[.DEPTH][frame],
    ); depth != nil {
      cmd_buf := gpu.begin_single_time_command(gctx) or_return
      gpu.image_barrier(
        cmd_buf,
        depth.image,
        .UNDEFINED,
        .DEPTH_STENCIL_READ_ONLY_OPTIMAL,
        {},
        {.DEPTH_STENCIL_ATTACHMENT_READ},
        {.TOP_OF_PIPE},
        {.EARLY_FRAGMENT_TESTS},
        {.DEPTH},
      )
      gpu.end_single_time_command(gctx, &cmd_buf) or_return
    }
  }
  if enable_culling {
    for frame in 0 ..< FRAMES_IN_FLIGHT {
      depth_pyramid_system.setup_pyramid(
        gctx,
        &camera.depth_pyramid[frame],
        texture_manager,
        extent,
      ) or_return
    }
  }

  log.infof("Camera resized to %dx%d", extent.width, extent.height)
  return .SUCCESS
}
