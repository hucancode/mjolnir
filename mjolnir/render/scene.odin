package render

import geom "../geometry"
import cont "../containers"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:strings"
import "core:sync"
import "gpu"
import vk "vendor:vulkan"

@(private)
MAX_NODES_IN_SCENE :: 65536
@(private)
MAX_ACTIVE_CAMERAS :: 128
// direct_light packs camera indices into 16 bits
#assert(MAX_ACTIVE_CAMERAS < 0xFFFF)
// MAX_LIGHTS is the capacity of the light buffer.
MAX_LIGHTS :: 256
@(private)
MAX_MESHES :: 65536
@(private)
MAX_MATERIALS :: 4096
@(private)
MAX_SHADOW_MAPS :: 16
@(private)
SHADOW_MAP_SIZE :: 512
// Shadow casters ranked by screen coverage get a map; the rest of the maps go
// to casters that ranked within the last SHADOW_GRACE_FRAMES frames.
@(private)
SHADOW_RANKED_CASTERS :: 12
@(private)
SHADOW_GRACE_FRAMES :: 30
#assert(SHADOW_RANKED_CASTERS <= MAX_SHADOW_MAPS)
// a cube map renders six views
@(private)
MAX_SHADOW_VIEWS :: MAX_SHADOW_MAPS * 6
@(private)
SHADOW_MAX_DRAWS :: 4096 * MAX_SHADOW_VIEWS

// A handle is the index of its resource in the resource's array, GPU table
// and (textures) bindless array. 0 is none: index 0 is never handed out.
MeshHandle :: distinct u32
// MaterialHandle identifies a material.
MaterialHandle :: distinct u32
// TextureHandle identifies a bindless texture; NO_TEXTURE is none.
TextureHandle :: distinct u32
// CameraHandle identifies a camera.
CameraHandle :: distinct u32
// EmitterHandle identifies a particle emitter.
EmitterHandle :: distinct u32
// ForceFieldHandle identifies a particle force field.
ForceFieldHandle :: distinct u32

// Single-variant pipelines; the others are indexed by MaterialType, LightType and effect.
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
//     shaders read them. Create them through the create_* procs; material,
//     emitter and forcefield return pointers into the table the next frame
//     draws from, to edit in place.
//   * attachments: per-slot emitters and force fields, indexed by transform
//     slot (meshes live in the slot's node record, lights in `lights`). A slot is
//     whatever index the caller uses to identify a transform; the engine uses
//     world node indices.
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
Renderer :: struct {
  gctx:                    gpu.GPUContext,
  swapchain:               gpu.Swapchain,
  meshes:                  []MeshData,
  mesh_slots:              cont.Slots,
  material_slots:          cont.Slots,
  emitter_slots:           cont.Slots,
  forcefield_slots:        cont.Slots,
  // its length is the node count every cull dispatch covers
  attachments:             [dynamic]Attachment,
  // unordered; light_slots[i] is the slot lights[i] shines from
  lights:                  [dynamic]Light,
  light_slots:             [dynamic]u32,
  builtin_materials:       [Color]MaterialHandle,
  builtin_meshes:          [Primitive]MeshHandle,
  cameras:                 []Camera,
  camera_slots:            cont.Slots,
  main_camera:             CameraHandle,
  ambient:                 AmbientRenderer,
  post_process:            PostProcessRenderer,
  command_buffers:         [gpu.FRAMES_IN_FLIGHT]vk.CommandBuffer,
  compute_command_buffers: [gpu.FRAMES_IN_FLIGHT]vk.CommandBuffer,
  level_ready:             bool,
  scene:                   SceneDescriptors,
  pipelines:               [PipelineId]vk.Pipeline,
  material_pipelines:      [MaterialType]vk.Pipeline,
  light_pipelines:         [LightType]vk.Pipeline,
  textures:                []gpu.Image,
  texture_slots:           cont.Slots,
  samplers:                [SamplerType]vk.Sampler,
  mesh_buffers:            [MeshStream]gpu.Buffer,
  mesh_slabs:              [MeshStream]cont.SlabAllocator,
  frame_arena:             [gpu.FRAMES_IN_FLIGHT]gpu.Buffer,
  bone_buffers:            [gpu.FRAMES_IN_FLIGHT]gpu.Buffer,
  arena_layout:            ArenaLayout,
  region_debt:             RegionDebt,
  mesh_data_buffer:        gpu.Buffer,
  draw_count_readback:     [gpu.FRAMES_IN_FLIGHT]gpu.Buffer,
  bone_matrix_slab:        cont.SlabAllocator,
  // per pyramid slot: groups done this dispatch; the last one resets it
  pyramid_counters:        gpu.Buffer,
  // alive list: an indirect draw header followed by one particle index per vertex
  particle_buffer:         gpu.Buffer,
  particle_alive_buffer:   gpu.Buffer,
  particle_params:         ParticleSystemParams,
  particle_time:           f32,
  debug_lines:             [dynamic]DebugLineSegment,
  debug_time:              f32,
  debug_mutex:             sync.Mutex,
  ui:                      OverlayRenderer,
  light_count:             [LightType]u32,
  shadow_casters:          [MAX_SHADOW_MAPS]Caster,
  // one per atlas layer in use (pack_lights)
  shadow_view_count:       u32,
  shadow_atlas:            [gpu.FRAMES_IN_FLIGHT]gpu.Image,
  shadow_draws:            DrawLists,
  mutex:                   sync.Recursive_Mutex,
}

// Creates a window surface for `instance`; `user` is passed through from init.
SurfaceProc :: #type proc(user: rawptr, instance: vk.Instance) -> (vk.SurfaceKHR, vk.Result)

// Bring the renderer up on a window: instance, surface (through
// `create_surface(surface_user, instance)`), device, swapchain, every
// app-lifetime resource and an empty level with a main camera. Paired with
// shutdown.
init :: proc(
  self: ^Renderer,
  app_name: string,
  instance_extensions: []cstring,
  get_instance_proc_addr: rawptr,
  create_surface: SurfaceProc,
  surface_user: rawptr,
  framebuffer_size: [2]u32,
  dpi_scale: f32,
) -> bool {
  res := init_vulkan(
    self,
    app_name,
    instance_extensions,
    get_instance_proc_addr,
    create_surface,
    surface_user,
    framebuffer_size,
    dpi_scale,
  )
  if res == .SUCCESS do res = setup_level(self)
  if res != .SUCCESS {
    log.errorf("Renderer init failed: %v", res)
    return false
  }
  return true
}

@(private = "file")
init_vulkan :: proc(
  self: ^Renderer,
  app_name: string,
  instance_extensions: []cstring,
  get_instance_proc_addr: rawptr,
  create_surface: SurfaceProc,
  surface_user: rawptr,
  framebuffer_size: [2]u32,
  dpi_scale: f32,
) -> vk.Result {
  gctx := &self.gctx
  name := strings.clone_to_cstring(app_name, context.temp_allocator)
  gpu.instance_init(gctx, name, instance_extensions, get_instance_proc_addr) or_return
  gctx.surface = create_surface(surface_user, gctx.instance) or_return
  gpu.device_init(gctx) or_return
  gpu.swapchain_init(&self.swapchain, gctx, framebuffer_size) or_return
  init_descriptor_pool(gctx) or_return
  cont.slots_init(&self.camera_slots, MAX_ACTIVE_CAMERAS, gpu.RETIRE_GRACE)
  cont.slots_init(&self.mesh_slots, MAX_MESHES, gpu.RETIRE_GRACE)
  cont.slots_init(&self.material_slots, MAX_MATERIALS, gpu.RETIRE_GRACE)
  cont.slots_init(&self.emitter_slots, MAX_EMITTERS, gpu.RETIRE_GRACE)
  cont.slots_init(&self.forcefield_slots, MAX_FORCE_FIELDS, gpu.RETIRE_GRACE)
  self.cameras = make([]Camera, MAX_ACTIVE_CAMERAS)
  self.meshes = make([]MeshData, MAX_MESHES)
  // full capacity up front: growth must not reallocate while flush reads it
  self.attachments = make([dynamic]Attachment, 0, MAX_NODES_IN_SCENE)
  gpu.allocate_command_buffer(gctx, self.command_buffers[:]) or_return
  gpu.allocate_command_buffer(gctx, self.compute_command_buffers[:], gctx.compute_command_pool) or_return
  mesh_arena_init(self) or_return
  init_scene_buffers(self, gctx) or_return
  init_builtin_materials(self)
  init_builtin_meshes(self)
  bindless_init(self) or_return
  scene_descriptors_init(self) or_return
  occlusion_init(self) or_return
  shadow_init(self) or_return
  direct_light_init(self) or_return
  material_pipelines_init(self) or_return
  particles_init(self) or_return
  post_process_init(self) or_return
  debug_line_init(self) or_return
  overlay_init(self, dpi_scale) or_return
  return .SUCCESS
}

// Level-lifetime resources: descriptors, per-level renderer state and the
// main camera. init runs it once; after teardown, call it to start the next
// level. Safe to call at any point outside frame; a no-op when the level is
// already set up. Load the environment map with load_environment_map afterwards.
setup :: proc(self: ^Renderer) -> bool {
  res := setup_level(self)
  if res != .SUCCESS do log.errorf("Renderer level setup failed: %v", res)
  return res == .SUCCESS
}

@(private = "file")
setup_level :: proc(self: ^Renderer) -> (ret: vk.Result) {
  if self.level_ready do return .SUCCESS
  swapchain_extent := self.swapchain.extent
  self.level_ready = true
  defer if ret != .SUCCESS do teardown(self)
  // retired, not reclaimed: submitted frames may still sample the slot
  cont.slots_init(&self.texture_slots, MAX_TEXTURES, gpu.RETIRE_GRACE)
  self.textures = make([]gpu.Image, MAX_TEXTURES)
  ambient_setup(self) or_return
  particles_reset(self) or_return
  overlay_setup(self) or_return
  if _, ok := main_camera(self); !ok {
    cam, created := create_camera(
      self,
      swapchain_extent.width,
      swapchain_extent.height,
      position = {3, 4, 3},
      far_plane = 1000.0,
    )
    if !created do return .ERROR_INITIALIZATION_FAILED
    self.main_camera = cam
  }
  return .SUCCESS
}

// Free every slot, camera and level resource. App-lifetime resources (pools,
// pipelines, builtin meshes) stay. Safe to call at any point outside frame: it
// waits for every frame in flight first. A no-op when no level is set up.
teardown :: proc(self: ^Renderer) {
  if !self.level_ready do return
  self.level_ready = false
  gctx := &self.gctx
  vk.DeviceWaitIdle(gctx.device)
  clear_slots(self)
  c: u32
  for i in cont.slots_next(&self.camera_slots, &c) do destroy_camera(self, CameraHandle(i))
  cont.slots_flush(&self.camera_slots)
  overlay_teardown(self)
  post_process_release_images(self)
  ambient_teardown(self)
  for r in cont.slots_flush(&self.texture_slots) do gpu.image_destroy(gctx.device, &self.textures[r.index])
  c = 0
  for i in cont.slots_next(&self.texture_slots, &c) do gpu.image_destroy(gctx.device, &self.textures[i])
  cont.slots_destroy(&self.texture_slots)
  delete(self.textures)
  self.textures = nil
  gpu.deferred_flush(gctx)
}

// Replace the environment map with the equirectangular HDR image at `path`
// and precompute image-based lighting from it. Level-lifetime: call after
// setup; teardown frees it. Without one, IBL and the skybox are black.
load_environment_map :: proc(self: ^Renderer, path: string) -> bool {
  res := ambient_load_environment(self, path)
  if res != .SUCCESS do log.warnf("Failed to load environment map %s: %v", path, res)
  return res == .SUCCESS
}

// Destroy everything init created; tears the level down first if needed.
shutdown :: proc(self: ^Renderer) {
  teardown(self)
  gctx := &self.gctx
  vk.DeviceWaitIdle(gctx.device)
  for p in self.pipelines do vk.DestroyPipeline(gctx.device, p, nil)
  for p in self.material_pipelines do vk.DestroyPipeline(gctx.device, p, nil)
  for p in self.light_pipelines do vk.DestroyPipeline(gctx.device, p, nil)
  for pipelines in self.post_process.pipelines do for p in pipelines do vk.DestroyPipeline(gctx.device, p, nil)
  delete(self.post_process.effect_stack)
  delete(self.debug_lines)
  delete(self.ui.batches)
  delete(self.ui.atlas_pixels)
  draw_lists_destroy(&self.shadow_draws, gctx)
  scene_descriptors_shutdown(&self.scene, gctx)
  bindless_shutdown(self)
  destroy_scene_buffers(self, gctx)
  mesh_arena_destroy(self)
  cont.slots_destroy(&self.camera_slots)
  cont.slots_destroy(&self.mesh_slots)
  cont.slots_destroy(&self.material_slots)
  cont.slots_destroy(&self.emitter_slots)
  cont.slots_destroy(&self.forcefield_slots)
  delete(self.cameras)
  delete(self.meshes)
  delete(self.attachments)
  delete(self.lights)
  delete(self.light_slots)
  gpu.swapchain_destroy(&self.swapchain, gctx.device)
  gpu.shutdown(gctx)
}

// Cameras that matched the old extent follow the new one.
@(private)
recreate_swapchain :: proc(self: ^Renderer, framebuffer_size: [2]u32, dpi_scale: f32) -> vk.Result {
  gctx := &self.gctx
  old := self.swapchain.extent
  vk.DeviceWaitIdle(gctx.device)
  gpu.swapchain_destroy(&self.swapchain, gctx.device)
  gpu.swapchain_init(&self.swapchain, gctx, framebuffer_size) or_return
  extent := self.swapchain.extent
  c: u32
  for i in cont.slots_next(&self.camera_slots, &c) {
    if self.cameras[i].extent != {old.width, old.height} do continue
    resize_camera(self, CameraHandle(i), extent.width, extent.height) or_return
  }
  post_process_release_images(self)
  self.ui.dpi_scale = dpi_scale
  return .SUCCESS
}

@(private = "file")
init_descriptor_pool :: proc(gctx: ^gpu.GPUContext) -> vk.Result {
  sizes := make([dynamic]vk.DescriptorPoolSize, context.temp_allocator)
  add :: proc(sizes: ^[dynamic]vk.DescriptorPoolSize, type: vk.DescriptorType, count: u32) {
    for &s in sizes do if s.type == type {s.descriptorCount += count; return}
    append(sizes, vk.DescriptorPoolSize{type, count})
  }
  for type in SCENE_BINDING_TYPES do add(&sizes, type, gpu.FRAMES_IN_FLIGHT)
  for b in BINDLESS_BINDINGS do add(&sizes, b.type, b.count)
  return gpu.descriptor_pool_init(gctx, sizes[:], gpu.FRAMES_IN_FLIGHT + 1)
}

// Hold off the render thread's frame while editing scene data through the
// pointers material, emitter and forcefield return. Only needed when another
// thread than the one calling frame edits; the stage_*, create_* and
// destroy_* procs lock themselves. frame holds the lock from flush through
// the hand-off to the next write frame.
lock :: proc(self: ^Renderer) {
  sync.recursive_mutex_lock(&self.mutex)
}

// unlock releases the lock taken by lock.
unlock :: proc(self: ^Renderer) {
  sync.recursive_mutex_unlock(&self.mutex)
}

// The only place retirement advances; once per frame, so ticks follow frame_serial.
@(private)
tick_resource_pools :: proc(self: ^Renderer) {
  gpu.deferred_tick(&self.gctx)
  for r in cont.slots_tick(&self.texture_slots) do gpu.image_destroy(self.gctx.device, &self.textures[r.index])
  for r in cont.slots_tick(&self.mesh_slots) {
    free_mesh(self, self.meshes[r.index])
    self.meshes[r.index] = {}
  }
  cont.slots_tick(&self.material_slots)
  cont.slots_tick(&self.emitter_slots)
  cont.slots_tick(&self.forcefield_slots)
  cont.slots_tick(&self.camera_slots)
}

// Advance the render clock (debug line lifetimes) and the particle
// simulation time. Call once per update tick; the next frame emits and
// simulates everything accumulated since the previous one.
update :: proc(self: ^Renderer, delta_time: f32) {
  sync.mutex_lock(&self.debug_mutex)
  self.debug_time += delta_time
  sync.mutex_unlock(&self.debug_mutex)
  if delta_time <= 0 do return
  sync.recursive_mutex_lock(&self.mutex)
  self.particle_time += delta_time
  sync.recursive_mutex_unlock(&self.mutex)
}

// caller holds the render mutex
@(private)
clear_entry :: proc(r: ^Renderer, b: SceneBinding, $T: typeid, index: u32) {
  write_table(r, b, T)[index] = {}
  mark_dirty(r, b, T, int(index))
}

@(private)
NodeFlag :: enum u32 {
  VISIBLE,
  CASTS_SHADOW,
}

@(private)
NodeFlagSet :: bit_set[NodeFlag;u32]

// attachment_data_index is the first entry of the slot's bone table range.
@(private)
NodeData :: struct #packed {
  world_matrix:          matrix[4, 4]f32,
  material_id:           u32,
  mesh_id:               u32,
  attachment_data_index: u32,
  flags:                 NodeFlagSet,
}

@(private)
NO_BONES :: 0xFFFFFFFF

@(private)
INVALID_NODE :: NodeData {
  material_id           = 0xFFFFFFFF,
  mesh_id               = 0xFFFFFFFF,
  attachment_data_index = NO_BONES,
}

// MeshAttachment draws mesh handle with material from a slot's transform.
MeshAttachment :: struct {
  handle:      MeshHandle,
  material:    MaterialHandle,
  cast_shadow: bool,
}

// What a slot draws. An emitter or force field is bound to the slot's
// transform; a Light shines from it.
Attachment :: union {
  Light,
  MeshAttachment,
  EmitterHandle,
  ForceFieldHandle,
}

// Grows the slot range to cover `slot`. Caller holds the render mutex and marks what it changes.
@(private)
slot_node :: proc(self: ^Renderer, slot: u32) -> ^NodeData {
  assert(slot < MAX_NODES_IN_SCENE, "slot exceeds MAX_NODES_IN_SCENE")
  nodes := write_table(self, .NODES, NodeData)
  if n := len(self.attachments); int(slot) >= n {
    resize(&self.attachments, int(slot) + 1)
    for &node in nodes[n:][:int(slot) + 1 - n] do node = INVALID_NODE
    mark_dirty(self, .NODES, NodeData, n, int(slot) + 1 - n)
  }
  return &nodes[slot]
}

// Set the world transform and effective visibility of every slot in
// `changes`, and forget (see stage_slot_removal) the slots marked removed: any
// struct with `index` (the slot), `world_matrix`, `visible` and `removed`
// fields, such as world.NodeChange. Removals come first in the feed, so a slot
// freed and reused in one tick ends up drawn by its new owner.
stage_transforms :: proc(self: ^Renderer, changes: []$T) {
  sync.recursive_mutex_lock(&self.mutex)
  defer sync.recursive_mutex_unlock(&self.mutex)
  for &c in changes {
    if c.removed {
      stage_slot_removal(self, c.index)
      continue
    }
    node := slot_node(self, c.index)
    node.world_matrix = c.world_matrix
    if c.visible do node.flags += {.VISIBLE}
    else do node.flags -= {.VISIBLE}
    mark_dirty(self, .NODES, NodeData, int(c.index))
  }
}

// Forget everything drawn at a slot. Emitters and force fields owned
// by the attachment are destroyed; meshes and materials are shared and stay.
stage_slot_removal :: proc(self: ^Renderer, slot: u32) {
  sync.recursive_mutex_lock(&self.mutex)
  defer sync.recursive_mutex_unlock(&self.mutex)
  detach_light(self, slot)
  if int(slot) >= len(self.attachments) do return
  #partial switch a in self.attachments[slot] {
  case EmitterHandle:
    destroy_emitter(self, a)
  case ForceFieldHandle:
    destroy_forcefield(self, a)
  }
  self.attachments[slot] = nil
  release_bones(self, slot)
  write_table(self, .NODES, NodeData)[slot] = INVALID_NODE
  mark_dirty(self, .NODES, NodeData, int(slot))
}

@(private = "file")
clear_slots :: proc(self: ^Renderer) {
  sync.recursive_mutex_lock(&self.mutex)
  defer sync.recursive_mutex_unlock(&self.mutex)
  for i := len(self.attachments) - 1; i >= 0; i -= 1 do stage_slot_removal(self, u32(i))
  clear(&self.lights)
  clear(&self.light_slots)
}

// caller holds the render mutex
@(private = "file")
detach_light :: proc(self: ^Renderer, slot: u32) {
  i, found := slice.linear_search(self.light_slots[:], slot)
  if !found do return
  unordered_remove(&self.lights, i)
  unordered_remove(&self.light_slots, i)
}

// caller holds the render mutex
@(private = "file")
release_bones :: proc(self: ^Renderer, slot: u32) {
  node := &write_table(self, .NODES, NodeData)[slot]
  if node.attachment_data_index == NO_BONES do return
  cont.slab_free(&self.bone_matrix_slab, node.attachment_data_index)
  node.attachment_data_index = NO_BONES
  mark_dirty(self, .NODES, NodeData, int(slot))
}

// Skin palette (bone skinning matrices) for the skinned mesh at `slot`.
// The matrices are copied.
stage_bones :: proc(self: ^Renderer, slot: u32, matrices: []matrix[4, 4]f32) {
  count := u32(len(matrices))
  if count == 0 do return
  sync.recursive_mutex_lock(&self.mutex)
  defer sync.recursive_mutex_unlock(&self.mutex)
  node := slot_node(self, slot)
  if node.attachment_data_index == NO_BONES || cont.slab_block_size(&self.bone_matrix_slab, node.attachment_data_index) < count {
    release_bones(self, slot)
    node.attachment_data_index = alloc_bones(self, count)
    mark_dirty(self, .NODES, NodeData, int(slot))
  }
  offset := node.attachment_data_index
  if offset == NO_BONES do return
  copy(write_table(self, .BONES, matrix[4, 4]f32)[offset:][:count], matrices)
  mark_dirty(self, .BONES, matrix[4, 4]f32, int(offset), int(count))
}

// A bone range of `count` matrices, growing the slab when it is full.
// NO_BONES when no size class fits `count` or the grown buffer would exceed
// the device's storage buffer range. Caller holds the render mutex.
@(private = "file")
alloc_bones :: proc(self: ^Renderer, count: u32) -> u32 {
  if offset, ok := cont.slab_alloc(&self.bone_matrix_slab, count); ok do return offset
  if grow_bones(self) == .SUCCESS {
    if offset, ok := cont.slab_alloc(&self.bone_matrix_slab, count); ok do return offset
  }
  log.warnf("No bone range for a %d-bone palette; the mesh draws unskinned", count)
  return NO_BONES
}

// Doubles every size class and re-places every palette; the other frames' buffers follow at
// hand_off. Caller holds the render mutex.
@(private = "file")
grow_bones :: proc(self: ^Renderer) -> vk.Result {
  old_slab := self.bone_matrix_slab
  config: [cont.MAX_SLAB_CLASSES]struct {
    block_size, block_count: u32,
  }
  capacity: u64
  for c, i in old_slab.classes {
    config[i] = {c.block_size, c.block_count * 2}
    capacity += u64(c.block_size) * u64(c.block_count) * 2
  }
  limit := u64(self.gctx.device_properties.limits.maxStorageBufferRange)
  if capacity * size_of(matrix[4, 4]f32) > limit do return .ERROR_OUT_OF_DEVICE_MEMORY
  grown := gpu.buffer_create(
    &self.gctx,
    vk.DeviceSize(capacity * size_of(matrix[4, 4]f32)),
    {.STORAGE_BUFFER},
    host_cached = true,
  ) or_return
  w := write_frame(self)
  // the write frame is not in flight: its old buffer goes at once
  old := self.bone_buffers[w]
  defer gpu.buffer_destroy(self.gctx.device, &old)
  defer cont.slab_destroy(&old_slab)
  self.bone_buffers[w] = grown
  scene_write_binding(self, .BONES, int(w))
  cont.slab_init(&self.bone_matrix_slab, config)
  old_bones := gpu.mapped(&old, matrix[4, 4]f32)
  bones := write_table(self, .BONES, matrix[4, 4]f32)
  for &node, slot in write_table(self, .NODES, NodeData)[:len(self.attachments)] {
    if node.attachment_data_index == NO_BONES do continue
    size := cont.slab_block_size(&old_slab, node.attachment_data_index)
    offset, ok := cont.slab_alloc(&self.bone_matrix_slab, size)
    if ok do copy(bones[offset:][:size], old_bones[node.attachment_data_index:][:size])
    node.attachment_data_index = offset if ok else NO_BONES
    mark_dirty(self, .NODES, NodeData, slot)
  }
  for &debt in self.region_debt[.BONES] do debt = gpu.FRAMES_IN_FLIGHT - 1
  log.infof("Bone buffer grown to %d matrices", self.bone_matrix_slab.capacity)
  return .SUCCESS
}

// attach draws attachment at slot, replacing what the slot drew before.
attach :: proc(self: ^Renderer, slot: u32, attachment: Attachment) {
  sync.recursive_mutex_lock(&self.mutex)
  defer sync.recursive_mutex_unlock(&self.mutex)
  node := slot_node(self, slot)
  self.attachments[slot] = nil
  detach_light(self, slot)
  node.mesh_id, node.material_id = INVALID_NODE.mesh_id, INVALID_NODE.material_id
  node.flags -= {.CASTS_SHADOW}
  switch a in attachment {
  case MeshAttachment:
    node.mesh_id, node.material_id = u32(a.handle), u32(a.material)
    if a.cast_shadow do node.flags += {.CASTS_SHADOW}
  case Light:
    append(&self.lights, a)
    append(&self.light_slots, slot)
  case EmitterHandle:
    self.attachments[slot] = a
    if em, ok := emitter(self, a); ok do em.node_index = slot
  case ForceFieldHandle:
    self.attachments[slot] = a
    if ff, ok := forcefield(self, a); ok do ff.node_index = slot
  }
  mark_dirty(self, .NODES, NodeData, int(slot))
}

// attachment returns a copy of the attachment of type T at slot, e.g. attachment(r, slot, MeshAttachment).
// Edit it and pass it back to attach.
attachment :: proc(
  self: ^Renderer,
  slot: u32,
  $T: typeid,
) -> (
  att: T,
  ok: bool,
) #optional_ok {
  sync.recursive_mutex_lock(&self.mutex)
  defer sync.recursive_mutex_unlock(&self.mutex)
  if int(slot) >= len(self.attachments) do return
  when T == MeshAttachment {
    node := write_table(self, .NODES, NodeData)[slot]
    if node.mesh_id == INVALID_NODE.mesh_id do return
    return {MeshHandle(node.mesh_id), MaterialHandle(node.material_id), .CASTS_SHADOW in node.flags}, true
  } else when T == Light {
    i := slice.linear_search(self.light_slots[:], slot) or_return
    return self.lights[i], true
  } else {
    return self.attachments[slot].(T)
  }
}

// SPOT_LIGHT_INNER_RATIO is the default ratio of a spot light's full-intensity cone to its falloff cone.
SPOT_LIGHT_INNER_RATIO :: f32(0.75)

// LightType selects the light branch of the lighting shaders (specialization constant 0).
// AMBIENT is the environment light (image-based lighting, emissive, skybox), one per frame.
LightType :: enum u16 {
  POINT,
  SPOT,
  DIRECTIONAL,
  AMBIENT,
}

// Light is stored as the lighting shaders read it. Attached to a slot it shines from the
// slot's transform along its forward axis; render fills position, direction, shadow_map
// and shadow_texel each frame. Point lights ignore direction and angles; a directional
// light's shadow map covers radius in front of the main camera.
Light :: struct {
  color:        [4]f32, // RGB + intensity
  position:     [3]f32,
  // range of a point or spot light; shadow distance of a directional light
  // from the main camera
  radius:       f32,
  direction:    [3]f32, // normalized
  angle_inner:  f32, // spot cone angles
  angle_outer:  f32,
  // view table index of the shadow map's first face, NO_SHADOW without one
  shadow_map:   u32,
  // world size of a shadow texel per unit of view depth, for point and spot
  shadow_texel: f32,
  // the shaders' last u32, which they don't read
  type:         LightType,
  cast_shadow:  b16,
}
#assert(size_of(Light) == 64)

@(private)
NO_SHADOW :: 0xFFFFFFFF

// point_light_attachment returns an omnidirectional Light for attach.
point_light_attachment :: proc(
  color: [4]f32 = {1, 1, 1, 1},
  radius: f32 = 10.0,
  cast_shadow: bool = true,
) -> Light {
  return {type = .POINT, color = color, radius = radius, cast_shadow = b16(cast_shadow)}
}

// directional_light_attachment returns a sun-like Light for attach; shadow_radius is its shadow distance.
directional_light_attachment :: proc(
  color: [4]f32 = {1, 1, 1, 1},
  shadow_radius: f32 = 10.0,
  cast_shadow: bool = false,
) -> Light {
  return {type = .DIRECTIONAL, color = color, radius = shadow_radius, cast_shadow = b16(cast_shadow)}
}

// spot_light_attachment returns a cone Light of the given half angle for attach.
spot_light_attachment :: proc(
  color: [4]f32 = {1, 1, 1, 1},
  radius: f32 = 10.0,
  angle: f32 = math.PI * 0.2,
  cast_shadow: bool = true,
) -> Light {
  return {
    type        = .SPOT,
    color       = color,
    radius      = radius,
    angle_inner = angle * SPOT_LIGHT_INNER_RATIO,
    angle_outer = angle,
    cast_shadow = b16(cast_shadow),
  }
}

// matches SHADOW_CASCADES in the lighting shader
@(private)
SHADOW_CASCADES :: 4
// 0 splits uniformly, 1 logarithmically
@(private)
SHADOW_CASCADE_LOG_WEIGHT :: 0.75

// One shadow view and atlas layer per face.
@(private)
SHADOW_FACE_COUNT := [LightType]u32 {
  .POINT       = len(CUBE_FACES),
  .SPOT        = 1,
  .DIRECTIONAL = SHADOW_CASCADES,
  .AMBIENT     = 0,
}

// (forward, up) per face, in the order the lighting shader's shadowFace picks them
@(private)
CUBE_FACES := [6][2][3]f32 {
  {{1, 0, 0}, {0, -1, 0}},
  {{-1, 0, 0}, {0, -1, 0}},
  {{0, 1, 0}, {0, 0, 1}},
  {{0, -1, 0}, {0, 0, -1}},
  {{0, 0, 1}, {0, -1, 0}},
  {{0, 0, -1}, {0, -1, 0}},
}

// A shadow-casting light this frame, or the holder of a shadow map.
@(private)
Caster :: struct {
  light:       int, // index into the frame's lights
  owner:       u32, // light slot + 1; 0 for a free map
  score:       f32,
  // frame serial when the owner last ranked in the top SHADOW_RANKED_CASTERS
  last_ranked: u64,
}

// How much of a camera's view a light's shadow bounds cover, weighted by
// intensity: r²/(d²−r²) grows like the sphere's projected area, and a camera
// inside the sphere scores highest.
@(private)
shadow_score :: proc(bounds: [4]f32, intensity: f32, camera_position: [3]f32) -> f32 {
  offset := bounds.xyz - camera_position
  r2 := bounds.w * bounds.w
  return intensity * r2 / max(linalg.dot(offset, offset) - r2, 1e-6)
}

// `casters` is sorted by descending score; `maps` is the previous selection, rewritten.
@(private)
select_shadow_casters :: proc(casters: []Caster, maps: ^[MAX_SHADOW_MAPS]Caster, serial: u64) -> (count: int) {
  selected: [MAX_SHADOW_MAPS]Caster
  for c, rank in casters {
    if count == MAX_SHADOW_MAPS do break
    c := c
    c.last_ranked = serial
    if rank >= SHADOW_RANKED_CASTERS {
      held := false
      for m in maps do if m.owner == c.owner {c.last_ranked = m.last_ranked; held = true}
      if !held || serial - c.last_ranked > SHADOW_GRACE_FRAMES do continue
    }
    selected[count] = c
    count += 1
  }
  maps^ = selected
  return
}

@(private)
place_light :: proc(l: Light, world_matrix: matrix[4, 4]f32) -> Light {
  l := l
  forward := world_matrix[2].xyz
  l.position = world_matrix[3].xyz
  l.direction = linalg.normalize(forward) if linalg.dot(forward, forward) > 1e-6 else {0, -1, 0}
  l.shadow_map = NO_SHADOW
  perspective_texel :: proc(fovy: f32) -> f32 {return 2 * math.tan(0.5 * max(fovy, 0.001)) / SHADOW_MAP_SIZE}
  switch l.type {
  case .POINT:
    l.shadow_texel = perspective_texel(math.PI * 0.5)
  case .SPOT:
    l.shadow_texel = perspective_texel(l.angle_outer * 2)
  case .DIRECTIONAL:
    // radius: shadow distance from the main camera; the shader reads each
    // cascade's texel size from its projection
    l.radius = max(l.radius, 0.5)
  case .AMBIENT:
  }
  return l
}

@(private = "file")
light_look :: proc(position, direction: [3]f32) -> matrix[4, 4]f32 {
  up := [3]f32{0, 0, 1} if math.abs(direction.y) > 0.95 else {0, 1, 0}
  return linalg.matrix4_look_at(position, position + direction, up)
}

@(private)
shadow_face_matrices :: proc(l: Light, face: int, camera: ^ViewGPU) -> (view, projection: matrix[4, 4]f32) {
  perspective :: proc(fovy, radius: f32) -> matrix[4, 4]f32 {
    near :: 0.1
    return geom.make_perspective_matrix(max(fovy, 0.001), 1.0, near, max(near + 0.1, radius))
  }
  switch l.type {
  case .POINT:
    rotation := linalg.matrix4_look_at([3]f32{}, CUBE_FACES[face][0], CUBE_FACES[face][1])
    return rotation * linalg.matrix4_translate(-l.position), perspective(math.PI * 0.5, l.radius)
  case .SPOT:
    return light_look(l.position, l.direction), perspective(l.angle_outer * 2, l.radius)
  case .DIRECTIONAL:
    return cascade_matrices(l, face, camera)
  case .AMBIENT:
  }
  return
}

// Orthographic box around the bounding sphere of the cascade's camera-frustum slice: the
// sphere keeps the size fixed as the camera turns, texel snapping holds edges still as it moves.
@(private = "file")
cascade_matrices :: proc(l: Light, cascade: int, camera: ^ViewGPU) -> (view, projection: matrix[4, 4]f32) {
  near := camera.near
  far := max(min(l.radius, camera.far), near + 0.01)
  split :: proc(near, far: f32, i: int) -> f32 {
    t := f32(i) / SHADOW_CASCADES
    return math.lerp(near + (far - near) * t, near * math.pow(far / near, t), f32(SHADOW_CASCADE_LOG_WEIGHT))
  }
  depth_range := max(camera.far - camera.near, 1e-6)
  from := (split(near, far, cascade) - camera.near) / depth_range
  to := (split(near, far, cascade + 1) - camera.near) / depth_range
  corners: [8][3]f32
  center: [3]f32
  for i in 0 ..< 4 {
    ndc := [2]f32{f32(i & 1) * 2 - 1, f32(i >> 1) * 2 - 1}
    a := camera.inv_view_projection * [4]f32{ndc.x, ndc.y, 0, 1}
    b := camera.inv_view_projection * [4]f32{ndc.x, ndc.y, 1, 1}
    // view depth is linear along the corner ray, for both projections
    a_world, b_world := a.xyz / a.w, b.xyz / b.w
    corners[i] = linalg.lerp(a_world, b_world, from)
    corners[i + 4] = linalg.lerp(a_world, b_world, to)
    center += corners[i] + corners[i + 4]
  }
  center /= 8
  r: f32
  for c in corners do r = max(r, linalg.distance(c, center))
  // rounded up, so float noise can't change the texel size
  r = math.ceil(r * 16) / 16
  texel := 2 * r / SHADOW_MAP_SIZE
  rotation := light_look({}, l.direction)
  c := (rotation * [4]f32{center.x, center.y, center.z, 1}).xyz
  c.xy = linalg.floor(c.xy / texel) * texel
  // the eye sits r towards the light from the center, the box 2r deep
  view = linalg.matrix4_translate([3]f32{-c.x, -c.y, -(c.z + r)}) * rotation
  return view, geom.make_ortho_matrix(-r, r, -r, r, 0, 2 * r)
}

// Stable counting sort by type, so each type is one instance range of the lighting draw;
// then shadowed lights get consecutive shadow views in dst order (view i renders atlas layer i).
@(private)
pack_lights :: proc(lights, dst: []Light) -> (count: [LightType]u32, layers: u32) {
  for &l in lights do count[l.type] += 1
  first: [LightType]u32
  next: u32
  for type in LightType {
    first[type] = next
    next += count[type]
  }
  for &l in lights {
    dst[first[l.type]] = l
    first[l.type] += 1
  }
  for &l in dst[:len(lights)] {
    if l.shadow_map == NO_SHADOW do continue
    l.shadow_map = SHADOW_VIEW_BASE + layers
    layers += SHADOW_FACE_COUNT[l.type]
  }
  return
}

// Ambient light first, truncated to MAX_LIGHTS. Directional lights cast shadows only with a
// main camera to fit to. Caller holds the render mutex.
@(private)
collect_lights :: proc(self: ^Renderer, frame_index: u32) {
  lights: [MAX_LIGHTS]Light
  lights[0] = {type = .AMBIENT, color = {1, 1, 1, self.ambient.ibl_intensity}, shadow_map = NO_SHADOW}
  n := 1
  views := frame_table(self, .VIEWS, ViewGPU, frame_index)
  cameras := views[CAMERA_VIEW_BASE:][:self.camera_slots.high_water]
  casters: [MAX_LIGHTS]Caster
  caster_count := 0
  _, has_eye := main_camera(self)
  eye := &views[CAMERA_VIEW_BASE + u32(self.main_camera)]
  nodes := frame_table(self, .NODES, NodeData, frame_index)
  for &light, i in self.lights {
    if n == MAX_LIGHTS do break
    slot := self.light_slots[i]
    if .VISIBLE not_in nodes[slot].flags do continue
    lights[n] = place_light(light, nodes[slot].world_matrix)
    n += 1
    if !light.cast_shadow do continue
    if light.type == .DIRECTIONAL && !has_eye do continue
    // a spot light reuses the point light's sphere: loose but simple
    l := &lights[n - 1]
    bounds := [4]f32{l.position.x, l.position.y, l.position.z, l.radius}
    if l.type == .DIRECTIONAL do bounds.xyz = eye.position.xyz
    // -1: no camera sees the light
    score: f32 = -1
    for &v in cameras {
      if v.type_mask == 0 do continue
      if !geom.frustum_test_sphere({v.planes}, bounds.xyz, bounds.w) do continue
      score = max(score, shadow_score(bounds, light.color.a, v.position.xyz))
    }
    if score < 0 do continue
    casters[caster_count] = {light = n - 1, owner = u32(slot) + 1, score = score}
    caster_count += 1
  }
  slice.sort_by(casters[:caster_count], proc(a, b: Caster) -> bool {return a.score > b.score})
  maps := &self.shadow_casters
  selected := select_shadow_casters(casters[:caster_count], maps, self.gctx.frame_serial)
  // marks the light shadowed until pack_lights picks its layers
  for c in maps[:selected] do lights[c.light].shadow_map = 0
  dst := frame_table(self, .LIGHTS, Light, frame_index)
  self.light_count, self.shadow_view_count = pack_lights(lights[:n], dst)
  draws := &self.shadow_draws
  for &l in dst[:n] {
    if l.shadow_map == NO_SHADOW do continue
    for f in 0 ..< SHADOW_FACE_COUNT[l.type] {
      v := l.shadow_map + f
      view, projection := shadow_face_matrices(l, int(f), eye)
      view_projection := projection * view
      planes := geom.make_frustum(view_projection).planes
      // casters between a directional light and its cascade's box still
      // shadow it (the shadow pipeline clamps their depth)
      if l.type == .DIRECTIONAL do planes[4] = {0, 0, 0, 1}
      views[v] = {
        view            = view,
        projection      = projection,
        view_projection = view_projection,
        planes          = planes,
        type_mask       = GBUFFER_TYPES,
        require_flags   = SHADOW_CASTER_FLAGS,
        instance_tag    = v << 16,
        layer           = v - SHADOW_VIEW_BASE,
        draw_list       = draws.slot + frame_index,
        list_capacity   = draws.capacity,
      }
    }
  }
}

// Emitters take consecutive ranges of the frame's new particles, which take consecutive
// ring slots after the previous frame's.
@(private = "file")
flush_particles :: proc(self: ^Renderer) {
  emitters := write_table(self, .EMITTERS, Emitter)[:self.emitter_slots.high_water]
  p := &self.particle_params
  p.emit_cursor = (p.emit_cursor + p.emit_total) % MAX_PARTICLES
  total: u32
  for &em in emitters {
    emit: u32
    if em.enabled {
      em.emit_carry += em.emission_rate * self.particle_time
      emit = u32(em.emit_carry)
      em.emit_carry -= f32(emit)
    }
    em.emit_first = total
    total += emit
  }
  mark_dirty(self, .EMITTERS, Emitter, 0, len(emitters))
  // a ring slot takes at most one new particle per frame
  p.emit_total = min(total, MAX_PARTICLES)
  p.emitter_count = u32(len(emitters))
  p.forcefield_count = self.forcefield_slots.high_water
  p.delta_time = self.particle_time
  p.frame_counter += 1
  self.particle_time = 0
}

@(private = "file")
flush_cameras :: proc(self: ^Renderer, frame_index: u32) {
  views := frame_table(self, .VIEWS, ViewGPU, frame_index)
  // a slot without a camera keeps an empty view that draws no type
  next_frame_index := (frame_index + 1) % gpu.FRAMES_IN_FLIGHT
  slot_count := self.camera_slots.high_water
  slice.zero(views[CAMERA_VIEW_BASE:][:slot_count])
  all_types := u32(1 << len(MaterialType) - 1)
  c: u32
  for i in cont.slots_next(&self.camera_slots, &c) {
    cam := &self.cameras[i]
    occlusion_bind_pyramid(self, &cam.depth_pyramid[frame_index])
    view := camera_view_matrix(cam)
    projection := camera_projection_matrix(cam)
    view_projection := projection * view
    v := &views[CAMERA_VIEW_BASE + i]
    v^ = {
      view                = view,
      projection          = projection,
      view_projection     = view_projection,
      inv_view_projection = linalg.inverse(view_projection),
      planes              = geom.make_frustum(view_projection).planes,
      position            = {cam.position.x, cam.position.y, cam.position.z, 1},
      extent              = {f32(cam.extent[0]), f32(cam.extent[1])},
      near                = cam.near,
      far                 = cam.far,
      pyramid             = u32(cam.depth_pyramid[frame_index].texture),
      occlusion_mask      = GBUFFER_TYPES if self.gctx.frame_serial >= cam.ready_serial else 0,
      list_stride         = 1,
      type_mask           = all_types,
      require_flags       = {.VISIBLE},
      draw_list           = cam.draws.slot + next_frame_index,
      list_capacity       = cam.draws.capacity,
    }
    for a in AttachmentType do v.attachments[a] = u32(cam.attachments[a][frame_index])
  }
}

// Writes the render-generated tables. Once per frame under the render mutex, before record_frame.
@(private)
flush :: proc(self: ^Renderer, frame_index: u32) -> vk.Result {
  // before the lights: shadow casters are ranked by the camera views
  flush_cameras(self, frame_index)
  flush_particles(self)
  collect_lights(self, frame_index)
  shadow_atlas_reserve(self, frame_index, self.shadow_view_count) or_return
  // cull dispatches cover the slots up to the last one holding anything
  nodes := write_table(self, .NODES, NodeData)
  for n := len(self.attachments); n > 0 && self.attachments[n - 1] == nil && nodes[n - 1] == INVALID_NODE; n -= 1 {
    pop(&self.attachments)
  }
  flush_ui_atlas(self) or_return
  return .SUCCESS
}
