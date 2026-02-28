package render

import alg "../algebra"
import cont "../containers"
import geom "../geometry"
import "../gpu"
import cmd "../gpu/ui"
import graph "graph"
import "ambient"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import rd "data"
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

FRAMES_IN_FLIGHT :: rd.FRAMES_IN_FLIGHT
USE_FRAME_GRAPH :: #config(USE_FRAME_GRAPH, true)

Handle :: rd.Handle
MeshHandle :: rd.MeshHandle
MaterialHandle :: rd.MaterialHandle
Image2DHandle :: gpu.Texture2DHandle
ImageCubeHandle :: gpu.TextureCubeHandle
LightHandle :: rd.LightHandle

MeshFlag :: rd.MeshFlag
MeshFlagSet :: rd.MeshFlagSet
BufferAllocation :: rd.BufferAllocation
Primitive :: rd.Primitive
ShaderFeature :: rd.ShaderFeature
ShaderFeatureSet :: rd.ShaderFeatureSet
NodeFlag :: rd.NodeFlag
NodeFlagSet :: rd.NodeFlagSet
Node :: rd.Node
Mesh :: rd.Mesh
Material :: rd.Material
Emitter :: rd.Emitter
ForceField :: rd.ForceField
Sprite :: rd.Sprite
LightType :: rd.LightType
BoneInstance :: debug_bone.BoneInstance

// Shadow resource types - embed in light variants
ShadowMap :: struct {
  shadow_map_2d:   [FRAMES_IN_FLIGHT]gpu.Texture2DHandle,
  draw_commands:   [FRAMES_IN_FLIGHT]gpu.MutableBuffer(
    vk.DrawIndexedIndirectCommand,
  ),
  draw_count:      [FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  descriptor_sets: [FRAMES_IN_FLIGHT]vk.DescriptorSet,
  view:            matrix[4, 4]f32,
  projection:      matrix[4, 4]f32,
  view_projection: matrix[4, 4]f32, // Pre-multiplied
  near:            f32,
  far:             f32,
  frustum_planes:  [6][4]f32,
}

ShadowMapCube :: struct {
  shadow_map_cube: [FRAMES_IN_FLIGHT]gpu.TextureCubeHandle,
  draw_commands:   [FRAMES_IN_FLIGHT]gpu.MutableBuffer(
    vk.DrawIndexedIndirectCommand,
  ),
  draw_count:      [FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  descriptor_sets: [FRAMES_IN_FLIGHT]vk.DescriptorSet,
  projection:      matrix[4, 4]f32,
  near:            f32,
  far:             f32,
}

// Light union variants
PointLight :: struct {
  color:    [4]f32, // RGB + intensity
  position: [3]f32,
  radius:   f32,
  shadow:   Maybe(ShadowMapCube),
}

SpotLight :: struct {
  color:       [4]f32,
  position:    [3]f32,
  direction:   [3]f32,
  radius:      f32,
  angle_inner: f32,
  angle_outer: f32,
  shadow:      Maybe(ShadowMap),
}

DirectionalLight :: struct {
  color:     [4]f32,
  position:  [3]f32,
  direction: [3]f32,
  radius:    f32,
  shadow:    Maybe(ShadowMap),
}

Light :: union {
  PointLight,
  SpotLight,
  DirectionalLight,
}

PerLightData :: struct {
  light:       Light, // Union type (contains embedded shadow)
  light_index: u32,
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

Manager :: struct {
  command_buffers:              [FRAMES_IN_FLIGHT]vk.CommandBuffer,
  compute_command_buffers:      [FRAMES_IN_FLIGHT]vk.CommandBuffer,
  // Frame graph
  frame_graph:                  graph.Graph,
  // Swapchain context for frame graph (set per-frame)
  current_swapchain_image:      vk.Image,
  current_swapchain_view:       vk.ImageView,
  current_swapchain_extent:     vk.Extent2D,
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
  post_process:                 post_process.Renderer,
  debug_ui:                     debug_ui.Renderer,
  debug_renderer:               debug_bone.Renderer,
  ui:                           ui_render.Renderer,
  ui_commands:                  [dynamic]cmd.RenderCommand, // Staged commands from UI module
  per_camera_data:              map[u32]Camera,
  per_light_data:               map[u32]PerLightData,
  visibility:                   occlusion_culling.System,
  depth_pyramid:                depth_pyramid_system.System,
  shadow_culling:               shadow_culling_system.System,
  shadow_sphere_culling:        shadow_sphere_culling_system.System,
  shadow_render:                shadow_render_system.System,
  shadow_sphere_render:         shadow_sphere_render_system.System,
  linear_repeat_sampler:        vk.Sampler,
  linear_clamp_sampler:         vk.Sampler,
  nearest_repeat_sampler:       vk.Sampler,
  nearest_clamp_sampler:        vk.Sampler,
  particle_buffer:              gpu.MutableBuffer(rd.Particle),
  compact_particle_buffer:      gpu.MutableBuffer(rd.Particle),
  particle_draw_command_buffer: gpu.MutableBuffer(vk.DrawIndirectCommand),
  bone_buffer:                  gpu.PerFrameBindlessBuffer(
    matrix[4, 4]f32,
    FRAMES_IN_FLIGHT,
  ),
  camera_buffer:                gpu.PerFrameBindlessBuffer(
    rd.Camera,
    FRAMES_IN_FLIGHT,
  ),
  material_buffer:              gpu.BindlessBuffer(Material),
  node_data_buffer:             gpu.BindlessBuffer(Node),
  mesh_data_buffer:             gpu.BindlessBuffer(Mesh),
  emitter_buffer:               gpu.BindlessBuffer(Emitter),
  forcefield_buffer:            gpu.BindlessBuffer(ForceField),
  sprite_buffer:                gpu.BindlessBuffer(Sprite),
  mesh_manager:                 gpu.MeshManager,
  bone_matrix_slab:             cont.SlabAllocator,
  bone_matrix_offsets:          map[u32]u32,
  texture_manager:              gpu.TextureManager,
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
  self.per_camera_data = make(map[u32]Camera)
  self.per_light_data = make(map[u32]PerLightData)
  self.ui_commands = make([dynamic]cmd.RenderCommand, 0, 256)
  gpu.allocate_command_buffer(gctx, self.command_buffers[:]) or_return
  defer if ret != .SUCCESS {
    gpu.free_command_buffer(gctx, ..self.command_buffers[:])
  }
  if gctx.has_async_compute {
    gpu.allocate_compute_command_buffer(
      gctx,
      self.compute_command_buffers[:],
    ) or_return
    defer if ret != .SUCCESS {
      gpu.free_compute_command_buffer(gctx, self.compute_command_buffers[:])
    }
  }
  // Initialize geometry/bone/camera/scene buffers (survive teardown/setup cycles)
  gpu.mesh_manager_init(&self.mesh_manager, gctx)
  defer if ret != .SUCCESS {
    gpu.mesh_manager_shutdown(&self.mesh_manager, gctx)
  }
  cont.slab_init(
    &self.bone_matrix_slab,
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
    &self.bone_buffer,
    gctx,
    int(self.bone_matrix_slab.capacity),
    {.VERTEX},
  ) or_return
  self.bone_matrix_offsets = make(map[u32]u32)
  defer if ret != .SUCCESS {
    delete(self.bone_matrix_offsets)
    gpu.per_frame_bindless_buffer_destroy(&self.bone_buffer, gctx.device)
    cont.slab_destroy(&self.bone_matrix_slab)
  }
  gpu.per_frame_bindless_buffer_init(
    &self.camera_buffer,
    gctx,
    rd.MAX_ACTIVE_CAMERAS,
    {.VERTEX, .FRAGMENT, .COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.per_frame_bindless_buffer_destroy(&self.camera_buffer, gctx.device)
  }
  gpu.bindless_buffer_init(
    &self.material_buffer,
    gctx,
    rd.MAX_MATERIALS,
    {.VERTEX, .FRAGMENT},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.material_buffer, gctx.device)
  }
  gpu.bindless_buffer_init(
    &self.node_data_buffer,
    gctx,
    rd.MAX_NODES_IN_SCENE,
    {.VERTEX, .FRAGMENT, .COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.node_data_buffer, gctx.device)
  }
  gpu.bindless_buffer_init(
    &self.mesh_data_buffer,
    gctx,
    rd.MAX_MESHES,
    {.VERTEX},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.mesh_data_buffer, gctx.device)
  }
  gpu.bindless_buffer_init(
    &self.emitter_buffer,
    gctx,
    rd.MAX_EMITTERS,
    {.COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.emitter_buffer, gctx.device)
  }
  gpu.bindless_buffer_init(
    &self.forcefield_buffer,
    gctx,
    rd.MAX_FORCE_FIELDS,
    {.COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.forcefield_buffer, gctx.device)
  }
  gpu.bindless_buffer_init(
    &self.sprite_buffer,
    gctx,
    rd.MAX_SPRITES,
    {.VERTEX, .FRAGMENT},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.sprite_buffer, gctx.device)
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
    &self.linear_repeat_sampler,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroySampler(gctx.device, self.linear_repeat_sampler, nil)
    self.linear_repeat_sampler = 0
  }
  info.addressModeU, info.addressModeV, info.addressModeW =
    .CLAMP_TO_EDGE, .CLAMP_TO_EDGE, .CLAMP_TO_EDGE
  vk.CreateSampler(
    gctx.device,
    &info,
    nil,
    &self.linear_clamp_sampler,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroySampler(gctx.device, self.linear_clamp_sampler, nil)
    self.linear_clamp_sampler = 0
  }
  info.magFilter, info.minFilter = .NEAREST, .NEAREST
  info.addressModeU, info.addressModeV, info.addressModeW =
    .REPEAT, .REPEAT, .REPEAT
  vk.CreateSampler(
    gctx.device,
    &info,
    nil,
    &self.nearest_repeat_sampler,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroySampler(gctx.device, self.nearest_repeat_sampler, nil)
    self.nearest_repeat_sampler = 0
  }
  info.addressModeU, info.addressModeV, info.addressModeW =
    .CLAMP_TO_EDGE, .CLAMP_TO_EDGE, .CLAMP_TO_EDGE
  vk.CreateSampler(
    gctx.device,
    &info,
    nil,
    &self.nearest_clamp_sampler,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroySampler(gctx.device, self.nearest_clamp_sampler, nil)
    self.nearest_clamp_sampler = 0
  }
  // Initialize all subsystems (pipeline creation only)
  occlusion_culling.init(&self.visibility, gctx) or_return
  depth_pyramid_system.init(&self.depth_pyramid, gctx) or_return
  shadow_culling_system.init(&self.shadow_culling, gctx) or_return
  shadow_sphere_culling_system.init(
    &self.shadow_sphere_culling,
    gctx,
  ) or_return
  shadow_render_system.init(
    &self.shadow_render,
    gctx,
    self.texture_manager.set_layout,
    self.bone_buffer.set_layout,
    self.material_buffer.set_layout,
    self.node_data_buffer.set_layout,
    self.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
  ) or_return
  shadow_sphere_render_system.init(
    &self.shadow_sphere_render,
    gctx,
    self.texture_manager.set_layout,
    self.bone_buffer.set_layout,
    self.material_buffer.set_layout,
    self.node_data_buffer.set_layout,
    self.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
  ) or_return
  ambient.init(
    &self.ambient,
    gctx,
    self.camera_buffer.set_layout,
    self.texture_manager.set_layout,
  ) or_return
  direct_light.init(
    &self.direct_light,
    gctx,
    self.camera_buffer.set_layout,
    self.texture_manager.set_layout,
  ) or_return
  geometry.init(
    &self.geometry,
    gctx,
    self.camera_buffer.set_layout,
    self.texture_manager.set_layout,
    self.bone_buffer.set_layout,
    self.material_buffer.set_layout,
    self.node_data_buffer.set_layout,
    self.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
  ) or_return
  particles_compute.init(
    &self.particles_compute,
    gctx,
    self.emitter_buffer.set_layout,
    self.forcefield_buffer.set_layout,
    self.node_data_buffer.set_layout,
  ) or_return
  particles_render.init(
    &self.particles_render,
    gctx,
    &self.texture_manager,
    self.camera_buffer.set_layout,
    self.texture_manager.set_layout,
  ) or_return
  // Initialize transparency renderers
  transparent.init(
    &self.transparent_renderer,
    gctx,
    self.camera_buffer.set_layout,
    self.texture_manager.set_layout,
    self.bone_buffer.set_layout,
    self.material_buffer.set_layout,
    self.node_data_buffer.set_layout,
    self.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
  ) or_return
  sprite.init(
    &self.sprite_renderer,
    gctx,
    self.camera_buffer.set_layout,
    self.texture_manager.set_layout,
    self.node_data_buffer.set_layout,
    self.sprite_buffer.set_layout,
  ) or_return
  wireframe.init(
    &self.wireframe_renderer,
    gctx,
    self.camera_buffer.set_layout,
    self.texture_manager.set_layout,
    self.bone_buffer.set_layout,
    self.material_buffer.set_layout,
    self.node_data_buffer.set_layout,
    self.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
  ) or_return
  line_strip.init(
    &self.line_strip_renderer,
    gctx,
    self.camera_buffer.set_layout,
    self.texture_manager.set_layout,
    self.bone_buffer.set_layout,
    self.material_buffer.set_layout,
    self.node_data_buffer.set_layout,
    self.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
  ) or_return
  random_color.init(
    &self.random_color_renderer,
    gctx,
    self.camera_buffer.set_layout,
    self.texture_manager.set_layout,
    self.bone_buffer.set_layout,
    self.material_buffer.set_layout,
    self.node_data_buffer.set_layout,
    self.mesh_data_buffer.set_layout,
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
    &self.debug_renderer,
    gctx,
    self.camera_buffer.set_layout,
  ) or_return
  ui_render.init(
    &self.ui,
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
      self.nearest_clamp_sampler,
      self.linear_clamp_sampler,
      self.nearest_repeat_sampler,
      self.linear_repeat_sampler,
    },
  ) or_return
  defer if ret != .SUCCESS {
    gpu.texture_manager_teardown(&self.texture_manager, gctx)
  }
  // Re-allocate descriptor sets for scene buffers (freed by previous ResetDescriptorPool)
  gpu.bindless_buffer_realloc_descriptor(&self.material_buffer, gctx) or_return
  gpu.bindless_buffer_realloc_descriptor(
    &self.node_data_buffer,
    gctx,
  ) or_return
  gpu.bindless_buffer_realloc_descriptor(
    &self.mesh_data_buffer,
    gctx,
  ) or_return
  gpu.bindless_buffer_realloc_descriptor(&self.emitter_buffer, gctx) or_return
  gpu.bindless_buffer_realloc_descriptor(
    &self.forcefield_buffer,
    gctx,
  ) or_return
  gpu.bindless_buffer_realloc_descriptor(&self.sprite_buffer, gctx) or_return
  gpu.per_frame_bindless_buffer_realloc_descriptors(
    &self.bone_buffer,
    gctx,
  ) or_return
  gpu.per_frame_bindless_buffer_realloc_descriptors(
    &self.camera_buffer,
    gctx,
  ) or_return
  gpu.mesh_manager_realloc_descriptors(&self.mesh_manager, gctx) or_return
  // Setup subsystem GPU resources
  ambient.setup(&self.ambient, gctx, &self.texture_manager) or_return
  direct_light.setup(&self.direct_light, gctx) or_return
  // Allocate particle buffers
  self.particle_buffer = gpu.create_mutable_buffer(
    gctx,
    particles_compute.Particle,
    particles_compute.MAX_PARTICLES,
    {.STORAGE_BUFFER, .VERTEX_BUFFER, .TRANSFER_DST},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.mutable_buffer_destroy(gctx.device, &self.particle_buffer)
  }
  self.compact_particle_buffer = gpu.create_mutable_buffer(
    gctx,
    particles_compute.Particle,
    particles_compute.MAX_PARTICLES,
    {.STORAGE_BUFFER, .VERTEX_BUFFER, .TRANSFER_SRC},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.mutable_buffer_destroy(gctx.device, &self.compact_particle_buffer)
  }
  self.particle_draw_command_buffer = gpu.create_mutable_buffer(
    gctx,
    vk.DrawIndirectCommand,
    1,
    {.STORAGE_BUFFER, .INDIRECT_BUFFER},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.mutable_buffer_destroy(gctx.device, &self.particle_draw_command_buffer)
  }
  particles_compute.setup(
    &self.particles_compute,
    gctx,
    self.emitter_buffer.descriptor_set,
    self.forcefield_buffer.descriptor_set,
    &self.particle_buffer,
    &self.compact_particle_buffer,
    &self.particle_draw_command_buffer,
  ) or_return
  post_process.setup(
    &self.post_process,
    gctx,
    &self.texture_manager,
    swapchain_extent,
    swapchain_format,
  ) or_return
  debug_ui.setup(&self.debug_ui, gctx, &self.texture_manager) or_return
  ui_render.setup(&self.ui, gctx) or_return
  return .SUCCESS
}

teardown :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  // Destroy camera GPU resources (VkImages, draw command buffers) before texture_manager goes away
  for _, &cam in self.per_camera_data {
    camera_destroy(gctx, &cam, &self.texture_manager)
  }
  clear(&self.per_camera_data)
  shadow_keys := make([dynamic]u32, 0, context.temp_allocator)
  for light_node_index in self.per_light_data {
    append(&shadow_keys, light_node_index)
  }
  for light_node_index in shadow_keys {
    remove_light_entry(self, gctx, light_node_index)
  }
  clear(&self.per_light_data)
  ui_render.teardown(&self.ui, gctx)
  debug_ui.teardown(&self.debug_ui, gctx, &self.texture_manager)
  post_process.teardown(&self.post_process, gctx, &self.texture_manager)
  particles_compute.teardown(&self.particles_compute, gctx)
  gpu.mutable_buffer_destroy(gctx.device, &self.particle_buffer)
  gpu.mutable_buffer_destroy(gctx.device, &self.compact_particle_buffer)
  gpu.mutable_buffer_destroy(gctx.device, &self.particle_draw_command_buffer)
  ambient.teardown(&self.ambient, gctx, &self.texture_manager)
  direct_light.teardown(&self.direct_light, gctx)
  gpu.texture_manager_teardown(&self.texture_manager, gctx)
  // Zero all descriptor set handles (freed in bulk below)
  self.material_buffer.descriptor_set = 0
  self.node_data_buffer.descriptor_set = 0
  self.mesh_data_buffer.descriptor_set = 0
  self.emitter_buffer.descriptor_set = 0
  self.forcefield_buffer.descriptor_set = 0
  self.sprite_buffer.descriptor_set = 0
  for &ds in self.bone_buffer.descriptor_sets do ds = 0
  for &ds in self.camera_buffer.descriptor_sets do ds = 0
  self.mesh_manager.vertex_skinning_buffer.descriptor_set = 0
  // Bulk-free all descriptor sets allocated from the pool
  vk.ResetDescriptorPool(gctx.device, gctx.descriptor_pool, {})
}

@(private)
ensure_camera_slot :: proc(self: ^Manager, handle: u32) {
  if handle not_in self.per_camera_data {
    self.per_camera_data[handle] = {}
  }
}

@(private)
get_camera :: proc(
  self: ^Manager,
  handle: u32,
) -> (
  cam: Camera,
  ok: bool,
) #optional_ok {
  cam, ok = self.per_camera_data[handle]
  if !ok do return {}, false
  return cam, true
}


sync_camera_from_world :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
  handle: u32,
  world_camera: ^Camera,
  swapchain_format: vk.Format,
) {
}

clear_mesh :: proc(self: ^Manager, handle: u32) {
  free_mesh_geometry(self, handle)
}

record_compute_commands :: proc(
  self: ^Manager,
  frame_index: u32,
  gctx: ^gpu.GPUContext,
) -> vk.Result {
  cmd :=
    gctx.has_async_compute ? self.compute_command_buffers[frame_index] : self.command_buffers[frame_index]
  // Compute for frame N prepares data for frame N+1
  // Buffer indices with rd.FRAMES_IN_FLIGHT=2: frame N uses buffer [N], produces data for buffer [N+1]
  next_frame_index := alg.next(frame_index, rd.FRAMES_IN_FLIGHT)
  for cam_index, &cam in self.per_camera_data {
    // Only perform culling if enabled for this camera
    if !cam.enable_culling do continue
    depth_pyramid_system.build_pyramid(
      &self.depth_pyramid,
      cmd,
      &cam.depth_pyramid[frame_index],
      cam.depth_reduce_descriptor_sets[frame_index][:],
    ) // Build pyramid[N]
    prev_frame := alg.prev(next_frame_index, FRAMES_IN_FLIGHT)
    occlusion_culling.perform_culling(
      &self.visibility,
      cmd,
      u32(cam_index),
      next_frame_index,
      &cam.opaque_draw_count[next_frame_index],
      &cam.transparent_draw_count[next_frame_index],
      &cam.sprite_draw_count[next_frame_index],
      &cam.wireframe_draw_count[next_frame_index],
      &cam.random_color_draw_count[next_frame_index],
      &cam.line_strip_draw_count[next_frame_index],
      cam.descriptor_set[next_frame_index],
      cam.depth_pyramid[prev_frame].width,
      cam.depth_pyramid[prev_frame].height,
    ) // Write draw_list[N+1]
  }
  particles_compute.simulate(
    &self.particles_compute,
    cmd,
    self.node_data_buffer.descriptor_set,
    self.particle_buffer.buffer,
    self.compact_particle_buffer.buffer,
    self.particle_draw_command_buffer.buffer,
    vk.DeviceSize(self.particle_buffer.bytes_count),
  )
  return .SUCCESS
}

// Stage UI commands from UI module
stage_ui_commands :: proc(self: ^Manager, commands: []cmd.RenderCommand) {
  clear(&self.ui_commands)
  for command in commands {
    append(&self.ui_commands, command)
  }
}

// Stage bone visualization instances for debug rendering
stage_bone_visualization :: proc(
  self: ^Manager,
  instances: []debug_bone.BoneInstance,
) {
  debug_bone.stage_bones(&self.debug_renderer, instances)
}

// Clear staged debug visualization data
clear_debug_visualization :: proc(self: ^Manager) {
  debug_bone.clear_bones(&self.debug_renderer)
}

shutdown :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  gpu.free_command_buffer(gctx, ..self.command_buffers[:])
  if gctx.has_async_compute {
    gpu.free_compute_command_buffer(gctx, self.compute_command_buffers[:])
  }
  ui_render.shutdown(&self.ui, gctx)
  delete(self.ui_commands)
  debug_bone.shutdown(&self.debug_renderer, gctx)
  debug_ui.shutdown(&self.debug_ui, gctx)
  post_process.shutdown(&self.post_process, gctx)
  particles_compute.shutdown(&self.particles_compute, gctx)
  particles_render.shutdown(&self.particles_render, gctx)
  // Cleanup transparency renderers
  transparent.shutdown(&self.transparent_renderer, gctx)
  sprite.shutdown(&self.sprite_renderer, gctx)
  wireframe.shutdown(&self.wireframe_renderer, gctx)
  line_strip.shutdown(&self.line_strip_renderer, gctx)
  random_color.shutdown(&self.random_color_renderer, gctx)
  ambient.shutdown(&self.ambient, gctx)
  direct_light.shutdown(&self.direct_light, gctx)
  shadow_sphere_render_system.shutdown(&self.shadow_sphere_render, gctx)
  shadow_render_system.shutdown(&self.shadow_render, gctx)
  shadow_sphere_culling_system.shutdown(&self.shadow_sphere_culling, gctx)
  shadow_culling_system.shutdown(&self.shadow_culling, gctx)
  geometry.shutdown(&self.geometry, gctx)
  depth_pyramid_system.shutdown(&self.depth_pyramid, gctx)
  occlusion_culling.shutdown(&self.visibility, gctx)
  vk.DestroySampler(gctx.device, self.linear_repeat_sampler, nil)
  self.linear_repeat_sampler = 0
  vk.DestroySampler(gctx.device, self.linear_clamp_sampler, nil)
  self.linear_clamp_sampler = 0
  vk.DestroySampler(gctx.device, self.nearest_repeat_sampler, nil)
  self.nearest_repeat_sampler = 0
  vk.DestroySampler(gctx.device, self.nearest_clamp_sampler, nil)
  self.nearest_clamp_sampler = 0
  gpu.texture_manager_shutdown(&self.texture_manager, gctx)
  gpu.bindless_buffer_destroy(&self.material_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.node_data_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.mesh_data_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.emitter_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.forcefield_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.sprite_buffer, gctx.device)
  gpu.per_frame_bindless_buffer_destroy(&self.camera_buffer, gctx.device)
  delete(self.bone_matrix_offsets)
  gpu.per_frame_bindless_buffer_destroy(&self.bone_buffer, gctx.device)
  cont.slab_destroy(&self.bone_matrix_slab)
  gpu.mesh_manager_shutdown(&self.mesh_manager, gctx)
  delete(self.per_camera_data)
  delete(self.per_light_data)
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

// prepare_lights_for_frame assigns sequential light indices and computes shadow
// matrices (view, projection, frustum planes) for all lights. Must be called
// once per frame before any shadow culling/rendering, whether via the legacy
// path or the frame graph path.
prepare_lights_for_frame :: proc(self: ^Manager) {
  light_node_indices := make(
    [dynamic]u32,
    0,
    len(self.per_light_data),
    context.temp_allocator,
  )
  defer delete(light_node_indices)
  for light_node_index in self.per_light_data {
    append(&light_node_indices, light_node_index)
  }
  slice.sort(light_node_indices[:])
  next_light_index: u32 = 0
  for light_node_index in light_node_indices {
    light := &self.per_light_data[light_node_index]
    if next_light_index >= rd.MAX_LIGHTS do continue
    light.light_index = next_light_index
    next_light_index += 1
    switch &variant in light.light {
    case PointLight:
      shadow, has_shadow := &variant.shadow.?
      if has_shadow {
        shadow.near = 0.1
        shadow.far = max(shadow.near + 0.1, variant.radius)
        shadow.projection = linalg.matrix4_perspective(
          f32(math.PI * 0.5),
          1.0,
          shadow.near,
          shadow.far,
          flip_z_axis = false,
        )
      }
    case SpotLight:
      shadow, has_shadow := &variant.shadow.?
      if has_shadow {
        shadow.near = 0.1
        shadow.far = max(shadow.near + 0.1, variant.radius)
        shadow.view = shadow_make_light_view(
          variant.position,
          variant.direction,
        )
        shadow.projection = linalg.matrix4_perspective(
          max(variant.angle_outer * 2.0, 0.001),
          1.0,
          shadow.near,
          shadow.far,
        )
        shadow.view_projection = shadow.projection * shadow.view
        shadow.frustum_planes =
          geom.make_frustum(shadow.view_projection).planes
      }
    case DirectionalLight:
      shadow, has_shadow := &variant.shadow.?
      if has_shadow {
        shadow.near = 0.1
        shadow.far = max(shadow.near + 0.1, variant.radius * 2.0)
        camera_pos := variant.position - variant.direction * variant.radius
        shadow.view = shadow_make_light_view(camera_pos, variant.direction)
        half_extent := max(variant.radius, 0.5)
        shadow.projection = linalg.matrix_ortho3d(
          -half_extent,
          half_extent,
          -half_extent,
          half_extent,
          shadow.near,
          shadow.far,
        )
        shadow.view_projection = shadow.projection * shadow.view
        shadow.frustum_planes =
          geom.make_frustum(shadow.view_projection).planes
      }
    }
  }
}

render_shadow_depth :: proc(self: ^Manager, frame_index: u32) -> vk.Result {
  cmd := self.command_buffers[frame_index]
  prepare_lights_for_frame(self)
  active_shadow_keys := make(
    [dynamic]u32,
    0,
    len(self.per_light_data),
    context.temp_allocator,
  )
  defer delete(active_shadow_keys)
  for light_node_index in self.per_light_data {
    light_data := &self.per_light_data[light_node_index]
    if light_data.light_index >= rd.MAX_LIGHTS do continue
    switch &variant in light_data.light {
    case PointLight:
      if variant.shadow != nil do append(&active_shadow_keys, light_node_index)
    case SpotLight:
      if variant.shadow != nil do append(&active_shadow_keys, light_node_index)
    case DirectionalLight:
      if variant.shadow != nil do append(&active_shadow_keys, light_node_index)
    }
  }
  for light_node_index in active_shadow_keys {
    light_data := &self.per_light_data[light_node_index]
    // Access shadow resources from Light union variant
    switch &variant in &light_data.light {
    case SpotLight:
    shadow, has_shadow := &variant.shadow.?
      shadow_culling_system.execute(
        &self.shadow_culling,
        cmd,
        shadow.frustum_planes,
        shadow.draw_count[frame_index].buffer,
        shadow.descriptor_sets[frame_index],
      )
      shadow_render_system.render(
        &self.shadow_render,
        cmd,
        &self.texture_manager,
        shadow.view_projection,
        shadow.shadow_map_2d[frame_index],
        shadow.draw_commands[frame_index],
        shadow.draw_count[frame_index],
        self.texture_manager.descriptor_set,
        self.bone_buffer.descriptor_sets[frame_index],
        self.material_buffer.descriptor_set,
        self.node_data_buffer.descriptor_set,
        self.mesh_data_buffer.descriptor_set,
        self.mesh_manager.vertex_skinning_buffer.descriptor_set,
        self.mesh_manager.vertex_buffer.buffer,
        self.mesh_manager.index_buffer.buffer,
        frame_index,
      )
    case DirectionalLight:
    shadow, has_shadow := &variant.shadow.?
      shadow_culling_system.execute(
        &self.shadow_culling,
        cmd,
        shadow.frustum_planes,
        shadow.draw_count[frame_index].buffer,
        shadow.descriptor_sets[frame_index],
      )
      shadow_render_system.render(
        &self.shadow_render,
        cmd,
        &self.texture_manager,
        shadow.view_projection,
        shadow.shadow_map_2d[frame_index],
        shadow.draw_commands[frame_index],
        shadow.draw_count[frame_index],
        self.texture_manager.descriptor_set,
        self.bone_buffer.descriptor_sets[frame_index],
        self.material_buffer.descriptor_set,
        self.node_data_buffer.descriptor_set,
        self.mesh_data_buffer.descriptor_set,
        self.mesh_manager.vertex_skinning_buffer.descriptor_set,
        self.mesh_manager.vertex_buffer.buffer,
        self.mesh_manager.index_buffer.buffer,
        frame_index,
      )
    case PointLight:
    shadow, has_shadow := &variant.shadow.?
      shadow_sphere_culling_system.execute(
        &self.shadow_sphere_culling,
        cmd,
        variant.position,
        variant.radius,
        shadow.draw_count[frame_index].buffer,
        shadow.descriptor_sets[frame_index],
      )
      shadow_sphere_render_system.render(
        &self.shadow_sphere_render,
        cmd,
        &self.texture_manager,
        shadow.projection,
        shadow.near,
        shadow.far,
        variant.position,
        shadow.shadow_map_cube[frame_index],
        shadow.draw_commands[frame_index],
        shadow.draw_count[frame_index],
        self.texture_manager.descriptor_set,
        self.bone_buffer.descriptor_sets[frame_index],
        self.material_buffer.descriptor_set,
        self.node_data_buffer.descriptor_set,
        self.mesh_data_buffer.descriptor_set,
        self.mesh_manager.vertex_skinning_buffer.descriptor_set,
        self.mesh_manager.vertex_buffer.buffer,
        self.mesh_manager.index_buffer.buffer,
        frame_index,
      )
    }
  }
  return .SUCCESS
}

record_geometry_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  cam_index: u32,
  cam: ^Camera,
) -> vk.Result {
  cmd := self.command_buffers[frame_index]
  geometry.begin_pass(
    cam.attachments[.POSITION][frame_index],
    cam.attachments[.NORMAL][frame_index],
    cam.attachments[.ALBEDO][frame_index],
    cam.attachments[.METALLIC_ROUGHNESS][frame_index],
    cam.attachments[.EMISSIVE][frame_index],
    cam.attachments[.FINAL_IMAGE][frame_index],
    cam.attachments[.DEPTH][frame_index],
    &self.texture_manager,
    cmd,
  )
  geometry.render(
    &self.geometry,
    cam_index,
    cmd,
    self.camera_buffer.descriptor_sets[frame_index],
    self.texture_manager.descriptor_set,
    self.bone_buffer.descriptor_sets[frame_index],
    self.material_buffer.descriptor_set,
    self.node_data_buffer.descriptor_set,
    self.mesh_data_buffer.descriptor_set,
    self.mesh_manager.vertex_skinning_buffer.descriptor_set,
    self.mesh_manager.vertex_buffer.buffer,
    self.mesh_manager.index_buffer.buffer,
    cam.opaque_draw_commands[frame_index].buffer,
    cam.opaque_draw_count[frame_index].buffer,
  )
  geometry.end_pass(
    cam.attachments[.POSITION][frame_index],
    cam.attachments[.NORMAL][frame_index],
    cam.attachments[.ALBEDO][frame_index],
    cam.attachments[.METALLIC_ROUGHNESS][frame_index],
    cam.attachments[.EMISSIVE][frame_index],
    cam.attachments[.DEPTH][frame_index],
    &self.texture_manager,
    cmd,
  )
  return .SUCCESS
}

record_lighting_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  cam_index: u32,
  cam: ^Camera,
) -> vk.Result {
  cmd := self.command_buffers[frame_index]
  ambient.begin_pass(
    &self.ambient,
    cam.attachments[.FINAL_IMAGE][frame_index],
    &self.texture_manager,
    cmd,
    self.camera_buffer.descriptor_sets[frame_index],
  )
  ambient.render(
    &self.ambient,
    cam_index,
    cam.attachments[.POSITION][frame_index].index,
    cam.attachments[.NORMAL][frame_index].index,
    cam.attachments[.ALBEDO][frame_index].index,
    cam.attachments[.METALLIC_ROUGHNESS][frame_index].index,
    cam.attachments[.EMISSIVE][frame_index].index,
    cmd,
  )
  ambient.end_pass(cmd)
  direct_light.begin_pass(
    &self.direct_light,
    cam.attachments[.FINAL_IMAGE][frame_index],
    cam.attachments[.DEPTH][frame_index],
    &self.texture_manager,
    cmd,
    self.camera_buffer.descriptor_sets[frame_index],
  )
  light_node_indices := make(
    [dynamic]u32,
    0,
    len(self.per_light_data),
    context.temp_allocator,
  )
  defer delete(light_node_indices)
  for light_node_index in self.per_light_data {
    append(&light_node_indices, light_node_index)
  }
  slice.sort(light_node_indices[:])
  for light_node_index in light_node_indices {
    light_data := &self.per_light_data[light_node_index]
    if light_data.light_index >= rd.MAX_LIGHTS do continue

    switch &variant in &light_data.light {
    case PointLight:
      shadow_map_idx: u32 = 0xFFFFFFFF
      shadow_view_projection := matrix[4, 4]f32{}
      if variant.shadow != nil {
        sm := variant.shadow.?
        shadow_map_idx = sm.shadow_map_cube[frame_index].index
        shadow_view_projection = sm.projection
      }
      direct_light.render_point_light(
        &self.direct_light,
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
      if variant.shadow != nil {
        sm := variant.shadow.?
        shadow_map_idx = sm.shadow_map_2d[frame_index].index
        shadow_view_projection = sm.view_projection
      }
      direct_light.render_spot_light(
        &self.direct_light,
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
      if variant.shadow != nil {
        sm := variant.shadow.?
        shadow_map_idx = sm.shadow_map_2d[frame_index].index
        shadow_view_projection = sm.view_projection
      }
      direct_light.render_directional_light(
        &self.direct_light,
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

record_particles_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  cam_index: u32,
  cam: ^Camera,
) -> vk.Result {
  cmd := self.command_buffers[frame_index]
  particles_render.begin_pass(
    &self.particles_render,
    cmd,
    cam.attachments[.FINAL_IMAGE][frame_index],
    cam.attachments[.DEPTH][frame_index],
    &self.texture_manager,
  )
  particles_render.render(
    &self.particles_render,
    cmd,
    cam_index,
    self.camera_buffer.descriptor_sets[frame_index],
    self.texture_manager.descriptor_set,
    self.compact_particle_buffer.buffer,
    self.particle_draw_command_buffer.buffer,
  )
  particles_render.end_pass(cmd)
  return .SUCCESS
}

record_transparency_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  gctx: ^gpu.GPUContext,
  cam_index: u32,
  cam: ^Camera,
) -> vk.Result {
  cmd := self.command_buffers[frame_index]

  // Begin pass (shared by all 5 techniques)
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

  // Render transparent objects
  gpu.buffer_barrier(
    cmd,
    cam.transparent_draw_commands[frame_index].buffer,
    vk.DeviceSize(cam.transparent_draw_commands[frame_index].bytes_count),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  gpu.buffer_barrier(
    cmd,
    cam.transparent_draw_count[frame_index].buffer,
    vk.DeviceSize(cam.transparent_draw_count[frame_index].bytes_count),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  transparent.render(
    &self.transparent_renderer,
    cmd,
    cam_index,
    self.camera_buffer.descriptor_sets[frame_index],
    self.texture_manager.descriptor_set,
    self.bone_buffer.descriptor_sets[frame_index],
    self.material_buffer.descriptor_set,
    self.node_data_buffer.descriptor_set,
    self.mesh_data_buffer.descriptor_set,
    self.mesh_manager.vertex_skinning_buffer.descriptor_set,
    self.mesh_manager.vertex_buffer.buffer,
    self.mesh_manager.index_buffer.buffer,
    cam.transparent_draw_commands[frame_index].buffer,
    cam.transparent_draw_count[frame_index].buffer,
    rd.MAX_NODES_IN_SCENE,
  )

  // Render wireframe objects
  gpu.buffer_barrier(
    cmd,
    cam.wireframe_draw_commands[frame_index].buffer,
    vk.DeviceSize(cam.wireframe_draw_commands[frame_index].bytes_count),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  gpu.buffer_barrier(
    cmd,
    cam.wireframe_draw_count[frame_index].buffer,
    vk.DeviceSize(cam.wireframe_draw_count[frame_index].bytes_count),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  wireframe.render(
    &self.wireframe_renderer,
    cmd,
    cam_index,
    self.camera_buffer.descriptor_sets[frame_index],
    self.texture_manager.descriptor_set,
    self.bone_buffer.descriptor_sets[frame_index],
    self.material_buffer.descriptor_set,
    self.node_data_buffer.descriptor_set,
    self.mesh_data_buffer.descriptor_set,
    self.mesh_manager.vertex_skinning_buffer.descriptor_set,
    self.mesh_manager.vertex_buffer.buffer,
    self.mesh_manager.index_buffer.buffer,
    cam.wireframe_draw_commands[frame_index].buffer,
    cam.wireframe_draw_count[frame_index].buffer,
    rd.MAX_NODES_IN_SCENE,
  )

  // Render random_color objects
  gpu.buffer_barrier(
    cmd,
    cam.random_color_draw_commands[frame_index].buffer,
    vk.DeviceSize(cam.random_color_draw_commands[frame_index].bytes_count),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  gpu.buffer_barrier(
    cmd,
    cam.random_color_draw_count[frame_index].buffer,
    vk.DeviceSize(cam.random_color_draw_count[frame_index].bytes_count),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  random_color.render(
    &self.random_color_renderer,
    cmd,
    cam_index,
    self.camera_buffer.descriptor_sets[frame_index],
    self.texture_manager.descriptor_set,
    self.bone_buffer.descriptor_sets[frame_index],
    self.material_buffer.descriptor_set,
    self.node_data_buffer.descriptor_set,
    self.mesh_data_buffer.descriptor_set,
    self.mesh_manager.vertex_skinning_buffer.descriptor_set,
    self.mesh_manager.vertex_buffer.buffer,
    self.mesh_manager.index_buffer.buffer,
    cam.random_color_draw_commands[frame_index].buffer,
    cam.random_color_draw_count[frame_index].buffer,
    rd.MAX_NODES_IN_SCENE,
  )

  // Render line_strip objects
  gpu.buffer_barrier(
    cmd,
    cam.line_strip_draw_commands[frame_index].buffer,
    vk.DeviceSize(cam.line_strip_draw_commands[frame_index].bytes_count),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  gpu.buffer_barrier(
    cmd,
    cam.line_strip_draw_count[frame_index].buffer,
    vk.DeviceSize(cam.line_strip_draw_count[frame_index].bytes_count),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  line_strip.render(
    &self.line_strip_renderer,
    cmd,
    cam_index,
    self.camera_buffer.descriptor_sets[frame_index],
    self.texture_manager.descriptor_set,
    self.bone_buffer.descriptor_sets[frame_index],
    self.material_buffer.descriptor_set,
    self.node_data_buffer.descriptor_set,
    self.mesh_data_buffer.descriptor_set,
    self.mesh_manager.vertex_skinning_buffer.descriptor_set,
    self.mesh_manager.vertex_buffer.buffer,
    self.mesh_manager.index_buffer.buffer,
    cam.line_strip_draw_commands[frame_index].buffer,
    cam.line_strip_draw_count[frame_index].buffer,
    rd.MAX_NODES_IN_SCENE,
  )

  // Render sprites
  gpu.buffer_barrier(
    cmd,
    cam.sprite_draw_commands[frame_index].buffer,
    vk.DeviceSize(cam.sprite_draw_commands[frame_index].bytes_count),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  gpu.buffer_barrier(
    cmd,
    cam.sprite_draw_count[frame_index].buffer,
    vk.DeviceSize(cam.sprite_draw_count[frame_index].bytes_count),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  sprite.render(
    &self.sprite_renderer,
    cmd,
    cam_index,
    self.camera_buffer.descriptor_sets[frame_index],
    self.texture_manager.descriptor_set,
    self.node_data_buffer.descriptor_set,
    self.sprite_buffer.descriptor_set,
    self.mesh_manager.vertex_buffer.buffer,
    self.mesh_manager.index_buffer.buffer,
    cam.sprite_draw_commands[frame_index].buffer,
    cam.sprite_draw_count[frame_index].buffer,
    rd.MAX_NODES_IN_SCENE,
  )

  // End pass
  vk.CmdEndRendering(cmd)
  return .SUCCESS
}

record_debug_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  cam_index: u32,
  cam: ^Camera,
) -> vk.Result {
  // Skip debug rendering if no instances are staged
  if len(self.debug_renderer.bone_instances) == 0 do return .SUCCESS

  cmd := self.command_buffers[frame_index]

  // Begin debug render pass (renders on top of transparency)
  // Skip rendering if attachments are missing
  if !debug_bone.begin_pass(
    &self.debug_renderer,
    cam.attachments[.FINAL_IMAGE][frame_index],
    cam.attachments[.DEPTH][frame_index],
    &self.texture_manager,
    cmd,
  ) {
    return .SUCCESS
  }

  // Render debug visualization (bones, etc.)
  debug_bone.render(
    &self.debug_renderer,
    cmd,
    self.camera_buffer.descriptor_sets[frame_index],
    cam_index,
  ) or_return

  debug_bone.end_pass(&self.debug_renderer, cmd)

  return .SUCCESS
}

record_post_process_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  cam: ^Camera,
  swapchain_extent: vk.Extent2D,
  swapchain_image: vk.Image,
  swapchain_view: vk.ImageView,
) -> vk.Result {
  cmd := self.command_buffers[frame_index]
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
  post_process.begin_pass(&self.post_process, cmd, swapchain_extent)
  post_process.render(
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
  post_process.end_pass(&self.post_process, cmd)
  return .SUCCESS
}

record_ui_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  gctx: ^gpu.GPUContext,
  swapchain_view: vk.ImageView,
  swapchain_extent: vk.Extent2D,
) {
  cmd := self.command_buffers[frame_index]
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

  // Bind pipeline and descriptor sets
  vk.CmdBindPipeline(cmd, .GRAPHICS, self.ui.pipeline)
  vk.CmdBindDescriptorSets(
    cmd,
    .GRAPHICS,
    self.ui.pipeline_layout,
    0,
    1,
    &self.texture_manager.descriptor_set,
    0,
    nil,
  )

  // Render UI using staged commands
  ui_render.render(
    &self.ui,
    self.ui_commands[:],
    gctx,
    &self.texture_manager,
    cmd,
    swapchain_extent.width,
    swapchain_extent.height,
    frame_index,
  )

  vk.CmdEndRendering(cmd)
}

sync_mesh_geometry_for_handle :: proc(
  gctx: ^gpu.GPUContext,
  render: ^Manager,
  handle: u32,
  geometry_data: geom.Geometry,
) -> vk.Result {
  mesh := gpu.mutable_buffer_get(&render.mesh_data_buffer.buffer, handle)
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

free_mesh_geometry :: proc(render: ^Manager, handle: u32) {
  mesh := gpu.mutable_buffer_get(&render.mesh_data_buffer.buffer, handle)
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
  shadow: ^ShadowMap,
) {
  for frame in 0 ..< rd.FRAMES_IN_FLIGHT {
    gpu.free_texture_2d(
      &render.texture_manager,
      gctx,
      shadow.shadow_map_2d[frame],
    )
    gpu.mutable_buffer_destroy(gctx.device, &shadow.draw_count[frame])
    gpu.mutable_buffer_destroy(gctx.device, &shadow.draw_commands[frame])
    shadow.descriptor_sets[frame] = 0
  }
}

@(private)
release_shadow_cube :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
  shadow: ^ShadowMapCube,
) {
  for frame in 0 ..< rd.FRAMES_IN_FLIGHT {
    gpu.free_texture_cube(
      &render.texture_manager,
      gctx,
      shadow.shadow_map_cube[frame],
    )
    gpu.mutable_buffer_destroy(gctx.device, &shadow.draw_count[frame])
    gpu.mutable_buffer_destroy(gctx.device, &shadow.draw_commands[frame])
    shadow.descriptor_sets[frame] = 0
  }
}

@(private)
ensure_shadow_2d_resource :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
  shadow: ^Maybe(ShadowMap),
) -> vk.Result {
  // Check if already allocated
  if shadow != nil {
    if sm, ok := shadow^.?; ok {
      if sm.shadow_map_2d[0].index != 0 do return .SUCCESS
    }
  }

  // Allocate new shadow resources
  sm: ShadowMap
  for frame in 0 ..< rd.FRAMES_IN_FLIGHT {
    sm.shadow_map_2d[frame] = gpu.allocate_texture_2d(
      &render.texture_manager,
      gctx,
      vk.Extent2D{rd.SHADOW_MAP_SIZE, rd.SHADOW_MAP_SIZE},
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
      rd.MAX_NODES_IN_SCENE,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER},
    ) or_return
    sm.descriptor_sets[frame] = gpu.create_descriptor_set(
      gctx,
      &render.shadow_culling.descriptor_layout,
      {.STORAGE_BUFFER, gpu.buffer_info(&render.node_data_buffer.buffer)},
      {.STORAGE_BUFFER, gpu.buffer_info(&render.mesh_data_buffer.buffer)},
      {.STORAGE_BUFFER, gpu.buffer_info(&sm.draw_count[frame])},
      {.STORAGE_BUFFER, gpu.buffer_info(&sm.draw_commands[frame])},
    ) or_return
  }
  shadow^ = sm
  return .SUCCESS
}

@(private)
ensure_shadow_cube_resource :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
  shadow: ^Maybe(ShadowMapCube),
) -> vk.Result {
  // Check if already allocated
  if shadow != nil {
    if sm, ok := shadow^.?; ok {
      if sm.shadow_map_cube[0].index != 0 do return .SUCCESS
    }
  }

  // Allocate new shadow resources
  sm: ShadowMapCube
  for frame in 0 ..< rd.FRAMES_IN_FLIGHT {
    sm.shadow_map_cube[frame] = gpu.allocate_texture_cube(
      &render.texture_manager,
      gctx,
      rd.SHADOW_MAP_SIZE,
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
      rd.MAX_NODES_IN_SCENE,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER},
    ) or_return
    sm.descriptor_sets[frame] = gpu.create_descriptor_set(
      gctx,
      &render.shadow_sphere_culling.descriptor_layout,
      {.STORAGE_BUFFER, gpu.buffer_info(&render.node_data_buffer.buffer)},
      {.STORAGE_BUFFER, gpu.buffer_info(&render.mesh_data_buffer.buffer)},
      {.STORAGE_BUFFER, gpu.buffer_info(&sm.draw_count[frame])},
      {.STORAGE_BUFFER, gpu.buffer_info(&sm.draw_commands[frame])},
    ) or_return
  }
  shadow^ = sm
  return .SUCCESS
}

upsert_light_entry :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
  light_node_index: u32,
  light_data: ^Light,
  cast_shadow: bool,
) -> vk.Result {
  is_existing := light_node_index in render.per_light_data

  if is_existing {
    // UPDATE PATH: Preserve shadow resources when updating light properties
    light := &render.per_light_data[light_node_index]
    existing_shadow_2d: Maybe(ShadowMap)
    existing_shadow_cube: Maybe(ShadowMapCube)

    #partial switch &variant in &light.light {
    case SpotLight:
      existing_shadow_2d = variant.shadow
    case DirectionalLight:
      existing_shadow_2d = variant.shadow
    case PointLight:
      existing_shadow_cube = variant.shadow
    }

    // Update light data
    light.light = light_data^

    // Restore preserved shadows
    #partial switch &variant in &light.light {
    case SpotLight:
      variant.shadow = existing_shadow_2d
    case DirectionalLight:
      variant.shadow = existing_shadow_2d
    case PointLight:
      variant.shadow = existing_shadow_cube
    }
  } else {
    // INSERT PATH: Create new entry (no shadows to preserve)
    render.per_light_data[light_node_index] = PerLightData {
      light       = light_data^,
      light_index = rd.MAX_LIGHTS,
    }
  }

  // Manage shadow resources (common for both insert and update)
  light := &render.per_light_data[light_node_index]
  if cast_shadow {
    shadow_result: vk.Result
    switch &variant in &light.light {
    case PointLight:
      shadow_result = ensure_shadow_cube_resource(
        render,
        gctx,
        &variant.shadow,
      )
    case SpotLight:
      shadow_result = ensure_shadow_2d_resource(render, gctx, &variant.shadow)
    case DirectionalLight:
      shadow_result = ensure_shadow_2d_resource(render, gctx, &variant.shadow)
    }
    if shadow_result != .SUCCESS {
      log.warnf(
        "Failed to allocate shadow resources for light %d: %v (shadows disabled)",
        light_node_index,
        shadow_result,
      )
    }
  } else {
    // Release shadow resources if they exist
    switch &variant in &light.light {
    case PointLight:
      if variant.shadow != nil {
        sm := variant.shadow.?
        release_shadow_cube(render, gctx, &sm)
        variant.shadow = nil
      }
    case SpotLight:
      if variant.shadow != nil {
        sm := variant.shadow.?
        release_shadow_2d(render, gctx, &sm)
        variant.shadow = nil
      }
    case DirectionalLight:
      if variant.shadow != nil {
        sm := variant.shadow.?
        release_shadow_2d(render, gctx, &sm)
        variant.shadow = nil
      }
    }
  }

  return .SUCCESS
}

remove_light_entry :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
  light_node_index: u32,
) {
  light, ok := render.per_light_data[light_node_index]
  if !ok do return

  // Release shadow resources if they exist
  switch &variant in light.light {
  case PointLight:
    if variant.shadow != nil {
      sm := variant.shadow.?
      release_shadow_cube(render, gctx, &sm)
    }
  case SpotLight:
    if variant.shadow != nil {
      sm := variant.shadow.?
      release_shadow_2d(render, gctx, &sm)
    }
  case DirectionalLight:
    if variant.shadow != nil {
      sm := variant.shadow.?
      release_shadow_2d(render, gctx, &sm)
    }
  }

  delete_key(&render.per_light_data, light_node_index)
}

upload_node_data :: proc(render: ^Manager, index: u32, node_data: ^Node) {
  gpu.write(&render.node_data_buffer.buffer, node_data, int(index))
}

upload_bone_matrices :: proc(
  render: ^Manager,
  frame_index: u32,
  offset: u32,
  matrices: []matrix[4, 4]f32,
) {
  frame_buffer := &render.bone_buffer.buffers[frame_index]
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
  gpu.write(&render.sprite_buffer.buffer, sprite_data, int(index))
}

upload_emitter_data :: proc(render: ^Manager, index: u32, emitter: ^Emitter) {
  gpu.write(&render.emitter_buffer.buffer, emitter, int(index))
}

upload_forcefield_data :: proc(
  render: ^Manager,
  index: u32,
  forcefield: ^ForceField,
) {
  gpu.write(&render.forcefield_buffer.buffer, forcefield, int(index))
}

upload_mesh_data :: proc(render: ^Manager, index: u32, mesh: ^Mesh) {
  gpu.write(&render.mesh_data_buffer.buffer, mesh, int(index))
}

upload_material_data :: proc(
  render: ^Manager,
  index: u32,
  material: ^Material,
) {
  gpu.write(&render.material_buffer.buffer, material, int(index))
}

ensure_bone_matrix_range_for_node :: proc(
  render: ^Manager,
  handle: u32,
  bone_count: u32,
) -> u32 {
  if existing, ok := render.bone_matrix_offsets[handle]; ok {
    return existing
  }
  offset := cont.slab_alloc(&render.bone_matrix_slab, bone_count)
  if offset == 0xFFFFFFFF do return 0xFFFFFFFF
  render.bone_matrix_offsets[handle] = offset
  return offset
}

release_bone_matrix_range_for_node :: proc(render: ^Manager, handle: u32) {
  if offset, ok := render.bone_matrix_offsets[handle]; ok {
    cont.slab_free(&render.bone_matrix_slab, offset)
    delete_key(&render.bone_matrix_offsets, handle)
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
  camera_data: rd.Camera
  camera_data.view = view
  camera_data.projection = projection
  camera_data.viewport_extent = {f32(extent[0]), f32(extent[1])}
  camera_data.near = near
  camera_data.far = far
  camera_data.position = [4]f32{position.x, position.y, position.z, 1.0}
  frustum := geom.make_frustum(camera_data.projection * camera_data.view)
  camera_data.frustum_planes = frustum.planes
  gpu.write(
    &render.camera_buffer.buffers[frame_index],
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

PassType :: enum {
  SHADOW       = 0,
  GEOMETRY     = 1,
  LIGHTING     = 2,
  TRANSPARENCY = 3,
  PARTICLES    = 4,
  POST_PROCESS = 5,
}

PassTypeSet :: bit_set[PassType;u32]

Camera :: struct {
  // Render pass configuration
  enabled_passes:               PassTypeSet,
  // Visibility culling control flags
  enable_culling:               bool, // If false, skip culling compute pass
  // GPU resources - Render target attachments (G-buffer textures, depth, final image)
  attachments:                  [AttachmentType][FRAMES_IN_FLIGHT]gpu.Texture2DHandle,
  // Indirect draw buffers (double-buffered for async compute)
  // Frame N compute writes to buffers[N], Frame N graphics reads from buffers[N-1]
  opaque_draw_count:            [FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  opaque_draw_commands:         [FRAMES_IN_FLIGHT]gpu.MutableBuffer(
    vk.DrawIndexedIndirectCommand,
  ),
  transparent_draw_count:       [FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  transparent_draw_commands:    [FRAMES_IN_FLIGHT]gpu.MutableBuffer(
    vk.DrawIndexedIndirectCommand,
  ),
  wireframe_draw_count:         [FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  wireframe_draw_commands:      [FRAMES_IN_FLIGHT]gpu.MutableBuffer(
    vk.DrawIndexedIndirectCommand,
  ),
  random_color_draw_count:      [FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  random_color_draw_commands:   [FRAMES_IN_FLIGHT]gpu.MutableBuffer(
    vk.DrawIndexedIndirectCommand,
  ),
  line_strip_draw_count:        [FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  line_strip_draw_commands:     [FRAMES_IN_FLIGHT]gpu.MutableBuffer(
    vk.DrawIndexedIndirectCommand,
  ),
  sprite_draw_count:            [FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  sprite_draw_commands:         [FRAMES_IN_FLIGHT]gpu.MutableBuffer(
    vk.DrawIndexedIndirectCommand,
  ),
  // Depth pyramid for hierarchical Z culling
  depth_pyramid:                [FRAMES_IN_FLIGHT]depth_pyramid_system.DepthPyramid,
  // Descriptor sets for visibility culling compute shaders
  descriptor_set:               [FRAMES_IN_FLIGHT]vk.DescriptorSet,
  depth_reduce_descriptor_sets: [FRAMES_IN_FLIGHT][depth_pyramid_system.MAX_DEPTH_MIPS_LEVEL]vk.DescriptorSet,
}


// Initialize GPU resources for perspective camera
// Takes only the specific resources needed, no dependency on render manager
camera_init :: proc(
  gctx: ^gpu.GPUContext,
  camera: ^Camera,
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
  },
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

  // Create indirect draw buffers (double-buffered)
  for frame in 0 ..< FRAMES_IN_FLIGHT {
    camera.opaque_draw_count[frame] = gpu.create_mutable_buffer(
      gctx,
      u32,
      1,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
    ) or_return
    camera.opaque_draw_commands[frame] = gpu.create_mutable_buffer(
      gctx,
      vk.DrawIndexedIndirectCommand,
      int(max_draws),
      {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
    ) or_return
    camera.transparent_draw_count[frame] = gpu.create_mutable_buffer(
      gctx,
      u32,
      1,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
    ) or_return
    camera.transparent_draw_commands[frame] = gpu.create_mutable_buffer(
      gctx,
      vk.DrawIndexedIndirectCommand,
      int(max_draws),
      {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
    ) or_return
    camera.wireframe_draw_count[frame] = gpu.create_mutable_buffer(
      gctx,
      u32,
      1,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
    ) or_return
    camera.wireframe_draw_commands[frame] = gpu.create_mutable_buffer(
      gctx,
      vk.DrawIndexedIndirectCommand,
      int(max_draws),
      {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
    ) or_return
    camera.random_color_draw_count[frame] = gpu.create_mutable_buffer(
      gctx,
      u32,
      1,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
    ) or_return
    camera.random_color_draw_commands[frame] = gpu.create_mutable_buffer(
      gctx,
      vk.DrawIndexedIndirectCommand,
      int(max_draws),
      {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
    ) or_return
    camera.line_strip_draw_count[frame] = gpu.create_mutable_buffer(
      gctx,
      u32,
      1,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
    ) or_return
    camera.line_strip_draw_commands[frame] = gpu.create_mutable_buffer(
      gctx,
      vk.DrawIndexedIndirectCommand,
      int(max_draws),
      {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
    ) or_return
    camera.sprite_draw_count[frame] = gpu.create_mutable_buffer(
      gctx,
      u32,
      1,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
    ) or_return
    camera.sprite_draw_commands[frame] = gpu.create_mutable_buffer(
      gctx,
      vk.DrawIndexedIndirectCommand,
      int(max_draws),
      {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
    ) or_return
  }

  if camera.enable_culling {
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
  camera: ^Camera,
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
  for frame in 0 ..< FRAMES_IN_FLIGHT {
    gpu.mutable_buffer_destroy(gctx.device, &camera.opaque_draw_count[frame])
    gpu.mutable_buffer_destroy(
      gctx.device,
      &camera.opaque_draw_commands[frame],
    )
    gpu.mutable_buffer_destroy(
      gctx.device,
      &camera.transparent_draw_count[frame],
    )
    gpu.mutable_buffer_destroy(
      gctx.device,
      &camera.transparent_draw_commands[frame],
    )
    gpu.mutable_buffer_destroy(
      gctx.device,
      &camera.wireframe_draw_count[frame],
    )
    gpu.mutable_buffer_destroy(
      gctx.device,
      &camera.wireframe_draw_commands[frame],
    )
    gpu.mutable_buffer_destroy(
      gctx.device,
      &camera.random_color_draw_count[frame],
    )
    gpu.mutable_buffer_destroy(
      gctx.device,
      &camera.random_color_draw_commands[frame],
    )
    gpu.mutable_buffer_destroy(
      gctx.device,
      &camera.line_strip_draw_count[frame],
    )
    gpu.mutable_buffer_destroy(
      gctx.device,
      &camera.line_strip_draw_commands[frame],
    )
    gpu.mutable_buffer_destroy(gctx.device, &camera.sprite_draw_count[frame])
    gpu.mutable_buffer_destroy(
      gctx.device,
      &camera.sprite_draw_commands[frame],
    )
  }
  // Zero out the GPU struct
  camera^ = {}
}

// Allocate descriptor sets for perspective/orthographic camera culling pipelines
camera_allocate_descriptors :: proc(
  gctx: ^gpu.GPUContext,
  camera: ^Camera,
  texture_manager: ^gpu.TextureManager,
  normal_descriptor_layout: ^vk.DescriptorSetLayout,
  depth_reduce_descriptor_layout: ^vk.DescriptorSetLayout,
  node_data_buffer: ^gpu.BindlessBuffer(rd.Node),
  mesh_data_buffer: ^gpu.BindlessBuffer(rd.Mesh),
  camera_buffer: ^gpu.PerFrameBindlessBuffer(rd.Camera, FRAMES_IN_FLIGHT),
) -> vk.Result {
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
        gpu.buffer_info(&camera.opaque_draw_count[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.opaque_draw_commands[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.transparent_draw_count[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.transparent_draw_commands[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.sprite_draw_count[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.sprite_draw_commands[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.wireframe_draw_count[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.wireframe_draw_commands[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.random_color_draw_count[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.random_color_draw_commands[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.line_strip_draw_count[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.line_strip_draw_commands[frame_index]),
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
  camera: ^Camera,
  texture_manager: ^gpu.TextureManager,
  extent: vk.Extent2D,
  color_format, depth_format: vk.Format,
  enabled_passes: PassTypeSet,
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
  if camera.enable_culling {
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

// ============================================================================
// Frame Graph Compilation
// ============================================================================

// Compile frame graph from current topology (camera/light counts)
compile_frame_graph :: proc(
	self: ^Manager,
	gctx: ^gpu.GPUContext,
) -> vk.Result {
	log.info("Compiling frame graph...")

	// Build camera and light handle arrays for graph context
	camera_handles := make([dynamic]u32, 0, len(self.per_camera_data))
	defer delete(camera_handles)
	for handle in self.per_camera_data {
		append(&camera_handles, handle)
	}
	slice.sort(camera_handles[:])

	light_handles := make([dynamic]u32, 0, len(self.per_light_data))
	defer delete(light_handles)
	for handle in self.per_light_data {
		append(&light_handles, handle)
	}
	slice.sort(light_handles[:])

	log.infof("Frame graph topology: %d cameras, %d lights", len(camera_handles), len(light_handles))

	// Validate we have at least one camera
	if len(camera_handles) == 0 {
		log.warn("No cameras registered - frame graph requires at least one camera")
		return .ERROR_UNKNOWN
	}

	// Create compile context
	ctx := graph.CompileContext{
		num_cameras = len(camera_handles),
		num_lights = len(light_handles),
		frames_in_flight = FRAMES_IN_FLIGHT,
		gctx = gctx,
		camera_handles = camera_handles[:],
		light_handles = light_handles[:],
	}

	// Build pass declarations
	pass_decls := build_pass_declarations(self)
	defer delete(pass_decls)

	// If graph exists, rebuild it; otherwise build new
	if self.frame_graph.sorted_passes != nil {
		err := graph.rebuild_graph(&self.frame_graph, pass_decls[:], ctx)
		if err != .NONE {
			log.errorf("Failed to rebuild frame graph: %v", err)
			return .ERROR_UNKNOWN
		}
	} else {
		new_graph, err := graph.build_graph(pass_decls[:], ctx)
		if err != .NONE {
			log.errorf("Failed to build frame graph: %v", err)
			return .ERROR_UNKNOWN
		}
		self.frame_graph = new_graph
	}

	log.infof("Frame graph compiled: %d passes, %d cameras, %d lights",
		len(self.frame_graph.sorted_passes), len(camera_handles), len(light_handles))

	return .SUCCESS
}

// get_camera_handle_by_index returns the actual camera handle for the N-th camera
// (sorted by handle value, matching compile_frame_graph ordering).
get_camera_handle_by_index :: proc(self: ^Manager, instance_idx: u32) -> u32 {
	handles := make([dynamic]u32, 0, len(self.per_camera_data), context.temp_allocator)
	for h in self.per_camera_data {
		append(&handles, h)
	}
	slice.sort(handles[:])
	if int(instance_idx) < len(handles) {
		return handles[instance_idx]
	}
	return 0
}

// get_light_handle_by_index returns the actual light handle for the N-th light
// (sorted by handle value, matching compile_frame_graph ordering).
get_light_handle_by_index :: proc(self: ^Manager, instance_idx: u32) -> u32 {
	handles := make([dynamic]u32, 0, len(self.per_light_data), context.temp_allocator)
	for h in self.per_light_data {
		append(&handles, h)
	}
	slice.sort(handles[:])
	if int(instance_idx) < len(handles) {
		return handles[instance_idx]
	}
	return 0
}
