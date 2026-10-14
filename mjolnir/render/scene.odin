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

// Renderer is the whole renderer. Public fields: builtin_meshes, builtin_materials,
// main_camera, ibl_intensity, skybox_intensity, skybox_blur and effect_stack; the rest is
// internal state. init/shutdown own the device and every resource (application lifetime);
// setup/teardown reset map state between maps.
Renderer :: struct {
  gctx:                    gpu.GPUContext,
  swapchain:               gpu.Swapchain,
  mesh_slots:              cont.Slots,
  material_slots:          cont.Slots,
  emitter_slots:           cont.Slots,
  forcefield_slots:        cont.Slots,
  // slots up to this one are covered by every cull dispatch
  node_count:              u32,
  // each light and the slot it shines from (bound_at)
  lights:                  []struct {
    node_index: u32,
    light:      Light,
  },
  light_slots:             cont.Slots,
  builtin_materials:       [Color]MaterialHandle,
  builtin_meshes:          [Primitive]MeshHandle,
  cameras:                 []Camera,
  camera_slots:            cont.Slots,
  main_camera:             CameraHandle,
  // the environment light, drawn as the AMBIENT light (pass_ambient.odin)
  environment_map:         TextureHandle,
  brdf_lut:                TextureHandle,
  // precomputed from environment_map
  irradiance_cube:         TextureHandle,
  prefilter_cube:          TextureHandle,
  // scales image-based lighting
  ibl_intensity:           f32,
  // 0 hides the skybox
  skybox_intensity:        f32,
  skybox_blur:             f32,
  // every camera runs the stack in order (pass_post_process.odin)
  effect_stack:            [dynamic]PostprocessEffect,
  // [is_last][tag]: every pass writes an HDR ring image but the last, which writes the
  // swapchain format
  post_process_pipelines:  [2][len(EFFECTS)]vk.Pipeline,
  // pass i writes slot i % POST_PROCESS_RING; its input and original are the two slots before
  post_process_images:     [gpu.FRAMES_IN_FLIGHT][POST_PROCESS_RING]TextureHandle,
  command_buffers:         [gpu.FRAMES_IN_FLIGHT]vk.CommandBuffer,
  compute_command_buffers: [gpu.FRAMES_IN_FLIGHT]vk.CommandBuffer,
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
  arena_offset:            [SceneBinding]vk.DeviceSize,
  region_debt:             RegionDebt,
  draw_count_readback:     [gpu.FRAMES_IN_FLIGHT]gpu.Buffer,
  bone_matrix_slab:        cont.SlabAllocator,
  // per pyramid slot: groups done this dispatch; the last one resets it
  pyramid_counters:        gpu.Buffer,
  // alive list: an indirect draw header followed by one particle index per vertex
  particle_buffer:         gpu.Buffer,
  particle_alive_buffer:   gpu.Buffer,
  particle_params:         ParticleSystemParams,
  // simulated seconds; an emitter emits floor(rate * time) particles in total
  particle_time:           f64,
  // segments added since the last frame, per ring: [0] depth-tested, [1] drawn over the scene
  debug_lines:             [2][dynamic]DebugLineSegment,
  // segments each ring has taken in total (pass_debug_line.odin)
  debug_filled:            [2]u64,
  debug_time:              f32,
  debug_mutex:             sync.Mutex,
  ui:                      OverlayRenderer,
  light_count:             [LightType]u32,
  shadow_casters:          [MAX_SHADOW_MAPS]Caster,
  // one per atlas layer in use (pack_lights)
  shadow_view_count:       u32,
  shadow_atlas:            [gpu.FRAMES_IN_FLIGHT]gpu.Image,
  // indirect draw lists per bindless draw-list slot (pass_occlusion_culling.odin)
  draw_lists:              [MAX_DRAW_LIST_SLOTS]gpu.Buffer,
  // per pyramid slot: the depth pyramid, its storage view per mip and whether they are in the
  // storage image array yet
  pyramids:                [MAX_PYRAMID_SLOTS]TextureHandle,
  pyramid_views:           [MAX_PYRAMID_SLOTS][MAX_DEPTH_MIPS_LEVEL]vk.ImageView,
  pyramid_bound:           [MAX_PYRAMID_SLOTS]bool,
  mutex:                   sync.Recursive_Mutex,
}

// Creates a window surface for `instance`; `user` is passed through from init.
SurfaceProc :: #type proc(user: rawptr, instance: vk.Instance) -> (vk.SurfaceKHR, vk.Result)

// Bring the renderer up on a window: instance, surface (through
// `create_surface(surface_user, instance)`), device, swapchain, every
// resource and an empty scene with a main camera. Paired with shutdown.
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
  // retired, not reclaimed: submitted frames may still sample the slot
  cont.slots_init(&self.texture_slots, MAX_TEXTURES, gpu.RETIRE_GRACE)
  // Attachments have no handle to go stale and each frame reads its own copy of the
  // table, so no grace. Index 0 is never handed out and the ambient light takes it, so
  // every light fits the frame's table.
  cont.slots_init(&self.emitter_slots, MAX_EMITTERS)
  cont.slots_init(&self.forcefield_slots, MAX_FORCE_FIELDS)
  cont.slots_init(&self.light_slots, MAX_LIGHTS)
  self.lights = make(type_of(self.lights), MAX_LIGHTS)
  self.cameras = make([]Camera, MAX_ACTIVE_CAMERAS)
  self.textures = make([]gpu.Image, MAX_TEXTURES)
  gpu.allocate_command_buffer(gctx, self.command_buffers[:]) or_return
  gpu.allocate_command_buffer(gctx, self.compute_command_buffers[:], gctx.compute_command_pool) or_return
  mesh_arena_init(self) or_return
  init_scene_buffers(self, gctx) or_return
  init_builtin_materials(self)
  init_builtin_meshes(self)
  bindless_init(self) or_return
  scene_descriptors_init(self) or_return
  ambient_init(self) or_return
  occlusion_init(self) or_return
  shadow_init(self) or_return
  direct_light_init(self) or_return
  material_pipelines_init(self) or_return
  particles_init(self) or_return
  post_process_init(self) or_return
  debug_line_init(self) or_return
  overlay_init(self, dpi_scale) or_return
  extent := self.swapchain.extent
  cam, created := create_camera(self, extent.width, extent.height, position = {3, 4, 3}, far_plane = 1000.0)
  if !created do return .ERROR_INITIALIZATION_FAILED
  self.main_camera = cam
  return .SUCCESS
}

// setup starts a map: no particle is alive. init/shutdown own every resource;
// setup/teardown only reset map state, so meshes, materials, textures and
// cameras outlive them.
setup :: proc(self: ^Renderer) -> bool {
  guard(self)
  res := particles_reset(self)
  if res != .SUCCESS do log.errorf("Renderer map setup failed: %v", res)
  return res == .SUCCESS
}

// teardown ends a map: every slot forgets its attachment and bone palette.
teardown :: proc(self: ^Renderer) {
  clear_slots(self)
}

// Replace the environment map with the equirectangular HDR image at `path`
// and precompute image-based lighting from it. Without one, IBL and the
// skybox are black.
load_environment_map :: proc(self: ^Renderer, path: string) -> bool {
  res := ambient_load_environment(self, path)
  if res != .SUCCESS do log.warnf("Failed to load environment map %s: %v", path, res)
  return res == .SUCCESS
}

// Destroy everything init created.
shutdown :: proc(self: ^Renderer) {
  gctx := &self.gctx
  vk.DeviceWaitIdle(gctx.device)
  c: u32
  for i in cont.slots_next(&self.camera_slots, &c) do destroy_camera(self, CameraHandle(i))
  draw_lists_destroy(self, SHADOW_DRAW_SLOT_BASE)
  for r in cont.slots_flush(&self.texture_slots) do gpu.image_destroy(gctx.device, &self.textures[r.index])
  c = 0
  for i in cont.slots_next(&self.texture_slots, &c) do gpu.image_destroy(gctx.device, &self.textures[i])
  gpu.deferred_flush(gctx)
  overlay_shutdown(self)
  for p in self.pipelines do vk.DestroyPipeline(gctx.device, p, nil)
  for p in self.material_pipelines do vk.DestroyPipeline(gctx.device, p, nil)
  for p in self.light_pipelines do vk.DestroyPipeline(gctx.device, p, nil)
  for pipelines in self.post_process_pipelines do for p in pipelines do vk.DestroyPipeline(gctx.device, p, nil)
  delete(self.effect_stack)
  for inbox in self.debug_lines do delete(inbox)
  scene_descriptors_shutdown(&self.scene, gctx)
  bindless_shutdown(self)
  destroy_scene_buffers(self, gctx)
  mesh_arena_destroy(self)
  cont.slots_destroy(&self.camera_slots)
  cont.slots_destroy(&self.mesh_slots)
  cont.slots_destroy(&self.material_slots)
  cont.slots_destroy(&self.emitter_slots)
  cont.slots_destroy(&self.forcefield_slots)
  cont.slots_destroy(&self.light_slots)
  cont.slots_destroy(&self.texture_slots)
  delete(self.cameras)
  delete(self.lights)
  delete(self.textures)
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
  post_process_create_images(self) or_return
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
  for b in BINDINGS do add(&sizes, b.type, gpu.FRAMES_IN_FLIGHT)
  for b in BINDLESS_BINDINGS do add(&sizes, b.type, b.count)
  return gpu.descriptor_pool_init(gctx, sizes[:], gpu.FRAMES_IN_FLIGHT + 1)
}

// lock holds off frame while another thread edits through the pointers material,
// emitter and forcefield return; stage_*, create_* and destroy_* lock themselves.
lock :: proc(self: ^Renderer) {
  sync.recursive_mutex_lock(&self.mutex)
}

// unlock releases the lock taken by lock.
unlock :: proc(self: ^Renderer) {
  sync.recursive_mutex_unlock(&self.mutex)
}

// guard holds the lock until the end of the calling scope.
@(private, deferred_in = unlock)
guard :: proc(self: ^Renderer) {
  lock(self)
}

// The only place retirement advances; once per frame, so ticks follow frame_serial.
@(private)
tick_resource_pools :: proc(self: ^Renderer) {
  gpu.deferred_tick(&self.gctx)
  for r in cont.slots_tick(&self.texture_slots) do gpu.image_destroy(self.gctx.device, &self.textures[r.index])
  for r in cont.slots_tick(&self.mesh_slots) {
    free_mesh(self, write_table(self, .MESHES, MeshData)[r.index])
    clear_entry(self, .MESHES, r.index)
  }
  cont.slots_tick(&self.material_slots)
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
  guard(self)
  // flush_particles emits for it; particles_simulate consumes it
  self.particle_params.delta_time += delta_time
}

@(private)
NodeFlag :: enum u32 {
  VISIBLE,
  CASTS_SHADOW,
  // attachment_data_index holds a bone range; only set while the mesh is skinned, so the
  // shaders skin by this flag alone
  SKINNED,
}

@(private)
NodeFlagSet :: bit_set[NodeFlag;u32]

// The zero record is an empty slot: mesh and material 0 are none. attachment_data_index is
// the first entry of the slot's bone table range when .SKINNED is set.
@(private)
NodeData :: struct #packed {
  world_matrix:          matrix[4, 4]f32,
  material_id:           u32,
  mesh_id:               u32,
  attachment_data_index: u32,
  flags:                 NodeFlagSet,
}

// MeshAttachment draws mesh handle with material from a slot's transform.
MeshAttachment :: struct {
  handle:      MeshHandle,
  material:    MaterialHandle,
  cast_shadow: bool,
}

// What a slot draws. A Light shines from the slot's transform; an Emitter spawns
// particles from it and a ForceField is centered on it.
Attachment :: union {
  Light,
  MeshAttachment,
  Emitter,
  ForceField,
}

// Grows the slot range to cover `slot`; slots past it are already empty (zero). Caller
// holds the render mutex and marks what it changes.
@(private)
slot_node :: proc(self: ^Renderer, slot: u32) -> ^NodeData {
  assert(slot < MAX_NODES_IN_SCENE, "slot exceeds MAX_NODES_IN_SCENE")
  self.node_count = max(self.node_count, slot + 1)
  return &write_table(self, .NODES, NodeData)[slot]
}

// stage_transforms applies a change feed: sets each slot's world matrix and visibility,
// and forgets slots marked removed. `changes` is any struct with `index`, `world_matrix`,
// `visible` and `removed` fields (world.NodeChange), removals first.
stage_transforms :: proc(self: ^Renderer, changes: []$T) {
  guard(self)
  for &c in changes {
    if c.removed {
      stage_slot_removal(self, c.index)
      continue
    }
    node := slot_node(self, c.index)
    node.world_matrix = c.world_matrix
    if c.visible do node.flags += {.VISIBLE}
    else do node.flags -= {.VISIBLE}
    mark_dirty(self, .NODES, int(c.index))
  }
}

// Lights, emitters and force fields are tables of entries bound to a slot by node_index,
// at most one entry per slot. The live entry of `table` bound to `slot`.
@(private = "file")
bound_at :: proc(slots: ^cont.Slots, table: []$T, slot: u32) -> (index: u32, ok: bool) {
  c: u32
  for i in cont.slots_next(slots, &c) do if table[i].node_index == slot do return i, true
  return
}

// Takes a free entry of `table` for `entry`, bound to `slot`.
@(private = "file")
bind :: proc(slots: ^cont.Slots, table: []$T, slot: u32, entry: T) -> (index: u32, ok: bool) {
  index = cont.slots_alloc(slots) or_return
  table[index] = entry
  table[index].node_index = slot
  return index, true
}

// Drops the slot's light, emitter and force field. Caller holds the render mutex.
@(private = "file")
unbind :: proc(self: ^Renderer, slot: u32) {
  if i, ok := bound_at(&self.light_slots, self.lights, slot); ok do cont.slots_free(&self.light_slots, i)
  if i, ok := bound_at(&self.emitter_slots, write_table(self, .EMITTERS, Emitter), slot); ok {
    cont.slots_free(&self.emitter_slots, i)
    clear_entry(self, .EMITTERS, i)
  }
  if i, ok := bound_at(&self.forcefield_slots, write_table(self, .FORCEFIELDS, ForceField), slot); ok {
    cont.slots_free(&self.forcefield_slots, i)
    clear_entry(self, .FORCEFIELDS, i)
  }
}

// Forget everything drawn at a slot; meshes and materials are shared and stay.
@(private)
stage_slot_removal :: proc(self: ^Renderer, slot: u32) {
  guard(self)
  unbind(self, slot)
  if slot >= self.node_count do return
  release_bones(self, slot)
  write_table(self, .NODES, NodeData)[slot] = {}
  mark_dirty(self, .NODES, int(slot))
}

// Every slot at once: what stage_slot_removal does per slot, in one pass per table.
@(private = "file")
clear_slots :: proc(self: ^Renderer) {
  guard(self)
  slice.zero(write_table(self, .NODES, NodeData)[:self.node_count])
  mark_dirty(self, .NODES, 0, int(self.node_count))
  self.node_count = 0
  cont.slab_reset(&self.bone_matrix_slab)
  c: u32
  for i in cont.slots_next(&self.light_slots, &c) do cont.slots_free(&self.light_slots, i)
  c = 0
  for i in cont.slots_next(&self.emitter_slots, &c) {
    cont.slots_free(&self.emitter_slots, i)
    clear_entry(self, .EMITTERS, i)
  }
  c = 0
  for i in cont.slots_next(&self.forcefield_slots, &c) {
    cont.slots_free(&self.forcefield_slots, i)
    clear_entry(self, .FORCEFIELDS, i)
  }
}

// whether mesh_id carries skinning data, so a bone palette may deform it
@(private = "file")
skinned_mesh :: proc(self: ^Renderer, mesh_id: u32) -> bool {
  return .SKINNED in write_table(self, .MESHES, MeshData)[mesh_id].flags
}

// caller holds the render mutex
@(private = "file")
release_bones :: proc(self: ^Renderer, slot: u32) {
  node := &write_table(self, .NODES, NodeData)[slot]
  if .SKINNED not_in node.flags do return
  cont.slab_free(&self.bone_matrix_slab, node.attachment_data_index)
  node.attachment_data_index = 0
  node.flags -= {.SKINNED}
  mark_dirty(self, .NODES, int(slot))
}

// Skin palette (bone skinning matrices) for the skinned mesh at `slot`, attached first.
// The matrices are copied.
stage_bones :: proc(self: ^Renderer, slot: u32, matrices: []matrix[4, 4]f32) {
  count := u32(len(matrices))
  if count == 0 do return
  guard(self)
  node := slot_node(self, slot)
  if !skinned_mesh(self, node.mesh_id) {
    log.warnf("Slot %d has no skinned mesh; its bone palette is dropped", slot)
    return
  }
  if .SKINNED not_in node.flags || cont.slab_block_size(&self.bone_matrix_slab, node.attachment_data_index) < count {
    release_bones(self, slot)
    offset, ok := cont.slab_alloc(&self.bone_matrix_slab, count)
    if !ok {
      log.warnf("No bone range for a %d-bone palette; the mesh draws unskinned", count)
      return
    }
    node.attachment_data_index = offset
    node.flags += {.SKINNED}
    mark_dirty(self, .NODES, int(slot))
  }
  offset := node.attachment_data_index
  copy(write_table(self, .BONES, matrix[4, 4]f32)[offset:][:count], matrices)
  mark_dirty(self, .BONES, int(offset), int(count))
}

// attach draws attachment at slot, replacing what the slot drew before. A bone palette
// stays while the slot draws a skinned mesh.
attach :: proc(self: ^Renderer, slot: u32, attachment: Attachment) {
  guard(self)
  node := slot_node(self, slot)
  unbind(self, slot)
  node.mesh_id, node.material_id = 0, 0
  node.flags -= {.CASTS_SHADOW}
  switch a in attachment {
  case MeshAttachment:
    node.mesh_id, node.material_id = u32(a.handle), u32(a.material)
    if a.cast_shadow do node.flags += {.CASTS_SHADOW}
  case Light:
    if i, ok := cont.slots_alloc(&self.light_slots); ok do self.lights[i] = {slot, a}
    else do log.warnf("No room for more than %d lights; the light is dropped", MAX_LIGHTS - 1)
  case Emitter:
    if i, ok := bind(&self.emitter_slots, write_table(self, .EMITTERS, Emitter), slot, a); ok do mark_dirty(self, .EMITTERS, int(i))
    else do log.warnf("No room for more than %d emitters; the emitter is dropped", MAX_EMITTERS - 1)
  case ForceField:
    if i, ok := bind(&self.forcefield_slots, write_table(self, .FORCEFIELDS, ForceField), slot, a); ok do mark_dirty(self, .FORCEFIELDS, int(i))
    else do log.warnf("No room for more than %d force fields; the force field is dropped", MAX_FORCE_FIELDS - 1)
  }
  if !skinned_mesh(self, node.mesh_id) do release_bones(self, slot)
  mark_dirty(self, .NODES, int(slot))
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
  guard(self)
  when T == MeshAttachment {
    if slot >= self.node_count do return
    node := write_table(self, .NODES, NodeData)[slot]
    if node.mesh_id == 0 do return
    return {MeshHandle(node.mesh_id), MaterialHandle(node.material_id), .CASTS_SHADOW in node.flags}, true
  } else when T == Light {
    i := bound_at(&self.light_slots, self.lights, slot) or_return
    return self.lights[i].light, true
  } else when T == Emitter {
    emitters := write_table(self, .EMITTERS, Emitter)
    return emitters[bound_at(&self.emitter_slots, emitters, slot) or_return], true
  } else when T == ForceField {
    forcefields := write_table(self, .FORCEFIELDS, ForceField)
    return forcefields[bound_at(&self.forcefield_slots, forcefields, slot) or_return], true
  }
  return
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
  // view table index of the shadow map's first face, 0 when the light got none this frame
  shadow_map:         u32,
  // world size of a shadow texel per unit of view depth, for point and spot
  shadow_texel:       f32,
  // the shaders' last u32, which they don't read
  type:               LightType,
  // the light competes for a shadow map; shadow_map tells whether it got one
  should_cast_shadow: b16,
}
#assert(size_of(Light) == 64)

// point_light_attachment returns an omnidirectional Light for attach.
point_light_attachment :: proc(
  color: [4]f32 = {1, 1, 1, 1},
  radius: f32 = 10.0,
  cast_shadow: bool = true,
) -> Light {
  return {type = .POINT, color = color, radius = radius, should_cast_shadow = b16(cast_shadow)}
}

// directional_light_attachment returns a sun-like Light for attach; shadow_radius is its shadow distance.
directional_light_attachment :: proc(
  color: [4]f32 = {1, 1, 1, 1},
  shadow_radius: f32 = 10.0,
  cast_shadow: bool = false,
) -> Light {
  return {type = .DIRECTIONAL, color = color, radius = shadow_radius, should_cast_shadow = b16(cast_shadow)}
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
    should_cast_shadow = b16(cast_shadow),
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
  // set by collect_lights for the lights picked to cast this frame
  l.shadow_map = 0
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
// then the lights picked to cast (any nonzero shadow_map) get consecutive shadow views in
// dst order (view i renders atlas layer i).
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
    if l.shadow_map == 0 do continue
    l.shadow_map = SHADOW_VIEW_BASE + layers
    layers += SHADOW_FACE_COUNT[l.type]
  }
  return
}

// Ambient light first, then the attached lights (light_slots leaves index 0 for it).
// Directional lights cast shadows only with a main camera to fit to. Caller holds the
// render mutex.
@(private)
collect_lights :: proc(self: ^Renderer, frame_index: u32) {
  lights: [MAX_LIGHTS]Light
  lights[0] = {type = .AMBIENT, color = {1, 1, 1, self.ibl_intensity}}
  n := 1
  views := frame_table(self, .VIEWS, ViewGPU, frame_index)
  cameras := views[CAMERA_VIEW_BASE:][:self.camera_slots.high_water]
  casters: [MAX_LIGHTS]Caster
  caster_count := 0
  _, has_eye := main_camera(self)
  eye := &views[CAMERA_VIEW_BASE + u32(self.main_camera)]
  nodes := frame_table(self, .NODES, NodeData, frame_index)
  cursor: u32
  for i in cont.slots_next(&self.light_slots, &cursor) {
    slot, light := self.lights[i].node_index, self.lights[i].light
    if .VISIBLE not_in nodes[slot].flags do continue
    lights[n] = place_light(light, nodes[slot].world_matrix)
    n += 1
    if !light.should_cast_shadow do continue
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
  // any nonzero view marks the pick; pack_lights assigns the real one
  for c in maps[:selected] do lights[c.light].shadow_map = 1
  dst := frame_table(self, .LIGHTS, Light, frame_index)
  self.light_count, self.shadow_view_count = pack_lights(lights[:n], dst)
  for &l in dst[:n] {
    if l.shadow_map == 0 do continue
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
        draw_list       = SHADOW_DRAW_SLOT_BASE + frame_index,
        list_capacity   = SHADOW_LIST_CAPACITY,
      }
    }
  }
}

// Emitters take consecutive ranges of the frame's new particles, which take consecutive
// ring slots after the previous frame's. An emitter emits what floor(rate * particle_time)
// grew by, so it carries no fraction from frame to frame.
@(private = "file")
flush_particles :: proc(self: ^Renderer) {
  emitters := write_table(self, .EMITTERS, Emitter)[:self.emitter_slots.high_water]
  p := &self.particle_params
  p.emit_cursor = (p.emit_cursor + p.emit_total) % MAX_PARTICLES
  t0 := self.particle_time
  t1 := t0 + f64(p.delta_time)
  self.particle_time = t1
  total: u32
  for &em in emitters {
    emit: u32
    if em.enabled {
      rate := f64(max(em.emission_rate, 0))
      emit = u32(u64(rate * t1) - u64(rate * t0))
    }
    em.emit_first = total
    total += emit
  }
  mark_dirty(self, .EMITTERS, 0, len(emitters))
  // a ring slot takes at most one new particle per frame
  p.emit_total = min(total, MAX_PARTICLES)
  p.emitter_count = u32(len(emitters))
  p.forcefield_count = self.forcefield_slots.high_water
  p.frame_counter += 1
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
    occlusion_bind_pyramid(self, camera_slot(i) + frame_index)
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
      pyramid             = u32(self.pyramids[camera_slot(i) + frame_index]),
      occlusion_mask      = GBUFFER_TYPES if self.gctx.frame_serial >= cam.ready_serial else 0,
      list_stride         = 1,
      type_mask           = all_types,
      require_flags       = {.VISIBLE},
      draw_list           = CAMERA_DRAW_SLOT_BASE + camera_slot(i) + next_frame_index,
      list_capacity       = CAMERA_LIST_CAPACITY,
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
  flush_debug_lines(self)
  shadow_atlas_reserve(self, frame_index, self.shadow_view_count) or_return
  // cull dispatches cover the slots up to the last one holding anything
  nodes := write_table(self, .NODES, NodeData)
  for self.node_count > 0 && nodes[self.node_count - 1] == {} do self.node_count -= 1
  return .SUCCESS
}
