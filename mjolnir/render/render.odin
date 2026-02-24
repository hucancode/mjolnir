package render

import alg "../algebra"
import cont "../containers"
import geom "../geometry"
import "../gpu"
import cmd "../gpu/ui"
import "camera"
import cam "camera"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import rd "data"
import "debug_bone"
import "debug_ui"
import "geometry"
import "ambient"
import "direct_light"
import "shadow"
import "occlusion_culling"
import particles_compute "particles_compute"
import particles_render "particles_render"
import "post_process"
import "transparent"
import "sprite"
import "wireframe"
import "line_strip"
import "random_color"
import ui_render "ui"
import rg "graph"
import vk "vendor:vulkan"

FRAMES_IN_FLIGHT :: rd.FRAMES_IN_FLIGHT

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
Light :: rd.Light
LightType :: rd.LightType
BoneInstance :: debug_bone.BoneInstance

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

ParticleResources :: struct {
	particle_buffer:         gpu.MutableBuffer(particles_compute.Particle),
	compact_particle_buffer: gpu.MutableBuffer(particles_compute.Particle),
	draw_command_buffer:     gpu.MutableBuffer(vk.DrawIndirectCommand),
}

Manager :: struct {
  command_buffers:         [FRAMES_IN_FLIGHT]vk.CommandBuffer,
  compute_command_buffers: [FRAMES_IN_FLIGHT]vk.CommandBuffer,

  // Render graph system
  graph:                   rg.Graph,

  // Renderers
  geometry:                geometry.Renderer,
  ambient:                 ambient.Renderer,
  direct_light:            direct_light.Renderer,
  transparent_renderer:    transparent.Renderer,
  sprite_renderer:         sprite.Renderer,
  wireframe_renderer:      wireframe.Renderer,
  line_strip_renderer:     line_strip.Renderer,
  random_color_renderer:   random_color.Renderer,
  particles_compute:       particles_compute.Renderer,
  particles_render:        particles_render.Renderer,
  particle_resources:      ParticleResources,
  post_process:            post_process.Renderer,
  debug_ui:                debug_ui.Renderer,
  debug_renderer:          debug_bone.Renderer,
  ui:                      ui_render.Renderer,
  ui_commands:             [dynamic]cmd.RenderCommand, // Staged commands from UI module
  cameras:                 map[u32]camera.Camera,
  meshes:                  map[u32]Mesh,
  visibility:              occlusion_culling.System,
  shadow:                  shadow.ShadowSystem,
  linear_repeat_sampler:   vk.Sampler,
  linear_clamp_sampler:    vk.Sampler,
  nearest_repeat_sampler:  vk.Sampler,
  nearest_clamp_sampler:   vk.Sampler,
  bone_buffer:             gpu.PerFrameBindlessBuffer(
    matrix[4, 4]f32,
    FRAMES_IN_FLIGHT,
  ),
  camera_buffer:           gpu.PerFrameBindlessBuffer(
    rd.Camera,
    FRAMES_IN_FLIGHT,
  ),
  material_buffer:         gpu.BindlessBuffer(Material),
  node_data_buffer:        gpu.BindlessBuffer(Node),
  mesh_data_buffer:        gpu.BindlessBuffer(Mesh),
  emitter_buffer:          gpu.BindlessBuffer(Emitter),
  forcefield_buffer:       gpu.BindlessBuffer(ForceField),
  sprite_buffer:           gpu.BindlessBuffer(Sprite),
  lights_buffer:           gpu.BindlessBuffer(Light),
  mesh_manager:            gpu.MeshManager,
  bone_matrix_slab:        cont.SlabAllocator,
  bone_matrix_offsets:     map[u32]u32,
  texture_manager:         gpu.TextureManager,
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
  self.cameras = make(map[u32]camera.Camera)
  self.meshes = make(map[u32]Mesh)
  self.ui_commands = make([dynamic]cmd.RenderCommand, 0, 256)

  // Initialize render graph
  rg.init(&self.graph)

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
  gpu.bindless_buffer_init(
    &self.lights_buffer,
    gctx,
    rd.MAX_LIGHTS,
    {.VERTEX, .FRAGMENT},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.lights_buffer, gctx.device)
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
  occlusion_culling.init(
    &self.visibility,
    gctx,
    swapchain_extent.width,
    swapchain_extent.height,
    self.camera_buffer.set_layout,
    self.texture_manager.set_layout,
    self.bone_buffer.set_layout,
    self.material_buffer.set_layout,
    self.node_data_buffer.set_layout,
    self.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
  ) or_return
  shadow.init(
    &self.shadow,
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
    self.lights_buffer.set_layout,
    self.shadow.shadow_data_buffer.set_layout,
    self.texture_manager.set_layout,
  ) or_return
  geometry.init(
    &self.geometry,
    gctx,
    swapchain_extent.width,
    swapchain_extent.height,
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

  // Register render graph resources for particle system
  register_particle_resources(self)

  // Register render graph resources for UI system
  register_ui_resources(self)

  // Register render graph resources for shadow system
  register_shadow_resources(self)

  // Register render graph resources for post-process system
  register_post_process_resources(self)

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
  ui_render.init_renderer(
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
  gpu.bindless_buffer_realloc_descriptor(&self.lights_buffer, gctx) or_return
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
  shadow.setup(
    &self.shadow,
    gctx,
    &self.texture_manager,
    &self.node_data_buffer,
    &self.mesh_data_buffer,
  ) or_return
  // Allocate particle buffers
  self.particle_resources.particle_buffer = gpu.create_mutable_buffer(
    gctx,
    particles_compute.Particle,
    particles_compute.MAX_PARTICLES,
    {.STORAGE_BUFFER, .VERTEX_BUFFER, .TRANSFER_DST},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.mutable_buffer_destroy(gctx.device, &self.particle_resources.particle_buffer)
  }
  self.particle_resources.compact_particle_buffer = gpu.create_mutable_buffer(
    gctx,
    particles_compute.Particle,
    particles_compute.MAX_PARTICLES,
    {.STORAGE_BUFFER, .VERTEX_BUFFER, .TRANSFER_SRC},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.mutable_buffer_destroy(gctx.device, &self.particle_resources.compact_particle_buffer)
  }
  self.particle_resources.draw_command_buffer = gpu.create_mutable_buffer(
    gctx,
    vk.DrawIndirectCommand,
    1,
    {.STORAGE_BUFFER, .INDIRECT_BUFFER},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.mutable_buffer_destroy(gctx.device, &self.particle_resources.draw_command_buffer)
  }
  particles_compute.setup(
    &self.particles_compute,
    gctx,
    self.emitter_buffer.descriptor_set,
    self.forcefield_buffer.descriptor_set,
    &self.particle_resources.particle_buffer,
    &self.particle_resources.compact_particle_buffer,
    &self.particle_resources.draw_command_buffer,
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
  // Destroy render graph
  rg.destroy(&self.graph)

  // Destroy camera GPU resources (VkImages, draw command buffers) before texture_manager goes away
  for _, &cam in self.cameras {
    camera.destroy_gpu(gctx, &cam, &self.texture_manager)
  }
  clear(&self.cameras)
  ui_render.teardown(&self.ui, gctx)
  debug_ui.teardown(&self.debug_ui, gctx, &self.texture_manager)
  post_process.teardown(&self.post_process, gctx, &self.texture_manager)
  particles_compute.teardown(&self.particles_compute, gctx)
  gpu.mutable_buffer_destroy(gctx.device, &self.particle_resources.particle_buffer)
  gpu.mutable_buffer_destroy(gctx.device, &self.particle_resources.compact_particle_buffer)
  gpu.mutable_buffer_destroy(gctx.device, &self.particle_resources.draw_command_buffer)
  shadow.teardown(&self.shadow, gctx, &self.texture_manager)
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
  self.lights_buffer.descriptor_set = 0
  for &ds in self.bone_buffer.descriptor_sets do ds = 0
  for &ds in self.camera_buffer.descriptor_sets do ds = 0
  self.mesh_manager.vertex_skinning_buffer.descriptor_set = 0
  // Bulk-free all descriptor sets allocated from the pool
  vk.ResetDescriptorPool(gctx.device, gctx.descriptor_pool, {})
}

@(private)
ensure_camera_slot :: proc(self: ^Manager, handle: u32) {
  if handle not_in self.cameras {
    self.cameras[handle] = {}
  }
}

@(private)
get_camera :: proc(
  self: ^Manager,
  handle: u32,
) -> (
  cam: camera.Camera,
  ok: bool,
) #optional_ok {
  cam, ok = self.cameras[handle]
  if !ok do return {}, false
  return cam, true
}

@(private)
ensure_mesh_slot :: proc(self: ^Manager, handle: u32) {
  if _, ok := self.meshes[handle]; !ok {
    self.meshes[handle] = {}
  }
}

sync_camera_from_world :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
  handle: u32,
  world_camera: ^camera.Camera,
  swapchain_format: vk.Format,
) {
}

clear_mesh :: proc(self: ^Manager, handle: u32) {
  if _, ok := self.meshes[handle]; !ok do return
  free_mesh_geometry(self, handle)
  upload_mesh_data(self, handle, &Mesh{})
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
  for cam_index, &cam in self.cameras {
    // Only build pyramid if enabled for this camera
    if cam.enable_depth_pyramid {
      occlusion_culling.build_pyramid(
        &self.visibility,
        gctx,
        cmd,
        &cam,
        u32(cam_index),
        frame_index,
      ) // Build pyramid[N]
    }
    // Only perform culling if enabled for this camera
    if cam.enable_culling {
      occlusion_culling.perform_culling(
        &self.visibility,
        gctx,
        cmd,
        &cam,
        u32(cam_index),
        next_frame_index,
        {.VISIBLE},
        {},
      ) // Write draw_list[N+1]
    }
  }
  particles_compute.simulate(
    &self.particles_compute,
    cmd,
    self.node_data_buffer.descriptor_set,
    self.particle_resources.particle_buffer.buffer,
    self.particle_resources.compact_particle_buffer.buffer,
    self.particle_resources.draw_command_buffer.buffer,
    vk.DeviceSize(self.particle_resources.particle_buffer.bytes_count),
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
  transparent.destroy(&self.transparent_renderer, gctx)
  sprite.destroy(&self.sprite_renderer, gctx)
  wireframe.destroy(&self.wireframe_renderer, gctx)
  line_strip.destroy(&self.line_strip_renderer, gctx)
  random_color.destroy(&self.random_color_renderer, gctx)
  ambient.shutdown(&self.ambient, gctx)
  direct_light.shutdown(&self.direct_light, gctx)
  shadow.shutdown(&self.shadow, gctx)
  geometry.shutdown(&self.geometry, gctx)
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
  gpu.bindless_buffer_destroy(&self.lights_buffer, gctx.device)
  gpu.per_frame_bindless_buffer_destroy(&self.camera_buffer, gctx.device)
  delete(self.bone_matrix_offsets)
  gpu.per_frame_bindless_buffer_destroy(&self.bone_buffer, gctx.device)
  cont.slab_destroy(&self.bone_matrix_slab)
  gpu.mesh_manager_shutdown(&self.mesh_manager, gctx)
  delete(self.cameras)
  delete(self.meshes)
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
  debug_ui.recreate_images(
    &self.debug_ui,
    color_format,
    extent,
    dpi_scale,
  )
  return .SUCCESS
}

allocate_mesh_geometry :: proc(
  gctx: ^gpu.GPUContext,
  render: ^Manager,
  geometry_data: geom.Geometry,
) -> (
  handle: u32,
  ret: vk.Result,
) {
  if len(render.meshes) >= rd.MAX_MESHES do return {}, .ERROR_OUT_OF_DEVICE_MEMORY
  found := false
  // TODO: eliminate this inefficiency
  for i in u32(0) ..< rd.MAX_MESHES {
    if _, ok := render.meshes[i]; !ok {
      handle = i
      found = true
      break
    }
  }
  if !found do return {}, .ERROR_OUT_OF_DEVICE_MEMORY
  mesh := Mesh{}
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
  render.meshes[handle] = mesh
  upload_mesh_data(render, handle, &mesh)
  return handle, .SUCCESS
}

sync_mesh_geometry_for_handle :: proc(
  gctx: ^gpu.GPUContext,
  render: ^Manager,
  handle: u32,
  geometry_data: geom.Geometry,
) -> vk.Result {
  ensure_mesh_slot(render, handle)
  mesh := render.meshes[handle]
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
  render.meshes[handle] = mesh
  upload_mesh_data(render, handle, &mesh)
  return .SUCCESS
}

free_mesh_geometry :: proc(render: ^Manager, handle: u32) {
  mesh, ok := render.meshes[handle]
  if !ok do return
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
  delete_key(&render.meshes, handle)
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

upload_light_data :: proc(
  render: ^Manager,
  index: u32,
  light_data: ^rd.Light,
) {
  gpu.write(&render.lights_buffer.buffer, light_data, int(index))
  shadow.invalidate_light(&render.shadow, index)
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

// ====== RENDER GRAPH RESOURCE REGISTRATION ======

MAX_CAMERAS_IN_GRAPH :: rd.MAX_ACTIVE_CAMERAS
MAX_GRAPH_CAMERA_TECHNIQUES :: 6

register_graph_buffer_resource :: proc(
  self: ^Manager,
  name: string,
  scope: rg.ResourceScope,
  element_size: uint,
  element_count: uint,
  usage: vk.BufferUsageFlags,
  resolve: rg.ResourceResolveProc,
) {
  rg.register_resource(&self.graph, name, rg.ResourceDescriptor{
    scope = scope,
    type = .BUFFER,
    format = rg.BufferFormat{
      element_size = element_size,
      element_count = element_count,
      usage = usage,
    },
    is_transient = false,
    resolve = resolve,
  })
}

register_graph_texture_resource :: proc(
  self: ^Manager,
  name: string,
  scope: rg.ResourceScope,
  type: rg.ResourceType,
  format: vk.Format,
  usage: vk.ImageUsageFlags,
  resolve: rg.ResourceResolveProc,
  width: u32 = 1920,
  height: u32 = 1080,
) {
  rg.register_resource(&self.graph, name, rg.ResourceDescriptor{
    scope = scope,
    type = type,
    format = rg.TextureFormat{
      width = width,
      height = height,
      format = format,
      usage = usage,
      mip_levels = 1,
    },
    is_transient = false,
    resolve = resolve,
  })
}

// Register particle system resources in the render graph
register_particle_resources :: proc(self: ^Manager) {
  register_graph_buffer_resource(
    self,
    "compact_particle_buffer",
    .GLOBAL,
    size_of(particles_render.Particle),
    1024 * 1024,
    {.VERTEX_BUFFER, .STORAGE_BUFFER},
    resolve_buffer,
  )
  register_graph_buffer_resource(
    self,
    "draw_command_buffer",
    .GLOBAL,
    size_of(vk.DrawIndirectCommand),
    1,
    {.INDIRECT_BUFFER, .STORAGE_BUFFER},
    resolve_buffer,
  )

  // Register camera resources (depth and final_image) for all possible cameras
  // These use PER_CAMERA scope and are resolved via resolve_camera_texture callback
  gbuffer_suffixes := [?]string{"normal", "albedo", "metallic_roughness", "emissive"}
  camera_draw_techniques := [?]string{"opaque", "transparent", "wireframe", "random_color", "line_strip", "sprite"}
  for cam_idx in 0..<MAX_CAMERAS_IN_GRAPH {
    register_graph_texture_resource(
      self,
      fmt.aprintf("camera_%d_depth", cam_idx),
      .PER_CAMERA,
      .DEPTH_TEXTURE,
      .D32_SFLOAT,
      {.DEPTH_STENCIL_ATTACHMENT},
      resolve_camera_texture,
    )
    register_graph_texture_resource(
      self,
      fmt.aprintf("camera_%d_final_image", cam_idx),
      .PER_CAMERA,
      .TEXTURE_2D,
      .R16G16B16A16_SFLOAT,
      {.COLOR_ATTACHMENT, .SAMPLED},
      resolve_camera_texture,
    )
    register_graph_texture_resource(
      self,
      fmt.aprintf("camera_%d_gbuffer_position", cam_idx),
      .PER_CAMERA,
      .TEXTURE_2D,
      .R32G32B32A32_SFLOAT,
      {.COLOR_ATTACHMENT, .SAMPLED},
      resolve_camera_texture,
    )
    for suffix in gbuffer_suffixes {
      register_graph_texture_resource(
        self,
        fmt.aprintf("camera_%d_gbuffer_%s", cam_idx, suffix),
        .PER_CAMERA,
        .TEXTURE_2D,
        .R8G8B8A8_UNORM,
        {.COLOR_ATTACHMENT, .SAMPLED},
        resolve_camera_texture,
      )
    }

    for technique in camera_draw_techniques {
      register_graph_buffer_resource(
        self,
        fmt.aprintf("camera_%d_%s_draw_commands", cam_idx, technique),
        .PER_CAMERA,
        size_of(vk.DrawIndexedIndirectCommand),
        rd.MAX_NODES_IN_SCENE,
        {.STORAGE_BUFFER, .INDIRECT_BUFFER},
        resolve_camera_buffer,
      )
      register_graph_buffer_resource(
        self,
        fmt.aprintf("camera_%d_%s_draw_count", cam_idx, technique),
        .PER_CAMERA,
        size_of(u32),
        1,
        {.STORAGE_BUFFER, .INDIRECT_BUFFER},
        resolve_camera_buffer,
      )
    }
  }

  log.infof("Registered %d particle resources and %d camera resources in graph",
    2, MAX_CAMERAS_IN_GRAPH * (7 + MAX_GRAPH_CAMERA_TECHNIQUES * 2))
}

// Register shadow system resources in the render graph
register_shadow_resources :: proc(self: ^Manager) {
  // Register shadow resources for all MAX_SHADOW_MAPS slots
  // Dead pass elimination will remove unused slots automatically
  for slot in 0 ..< shadow.MAX_SHADOW_MAPS {
    register_graph_buffer_resource(
      self,
      fmt.aprintf("shadow_draw_commands_%d", slot),
      .PER_LIGHT,
      size_of(vk.DrawIndexedIndirectCommand),
      rd.MAX_NODES_IN_SCENE,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER},
      resolve_shadow_buffer,
    )
    register_graph_buffer_resource(
      self,
      fmt.aprintf("shadow_draw_count_%d", slot),
      .PER_LIGHT,
      size_of(u32),
      1,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER},
      resolve_shadow_buffer,
    )
    register_graph_texture_resource(
      self,
      fmt.aprintf("shadow_map_%d", slot),
      .PER_LIGHT,
      .DEPTH_TEXTURE,
      .D32_SFLOAT,
      {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
      resolve_shadow_texture,
      shadow.SHADOW_MAP_SIZE,
      shadow.SHADOW_MAP_SIZE,
    )
  }

  log.infof("Registered %d shadow resources in graph (3 per slot)", shadow.MAX_SHADOW_MAPS * 3)
}

// Register UI system resources in the render graph
register_ui_resources :: proc(self: ^Manager) {
  register_graph_buffer_resource(
    self,
    "ui_vertex_buffer",
    .PER_FRAME,
    size_of(ui_render.Vertex2D),
    ui_render.UI_MAX_VERTICES,
    {.VERTEX_BUFFER},
    resolve_buffer,
  )
  register_graph_buffer_resource(
    self,
    "ui_index_buffer",
    .PER_FRAME,
    size_of(u32),
    ui_render.UI_MAX_INDICES,
    {.INDEX_BUFFER},
    resolve_buffer,
  )

  // Note: Swapchain image is NOT registered in graph because it's owned by Engine,
  // not Manager. It's passed directly through UIPassGraphContext.

  log.info("Registered UI resources in graph (vertex buffer, index buffer)")
}

// Register post-process system resources in the render graph
register_post_process_resources :: proc(self: ^Manager) {
  // Note: main_camera_final_image is NOT registered as a graph resource
  // It's accessed directly through the camera pointer in PostProcessPassGraphContext

  // Register post-process ping-pong image 0 (GLOBAL scope)
  rg.register_resource(&self.graph, "post_process_image_0", rg.ResourceDescriptor{
    scope = .GLOBAL,
    type = .TEXTURE_2D,
    format = rg.TextureFormat{
      width = 1920, // Set during post_process.setup()
      height = 1080,
      format = .R8G8B8A8_UNORM, // Matches swapchain format
      usage = {.COLOR_ATTACHMENT, .SAMPLED, .TRANSFER_SRC, .TRANSFER_DST},
      mip_levels = 1,
    },
    is_transient = false,
    resolve = proc(exec_ctx: ^rg.GraphExecutionContext, name: string, frame_index: u32) -> (rg.ResourceHandle, bool) {
      manager := cast(^Manager)exec_ctx.render_manager
      texture := gpu.get_texture_2d(&manager.texture_manager, manager.post_process.images[0])
      if texture == nil do return {}, false
      return rg.TextureHandle{
        image = texture.image,
        view = texture.view,
        extent = texture.spec.extent,
        format = texture.spec.format,
      }, true
    },
  })

  // Register post-process ping-pong image 1 (GLOBAL scope)
  rg.register_resource(&self.graph, "post_process_image_1", rg.ResourceDescriptor{
    scope = .GLOBAL,
    type = .TEXTURE_2D,
    format = rg.TextureFormat{
      width = 1920,
      height = 1080,
      format = .R8G8B8A8_UNORM,
      usage = {.COLOR_ATTACHMENT, .SAMPLED, .TRANSFER_SRC, .TRANSFER_DST},
      mip_levels = 1,
    },
    is_transient = false,
    resolve = proc(exec_ctx: ^rg.GraphExecutionContext, name: string, frame_index: u32) -> (rg.ResourceHandle, bool) {
      manager := cast(^Manager)exec_ctx.render_manager
      texture := gpu.get_texture_2d(&manager.texture_manager, manager.post_process.images[1])
      if texture == nil do return {}, false
      return rg.TextureHandle{
        image = texture.image,
        view = texture.view,
        extent = texture.spec.extent,
        format = texture.spec.format,
      }, true
    },
  })

  log.info("Registered post-process resources in graph (2 ping-pong images)")
}

DebugPassGraphContext :: struct {
  renderer:               ^debug_bone.Renderer,
  texture_manager:        ^gpu.TextureManager,
  cameras_descriptor_set: vk.DescriptorSet,
  cameras:                ^map[u32]camera.Camera,
}

debug_pass_setup :: proc(builder: ^rg.PassBuilder, user_data: rawptr) {
  cam_index := builder.scope_index
  rg.builder_read(builder, fmt.tprintf("camera_%d_depth", cam_index))
  rg.builder_read_write(builder, fmt.tprintf("camera_%d_final_image", cam_index))
}

debug_pass_execute :: proc(pass_ctx: ^rg.PassContext, user_data: rawptr) {
  ctx := cast(^DebugPassGraphContext)user_data
  if len(ctx.renderer.bone_instances) == 0 do return

  cam_index := pass_ctx.scope_index
  cam, cam_ok := ctx.cameras[cam_index]
  if !cam_ok do return

  if !debug_bone.begin_pass(
    ctx.renderer,
    &cam,
    ctx.texture_manager,
    pass_ctx.cmd,
    pass_ctx.frame_index,
  ) {
    return
  }

  if err := debug_bone.render(
    ctx.renderer,
    pass_ctx.cmd,
    ctx.cameras_descriptor_set,
    cam_index,
  ); err != .SUCCESS {
    log.errorf("Debug graph pass render failed for camera %d: %v", cam_index, err)
  }
  debug_bone.end_pass(ctx.renderer, pass_ctx.cmd)
}

render_frame_graph :: proc(
  self: ^Manager,
  frame_index: u32,
  gctx: ^gpu.GPUContext,
  active_cameras: []u32,
  active_lights: []rd.LightHandle,
  main_camera_index: u32,
  swapchain_view: vk.ImageView,
  swapchain_extent: vk.Extent2D,
) -> vk.Result {
  defer rg.reset(&self.graph)

  shadow.sync_lights(
    &self.shadow,
    &self.lights_buffer,
    active_lights,
    frame_index,
  )

  active_light_slots := make([dynamic]u32, context.temp_allocator)
  for slot in 0 ..< shadow.MAX_SHADOW_MAPS {
    if self.shadow.slot_active[slot] {
      append(&active_light_slots, u32(slot))
    }
  }

  depth_cameras := make([dynamic]u32, context.temp_allocator)
  geometry_cameras := make([dynamic]u32, context.temp_allocator)
  lighting_cameras := make([dynamic]u32, context.temp_allocator)
  particles_cameras := make([dynamic]u32, context.temp_allocator)
  transparency_cameras := make([dynamic]u32, context.temp_allocator)
  debug_cameras := make([dynamic]u32, context.temp_allocator)
  for cam_index in active_cameras {
    cam, cam_ok := self.cameras[cam_index]
    if !cam_ok do continue

    append(&depth_cameras, cam_index)

    if .GEOMETRY in cam.enabled_passes || .LIGHTING in cam.enabled_passes {
      append(&geometry_cameras, cam_index)
    }
    if .LIGHTING in cam.enabled_passes {
      append(&lighting_cameras, cam_index)
    }
    if .PARTICLES in cam.enabled_passes {
      append(&particles_cameras, cam_index)
    }
    if .TRANSPARENCY in cam.enabled_passes {
      append(&transparency_cameras, cam_index)
    }
  }

  shadow_texture_indices: [rd.MAX_LIGHTS]u32
  for i in 0 ..< rd.MAX_LIGHTS {
    shadow_texture_indices[i] = 0xFFFFFFFF
  }
  for handle in active_lights {
    light_data := gpu.get(&self.lights_buffer.buffer, handle.index)
    shadow_texture_indices[handle.index] = shadow.get_texture_index(
      &self.shadow,
      light_data.type,
      light_data.shadow_index,
      frame_index,
    )
  }

  shadow_compute_ctx := shadow.ShadowComputeGraphContext{
    renderer = &self.shadow,
  }
  shadow_depth_ctx := shadow.ShadowDepthGraphContext{
    renderer = &self.shadow,
    texture_manager = &self.texture_manager,
    textures_descriptor_set = self.texture_manager.descriptor_set,
    bone_descriptor_set = self.bone_buffer.descriptor_sets[frame_index],
    material_descriptor_set = self.material_buffer.descriptor_set,
    node_data_descriptor_set = self.node_data_buffer.descriptor_set,
    mesh_data_descriptor_set = self.mesh_data_buffer.descriptor_set,
    vertex_skinning_descriptor_set = self.mesh_manager.vertex_skinning_buffer.descriptor_set,
    vertex_buffer = self.mesh_manager.vertex_buffer.buffer,
    index_buffer = self.mesh_manager.index_buffer.buffer,
  }
  depth_ctx := occlusion_culling.DepthPassGraphContext{
    system = &self.visibility,
    texture_manager = &self.texture_manager,
    include_flags = {.VISIBLE},
    exclude_flags = {
      .MATERIAL_TRANSPARENT,
      .MATERIAL_WIREFRAME,
      .MATERIAL_RANDOM_COLOR,
      .MATERIAL_LINE_STRIP,
    },
    cameras_descriptor_set = self.camera_buffer.descriptor_sets[frame_index],
    bone_descriptor_set = self.bone_buffer.descriptor_sets[frame_index],
    node_data_descriptor_set = self.node_data_buffer.descriptor_set,
    mesh_data_descriptor_set = self.mesh_data_buffer.descriptor_set,
    vertex_skinning_descriptor_set = self.mesh_manager.vertex_skinning_buffer.descriptor_set,
    vertex_buffer = self.mesh_manager.vertex_buffer.buffer,
    index_buffer = self.mesh_manager.index_buffer.buffer,
  }
  geometry_ctx := geometry.GeometryPassGraphContext{
    renderer = &self.geometry,
    texture_manager = &self.texture_manager,
    cameras_descriptor_set = self.camera_buffer.descriptor_sets[frame_index],
    textures_descriptor_set = self.texture_manager.descriptor_set,
    bone_descriptor_set = self.bone_buffer.descriptor_sets[frame_index],
    material_descriptor_set = self.material_buffer.descriptor_set,
    node_data_descriptor_set = self.node_data_buffer.descriptor_set,
    mesh_data_descriptor_set = self.mesh_data_buffer.descriptor_set,
    vertex_skinning_descriptor_set = self.mesh_manager.vertex_skinning_buffer.descriptor_set,
    vertex_buffer = self.mesh_manager.vertex_buffer.buffer,
    index_buffer = self.mesh_manager.index_buffer.buffer,
  }
  ambient_ctx := ambient.AmbientPassGraphContext{
    renderer = &self.ambient,
    texture_manager = &self.texture_manager,
    cameras_descriptor_set = self.camera_buffer.descriptor_sets[frame_index],
    cameras = &self.cameras,
  }
  direct_light_ctx := direct_light.DirectLightPassGraphContext{
    renderer = &self.direct_light,
    texture_manager = &self.texture_manager,
    cameras_descriptor_set = self.camera_buffer.descriptor_sets[frame_index],
    lights_descriptor_set = self.lights_buffer.descriptor_set,
    shadow_data_descriptor_set = self.shadow.shadow_data_buffer.descriptor_sets[frame_index],
    cameras = &self.cameras,
    lights_buffer = &self.lights_buffer,
    active_lights = active_lights,
    shadow_texture_indices = &shadow_texture_indices,
  }
  particle_ctx := particles_render.ParticleRenderGraphContext{
    renderer = &self.particles_render,
    camera_descriptor_set = self.camera_buffer.descriptor_sets[frame_index],
    textures_descriptor_set = self.texture_manager.descriptor_set,
  }
  transparency_ctx := transparent.TransparencyRenderingPassGraphContext{
    transparent_renderer = &self.transparent_renderer,
    wireframe_renderer = &self.wireframe_renderer,
    random_color_renderer = &self.random_color_renderer,
    line_strip_renderer = &self.line_strip_renderer,
    sprite_renderer = &self.sprite_renderer,
    texture_manager = &self.texture_manager,
    cameras_descriptor_set = self.camera_buffer.descriptor_sets[frame_index],
    textures_descriptor_set = self.texture_manager.descriptor_set,
    bone_descriptor_set = self.bone_buffer.descriptor_sets[frame_index],
    material_descriptor_set = self.material_buffer.descriptor_set,
    node_data_descriptor_set = self.node_data_buffer.descriptor_set,
    mesh_data_descriptor_set = self.mesh_data_buffer.descriptor_set,
    vertex_skinning_descriptor_set = self.mesh_manager.vertex_skinning_buffer.descriptor_set,
    sprite_descriptor_set = self.sprite_buffer.descriptor_set,
    vertex_buffer = self.mesh_manager.vertex_buffer.buffer,
    index_buffer = self.mesh_manager.index_buffer.buffer,
    cameras = &self.cameras,
  }
  debug_ctx := DebugPassGraphContext{
    renderer = &self.debug_renderer,
    texture_manager = &self.texture_manager,
    cameras_descriptor_set = self.camera_buffer.descriptor_sets[frame_index],
    cameras = &self.cameras,
  }

  if len(active_light_slots) > 0 {
    rg.add_pass_template(&self.graph, rg.PassTemplate{
      name = "shadow_compute",
      scope = .PER_LIGHT,
      instance_indices = active_light_slots[:],
      queue = .COMPUTE,
      setup = shadow.shadow_compute_setup,
      execute = shadow.shadow_compute_execute,
      user_data = &shadow_compute_ctx,
    })
    rg.add_pass_template(&self.graph, rg.PassTemplate{
      name = "shadow_depth",
      scope = .PER_LIGHT,
      instance_indices = active_light_slots[:],
      queue = .GRAPHICS,
      setup = shadow.shadow_depth_setup,
      execute = shadow.shadow_depth_execute,
      user_data = &shadow_depth_ctx,
    })
  }

  if len(depth_cameras) > 0 {
    rg.add_pass_template(&self.graph, rg.PassTemplate{
      name = "depth_prepass",
      scope = .PER_CAMERA,
      instance_indices = depth_cameras[:],
      queue = .GRAPHICS,
      setup = occlusion_culling.depth_pass_setup,
      execute = occlusion_culling.depth_pass_execute,
      user_data = &depth_ctx,
    })
  }
  if len(geometry_cameras) > 0 {
    rg.add_pass_template(&self.graph, rg.PassTemplate{
      name = "geometry_pass",
      scope = .PER_CAMERA,
      instance_indices = geometry_cameras[:],
      queue = .GRAPHICS,
      setup = geometry.geometry_pass_setup,
      execute = geometry.geometry_pass_execute,
      user_data = &geometry_ctx,
    })
  }
  if len(lighting_cameras) > 0 {
    rg.add_pass_template(&self.graph, rg.PassTemplate{
      name = "ambient_pass",
      scope = .PER_CAMERA,
      instance_indices = lighting_cameras[:],
      queue = .GRAPHICS,
      setup = ambient.ambient_pass_setup,
      execute = ambient.ambient_pass_execute,
      user_data = &ambient_ctx,
    })
    rg.add_pass_template(&self.graph, rg.PassTemplate{
      name = "direct_light_pass",
      scope = .PER_CAMERA,
      instance_indices = lighting_cameras[:],
      queue = .GRAPHICS,
      setup = direct_light.direct_light_pass_setup,
      execute = direct_light.direct_light_pass_execute,
      user_data = &direct_light_ctx,
    })
  }
  if len(particles_cameras) > 0 {
    rg.add_pass_template(&self.graph, rg.PassTemplate{
      name = "particles_render",
      scope = .PER_CAMERA,
      instance_indices = particles_cameras[:],
      queue = .GRAPHICS,
      setup = particles_render.particles_render_setup,
      execute = particles_render.particles_render_execute,
      user_data = &particle_ctx,
    })
  }
  if len(transparency_cameras) > 0 {
    rg.add_pass_template(&self.graph, rg.PassTemplate{
      name = "transparency_rendering_pass",
      scope = .PER_CAMERA,
      instance_indices = transparency_cameras[:],
      queue = .GRAPHICS,
      setup = transparent.transparency_rendering_pass_setup,
      execute = transparent.transparency_rendering_pass_execute,
      user_data = &transparency_ctx,
    })
  }
  if len(self.debug_renderer.bone_instances) > 0 {
    append(&debug_cameras, main_camera_index)
    rg.add_pass_template(&self.graph, rg.PassTemplate{
      name = "debug_pass",
      scope = .PER_CAMERA,
      instance_indices = debug_cameras[:],
      queue = .GRAPHICS,
      setup = debug_pass_setup,
      execute = debug_pass_execute,
      user_data = &debug_ctx,
    })
  }

  main_camera, has_main_camera := self.cameras[main_camera_index]
  if !has_main_camera {
    log.errorf("Failed to find main camera %d for post-process", main_camera_index)
    return .ERROR_UNKNOWN
  }
  pp_ctx := post_process.PostProcessPassGraphContext{
    renderer = &self.post_process,
    texture_manager = &self.texture_manager,
    main_camera = &main_camera,
    main_camera_index = main_camera_index,
    swapchain_view = swapchain_view,
    swapchain_extent = swapchain_extent,
    frame_index = frame_index,
  }
  ui_ctx := ui_render.UIPassGraphContext{
    renderer = &self.ui,
    texture_manager = &self.texture_manager,
    gctx = gctx,
    commands = self.ui_commands[:],
    swapchain_view = swapchain_view,
    swapchain_extent = swapchain_extent,
  }
  rg.add_pass_template(&self.graph, rg.PassTemplate{
    name = "post_process_pass",
    scope = .GLOBAL,
    queue = .GRAPHICS,
    setup = post_process.post_process_pass_setup,
    execute = post_process.post_process_pass_execute,
    user_data = &pp_ctx,
  })
  rg.add_pass_template(&self.graph, rg.PassTemplate{
    name = "ui_pass",
    scope = .GLOBAL,
    queue = .GRAPHICS,
    setup = ui_render.ui_pass_setup,
    execute = ui_render.ui_pass_execute,
    user_data = &ui_ctx,
  })

  exec_ctx := rg.GraphExecutionContext{
    texture_manager = &self.texture_manager,
    render_manager = self,
  }
  cmd := self.command_buffers[frame_index]
  if err := rg.build(&self.graph); err != .SUCCESS {
    log.errorf("Failed to build graph: %v", err)
    return .ERROR_UNKNOWN
  }
  if err := rg.execute(&self.graph, cmd, frame_index, &exec_ctx); err != .SUCCESS {
    log.errorf("Failed to execute graph: %v", err)
    return .ERROR_UNKNOWN
  }
  return .SUCCESS
}
