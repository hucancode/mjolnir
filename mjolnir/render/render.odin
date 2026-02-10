package render

import alg "../algebra"
import cont "../containers"
import d "../data"
import geo "../geometry"
import "../gpu"
import "../ui"
import "camera"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "debug_draw"
import "debug_ui"
import "geometry"
import "lighting"
import "particles"
import "post_process"
import "transparency"
import vk "vendor:vulkan"
import "visibility"

FRAMES_IN_FLIGHT :: d.FRAMES_IN_FLIGHT

TextureTracking :: struct {
  ref_count:  u32,
  auto_purge: bool,
}

Manager :: struct {
  geometry:                geometry.Renderer,
  lighting:                lighting.Renderer,
  transparency:            transparency.Renderer,
  particles:               particles.Renderer,
  debug_draw:              debug_draw.Renderer,
  debug_draw_ik:           bool,
  post_process:            post_process.Renderer,
  debug_ui:                debug_ui.Renderer,
  ui_system:               ui.System,
  ui:                      ui.Renderer,
  main_camera:             d.CameraHandle,
  visibility:              visibility.System,
  textures_set_layout:     vk.DescriptorSetLayout,
  textures_descriptor_set: vk.DescriptorSet,
  general_pipeline_layout: vk.PipelineLayout,
  sprite_pipeline_layout:  vk.PipelineLayout,
  sphere_pipeline_layout:  vk.PipelineLayout,
  linear_repeat_sampler:   vk.Sampler,
  linear_clamp_sampler:    vk.Sampler,
  nearest_repeat_sampler:  vk.Sampler,
  nearest_clamp_sampler:   vk.Sampler,
  bone_buffer:             gpu.PerFrameBindlessBuffer(
    matrix[4, 4]f32,
    FRAMES_IN_FLIGHT,
  ),
  camera_buffer:           gpu.PerFrameBindlessBuffer(
    d.CameraData,
    FRAMES_IN_FLIGHT,
  ),
  spherical_camera_buffer: gpu.PerFrameBindlessBuffer(
    d.SphericalCameraData,
    FRAMES_IN_FLIGHT,
  ),
  material_buffer:         gpu.BindlessBuffer(d.MaterialData),
  world_matrix_buffer:     gpu.BindlessBuffer(matrix[4, 4]f32),
  node_data_buffer:        gpu.BindlessBuffer(d.NodeData),
  mesh_data_buffer:        gpu.BindlessBuffer(d.MeshData),
  emitter_buffer:          gpu.BindlessBuffer(d.EmitterData),
  forcefield_buffer:       gpu.BindlessBuffer(d.ForceFieldData),
  sprite_buffer:           gpu.BindlessBuffer(d.SpriteData),
  lights_buffer:           gpu.BindlessBuffer(d.LightData),
  vertex_skinning_buffer:  gpu.ImmutableBindlessBuffer(geo.SkinningData),
  vertex_buffer:           gpu.ImmutableBuffer(geo.Vertex),
  index_buffer:            gpu.ImmutableBuffer(u32),
  bone_matrix_slab:        cont.SlabAllocator,
  bone_matrix_offsets:     map[d.NodeHandle]u32,
  vertex_skinning_slab:    cont.SlabAllocator,
  vertex_slab:             cont.SlabAllocator,
  index_slab:              cont.SlabAllocator,
  texture_manager:         gpu.TextureManager,
  texture_2d_tracking:     map[d.Image2DHandle]TextureTracking,
  texture_cube_tracking:   map[d.ImageCubeHandle]TextureTracking,
  retired_textures_2d:     map[d.Image2DHandle]u32,
  retired_textures_cube:   map[d.ImageCubeHandle]u32,
  // Camera GPU resources (indexed by camera handle.index)
  cameras_gpu:             [d.MAX_CAMERAS]camera.CameraGPU,
  spherical_cameras_gpu:   [d.MAX_CAMERAS]camera.SphericalCameraGPU,
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
  // Initialize vertex skinning buffer
  skinning_count := d.BINDLESS_SKINNING_BUFFER_SIZE / size_of(geo.SkinningData)
  log.infof(
    "Creating vertex skinning buffer with capacity %d entries...",
    skinning_count,
  )
  gpu.immutable_bindless_buffer_init(
    &self.vertex_skinning_buffer,
    gctx,
    skinning_count,
    {.VERTEX},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.immutable_bindless_buffer_destroy(
      &self.vertex_skinning_buffer,
      gctx.device,
    )
  }
  cont.slab_init(&self.vertex_skinning_slab, d.VERTEX_SLAB_CONFIG)
  defer if ret != .SUCCESS {
    cont.slab_destroy(&self.vertex_skinning_slab)
  }

  // Initialize vertex and index buffers
  vertex_count := d.BINDLESS_VERTEX_BUFFER_SIZE / size_of(geo.Vertex)
  index_count := d.BINDLESS_INDEX_BUFFER_SIZE / size_of(u32)
  self.vertex_buffer = gpu.malloc_buffer(
    gctx,
    geo.Vertex,
    vertex_count,
    {.VERTEX_BUFFER},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.buffer_destroy(gctx.device, &self.vertex_buffer)
  }
  self.index_buffer = gpu.malloc_buffer(
    gctx,
    u32,
    index_count,
    {.INDEX_BUFFER},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.buffer_destroy(gctx.device, &self.index_buffer)
  }
  cont.slab_init(&self.vertex_slab, d.VERTEX_SLAB_CONFIG)
  defer if ret != .SUCCESS {
    cont.slab_destroy(&self.vertex_slab)
  }
  cont.slab_init(&self.index_slab, d.INDEX_SLAB_CONFIG)
  defer if ret != .SUCCESS {
    cont.slab_destroy(&self.index_slab)
  }

  log.info("Vertex buffer capacity:", vertex_count, "vertices")
  log.info("Index buffer capacity:", index_count, "indices")
  return .SUCCESS
}

@(private)
destroy_geometry_buffers :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  cont.slab_destroy(&self.vertex_skinning_slab)
  gpu.immutable_bindless_buffer_destroy(
    &self.vertex_skinning_buffer,
    gctx.device,
  )
  gpu.buffer_destroy(gctx.device, &self.vertex_buffer)
  gpu.buffer_destroy(gctx.device, &self.index_buffer)
  cont.slab_destroy(&self.vertex_slab)
  cont.slab_destroy(&self.index_slab)
}

@(private)
sync_existing_resource_data :: proc(
  self: ^Manager,
  materials: ^d.Pool(d.Material),
  meshes: ^d.Pool(d.Mesh),
) {
  for &entry, i in materials.entries do if entry.active {
    handle := d.MaterialHandle {
      index      = u32(i),
      generation = entry.generation,
    }
    upload_material_data(self, handle, &entry.item)
  }
  for &entry, i in meshes.entries do if entry.active {
    handle := d.MeshHandle {
      index      = u32(i),
      generation = entry.generation,
    }
    upload_mesh_data(self, handle, &entry.item)
  }
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
  self.bone_matrix_offsets = make(map[d.NodeHandle]u32)
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
  gpu.per_frame_bindless_buffer_init(
    &self.spherical_camera_buffer,
    gctx,
    d.MAX_ACTIVE_CAMERAS,
    {.VERTEX, .FRAGMENT, .COMPUTE, .GEOMETRY},
  ) or_return
  return .SUCCESS
}

@(private)
shutdown_camera_buffers :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  gpu.per_frame_bindless_buffer_destroy(&self.camera_buffer, gctx.device)
  gpu.per_frame_bindless_buffer_destroy(
    &self.spherical_camera_buffer,
    gctx.device,
  )
}

@(private)
shutdown_camera_resources :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  for i in 0 ..< d.MAX_CAMERAS {
    camera.destroy_gpu(gctx, &self.cameras_gpu[i], &self.texture_manager)
    camera.destroy_spherical_gpu(
      gctx,
      &self.spherical_cameras_gpu[i],
      &self.texture_manager,
    )
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
    self.vertex_skinning_buffer.set_layout,
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
  self.sphere_pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.VERTEX, .GEOMETRY, .FRAGMENT},
      size = size_of(u32),
    },
    self.spherical_camera_buffer.set_layout,
    self.textures_set_layout,
    self.bone_buffer.set_layout,
    self.material_buffer.set_layout,
    self.world_matrix_buffer.set_layout,
    self.node_data_buffer.set_layout,
    self.mesh_data_buffer.set_layout,
    self.vertex_skinning_buffer.set_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.sphere_pipeline_layout, nil)
    self.sphere_pipeline_layout = 0
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
  vk.DestroyPipelineLayout(gctx.device, self.sphere_pipeline_layout, nil)
  vk.DestroyDescriptorSetLayout(gctx.device, self.textures_set_layout, nil)
  vk.DestroySampler(gctx.device, self.linear_repeat_sampler, nil)
  vk.DestroySampler(gctx.device, self.linear_clamp_sampler, nil)
  vk.DestroySampler(gctx.device, self.nearest_repeat_sampler, nil)
  vk.DestroySampler(gctx.device, self.nearest_clamp_sampler, nil)
  self.general_pipeline_layout = 0
  self.sprite_pipeline_layout = 0
  self.sphere_pipeline_layout = 0
  self.textures_set_layout = 0
  self.textures_descriptor_set = 0
  self.linear_repeat_sampler = 0
  self.linear_clamp_sampler = 0
  self.nearest_repeat_sampler = 0
  self.nearest_clamp_sampler = 0
}

record_compute_commands :: proc(
  self: ^Manager,
  frame_index: u32,
  gctx: ^gpu.GPUContext,
  cameras: ^d.Pool(d.Camera),
  spherical_cameras: ^d.Pool(d.SphericalCamera),
  compute_buffer: vk.CommandBuffer,
) -> vk.Result {
  // Compute for frame N prepares data for frame N+1
  // Buffer indices with d.FRAMES_IN_FLIGHT=2: frame N uses buffer [N], produces data for buffer [N+1]
  next_frame_index := alg.next(frame_index, d.FRAMES_IN_FLIGHT)
  for &entry, cam_index in cameras.entries do if entry.active {
    cam_cpu := &entry.item
    cam_gpu := &self.cameras_gpu[cam_index]
    upload_camera_data(self, cameras, u32(cam_index), frame_index)
    // Only build pyramid if enabled for this camera
    if cam_cpu.enable_depth_pyramid {
      visibility.build_pyramid(&self.visibility, gctx, compute_buffer, cam_gpu, u32(cam_index), frame_index) // Build pyramid[N]
    }
    // Only perform culling if enabled for this camera
    if cam_cpu.enable_culling {
      visibility.perform_culling(&self.visibility, gctx, compute_buffer, cam_gpu, u32(cam_index), next_frame_index, {.VISIBLE}, {}) // Write draw_list[N+1]
    }
  }
  for &entry, cam_index in spherical_cameras.entries do if entry.active {
    cam_cpu := &entry.item
    cam_gpu := &self.spherical_cameras_gpu[cam_index]
    upload_spherical_camera_data(self, cam_cpu, u32(cam_index), frame_index)
    visibility.perform_sphere_culling(&self.visibility, gctx, compute_buffer, cam_gpu, u32(cam_index), next_frame_index, {.VISIBLE}, {.MATERIAL_TRANSPARENT, .MATERIAL_WIREFRAME}) // Write draw_list[N+1]
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
  materials: ^d.Pool(d.Material),
  meshes: ^d.Pool(d.Mesh),
  cameras: ^d.Pool(d.Camera),
  spherical_cameras: ^d.Pool(d.SphericalCamera),
  builtin_meshes: ^[len(d.Primitive)]d.MeshHandle,
  swapchain_extent: vk.Extent2D,
  swapchain_format: vk.Format,
  dpi_scale: f32,
) -> (
  ret: vk.Result,
) {
  // Initialize texture tracking maps
  self.texture_2d_tracking = make(map[d.Image2DHandle]TextureTracking)
  self.texture_cube_tracking = make(map[d.ImageCubeHandle]TextureTracking)
  self.retired_textures_2d = make(map[d.Image2DHandle]u32)
  self.retired_textures_cube = make(map[d.ImageCubeHandle]u32)
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
  sync_existing_resource_data(self, materials, meshes)
  init_bindless_layouts(self, gctx) or_return
  defer if ret != .SUCCESS {
    shutdown_bindless_layouts(self, gctx)
  }
  init_builtin_meshes(gctx, self, meshes, builtin_meshes) or_return
  camera_handle, camera_cpu, ok := cont.alloc(cameras, d.CameraHandle)
  if !ok {
    return .ERROR_INITIALIZATION_FAILED
  }
  defer if ret != .SUCCESS {
    cont.free(cameras, camera_handle)
  }
  d.camera_init(
    camera_cpu,
    swapchain_extent.width,
    swapchain_extent.height,
    {
      .SHADOW,
      .GEOMETRY,
      .LIGHTING,
      .TRANSPARENCY,
      .PARTICLES,
      .DEBUG_DRAW,
      .POST_PROCESS,
    },
    {3, 4, 3}, // Camera slightly above and diagonal to origin
    {0, 0, 0}, // Looking at origin
    math.PI * 0.5, // FOV
    0.1, // near plane
    100.0, // far plane
  ) or_return
  // Initialize GPU resources for the camera
  camera_gpu := &self.cameras_gpu[camera_handle.index]
  camera.init_gpu(
    gctx,
    camera_gpu,
    camera_cpu,
    &self.texture_manager,
    swapchain_extent.width,
    swapchain_extent.height,
    swapchain_format,
    vk.Format.D32_SFLOAT,
    camera_cpu.enabled_passes,
    d.MAX_NODES_IN_SCENE,
  ) or_return
  self.main_camera = camera_handle
  visibility.init(
    &self.visibility,
    gctx,
    swapchain_extent.width,
    swapchain_extent.height,
    self.general_pipeline_layout,
    self.sphere_pipeline_layout,
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
  // Create light volume meshes for lighting renderer
  sphere_mesh := allocate_mesh_geometry(
    gctx,
    self,
    meshes,
    geo.make_sphere(segments = 64, rings = 64),
  ) or_return
  cone_mesh := allocate_mesh_geometry(
    gctx,
    self,
    meshes,
    geo.make_cone(segments = 128, height = 1, radius = 0.5),
  ) or_return
  triangle_mesh := allocate_mesh_geometry(
    gctx,
    self,
    meshes,
    geo.make_fullscreen_triangle(),
  ) or_return
  lighting.init(
    &self.lighting,
    gctx,
    &self.texture_manager,
    self.camera_buffer.set_layout,
    self.lights_buffer.set_layout,
    self.world_matrix_buffer.set_layout,
    self.spherical_camera_buffer.set_layout,
    &self.mesh_data_buffer,
    self.textures_set_layout,
    sphere_mesh,
    cone_mesh,
    triangle_mesh,
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
    builtin_meshes[d.Primitive.QUAD_XY],
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
  debug_draw.init(
    &self.debug_draw,
    gctx,
    self.camera_buffer.set_layout,
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
  debug_draw.shutdown(&self.debug_draw, gctx)
  post_process.shutdown(&self.post_process, gctx, &self.texture_manager)
  particles.shutdown(&self.particles, gctx)
  transparency.shutdown(&self.transparency, gctx)
  lighting.shutdown(&self.lighting, gctx, &self.texture_manager)
  geometry.shutdown(&self.geometry, gctx)
  visibility.shutdown(&self.visibility, gctx)
  shutdown_camera_resources(self, gctx)
  shutdown_bindless_layouts(self, gctx)
  shutdown_scene_buffers(self, gctx)
  shutdown_camera_buffers(self, gctx)
  shutdown_bone_buffer(self, gctx)
  destroy_geometry_buffers(self, gctx)
  // Cleanup texture tracking maps
  delete(self.texture_2d_tracking)
  delete(self.texture_cube_tracking)
  delete(self.retired_textures_2d)
  delete(self.retired_textures_cube)
}

resize :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
  extent: vk.Extent2D,
  color_format: vk.Format,
  dpi_scale: f32,
) -> vk.Result {
  lighting.recreate_images(
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

render_camera_depth :: proc(
  self: ^Manager,
  frame_index: u32,
  gctx: ^gpu.GPUContext,
  cameras: ^d.Pool(d.Camera),
  spherical_cameras: ^d.Pool(d.SphericalCamera),
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
  for &entry, cam_index in cameras.entries do if entry.active {
    cam_cpu := &entry.item
    cam_gpu := &self.cameras_gpu[cam_index]
    // Look up draw list source if specified (allows sharing culling between cameras)
    draw_list_source_gpu: ^camera.CameraGPU = nil
    if source := cam_cpu.draw_list_source_handle; source.generation > 0 {
      draw_list_source_gpu = &self.cameras_gpu[source.index]
    }
    visibility.render_depth(&self.visibility, gctx, command_buffer, cam_gpu, cam_cpu, &self.texture_manager, u32(cam_index), frame_index, {.VISIBLE}, {.MATERIAL_TRANSPARENT, .MATERIAL_WIREFRAME}, self.textures_descriptor_set, self.bone_buffer.descriptor_sets[frame_index], self.material_buffer.descriptor_set, self.world_matrix_buffer.descriptor_set, self.node_data_buffer.descriptor_set, self.mesh_data_buffer.descriptor_set, self.vertex_skinning_buffer.descriptor_set, self.vertex_buffer.buffer, self.index_buffer.buffer, draw_list_source_gpu)
  }
  for &entry, cam_index in spherical_cameras.entries do if entry.active {
    cam_cpu := &entry.item
    cam_gpu := &self.spherical_cameras_gpu[cam_index]
    visibility.render_sphere_depth(&self.visibility, gctx, command_buffer, cam_gpu, cam_cpu, &self.texture_manager, u32(cam_index), frame_index, {.VISIBLE}, {.MATERIAL_TRANSPARENT, .MATERIAL_WIREFRAME}, self.sphere_pipeline_layout, self.textures_descriptor_set, self.spherical_camera_buffer.descriptor_sets[frame_index], self.bone_buffer.descriptor_sets[frame_index], self.material_buffer.descriptor_set, self.world_matrix_buffer.descriptor_set, self.node_data_buffer.descriptor_set, self.mesh_data_buffer.descriptor_set, self.vertex_skinning_buffer.descriptor_set, self.vertex_buffer.buffer, self.index_buffer.buffer)
  }
  return .SUCCESS
}

record_geometry_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  gctx: ^gpu.GPUContext,
  cameras: d.Pool(d.Camera),
  camera_handle: d.CameraHandle,
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
  camera_cpu := cont.get(cameras, camera_handle)
  if camera_cpu == nil do return .ERROR_UNKNOWN
  camera_gpu := &self.cameras_gpu[camera_handle.index]
  geometry.begin_pass(
    camera_gpu,
    camera_cpu,
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
    self.vertex_skinning_buffer.descriptor_set,
    self.vertex_buffer.buffer,
    self.index_buffer.buffer,
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
  cameras: d.Pool(d.Camera),
  meshes: d.Pool(d.Mesh),
  lights: d.Pool(d.Light),
  active_lights: []d.LightHandle,
  camera_handle: d.CameraHandle,
  color_format: vk.Format,
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
  camera_cpu := cont.get(cameras, camera_handle)
  if camera_cpu == nil do return .ERROR_UNKNOWN
  camera_gpu := &self.cameras_gpu[camera_handle.index]
  lighting.begin_ambient_pass(
    &self.lighting,
    camera_gpu,
    camera_cpu,
    &self.texture_manager,
    command_buffer,
    frame_index,
  )
  lighting.render_ambient(
    &self.lighting,
    camera_handle,
    camera_gpu,
    command_buffer,
    frame_index,
  )
  lighting.end_ambient_pass(command_buffer)
  lighting.begin_pass(
    &self.lighting,
    camera_gpu,
    camera_cpu,
    &self.texture_manager,
    command_buffer,
    self.lights_buffer.descriptor_set,
    self.world_matrix_buffer.descriptor_set,
    self.spherical_camera_buffer.descriptor_sets[frame_index],
    frame_index,
  )
  lighting.render(
    &self.lighting,
    camera_handle,
    camera_gpu,
    &self.cameras_gpu,
    &self.spherical_cameras_gpu,
    command_buffer,
    meshes,
    cameras,
    lights,
    active_lights,
    &self.world_matrix_buffer,
    self.vertex_buffer.buffer,
    self.index_buffer.buffer,
    frame_index,
  )
  lighting.end_pass(command_buffer)
  return .SUCCESS
}

record_particles_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  cameras: d.Pool(d.Camera),
  camera_handle: d.CameraHandle,
  color_format: vk.Format,
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
  camera_cpu, ok := cont.get(cameras, camera_handle)
  if !ok do return .ERROR_UNKNOWN
  camera_gpu := &self.cameras_gpu[camera_handle.index]
  particles.begin_pass(
    &self.particles,
    command_buffer,
    camera_gpu,
    camera_cpu,
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
  cameras: d.Pool(d.Camera),
  camera_handle: d.CameraHandle,
  color_format: vk.Format,
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
  camera_cpu, ok := cont.get(cameras, camera_handle)
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
    camera_cpu,
    &self.texture_manager,
    command_buffer,
    frame_index,
  )
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
    self.vertex_skinning_buffer.descriptor_set,
    self.vertex_buffer.buffer,
    self.index_buffer.buffer,
    camera_handle,
    frame_index,
    command_buffer,
    camera_gpu.transparent_draw_commands[frame_index].buffer,
    camera_gpu.transparent_draw_count[frame_index].buffer,
  )
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
    self.vertex_skinning_buffer.descriptor_set,
    self.vertex_buffer.buffer,
    self.index_buffer.buffer,
    camera_handle,
    frame_index,
    command_buffer,
    camera_gpu.sprite_draw_commands[frame_index].buffer,
    camera_gpu.sprite_draw_count[frame_index].buffer,
  )
  transparency.end_pass(&self.transparency, command_buffer)
  return .SUCCESS
}

record_debug_draw_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  cameras: d.Pool(d.Camera),
  meshes: d.Pool(d.Mesh),
  destroy_line_strip_mesh_ctx: rawptr,
  destroy_line_strip_mesh: proc(ctx: rawptr, handle: d.MeshHandle),
  camera_handle: d.CameraHandle,
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
  camera_cpu, ok := cont.get(cameras, camera_handle)
  if !ok do return .ERROR_UNKNOWN
  camera_gpu := &self.cameras_gpu[camera_handle.index]
  debug_draw.update(
    &self.debug_draw,
    destroy_line_strip_mesh_ctx,
    destroy_line_strip_mesh,
  )
  debug_draw.begin_pass(
    &self.debug_draw,
    camera_gpu,
    camera_cpu,
    &self.texture_manager,
    command_buffer,
    frame_index,
  )
  debug_draw.render(
    &self.debug_draw,
    camera_gpu,
    camera_handle,
    command_buffer,
    meshes,
    frame_index,
    self.vertex_buffer.buffer,
    self.index_buffer.buffer,
  )
  debug_draw.end_pass(&self.debug_draw, command_buffer)
  return .SUCCESS
}

record_post_process_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  cameras: d.Pool(d.Camera),
  camera_handle: d.CameraHandle,
  color_format: vk.Format,
  swapchain_extent: vk.Extent2D,
  swapchain_image: vk.Image,
  swapchain_view: vk.ImageView,
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
  camera_cpu, ok := cont.get(cameras, camera_handle)
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

get_camera_attachment :: proc(
  self: ^Manager,
  camera_handle: d.CameraHandle,
  attachment_type: d.AttachmentType,
  frame_index: u32 = 0,
) -> d.Image2DHandle {
  return camera.get_attachment(
    &self.cameras_gpu[camera_handle.index],
    attachment_type,
    frame_index,
  )
}
