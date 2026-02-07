package resources

import "../animation"
import cont "../containers"
import "../geometry"
import "../gpu"
import "core:log"
import "core:slice"
import vk "vendor:vulkan"

FRAMES_IN_FLIGHT :: #config(FRAMES_IN_FLIGHT, 2)
// Bone matrix buffer capacity (default: 60MB per frame × 2 frames = 120MB total)
// Override at build time: -define:BONE_BUFFER_CAPACITY_MB=80
BONE_BUFFER_CAPACITY_MB :: #config(BONE_BUFFER_CAPACITY_MB, 60)
MAX_TEXTURES :: 1000
MAX_CUBE_TEXTURES :: 200
MAX_NODES_IN_SCENE :: 65536
MAX_ACTIVE_CAMERAS :: 128
MAX_EMITTERS :: 64
MAX_FORCE_FIELDS :: 32
MAX_LIGHTS :: 256
MAX_SHADOW_MAPS :: 16
SHADOW_MAP_SIZE :: 512
MAX_UI_WIDGETS :: 4096
BINDLESS_VERTEX_BUFFER_SIZE :: 128 * 1024 * 1024 // 128MB
BINDLESS_INDEX_BUFFER_SIZE :: 64 * 1024 * 1024 // 64MB
BINDLESS_SKINNING_BUFFER_SIZE :: 128 * 1024 * 1024 // 128MB
// Configuration for different allocation sizes
// Total capacity MUST equal buffer capacity: 128MB / 64 bytes = 2,097,152 vertices
// Current: 256*512 + 1024*128 + 4096*64 + 16384*16 + 65536*8 + 131072*4 = 2,097,152 vertices
VERTEX_SLAB_CONFIG :: [cont.MAX_SLAB_CLASSES]struct {
  block_size, block_count: u32,
} {
  {block_size = 256, block_count = 512},    // Small meshes: 131,072 vertices, range [0, 131K)
  {block_size = 1024, block_count = 128},   // Medium meshes: 131,072 vertices, range [131K, 262K)
  {block_size = 4096, block_count = 64},    // Large meshes: 262,144 vertices, range [262K, 524K)
  {block_size = 16384, block_count = 16},   // Very large meshes: 262,144 vertices, range [524K, 786K)
  {block_size = 65536, block_count = 8},    // Huge meshes: 524,288 vertices, range [786K, 1310K)
  {block_size = 131072, block_count = 4},   // Massive meshes: 524,288 vertices, range [1310K, 1835K)
  {block_size = 262144, block_count = 1},   // Giant meshes: 262,144 vertices, range [1835K, 2097K)
  {block_size = 0, block_count = 0},        // Unused
}

// Total capacity: 128*2048 + 512*1024 + 2048*512 + 8192*256 + 32768*128 + 131072*32 + 524288*8 + 2097152*4 = 16,777,216 indices
INDEX_SLAB_CONFIG :: [cont.MAX_SLAB_CLASSES]struct {
  block_size, block_count: u32,
} {
  {block_size = 128, block_count = 2048}, // Small index counts: 262,144 indices
  {block_size = 512, block_count = 1024}, // Medium index counts: 524,288 indices
  {block_size = 2048, block_count = 512}, // Large index counts: 1,048,576 indices
  {block_size = 8192, block_count = 256}, // Very large index counts: 2,097,152 indices
  {block_size = 32768, block_count = 128}, // Huge index counts: 4,194,304 indices
  {block_size = 131072, block_count = 32}, // Massive index counts: 4,194,304 indices
  {block_size = 524288, block_count = 8}, // Giant index counts: 4,194,304 indices
  {block_size = 2097152, block_count = 4}, // Enormous index counts: 8,388,608 indices
}

Handle :: cont.Handle
NodeHandle :: distinct Handle
MeshHandle :: distinct Handle
MaterialHandle :: distinct Handle
Image2DHandle :: distinct Handle
ImageCubeHandle :: distinct Handle
CameraHandle :: distinct Handle
SphereCameraHandle :: CameraHandle // TODO: for better type-safety, make this distinct
EmitterHandle :: distinct Handle
ForceFieldHandle :: distinct Handle
ClipHandle :: distinct Handle
SpriteHandle :: distinct Handle
LightHandle :: distinct Handle

Pool :: cont.Pool
SlabAllocator :: cont.SlabAllocator

ResourceMetadata :: struct {
  ref_count:  u32, // Reference count for resource lifetime tracking
  auto_purge: bool, // true = purge when ref_count==0, false = self managed lifecycle, never purged automatically
}

SamplerType :: enum u32 {
  NEAREST_CLAMP  = 0,
  LINEAR_CLAMP   = 1,
  NEAREST_REPEAT = 2,
  LINEAR_REPEAT  = 3,
}

Manager :: struct {
  // Global samplers
  linear_repeat_sampler:     vk.Sampler,
  linear_clamp_sampler:      vk.Sampler,
  nearest_repeat_sampler:    vk.Sampler,
  nearest_clamp_sampler:     vk.Sampler,
  builtin_materials:         [len(Color)]MaterialHandle,
  builtin_meshes:            [len(Primitive)]MeshHandle,
  meshes:                    Pool(Mesh),
  materials:                 Pool(Material),
  images_2d:                 Pool(gpu.Image),
  images_cube:               Pool(gpu.CubeImage),
  cameras:                   Pool(Camera),
  spherical_cameras:         Pool(SphericalCamera),
  emitters:                  Pool(Emitter),
  forcefields:               Pool(ForceField),
  animation_clips:           Pool(animation.Clip),
  sprites:                   Pool(Sprite),
  lights:                    Pool(Light),
  bone_buffer:               gpu.PerFrameBindlessBuffer(
    matrix[4, 4]f32,
    FRAMES_IN_FLIGHT,
  ),
  bone_matrix_slab:          SlabAllocator,
  camera_buffer:             gpu.PerFrameBindlessBuffer(
    CameraData,
    FRAMES_IN_FLIGHT,
  ),
  spherical_camera_buffer:   gpu.PerFrameBindlessBuffer(
    SphericalCameraData,
    FRAMES_IN_FLIGHT,
  ),
  material_buffer:           gpu.BindlessBuffer(MaterialData),
  world_matrix_buffer:       gpu.BindlessBuffer(matrix[4, 4]f32),
  node_data_buffer:          gpu.BindlessBuffer(NodeData),
  mesh_data_buffer:          gpu.BindlessBuffer(MeshData),
  emitter_buffer:            gpu.BindlessBuffer(EmitterData),
  forcefield_buffer:         gpu.BindlessBuffer(ForceFieldData),
  sprite_buffer:             gpu.BindlessBuffer(SpriteData),
  vertex_skinning_buffer:    gpu.ImmutableBindlessBuffer(
    geometry.SkinningData,
  ),
  vertex_skinning_slab:      SlabAllocator,
  lights_buffer:             gpu.BindlessBuffer(LightData),
  textures_set_layout:       vk.DescriptorSetLayout,
  textures_descriptor_set:   vk.DescriptorSet,
  general_pipeline_layout:   vk.PipelineLayout, // general purpose layout, used by geometry, transparency, depth renderers
  sprite_pipeline_layout:    vk.PipelineLayout, // 5-set layout for sprite rendering
  sphere_pipeline_layout:    vk.PipelineLayout, // general purpose layout, used by spherical depth rendering, same as general_pipeline_layout but use spherical camera instead
  vertex_buffer:             gpu.ImmutableBuffer(geometry.Vertex),
  index_buffer:              gpu.ImmutableBuffer(u32),
  vertex_slab:               SlabAllocator,
  index_slab:                SlabAllocator,
  current_frame_index:       u32,
  animatable_sprites:        [dynamic]SpriteHandle,
  active_lights:             [dynamic]LightHandle,
  ui_widgets:                rawptr, // Pool(ui.Widget), set by ui module to avoid circular dependency
}

init :: proc(self: ^Manager, gctx: ^gpu.GPUContext) -> (ret: vk.Result) {
  cont.init(&self.meshes, MAX_MESHES)
  cont.init(&self.materials, MAX_MATERIALS)
  cont.init(&self.images_2d, MAX_TEXTURES)
  cont.init(&self.images_cube, MAX_CUBE_TEXTURES)
  cont.init(&self.cameras, MAX_ACTIVE_CAMERAS)
  cont.init(&self.spherical_cameras, MAX_ACTIVE_CAMERAS)
  cont.init(&self.forcefields, MAX_FORCE_FIELDS)
  cont.init(&self.animation_clips, 0)
  cont.init(&self.sprites, MAX_SPRITES)
  cont.init(&self.lights, MAX_LIGHTS)
  self.current_frame_index = 0
  log.infof("All resource pools initialized successfully")
  init_global_samplers(self, gctx)
  log.info("Initializing bindless buffer systems...")
  // Calculate slab configuration to fit within BONE_BUFFER_CAPACITY_MB
  // Each bone matrix is 64 bytes (matrix[4,4]f32)
  // Distribution: favor smaller allocations, reduce large blocks
  // This configuration totals to ~60MB with default setting
  cont.slab_init(
    &self.bone_matrix_slab,
    {
      {32, 64}, // 64 bytes × 32 bones × 64 blocks = 128KB
      {64, 128}, // 64 bytes × 64 bones × 128 blocks = 512KB
      {128, 4096}, // 64 bytes × 128 bones × 4096 blocks = 32MB
      {256, 1792}, // 64 bytes × 256 bones × 1792 blocks = 28MB
      {512, 0}, // Disabled (users can override BONE_BUFFER_CAPACITY_MB if needed)
      {1024, 0}, // Disabled
      {2048, 0}, // Disabled
      {4096, 0}, // Disabled
      // Total: ~60MB per frame, 120MB for 2 frames (default)
      // To increase: odin build -define:BONE_BUFFER_CAPACITY_MB=80
    },
  )
  gpu.per_frame_bindless_buffer_init(
    &self.bone_buffer,
    gctx,
    int(self.bone_matrix_slab.capacity),
    {.VERTEX},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.per_frame_bindless_buffer_destroy(&self.bone_buffer, gctx.device)
    cont.slab_destroy(&self.bone_matrix_slab)
  }
  gpu.per_frame_bindless_buffer_init(
    &self.camera_buffer,
    gctx,
    MAX_ACTIVE_CAMERAS,
    {.VERTEX, .FRAGMENT, .COMPUTE},
  ) or_return
  defer if ret != .SUCCESS do gpu.per_frame_bindless_buffer_destroy(&self.camera_buffer, gctx.device)
  gpu.per_frame_bindless_buffer_init(
    &self.spherical_camera_buffer,
    gctx,
    MAX_ACTIVE_CAMERAS,
    {.VERTEX, .FRAGMENT, .COMPUTE, .GEOMETRY},
  ) or_return
  defer if ret != .SUCCESS do gpu.per_frame_bindless_buffer_destroy(&self.spherical_camera_buffer, gctx.device)
  gpu.bindless_buffer_init(
    &self.material_buffer,
    gctx,
    MAX_MATERIALS,
    {.VERTEX, .FRAGMENT},
  ) or_return
  defer if ret != .SUCCESS do gpu.bindless_buffer_destroy(&self.material_buffer, gctx.device)
  gpu.bindless_buffer_init(
    &self.world_matrix_buffer,
    gctx,
    MAX_NODES_IN_SCENE,
    {.VERTEX, .FRAGMENT, .COMPUTE},
  ) or_return
  defer if ret != .SUCCESS do gpu.bindless_buffer_destroy(&self.world_matrix_buffer, gctx.device)
  gpu.bindless_buffer_init(
    &self.node_data_buffer,
    gctx,
    MAX_NODES_IN_SCENE,
    {.VERTEX, .FRAGMENT},
  ) or_return
  defer if ret != .SUCCESS do gpu.bindless_buffer_destroy(&self.node_data_buffer, gctx.device)
  gpu.bindless_buffer_init(
    &self.mesh_data_buffer,
    gctx,
    MAX_MESHES,
    {.VERTEX},
  ) or_return
  defer if ret != .SUCCESS do gpu.bindless_buffer_destroy(&self.mesh_data_buffer, gctx.device)
  init_vertex_skinning_buffer(self, gctx) or_return
  defer if ret != .SUCCESS do destroy_vertex_skinning_buffer(self, gctx)
  gpu.bindless_buffer_init(
    &self.emitter_buffer,
    gctx,
    MAX_EMITTERS,
    {.COMPUTE},
  ) or_return
  defer if ret != .SUCCESS do gpu.bindless_buffer_destroy(&self.emitter_buffer, gctx.device)
  emitters := gpu.get_all(&self.emitter_buffer.buffer)
  for &emitter in emitters do emitter = {}
  gpu.bindless_buffer_init(
    &self.forcefield_buffer,
    gctx,
    MAX_FORCE_FIELDS,
    {.COMPUTE},
  ) or_return
  defer if ret != .SUCCESS do gpu.bindless_buffer_destroy(&self.forcefield_buffer, gctx.device)
  forcefields := gpu.get_all(&self.forcefield_buffer.buffer)
  for &forcefield in forcefields do forcefield = {}
  gpu.bindless_buffer_init(
    &self.lights_buffer,
    gctx,
    MAX_LIGHTS,
    {.VERTEX, .FRAGMENT},
  ) or_return
  defer if ret != .SUCCESS do gpu.bindless_buffer_destroy(&self.lights_buffer, gctx.device)
  gpu.bindless_buffer_init(
    &self.sprite_buffer,
    gctx,
    MAX_SPRITES,
    {.VERTEX, .FRAGMENT},
  ) or_return
  defer if ret != .SUCCESS do gpu.bindless_buffer_destroy(&self.sprite_buffer, gctx.device)
  sprites := gpu.get_all(&self.sprite_buffer.buffer)
  for &sprite in sprites do sprite = {}
  init_vertex_index_buffers(self, gctx) or_return
  defer if ret != .SUCCESS do destroy_vertex_index_buffers(self, gctx)
  log.info("Bindless buffer systems initialized successfully")
  self.textures_set_layout = gpu.create_descriptor_set_layout_array(
    gctx,
    {.SAMPLED_IMAGE, MAX_TEXTURES, {.FRAGMENT}},
    {.SAMPLER, gpu.MAX_SAMPLERS, {.FRAGMENT}},
    {.SAMPLED_IMAGE, MAX_CUBE_TEXTURES, {.FRAGMENT}},
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
    self.camera_buffer.set_layout, // Set 0
    self.textures_set_layout, // Set 1
    self.bone_buffer.set_layout, // Set 2
    self.material_buffer.set_layout, // Set 3
    self.world_matrix_buffer.set_layout, // Set 4
    self.node_data_buffer.set_layout, // Set 5
    self.mesh_data_buffer.set_layout, // Set 6
    self.vertex_skinning_buffer.set_layout, // Set 7
    // Removed: lights_buffer (set 8 - never used)
    // Removed: sprite_buffer (set 9 - moved to sprite_pipeline_layout)
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.general_pipeline_layout, nil)
    self.general_pipeline_layout = 0
  }
  // Pipeline layout for sprite rendering (no bones/skinning needed)
  self.sprite_pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.VERTEX, .FRAGMENT},
      size = size_of(u32),
    },
    self.camera_buffer.set_layout, // Set 0
    self.textures_set_layout, // Set 1
    self.world_matrix_buffer.set_layout, // Set 2 (renumbered from 4)
    self.node_data_buffer.set_layout, // Set 3 (renumbered from 5)
    self.sprite_buffer.set_layout, // Set 4 (renumbered from 9)
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.sprite_pipeline_layout, nil)
    self.sprite_pipeline_layout = 0
  }
  // Pipeline layout for spherical depth rendering (point light shadows)
  self.sphere_pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.VERTEX, .GEOMETRY, .FRAGMENT},
      size = size_of(u32),
    },
    self.spherical_camera_buffer.set_layout, // Set 0
    self.textures_set_layout, // Set 1
    self.bone_buffer.set_layout, // Set 2
    self.material_buffer.set_layout, // Set 3
    self.world_matrix_buffer.set_layout, // Set 4
    self.node_data_buffer.set_layout, // Set 5
    self.mesh_data_buffer.set_layout, // Set 6
    self.vertex_skinning_buffer.set_layout, // Set 7
    // Removed: lights_buffer (set 8 - never used)
    // Removed: sprite_buffer (set 9 - not used in spherical rendering)
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
  init_builtin_materials(self) or_return
  init_builtin_meshes(self, gctx) or_return
  log.info("Resource systems initialized successfully")
  return .SUCCESS
}

shutdown :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  gpu.bindless_buffer_destroy(&self.material_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.world_matrix_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.emitter_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.forcefield_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.lights_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.sprite_buffer, gctx.device)
  // Clean up lights (which may own shadow cameras with textures)
  for &entry, i in self.lights.entries do if entry.generation > 0 && entry.active {
    destroy_light(self, gctx, LightHandle{index = u32(i), generation = entry.generation})
  }
  delete(self.lights.entries)
  delete(self.lights.free_indices)
  for &entry in self.spherical_cameras.entries do if entry.generation > 0 && entry.active {
    spherical_camera_destroy(&entry.item, gctx, self)
  }
  delete(self.spherical_cameras.entries)
  delete(self.spherical_cameras.free_indices)
  for &entry in self.cameras.entries do if entry.generation > 0 && entry.active {
    camera_destroy(&entry.item, gctx, self)
  }
  delete(self.cameras.entries)
  delete(self.cameras.free_indices)
  for &entry in self.images_2d.entries do if entry.generation > 0 && entry.active {
    gpu.image_destroy(gctx.device, &entry.item)
  }
  delete(self.images_2d.entries)
  delete(self.images_2d.free_indices)
  for &entry in self.images_cube.entries do if entry.generation > 0 && entry.active {
    gpu.cube_depth_texture_destroy(gctx.device, &entry.item)
  }
  delete(self.images_cube.entries)
  delete(self.images_cube.free_indices)
  for &entry in self.meshes.entries do if entry.generation > 0 && entry.active {
    mesh_destroy(&entry.item, self)
  }
  delete(self.meshes.entries)
  delete(self.meshes.free_indices)
  // Simple cleanup for pools without GPU resources
  delete(self.materials.entries)
  delete(self.materials.free_indices)
  delete(self.emitters.entries)
  delete(self.emitters.free_indices)
  delete(self.forcefields.entries)
  delete(self.forcefields.free_indices)
  delete(self.sprites.entries)
  delete(self.sprites.free_indices)
  delete(self.animatable_sprites)
  delete(self.active_lights)
  for &entry in self.animation_clips.entries do if entry.generation > 0 && entry.active {
    animation.clip_destroy(&entry.item)
  }
  delete(self.animation_clips.entries)
  delete(self.animation_clips.free_indices)
  destroy_global_samplers(self, gctx)
  gpu.per_frame_bindless_buffer_destroy(&self.bone_buffer, gctx.device)
  cont.slab_destroy(&self.bone_matrix_slab)
  gpu.per_frame_bindless_buffer_destroy(&self.camera_buffer, gctx.device)
  gpu.per_frame_bindless_buffer_destroy(
    &self.spherical_camera_buffer,
    gctx.device,
  )
  gpu.bindless_buffer_destroy(&self.node_data_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.mesh_data_buffer, gctx.device)
  destroy_vertex_skinning_buffer(self, gctx)
  destroy_vertex_index_buffers(self, gctx)
  vk.DestroyPipelineLayout(gctx.device, self.general_pipeline_layout, nil)
  self.general_pipeline_layout = 0
  vk.DestroyPipelineLayout(gctx.device, self.sprite_pipeline_layout, nil)
  self.sprite_pipeline_layout = 0
  vk.DestroyPipelineLayout(gctx.device, self.sphere_pipeline_layout, nil)
  self.sphere_pipeline_layout = 0
  vk.DestroyDescriptorSetLayout(gctx.device, self.textures_set_layout, nil)
  self.textures_set_layout = 0
  self.textures_descriptor_set = 0
}

@(private)
init_global_samplers :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
) -> vk.Result {
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
  info.addressModeU = .CLAMP_TO_EDGE
  info.addressModeV = .CLAMP_TO_EDGE
  info.addressModeW = .CLAMP_TO_EDGE
  vk.CreateSampler(
    gctx.device,
    &info,
    nil,
    &self.linear_clamp_sampler,
  ) or_return
  info.magFilter = .NEAREST
  info.minFilter = .NEAREST
  info.addressModeU = .REPEAT
  info.addressModeV = .REPEAT
  info.addressModeW = .REPEAT
  vk.CreateSampler(
    gctx.device,
    &info,
    nil,
    &self.nearest_repeat_sampler,
  ) or_return
  info.addressModeU = .CLAMP_TO_EDGE
  info.addressModeV = .CLAMP_TO_EDGE
  info.addressModeW = .CLAMP_TO_EDGE
  vk.CreateSampler(
    gctx.device,
    &info,
    nil,
    &self.nearest_clamp_sampler,
  ) or_return
  return .SUCCESS
}

@(private)
init_vertex_skinning_buffer :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
) -> vk.Result {
  skinning_count :=
    BINDLESS_SKINNING_BUFFER_SIZE / size_of(geometry.SkinningData)
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
  cont.slab_init(&self.vertex_skinning_slab, VERTEX_SLAB_CONFIG)
  return .SUCCESS
}

@(private)
destroy_vertex_skinning_buffer :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  cont.slab_destroy(&self.vertex_skinning_slab)
  gpu.immutable_bindless_buffer_destroy(
    &self.vertex_skinning_buffer,
    gctx.device,
  )
}


@(private)
destroy_global_samplers :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  vk.DestroySampler(
    gctx.device,
    self.linear_repeat_sampler,
    nil,
  );self.linear_repeat_sampler = 0
  vk.DestroySampler(
    gctx.device,
    self.linear_clamp_sampler,
    nil,
  );self.linear_clamp_sampler = 0
  vk.DestroySampler(
    gctx.device,
    self.nearest_repeat_sampler,
    nil,
  );self.nearest_repeat_sampler = 0
  vk.DestroySampler(
    gctx.device,
    self.nearest_clamp_sampler,
    nil,
  );self.nearest_clamp_sampler = 0
}

@(private)
init_vertex_index_buffers :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
) -> vk.Result {
  vertex_count := BINDLESS_VERTEX_BUFFER_SIZE / size_of(geometry.Vertex)
  index_count := BINDLESS_INDEX_BUFFER_SIZE / size_of(u32)
  self.vertex_buffer = gpu.malloc_buffer(
    gctx,
    geometry.Vertex,
    vertex_count,
    {.VERTEX_BUFFER},
  ) or_return
  self.index_buffer = gpu.malloc_buffer(
    gctx,
    u32,
    index_count,
    {.INDEX_BUFFER},
  ) or_return
  cont.slab_init(&self.vertex_slab, VERTEX_SLAB_CONFIG)
  cont.slab_init(&self.index_slab, INDEX_SLAB_CONFIG)
  log.info("Vertex buffer capacity:", vertex_count, "vertices")
  log.info("Index buffer capacity:", index_count, "indices")
  return .SUCCESS
}

@(private)
destroy_vertex_index_buffers :: proc(
  rm: ^Manager,
  gctx: ^gpu.GPUContext,
) {
  gpu.buffer_destroy(gctx.device, &rm.vertex_buffer)
  gpu.buffer_destroy(gctx.device, &rm.index_buffer)
  cont.slab_destroy(&rm.vertex_slab)
  cont.slab_destroy(&rm.index_slab)
}
