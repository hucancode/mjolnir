package render

import alg "../algebra"
import cont "../containers"
import "../gpu"
import geom "../geometry"
import "camera"
import cam "camera"
import "core:log"
import "core:math"
import "core:math/linalg"
import d "data"
import rd "data"
import "debug"
import "debug_ui"
import "geometry"
import light "lighting"
import "particles"
import "post_process"
import "transparency"
import ui_render "ui"
import cmd "../gpu/ui"
import vk "vendor:vulkan"

FRAMES_IN_FLIGHT :: d.FRAMES_IN_FLIGHT

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
BoneInstance :: debug.BoneInstance

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
  geometry:                geometry.Renderer,
  lighting:                light.Renderer,
  transparency:            transparency.Renderer,
  particles:               particles.Renderer,
  post_process:            post_process.Renderer,
  debug_ui:                debug_ui.Renderer,
  debug_renderer:          debug.Renderer,
  ui:                      ui_render.Renderer,
  ui_commands:             [dynamic]cmd.RenderCommand,  // Staged commands from UI module
  cameras:                 map[u32]camera.Camera,
  meshes:                  map[u32]Mesh,
  visibility:              camera.System,
  shadow:                  light.ShadowSystem,
  textures_set_layout:     vk.DescriptorSetLayout,
  textures_descriptor_set: vk.DescriptorSet,
  general_pipeline_layout: vk.PipelineLayout,
  sprite_pipeline_layout:  vk.PipelineLayout,
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
  world_matrix_buffer:     gpu.BindlessBuffer(matrix[4, 4]f32),
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

@(private)
init_scene_buffers :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
) -> (
  ret: vk.Result,
) {
  gpu.bindless_buffer_init(
    &self.material_buffer,
    gctx,
    d.MAX_MATERIALS,
    {.VERTEX, .FRAGMENT},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.material_buffer, gctx.device)
  }
  gpu.bindless_buffer_init(
    &self.world_matrix_buffer,
    gctx,
    d.MAX_NODES_IN_SCENE,
    {.VERTEX, .FRAGMENT, .COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.world_matrix_buffer, gctx.device)
  }
  gpu.bindless_buffer_init(
    &self.node_data_buffer,
    gctx,
    d.MAX_NODES_IN_SCENE,
    {.VERTEX, .FRAGMENT},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.node_data_buffer, gctx.device)
  }
  gpu.bindless_buffer_init(
    &self.mesh_data_buffer,
    gctx,
    d.MAX_MESHES,
    {.VERTEX},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.mesh_data_buffer, gctx.device)
  }
  gpu.bindless_buffer_init(
    &self.emitter_buffer,
    gctx,
    d.MAX_EMITTERS,
    {.COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.emitter_buffer, gctx.device)
  }
  emitters := gpu.get_all(&self.emitter_buffer.buffer)
  for &emitter in emitters do emitter = {}
  gpu.bindless_buffer_init(
    &self.forcefield_buffer,
    gctx,
    d.MAX_FORCE_FIELDS,
    {.COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.forcefield_buffer, gctx.device)
  }
  forcefields := gpu.get_all(&self.forcefield_buffer.buffer)
  for &forcefield in forcefields do forcefield = {}
  gpu.bindless_buffer_init(
    &self.sprite_buffer,
    gctx,
    d.MAX_SPRITES,
    {.VERTEX, .FRAGMENT},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.sprite_buffer, gctx.device)
  }
  sprites := gpu.get_all(&self.sprite_buffer.buffer)
  for &sprite in sprites do sprite = {}
  gpu.bindless_buffer_init(
    &self.lights_buffer,
    gctx,
    d.MAX_LIGHTS,
    {.VERTEX, .FRAGMENT},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.lights_buffer, gctx.device)
  }
  return .SUCCESS
}

@(private)
shutdown_scene_buffers :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  gpu.bindless_buffer_destroy(&self.material_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.world_matrix_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.node_data_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.mesh_data_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.emitter_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.forcefield_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.sprite_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.lights_buffer, gctx.device)
}

@(private)
init_geometry_buffers :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
) -> (
  ret: vk.Result,
) {
  return gpu.mesh_manager_init(&self.mesh_manager, gctx)
}

@(private)
destroy_geometry_buffers :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  gpu.mesh_manager_shutdown(&self.mesh_manager, gctx)
}

@(private)
init_bone_buffer :: proc(self: ^Manager, gctx: ^gpu.GPUContext) -> vk.Result {
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
  return .SUCCESS
}

@(private)
shutdown_bone_buffer :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  delete(self.bone_matrix_offsets)
  gpu.per_frame_bindless_buffer_destroy(&self.bone_buffer, gctx.device)
  cont.slab_destroy(&self.bone_matrix_slab)
}

@(private)
shutdown_camera_buffers :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  gpu.per_frame_bindless_buffer_destroy(&self.camera_buffer, gctx.device)
}

@(private)
shutdown_camera_resources :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  for _, &cam in self.cameras {
    camera.destroy_gpu(gctx, &cam, &self.texture_manager)
  }
}

@(private)
init_bindless_layouts_infra :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
) -> (
  ret: vk.Result,
) {
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
  self.textures_set_layout = gpu.create_descriptor_set_layout_array(
    gctx,
    {.SAMPLED_IMAGE, gpu.MAX_TEXTURES, {.FRAGMENT}},
    {.SAMPLER, gpu.MAX_SAMPLERS, {.FRAGMENT}},
    {.SAMPLED_IMAGE, gpu.MAX_CUBE_TEXTURES, {.FRAGMENT}},
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyDescriptorSetLayout(gctx.device, self.textures_set_layout, nil)
    self.textures_set_layout = 0
  }
  self.general_pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.VERTEX, .FRAGMENT},
      size = size_of(u32),
    },
    self.camera_buffer.set_layout,
    self.textures_set_layout,
    self.bone_buffer.set_layout,
    self.material_buffer.set_layout,
    self.world_matrix_buffer.set_layout,
    self.node_data_buffer.set_layout,
    self.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.general_pipeline_layout, nil)
    self.general_pipeline_layout = 0
  }
  self.sprite_pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.VERTEX, .FRAGMENT},
      size = size_of(u32),
    },
    self.camera_buffer.set_layout,
    self.textures_set_layout,
    self.world_matrix_buffer.set_layout,
    self.node_data_buffer.set_layout,
    self.sprite_buffer.set_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.sprite_pipeline_layout, nil)
    self.sprite_pipeline_layout = 0
  }
  return .SUCCESS
}

@(private)
setup_bindless_textures :: proc(self: ^Manager, gctx: ^gpu.GPUContext) -> vk.Result {
  gpu.allocate_descriptor_set(
    gctx,
    &self.textures_descriptor_set,
    &self.textures_set_layout,
  ) or_return
  gpu.update_descriptor_set_array(
    gctx,
    self.textures_descriptor_set,
    1,
    {.SAMPLER, vk.DescriptorImageInfo{sampler = self.nearest_clamp_sampler}},
    {.SAMPLER, vk.DescriptorImageInfo{sampler = self.linear_clamp_sampler}},
    {.SAMPLER, vk.DescriptorImageInfo{sampler = self.nearest_repeat_sampler}},
    {.SAMPLER, vk.DescriptorImageInfo{sampler = self.linear_repeat_sampler}},
  )
  gpu.texture_manager_init(
    &self.texture_manager,
    self.textures_descriptor_set,
  ) or_return
  return .SUCCESS
}

@(private)
teardown_bindless_textures :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  gpu.texture_manager_shutdown(&self.texture_manager, gctx)
  self.textures_descriptor_set = 0
}

@(private)
shutdown_bindless_layouts_infra :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  vk.DestroyPipelineLayout(gctx.device, self.general_pipeline_layout, nil)
  vk.DestroyPipelineLayout(gctx.device, self.sprite_pipeline_layout, nil)
  vk.DestroyDescriptorSetLayout(gctx.device, self.textures_set_layout, nil)
  vk.DestroySampler(gctx.device, self.linear_repeat_sampler, nil)
  vk.DestroySampler(gctx.device, self.linear_clamp_sampler, nil)
  vk.DestroySampler(gctx.device, self.nearest_repeat_sampler, nil)
  vk.DestroySampler(gctx.device, self.nearest_clamp_sampler, nil)
  self.general_pipeline_layout = 0
  self.sprite_pipeline_layout = 0
  self.textures_set_layout = 0
  self.linear_repeat_sampler = 0
  self.linear_clamp_sampler = 0
  self.nearest_repeat_sampler = 0
  self.nearest_clamp_sampler = 0
}

@(private)
ensure_camera_slot :: proc(
  self: ^Manager,
  handle: u32,
) {
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
  compute_buffer: vk.CommandBuffer,
) -> vk.Result {
  // Compute for frame N prepares data for frame N+1
  // Buffer indices with d.FRAMES_IN_FLIGHT=2: frame N uses buffer [N], produces data for buffer [N+1]
  next_frame_index := alg.next(frame_index, d.FRAMES_IN_FLIGHT)
  for cam_index, &cam in self.cameras {
    // Only build pyramid if enabled for this camera
    if cam.enable_depth_pyramid {
      camera.build_pyramid(&self.visibility, gctx, compute_buffer, &cam, u32(cam_index), frame_index) // Build pyramid[N]
    }
    // Only perform culling if enabled for this camera
    if cam.enable_culling {
      camera.perform_culling(&self.visibility, gctx, compute_buffer, &cam, u32(cam_index), next_frame_index, {.VISIBLE}, {}) // Write draw_list[N+1]
    }
  }
  particles.simulate(
    &self.particles,
    compute_buffer,
    self.world_matrix_buffer.descriptor_set,
  )
  return .SUCCESS
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
  // Initialize geometry/bone/camera/scene buffers (survive teardown/setup cycles)
  init_geometry_buffers(self, gctx) or_return
  defer if ret != .SUCCESS {
    destroy_geometry_buffers(self, gctx)
  }
  init_bone_buffer(self, gctx) or_return
  defer if ret != .SUCCESS {
    shutdown_bone_buffer(self, gctx)
  }
  gpu.per_frame_bindless_buffer_init(
    &self.camera_buffer,
    gctx,
    d.MAX_ACTIVE_CAMERAS,
    {.VERTEX, .FRAGMENT, .COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    shutdown_camera_buffers(self, gctx)
  }
  init_scene_buffers(self, gctx) or_return
  defer if ret != .SUCCESS {
    shutdown_scene_buffers(self, gctx)
  }
  // Initialize bindless infra (samplers + descriptor set layouts + pipeline layouts)
  init_bindless_layouts_infra(self, gctx) or_return
  defer if ret != .SUCCESS {
    shutdown_bindless_layouts_infra(self, gctx)
  }
  // Initialize all subsystems (pipeline creation only)
  camera.init(
    &self.visibility,
    gctx,
    swapchain_extent.width,
    swapchain_extent.height,
    self.general_pipeline_layout,
  ) or_return
  light.shadow_init(
    &self.shadow,
    gctx,
    self.textures_set_layout,
    self.bone_buffer.set_layout,
    self.material_buffer.set_layout,
    self.world_matrix_buffer.set_layout,
    self.node_data_buffer.set_layout,
    self.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
  ) or_return
  light.init(
    &self.lighting,
    gctx,
    self.camera_buffer.set_layout,
    self.lights_buffer.set_layout,
    self.shadow.shadow_data_buffer.set_layout,
    self.textures_set_layout,
    swapchain_extent.width,
    swapchain_extent.height,
    swapchain_format,
    vk.Format.D32_SFLOAT,
  ) or_return
  geometry.init(
    &self.geometry,
    gctx,
    swapchain_extent.width,
    swapchain_extent.height,
    self.general_pipeline_layout,
  ) or_return
  particles.init(
    &self.particles,
    gctx,
    self.camera_buffer.set_layout,
    self.emitter_buffer.set_layout,
    self.forcefield_buffer.set_layout,
    self.world_matrix_buffer.set_layout,
    self.textures_set_layout,
  ) or_return
  transparency.init(
    &self.transparency,
    gctx,
    swapchain_extent.width,
    swapchain_extent.height,
    self.general_pipeline_layout,
    self.sprite_pipeline_layout,
  ) or_return
  post_process.init(
    &self.post_process,
    gctx,
    swapchain_format,
    self.textures_set_layout,
  ) or_return
  debug_ui.init(
    &self.debug_ui,
    gctx,
    swapchain_format,
    swapchain_extent.width,
    swapchain_extent.height,
    dpi_scale,
    self.textures_set_layout,
  ) or_return
  debug.init(
    &self.debug_renderer,
    gctx,
    self.camera_buffer.set_layout,
  ) or_return
  ui_render.init_renderer(
    &self.ui,
    gctx,
    self.textures_set_layout,
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
  // Allocate textures_descriptor_set and init texture_manager
  setup_bindless_textures(self, gctx) or_return
  defer if ret != .SUCCESS {
    teardown_bindless_textures(self, gctx)
  }
  // Re-allocate descriptor sets for scene buffers (freed by previous ResetDescriptorPool)
  gpu.bindless_buffer_realloc_descriptor(&self.material_buffer, gctx) or_return
  gpu.bindless_buffer_realloc_descriptor(&self.world_matrix_buffer, gctx) or_return
  gpu.bindless_buffer_realloc_descriptor(&self.node_data_buffer, gctx) or_return
  gpu.bindless_buffer_realloc_descriptor(&self.mesh_data_buffer, gctx) or_return
  gpu.bindless_buffer_realloc_descriptor(&self.emitter_buffer, gctx) or_return
  gpu.bindless_buffer_realloc_descriptor(&self.forcefield_buffer, gctx) or_return
  gpu.bindless_buffer_realloc_descriptor(&self.sprite_buffer, gctx) or_return
  gpu.bindless_buffer_realloc_descriptor(&self.lights_buffer, gctx) or_return
  gpu.per_frame_bindless_buffer_realloc_descriptors(&self.bone_buffer, gctx) or_return
  gpu.per_frame_bindless_buffer_realloc_descriptors(&self.camera_buffer, gctx) or_return
  gpu.mesh_manager_realloc_descriptors(&self.mesh_manager, gctx) or_return
  // Setup subsystem GPU resources
  light.setup(&self.lighting, gctx, &self.texture_manager) or_return
  light.shadow_setup(
    &self.shadow,
    gctx,
    &self.texture_manager,
    &self.node_data_buffer,
    &self.mesh_data_buffer,
    &self.world_matrix_buffer,
  ) or_return
  particles.setup(
    &self.particles,
    gctx,
    &self.texture_manager,
    self.emitter_buffer.descriptor_set,
    self.forcefield_buffer.descriptor_set,
  ) or_return
  post_process.setup(
    &self.post_process,
    gctx,
    &self.texture_manager,
    swapchain_extent.width,
    swapchain_extent.height,
    swapchain_format,
  ) or_return
  debug_ui.setup(&self.debug_ui, gctx, &self.texture_manager) or_return
  ui_render.setup(&self.ui, gctx) or_return
  return .SUCCESS
}

teardown :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  // Destroy camera GPU resources (VkImages, draw command buffers) before texture_manager goes away
  shutdown_camera_resources(self, gctx)
  clear(&self.cameras)
  ui_render.teardown(&self.ui, gctx)
  debug_ui.teardown(&self.debug_ui, gctx, &self.texture_manager)
  post_process.teardown(&self.post_process, gctx, &self.texture_manager)
  particles.teardown(&self.particles, gctx)
  light.shadow_teardown(&self.shadow, gctx, &self.texture_manager)
  light.teardown(&self.lighting, gctx, &self.texture_manager)
  teardown_bindless_textures(self, gctx)
  // Zero all descriptor set handles (freed in bulk below)
  self.material_buffer.descriptor_set = 0
  self.world_matrix_buffer.descriptor_set = 0
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

// Stage UI commands from UI module
stage_ui_commands :: proc(self: ^Manager, commands: []cmd.RenderCommand) {
  clear(&self.ui_commands)
  for command in commands {
    append(&self.ui_commands, command)
  }
}

// Stage bone visualization instances for debug rendering
stage_bone_visualization :: proc(self: ^Manager, instances: []debug.BoneInstance) {
  debug.stage_bones(&self.debug_renderer, instances)
}

// Clear staged debug visualization data
clear_debug_visualization :: proc(self: ^Manager) {
  debug.clear_bones(&self.debug_renderer)
}

shutdown :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  ui_render.shutdown(&self.ui, gctx)
  delete(self.ui_commands)
  debug.shutdown(&self.debug_renderer, gctx)
  debug_ui.shutdown(&self.debug_ui, gctx)
  post_process.shutdown(&self.post_process, gctx)
  particles.shutdown(&self.particles, gctx)
  transparency.shutdown(&self.transparency, gctx)
  light.shutdown(&self.lighting, gctx)
  light.shadow_shutdown(&self.shadow, gctx)
  geometry.shutdown(&self.geometry, gctx)
  camera.shutdown(&self.visibility, gctx)
  shutdown_bindless_layouts_infra(self, gctx)
  shutdown_scene_buffers(self, gctx)
  shutdown_camera_buffers(self, gctx)
  shutdown_bone_buffer(self, gctx)
  destroy_geometry_buffers(self, gctx)
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
  light.recreate_images(
    &self.lighting,
    extent.width,
    extent.height,
    color_format,
    vk.Format.D32_SFLOAT,
  ) or_return
  post_process.recreate_images(
    gctx,
    &self.post_process,
    &self.texture_manager,
    extent.width,
    extent.height,
    color_format,
  ) or_return
  debug_ui.recreate_images(
    &self.debug_ui,
    color_format,
    extent.width,
    extent.height,
    dpi_scale,
  )
  return .SUCCESS
}

render_shadow_depth :: proc(
  self: ^Manager,
  frame_index: u32,
  command_buffer: vk.CommandBuffer,
  active_lights: []d.LightHandle,
) -> vk.Result {
  light.shadow_sync_lights(
    &self.shadow,
    &self.lights_buffer,
    active_lights,
    frame_index,
  )
  light.shadow_compute_draw_lists(&self.shadow, command_buffer, frame_index)
  light.shadow_render_depth(
    &self.shadow,
    command_buffer,
    &self.texture_manager,
    self.textures_descriptor_set,
    self.bone_buffer.descriptor_sets[frame_index],
    self.material_buffer.descriptor_set,
    self.world_matrix_buffer.descriptor_set,
    self.node_data_buffer.descriptor_set,
    self.mesh_data_buffer.descriptor_set,
    self.mesh_manager.vertex_skinning_buffer.descriptor_set,
    self.mesh_manager.vertex_buffer.buffer,
    self.mesh_manager.index_buffer.buffer,
    frame_index,
  )
  return .SUCCESS
}

render_camera_depth :: proc(
  self: ^Manager,
  frame_index: u32,
  gctx: ^gpu.GPUContext,
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
  for cam_index, &cam in self.cameras {
    camera.render_depth(&self.visibility, gctx, command_buffer, &cam, &self.texture_manager, u32(cam_index), frame_index, {.VISIBLE}, {.MATERIAL_TRANSPARENT, .MATERIAL_WIREFRAME, .MATERIAL_RANDOM_COLOR, .MATERIAL_LINE_STRIP}, self.textures_descriptor_set, self.bone_buffer.descriptor_sets[frame_index], self.material_buffer.descriptor_set, self.world_matrix_buffer.descriptor_set, self.node_data_buffer.descriptor_set, self.mesh_data_buffer.descriptor_set, self.mesh_manager.vertex_skinning_buffer.descriptor_set, self.mesh_manager.vertex_buffer.buffer, self.mesh_manager.index_buffer.buffer)
  }
  return .SUCCESS
}

record_geometry_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  gctx: ^gpu.GPUContext,
  camera_handle: u32,
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
  camera, ok := &self.cameras[camera_handle]
  if !ok do return .ERROR_UNKNOWN
  geometry.begin_pass(
    camera,
    &self.texture_manager,
    command_buffer,
    frame_index,
  )
  geometry.render(
    &self.geometry,
    camera,
    camera_handle,
    frame_index,
    command_buffer,
    self.general_pipeline_layout,
    self.textures_descriptor_set,
    self.bone_buffer.descriptor_sets[frame_index],
    self.material_buffer.descriptor_set,
    self.world_matrix_buffer.descriptor_set,
    self.node_data_buffer.descriptor_set,
    self.mesh_data_buffer.descriptor_set,
    self.mesh_manager.vertex_skinning_buffer.descriptor_set,
    self.mesh_manager.vertex_buffer.buffer,
    self.mesh_manager.index_buffer.buffer,
    camera.opaque_draw_commands[frame_index].buffer,
    camera.opaque_draw_count[frame_index].buffer,
  )
  geometry.end_pass(
    camera,
    &self.texture_manager,
    command_buffer,
    frame_index,
  )
  return .SUCCESS
}

record_lighting_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  active_lights: []d.LightHandle,
  camera_handle: u32,
  color_format: vk.Format,
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
  camera, ok := &self.cameras[camera_handle]
  if !ok do return .ERROR_UNKNOWN
  light.begin_ambient_pass(
    &self.lighting,
    camera,
    &self.texture_manager,
    command_buffer,
    frame_index,
  )
  light.render_ambient(
    &self.lighting,
    camera_handle,
    camera,
    command_buffer,
    frame_index,
  )
  light.end_ambient_pass(command_buffer)
  light.begin_pass(
    &self.lighting,
    camera,
    &self.texture_manager,
    command_buffer,
    self.lights_buffer.descriptor_set,
    self.shadow.shadow_data_buffer.descriptor_sets[frame_index],
    frame_index,
  )
  shadow_texture_indices: [d.MAX_LIGHTS]u32
  for i in 0 ..< d.MAX_LIGHTS {
    shadow_texture_indices[i] = 0xFFFFFFFF
  }
  for handle in active_lights {
    light_data := gpu.get(&self.lights_buffer.buffer, handle.index)
    shadow_texture_indices[handle.index] = light.shadow_get_texture_index(
      &self.shadow,
      light_data.type,
      light_data.shadow_index,
      frame_index,
    )
  }
  light.render(
    &self.lighting,
    camera_handle,
    camera,
    &shadow_texture_indices,
    command_buffer,
    &self.lights_buffer,
    active_lights,
    frame_index,
  )
  light.end_pass(command_buffer)
  return .SUCCESS
}

record_particles_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  camera_handle: u32,
  color_format: vk.Format,
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
  camera, ok := &self.cameras[camera_handle]
  if !ok do return .ERROR_UNKNOWN
  particles.begin_pass(
    &self.particles,
    command_buffer,
    camera,
    &self.texture_manager,
    frame_index,
  )
  particles.render(
    &self.particles,
    command_buffer,
    camera,
    camera_handle,
    frame_index,
    self.textures_descriptor_set,
  )
  particles.end_pass(command_buffer)
  return .SUCCESS
}

record_transparency_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  gctx: ^gpu.GPUContext,
  camera_handle: u32,
  color_format: vk.Format,
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
  cam, ok := &self.cameras[camera_handle]
  if !ok do return .ERROR_UNKNOWN
  transparency.begin_pass(
    &self.transparency,
    cam,
    &self.texture_manager,
    command_buffer,
    frame_index,
  )
  // Render transparent objects
  camera.perform_culling(
    &self.visibility,
    gctx,
    command_buffer,
    cam,
    camera_handle,
    frame_index,
    NodeFlagSet{.VISIBLE, .MATERIAL_TRANSPARENT},
    NodeFlagSet{
      .MATERIAL_WIREFRAME,
      .MATERIAL_RANDOM_COLOR,
      .MATERIAL_LINE_STRIP,
      .MATERIAL_SPRITE,
    },
  )
  gpu.buffer_barrier(
    command_buffer,
    cam.transparent_draw_commands[frame_index].buffer,
    vk.DeviceSize(cam.transparent_draw_commands[frame_index].bytes_count),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  gpu.buffer_barrier(
    command_buffer,
    cam.transparent_draw_count[frame_index].buffer,
    vk.DeviceSize(cam.transparent_draw_count[frame_index].bytes_count),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  transparency.render(
    &self.transparency,
    cam,
    self.transparency.transparent_pipeline,
    self.general_pipeline_layout,
    self.sprite_pipeline_layout,
    self.textures_descriptor_set,
    self.bone_buffer.descriptor_sets[frame_index],
    self.material_buffer.descriptor_set,
    self.world_matrix_buffer.descriptor_set,
    self.node_data_buffer.descriptor_set,
    self.mesh_data_buffer.descriptor_set,
    self.sprite_buffer.descriptor_set,
    self.mesh_manager.vertex_skinning_buffer.descriptor_set,
    self.mesh_manager.vertex_buffer.buffer,
    self.mesh_manager.index_buffer.buffer,
    camera_handle,
    frame_index,
    command_buffer,
    cam.transparent_draw_commands[frame_index].buffer,
    cam.transparent_draw_count[frame_index].buffer,
  )
  // Render wireframe objects
  camera.perform_culling(
    &self.visibility,
    gctx,
    command_buffer,
    cam,
    camera_handle,
    frame_index,
    NodeFlagSet{.VISIBLE, .MATERIAL_WIREFRAME},
    NodeFlagSet{
      .MATERIAL_TRANSPARENT,
      .MATERIAL_RANDOM_COLOR,
      .MATERIAL_LINE_STRIP,
      .MATERIAL_SPRITE,
    },
  )
  gpu.buffer_barrier(
    command_buffer,
    cam.transparent_draw_commands[frame_index].buffer,
    vk.DeviceSize(cam.transparent_draw_commands[frame_index].bytes_count),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  gpu.buffer_barrier(
    command_buffer,
    cam.transparent_draw_count[frame_index].buffer,
    vk.DeviceSize(cam.transparent_draw_count[frame_index].bytes_count),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  transparency.render(
    &self.transparency,
    cam,
    self.transparency.wireframe_pipeline,
    self.general_pipeline_layout,
    self.sprite_pipeline_layout,
    self.textures_descriptor_set,
    self.bone_buffer.descriptor_sets[frame_index],
    self.material_buffer.descriptor_set,
    self.world_matrix_buffer.descriptor_set,
    self.node_data_buffer.descriptor_set,
    self.mesh_data_buffer.descriptor_set,
    self.sprite_buffer.descriptor_set,
    self.mesh_manager.vertex_skinning_buffer.descriptor_set,
    self.mesh_manager.vertex_buffer.buffer,
    self.mesh_manager.index_buffer.buffer,
    camera_handle,
    frame_index,
    command_buffer,
    cam.transparent_draw_commands[frame_index].buffer,
    cam.transparent_draw_count[frame_index].buffer,
  )
  // Render random_color objects
  camera.perform_culling(
    &self.visibility,
    gctx,
    command_buffer,
    cam,
    camera_handle,
    frame_index,
    NodeFlagSet{.VISIBLE, .MATERIAL_RANDOM_COLOR},
    NodeFlagSet{
      .MATERIAL_TRANSPARENT,
      .MATERIAL_WIREFRAME,
      .MATERIAL_LINE_STRIP,
      .MATERIAL_SPRITE,
    },
  )
  gpu.buffer_barrier(
    command_buffer,
    cam.transparent_draw_commands[frame_index].buffer,
    vk.DeviceSize(cam.transparent_draw_commands[frame_index].bytes_count),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  gpu.buffer_barrier(
    command_buffer,
    cam.transparent_draw_count[frame_index].buffer,
    vk.DeviceSize(cam.transparent_draw_count[frame_index].bytes_count),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  transparency.render(
    &self.transparency,
    cam,
    self.transparency.random_color_pipeline,
    self.general_pipeline_layout,
    self.sprite_pipeline_layout,
    self.textures_descriptor_set,
    self.bone_buffer.descriptor_sets[frame_index],
    self.material_buffer.descriptor_set,
    self.world_matrix_buffer.descriptor_set,
    self.node_data_buffer.descriptor_set,
    self.mesh_data_buffer.descriptor_set,
    self.sprite_buffer.descriptor_set,
    self.mesh_manager.vertex_skinning_buffer.descriptor_set,
    self.mesh_manager.vertex_buffer.buffer,
    self.mesh_manager.index_buffer.buffer,
    camera_handle,
    frame_index,
    command_buffer,
    cam.transparent_draw_commands[frame_index].buffer,
    cam.transparent_draw_count[frame_index].buffer,
  )
  // Render line_strip objects
  camera.perform_culling(
    &self.visibility,
    gctx,
    command_buffer,
    cam,
    camera_handle,
    frame_index,
    NodeFlagSet{.VISIBLE, .MATERIAL_LINE_STRIP},
    NodeFlagSet{
      .MATERIAL_TRANSPARENT,
      .MATERIAL_WIREFRAME,
      .MATERIAL_RANDOM_COLOR,
      .MATERIAL_SPRITE,
    },
  )
  gpu.buffer_barrier(
    command_buffer,
    cam.transparent_draw_commands[frame_index].buffer,
    vk.DeviceSize(cam.transparent_draw_commands[frame_index].bytes_count),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  gpu.buffer_barrier(
    command_buffer,
    cam.transparent_draw_count[frame_index].buffer,
    vk.DeviceSize(cam.transparent_draw_count[frame_index].bytes_count),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  transparency.render(
    &self.transparency,
    cam,
    self.transparency.line_strip_pipeline,
    self.general_pipeline_layout,
    self.sprite_pipeline_layout,
    self.textures_descriptor_set,
    self.bone_buffer.descriptor_sets[frame_index],
    self.material_buffer.descriptor_set,
    self.world_matrix_buffer.descriptor_set,
    self.node_data_buffer.descriptor_set,
    self.mesh_data_buffer.descriptor_set,
    self.sprite_buffer.descriptor_set,
    self.mesh_manager.vertex_skinning_buffer.descriptor_set,
    self.mesh_manager.vertex_buffer.buffer,
    self.mesh_manager.index_buffer.buffer,
    camera_handle,
    frame_index,
    command_buffer,
    cam.transparent_draw_commands[frame_index].buffer,
    cam.transparent_draw_count[frame_index].buffer,
  )
  // Render sprites
  camera.perform_culling(
    &self.visibility,
    gctx,
    command_buffer,
    cam,
    camera_handle,
    frame_index,
    NodeFlagSet{.VISIBLE, .MATERIAL_SPRITE},
    NodeFlagSet{},
  )
  gpu.buffer_barrier(
    command_buffer,
    cam.sprite_draw_commands[frame_index].buffer,
    vk.DeviceSize(cam.sprite_draw_commands[frame_index].bytes_count),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  gpu.buffer_barrier(
    command_buffer,
    cam.sprite_draw_count[frame_index].buffer,
    vk.DeviceSize(cam.sprite_draw_count[frame_index].bytes_count),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  transparency.render(
    &self.transparency,
    cam,
    self.transparency.sprite_pipeline,
    self.general_pipeline_layout,
    self.sprite_pipeline_layout,
    self.textures_descriptor_set,
    self.bone_buffer.descriptor_sets[frame_index],
    self.material_buffer.descriptor_set,
    self.world_matrix_buffer.descriptor_set,
    self.node_data_buffer.descriptor_set,
    self.mesh_data_buffer.descriptor_set,
    self.sprite_buffer.descriptor_set,
    self.mesh_manager.vertex_skinning_buffer.descriptor_set,
    self.mesh_manager.vertex_buffer.buffer,
    self.mesh_manager.index_buffer.buffer,
    camera_handle,
    frame_index,
    command_buffer,
    cam.sprite_draw_commands[frame_index].buffer,
    cam.sprite_draw_count[frame_index].buffer,
  )

  transparency.end_pass(&self.transparency, command_buffer)
  return .SUCCESS
}

record_debug_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  camera_handle: u32,
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
  // Skip debug rendering if no instances are staged
  if len(self.debug_renderer.bone_instances) == 0 do return .SUCCESS

  cam, ok := &self.cameras[camera_handle]
  if !ok do return .ERROR_UNKNOWN

  // Begin debug render pass (renders on top of transparency)
  // Skip rendering if attachments are missing
  if !debug.begin_pass(
    &self.debug_renderer,
    cam,
    &self.texture_manager,
    command_buffer,
    frame_index,
  ) {
    return .SUCCESS
  }

  // Render debug visualization (bones, etc.)
  debug.render(
    &self.debug_renderer,
    command_buffer,
    self.camera_buffer.descriptor_sets[frame_index],
    camera_handle,
  ) or_return

  debug.end_pass(&self.debug_renderer, command_buffer)

  return .SUCCESS
}

record_post_process_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  camera_handle: u32,
  color_format: vk.Format,
  swapchain_extent: vk.Extent2D,
  swapchain_image: vk.Image,
  swapchain_view: vk.ImageView,
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
  camera := &self.cameras[camera_handle]
  if final_image := gpu.get_texture_2d(
    &self.texture_manager,
    camera.attachments[.FINAL_IMAGE][frame_index],
  ); final_image != nil {
    gpu.image_barrier(
      command_buffer,
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
    command_buffer,
    swapchain_image,
    .UNDEFINED,
    .COLOR_ATTACHMENT_OPTIMAL,
    {},
    {.COLOR_ATTACHMENT_WRITE},
    {.TOP_OF_PIPE},
    {.COLOR_ATTACHMENT_OUTPUT},
    {.COLOR},
  )
  post_process.begin_pass(&self.post_process, command_buffer, swapchain_extent)
  post_process.render(
    &self.post_process,
    command_buffer,
    swapchain_extent,
    swapchain_view,
    camera,
    &self.texture_manager,
    frame_index,
  )
  post_process.end_pass(&self.post_process, command_buffer)
  return .SUCCESS
}

record_ui_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  gctx: ^gpu.GPUContext,
  swapchain_view: vk.ImageView,
  swapchain_extent: vk.Extent2D,
  command_buffer: vk.CommandBuffer,
) {
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

  vk.CmdBeginRendering(command_buffer, &rendering_info)

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
  vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
  vk.CmdSetScissor(command_buffer, 0, 1, &scissor)

  // Bind pipeline and descriptor sets
  vk.CmdBindPipeline(command_buffer, .GRAPHICS, self.ui.pipeline)
  vk.CmdBindDescriptorSets(
    command_buffer,
    .GRAPHICS,
    self.ui.pipeline_layout,
    0,
    1,
    &self.textures_descriptor_set,
    0,
    nil,
  )

  // Render UI using staged commands
  ui_render.render(
    &self.ui,
    self.ui_commands[:],
    gctx,
    &self.texture_manager,
    command_buffer,
    swapchain_extent.width,
    swapchain_extent.height,
    frame_index,
  )

  vk.CmdEndRendering(command_buffer)
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

upload_node_transform :: proc(
  render: ^Manager,
  index: u32,
  world_matrix: ^matrix[4, 4]f32,
) {
  gpu.write(&render.world_matrix_buffer.buffer, world_matrix, int(index))
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

upload_light_data :: proc(render: ^Manager, index: u32, light_data: ^rd.Light) {
  gpu.write(&render.lights_buffer.buffer, light_data, int(index))
  light.shadow_invalidate_light(&render.shadow, index)
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
  camera_data.viewport_params = [4]f32 {
    f32(extent[0]),
    f32(extent[1]),
    near,
    far,
  }
  camera_data.position = [4]f32 {
    position[0],
    position[1],
    position[2],
    1.0,
  }
  frustum := geom.make_frustum(camera_data.projection * camera_data.view)
  camera_data.frustum_planes = frustum.planes
  gpu.write(
    &render.camera_buffer.buffers[frame_index],
    &camera_data,
    int(camera_index),
  )
}
