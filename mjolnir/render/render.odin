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
import "debug_ui"
import "geometry"
import light "lighting"
import "particles"
import "post_process"
import "transparency"
import "ui"
import vk "vendor:vulkan"

FRAMES_IN_FLIGHT :: d.FRAMES_IN_FLIGHT

Handle :: rd.Handle
MeshHandle :: rd.MeshHandle
MaterialHandle :: rd.MaterialHandle
Image2DHandle :: gpu.Texture2DHandle
ImageCubeHandle :: gpu.TextureCubeHandle
CameraHandle :: rd.CameraHandle
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

Manager :: struct {
  geometry:                geometry.Renderer,
  lighting:                light.Renderer,
  transparency:            transparency.Renderer,
  particles:               particles.Renderer,
  post_process:            post_process.Renderer,
  debug_ui:                debug_ui.Renderer,
  ui_system:               ui.System,
  ui:                      ui.Renderer,
  main_camera:             d.CameraHandle,
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
  // Camera GPU resources (indexed by camera handle.index)
  cameras_gpu:             [d.MAX_CAMERAS]camera.CameraGPU,
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
init_camera_buffers :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
) -> vk.Result {
  gpu.per_frame_bindless_buffer_init(
    &self.camera_buffer,
    gctx,
    d.MAX_ACTIVE_CAMERAS,
    {.VERTEX, .FRAGMENT, .COMPUTE},
  ) or_return
  return .SUCCESS
}

@(private)
shutdown_camera_buffers :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  gpu.per_frame_bindless_buffer_destroy(&self.camera_buffer, gctx.device)
}

@(private)
shutdown_camera_resources :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  for i in 0 ..< d.MAX_CAMERAS {
    camera.destroy_gpu(gctx, &self.cameras_gpu[i], &self.texture_manager)
  }
}

@(private)
init_bindless_layouts :: proc(
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
    {.SAMPLED_IMAGE, d.MAX_TEXTURES, {.FRAGMENT}},
    {.SAMPLER, gpu.MAX_SAMPLERS, {.FRAGMENT}},
    {.SAMPLED_IMAGE, d.MAX_CUBE_TEXTURES, {.FRAGMENT}},
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
  // Initialize texture manager
  gpu.texture_manager_init(
    &self.texture_manager,
    self.textures_descriptor_set,
  ) or_return
  return .SUCCESS
}

@(private)
shutdown_bindless_layouts :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  gpu.texture_manager_shutdown(&self.texture_manager, gctx)
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
  self.textures_descriptor_set = 0
  self.linear_repeat_sampler = 0
  self.linear_clamp_sampler = 0
  self.nearest_repeat_sampler = 0
  self.nearest_clamp_sampler = 0
}

@(private)
ensure_camera_slot :: proc(
  self: ^Manager,
  handle: d.CameraHandle,
) {
  if _, ok := self.cameras[handle.index]; !ok {
    self.cameras[handle.index] = {}
  }
}

@(private)
get_camera :: proc(
  self: ^Manager,
  handle: d.CameraHandle,
) -> (
  camera_cpu: camera.Camera,
  ok: bool,
) #optional_ok {
  camera_cpu, ok = self.cameras[handle.index]
  if !ok do return {}, false
  return camera_cpu, true
}

@(private)
ensure_mesh_slot :: proc(self: ^Manager, handle: u32) {
  if _, ok := self.meshes[handle]; !ok {
    self.meshes[handle] = {}
  }
}

sync_camera_from_world :: proc(
  self: ^Manager,
  handle: d.CameraHandle,
  world_camera: ^camera.Camera,
) {
  ensure_camera_slot(self, handle)
  self.cameras[handle.index] = world_camera^
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
  for cam_index, cam_cpu in self.cameras {
    cam_gpu := &self.cameras_gpu[cam_index]
    upload_camera_data(self, cam_index, cam_cpu, frame_index)
    // Only build pyramid if enabled for this camera
    if cam_cpu.enable_depth_pyramid {
      camera.build_pyramid(&self.visibility, gctx, compute_buffer, cam_gpu, u32(cam_index), frame_index) // Build pyramid[N]
    }
    // Only perform culling if enabled for this camera
    if cam_cpu.enable_culling {
      camera.perform_culling(&self.visibility, gctx, compute_buffer, cam_gpu, u32(cam_index), next_frame_index, {.VISIBLE}, {}) // Write draw_list[N+1]
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
  // Initialize texture tracking maps
  init_geometry_buffers(self, gctx) or_return
  defer if ret != .SUCCESS {
    destroy_geometry_buffers(self, gctx)
  }
  init_bone_buffer(self, gctx) or_return
  defer if ret != .SUCCESS {
    shutdown_bone_buffer(self, gctx)
  }
  init_camera_buffers(self, gctx) or_return
  defer if ret != .SUCCESS {
    shutdown_camera_buffers(self, gctx)
  }
  init_scene_buffers(self, gctx) or_return
  defer if ret != .SUCCESS {
    shutdown_scene_buffers(self, gctx)
  }
  init_bindless_layouts(self, gctx) or_return
  defer if ret != .SUCCESS {
    shutdown_bindless_layouts(self, gctx)
  }
  camera_handle := d.CameraHandle {index = 0, generation = 1}
  ensure_camera_slot(self, camera_handle)
  camera_cpu := camera.Camera {}
  camera_cpu.position = {3, 4, 3}
  camera_cpu.rotation = linalg.QUATERNIONF32_IDENTITY
  camera_cpu.projection = camera.PerspectiveProjection {
    fov          = math.PI * 0.5,
    aspect_ratio = f32(swapchain_extent.width) / f32(swapchain_extent.height),
    near         = 0.1,
    far          = 100.0,
  }
  camera_cpu.extent = {swapchain_extent.width, swapchain_extent.height}
  camera_cpu.enabled_passes = {
    .SHADOW,
    .GEOMETRY,
    .LIGHTING,
    .TRANSPARENCY,
    .PARTICLES,
    .POST_PROCESS,
  }
  camera_cpu.enable_culling = true
  camera_cpu.enable_depth_pyramid = true
  self.cameras[camera_handle.index] = camera_cpu
  // Initialize GPU resources for the camera
  camera_gpu := &self.cameras_gpu[camera_handle.index]
  camera.init_gpu(
    gctx,
    camera_gpu,
    &self.texture_manager,
    swapchain_extent.width,
    swapchain_extent.height,
    swapchain_format,
    vk.Format.D32_SFLOAT,
    camera_cpu.enabled_passes,
    camera_cpu.enable_depth_pyramid,
    d.MAX_NODES_IN_SCENE,
  ) or_return
  self.main_camera = camera_handle
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
    &self.texture_manager,
    &self.node_data_buffer,
    &self.mesh_data_buffer,
    &self.world_matrix_buffer,
    self.textures_set_layout,
    self.bone_buffer.set_layout,
    self.material_buffer.set_layout,
    self.world_matrix_buffer.set_layout,
    self.node_data_buffer.set_layout,
    self.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
  ) or_return
  camera.allocate_descriptors(
    gctx,
    camera_gpu,
    &self.texture_manager,
    &self.visibility.normal_cam_descriptor_layout,
    &self.visibility.depth_reduce_descriptor_layout,
    &self.node_data_buffer,
    &self.mesh_data_buffer,
    &self.world_matrix_buffer,
    &self.camera_buffer,
  ) or_return
  light.init(
    &self.lighting,
    gctx,
    &self.texture_manager,
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
    &self.texture_manager,
    self.camera_buffer.set_layout,
    self.emitter_buffer.set_layout,
    self.forcefield_buffer.set_layout,
    self.world_matrix_buffer.set_layout,
    self.emitter_buffer.descriptor_set,
    self.forcefield_buffer.descriptor_set,
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
    &self.texture_manager,
    swapchain_format,
    swapchain_extent.width,
    swapchain_extent.height,
    self.textures_set_layout,
  ) or_return
  debug_ui.init(
    &self.debug_ui,
    gctx,
    &self.texture_manager,
    swapchain_format,
    swapchain_extent.width,
    swapchain_extent.height,
    dpi_scale,
    self.textures_set_layout,
  ) or_return
  ui.init_ui_system(&self.ui_system)
  ui.init_renderer(
    &self.ui,
    &self.ui_system,
    gctx,
    &self.texture_manager,
    self.textures_set_layout,
    swapchain_extent.width,
    swapchain_extent.height,
    swapchain_format,
  ) or_return
  return .SUCCESS
}

shutdown :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  ui.shutdown(&self.ui, gctx, &self.texture_manager)
  ui.shutdown_ui_system(&self.ui_system)
  debug_ui.shutdown(&self.debug_ui, gctx)
  post_process.shutdown(&self.post_process, gctx, &self.texture_manager)
  particles.shutdown(&self.particles, gctx)
  transparency.shutdown(&self.transparency, gctx)
  light.shutdown(&self.lighting, gctx, &self.texture_manager)
  light.shadow_shutdown(&self.shadow, gctx, &self.texture_manager)
  geometry.shutdown(&self.geometry, gctx)
  camera.shutdown(&self.visibility, gctx)
  shutdown_camera_resources(self, gctx)
  shutdown_bindless_layouts(self, gctx)
  shutdown_scene_buffers(self, gctx)
  shutdown_camera_buffers(self, gctx)
  shutdown_bone_buffer(self, gctx)
  destroy_geometry_buffers(self, gctx)
  // Cleanup texture tracking maps
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
  for cam_index, &cam_cpu in self.cameras {
    cam_gpu := &self.cameras_gpu[cam_index]
    camera.render_depth(&self.visibility, gctx, command_buffer, cam_gpu, &cam_cpu, &self.texture_manager, u32(cam_index), frame_index, {.VISIBLE}, {.MATERIAL_TRANSPARENT, .MATERIAL_WIREFRAME, .MATERIAL_RANDOM_COLOR, .MATERIAL_LINE_STRIP}, self.textures_descriptor_set, self.bone_buffer.descriptor_sets[frame_index], self.material_buffer.descriptor_set, self.world_matrix_buffer.descriptor_set, self.node_data_buffer.descriptor_set, self.mesh_data_buffer.descriptor_set, self.mesh_manager.vertex_skinning_buffer.descriptor_set, self.mesh_manager.vertex_buffer.buffer, self.mesh_manager.index_buffer.buffer)
  }
  return .SUCCESS
}

record_geometry_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  gctx: ^gpu.GPUContext,
  camera_handle: d.CameraHandle,
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
  camera_cpu, ok := get_camera(self, camera_handle)
  if !ok do return .ERROR_UNKNOWN
  camera_gpu := &self.cameras_gpu[camera_handle.index]
  geometry.begin_pass(
    camera_gpu,
    &camera_cpu,
    &self.texture_manager,
    command_buffer,
    frame_index,
  )
  geometry.render(
    &self.geometry,
    camera_gpu,
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
    camera_gpu.opaque_draw_commands[frame_index].buffer,
    camera_gpu.opaque_draw_count[frame_index].buffer,
  )
  geometry.end_pass(
    camera_gpu,
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
  camera_handle: d.CameraHandle,
  color_format: vk.Format,
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
  camera_cpu, ok := get_camera(self, camera_handle)
  if !ok do return .ERROR_UNKNOWN
  camera_gpu := &self.cameras_gpu[camera_handle.index]
  light.begin_ambient_pass(
    &self.lighting,
    camera_gpu,
    &camera_cpu,
    &self.texture_manager,
    command_buffer,
    frame_index,
  )
  light.render_ambient(
    &self.lighting,
    camera_handle,
    camera_gpu,
    command_buffer,
    frame_index,
  )
  light.end_ambient_pass(command_buffer)
  light.begin_pass(
    &self.lighting,
    camera_gpu,
    &camera_cpu,
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
    camera_gpu,
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
  camera_handle: d.CameraHandle,
  color_format: vk.Format,
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
  camera_cpu, ok := get_camera(self, camera_handle)
  if !ok do return .ERROR_UNKNOWN
  camera_gpu := &self.cameras_gpu[camera_handle.index]
  particles.begin_pass(
    &self.particles,
    command_buffer,
    camera_gpu,
    &camera_cpu,
    &self.texture_manager,
    frame_index,
  )
  particles.render(
    &self.particles,
    command_buffer,
    camera_gpu,
    camera_handle.index,
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
  camera_handle: d.CameraHandle,
  color_format: vk.Format,
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
  camera_cpu, ok := get_camera(self, camera_handle)
  if !ok do return .ERROR_UNKNOWN
  camera_gpu := &self.cameras_gpu[camera_handle.index]
  // Barrier: Wait for compute to finish before reading draw commands
  gpu.buffer_barrier(
    command_buffer,
    camera_gpu.transparent_draw_commands[frame_index].buffer,
    vk.DeviceSize(
      camera_gpu.transparent_draw_commands[frame_index].bytes_count,
    ),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  gpu.buffer_barrier(
    command_buffer,
    camera_gpu.transparent_draw_count[frame_index].buffer,
    vk.DeviceSize(camera_gpu.transparent_draw_count[frame_index].bytes_count),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  gpu.buffer_barrier(
    command_buffer,
    camera_gpu.sprite_draw_commands[frame_index].buffer,
    vk.DeviceSize(camera_gpu.sprite_draw_commands[frame_index].bytes_count),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  gpu.buffer_barrier(
    command_buffer,
    camera_gpu.sprite_draw_count[frame_index].buffer,
    vk.DeviceSize(camera_gpu.sprite_draw_count[frame_index].bytes_count),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  transparency.begin_pass(
    &self.transparency,
    camera_gpu,
    &camera_cpu,
    &self.texture_manager,
    command_buffer,
    frame_index,
  )
  // Render transparent objects
  transparency.render(
    &self.transparency,
    camera_gpu,
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
    camera_gpu.transparent_draw_commands[frame_index].buffer,
    camera_gpu.transparent_draw_count[frame_index].buffer,
  )
  // Render wireframe objects
  transparency.render(
    &self.transparency,
    camera_gpu,
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
    camera_gpu.transparent_draw_commands[frame_index].buffer,
    camera_gpu.transparent_draw_count[frame_index].buffer,
  )
  // Render random_color objects
  transparency.render(
    &self.transparency,
    camera_gpu,
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
    camera_gpu.transparent_draw_commands[frame_index].buffer,
    camera_gpu.transparent_draw_count[frame_index].buffer,
  )
  // Render line_strip objects
  transparency.render(
    &self.transparency,
    camera_gpu,
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
    camera_gpu.transparent_draw_commands[frame_index].buffer,
    camera_gpu.transparent_draw_count[frame_index].buffer,
  )
  // Render sprites
  transparency.render(
    &self.transparency,
    camera_gpu,
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
    camera_gpu.sprite_draw_commands[frame_index].buffer,
    camera_gpu.sprite_draw_count[frame_index].buffer,
  )
  transparency.end_pass(&self.transparency, command_buffer)
  return .SUCCESS
}

record_post_process_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  camera_handle: d.CameraHandle,
  color_format: vk.Format,
  swapchain_extent: vk.Extent2D,
  swapchain_image: vk.Image,
  swapchain_view: vk.ImageView,
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
  camera_cpu, ok := get_camera(self, camera_handle)
  if !ok do return .ERROR_UNKNOWN
  camera_gpu := &self.cameras_gpu[camera_handle.index]
  if final_image := gpu.get_texture_2d(
    &self.texture_manager,
    camera_gpu.attachments[.FINAL_IMAGE][frame_index],
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
    camera_gpu,
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
    &self.ui.projection_descriptor_set,
    0,
    nil,
  )
  vk.CmdBindDescriptorSets(
    command_buffer,
    .GRAPHICS,
    self.ui.pipeline_layout,
    1,
    1,
    &self.textures_descriptor_set,
    0,
    nil,
  )

  // Render UI
  ui.compute_layout_all(&self.ui_system)
  ui.render(
    &self.ui,
    &self.ui_system,
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
  if texture_index >= rd.MAX_TEXTURES {
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
  if texture_index >= rd.MAX_CUBE_TEXTURES {
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
// Takes single CPU camera data and copies to the specified frame index
upload_camera_data :: proc(
  render: ^Manager,
  camera_index: u32,
  camera: cam.Camera,
  frame_index: u32,
) {
  camera_copy := camera
  camera_data: rd.Camera
  camera_data.view = cam.camera_view_matrix(&camera_copy)
  camera_data.projection = cam.camera_projection_matrix(&camera_copy)
  near, far := cam.camera_get_near_far(&camera_copy)
  camera_data.viewport_params = [4]f32 {
    f32(camera_copy.extent[0]),
    f32(camera_copy.extent[1]),
    near,
    far,
  }
  camera_data.position = [4]f32 {
    camera_copy.position[0],
    camera_copy.position[1],
    camera_copy.position[2],
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
