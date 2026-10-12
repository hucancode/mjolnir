package render

import "base:builtin"
import geom "../geometry"
import cont "../containers"
import ba "core:container/bit_array"
import "core:log"
import "gpu"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:sync"
import vk "vendor:vulkan"

// Default inner/outer cone ratio for spot lights. Inner cone is the angular
// region with full intensity; outer cone is the falloff edge.
SPOT_LIGHT_INNER_RATIO :: f32(0.75)

PointLightAttachment :: struct {
  color:       [4]f32, // RGB + intensity
  radius:      f32, // range
  cast_shadow: bool,
}

DirectionalLightAttachment :: struct {
  color:       [4]f32, // RGB + intensity
  radius:      f32, // shadow projection radius
  cast_shadow: bool,
}

SpotLightAttachment :: struct {
  color:       [4]f32, // RGB + intensity
  radius:      f32, // range
  angle_inner: f32, // inner cone angle
  angle_outer: f32, // outer cone angle
  cast_shadow: bool,
}

MeshAttachment :: struct {
  handle:      MeshHandle,
  material:    MaterialHandle,
  cast_shadow: bool,
}

EmitterAttachment :: struct {
  handle: EmitterHandle,
}

ForceFieldAttachment :: struct {
  handle: ForceFieldHandle,
}

Attachment :: union {
  PointLightAttachment,
  DirectionalLightAttachment,
  SpotLightAttachment,
  MeshAttachment,
  EmitterAttachment,
  ForceFieldAttachment,
}

// What render draws at one transform slot. The transform itself is owned by
// whoever drives the slot (normally the world module) and pushed in with
// stage_transforms.
@(private)
Instance :: struct {
  world_matrix: matrix[4, 4]f32,
  visible:      bool,
  attachment:   Attachment,
}

// A slot's skin palette: CPU copy plus its range in the per-frame bone
// buffers. `offset` is NO_BONES when the slab is full.
@(private)
BonePalette :: struct {
  offset:   u32,
  matrices: []matrix[4, 4]f32,
}

@(private)
NO_BONES :: 0xFFFFFFFF

// Dirty sets drained by flush, one bit per slot or pool index, sized to the
// slot and pool capacities so marking never allocates. Every marked entry is
// written from the current state of its slot or pool entry; a removed one is
// written empty. Nodes and bones live in per-frame buffers, so they have one
// set per frame in flight: staging marks all of them and each frame drains its
// own. Everything else is written once.
// Instance writes and their staging happen under `mutex` so flush on the
// render thread never sees a half-written slot.
@(private)
Staging :: struct {
  nodes:       [gpu.FRAMES_IN_FLIGHT]ba.Bit_Array,
  bones:       [gpu.FRAMES_IN_FLIGHT]ba.Bit_Array,
  meshes:      ba.Bit_Array,
  materials:   [gpu.FRAMES_IN_FLIGHT]ba.Bit_Array,
  forcefields: [gpu.FRAMES_IN_FLIGHT]ba.Bit_Array,
  // slots whose attachment is a light; not drained
  lights:      ba.Bit_Array,
  // simulation seconds advanced by update since the last frame
  particle_time: f32,
  mutex:       sync.Mutex,
}

@(private)
staging_init :: proc(s: ^Staging) {
  for f in 0 ..< gpu.FRAMES_IN_FLIGHT {
    ba.init(&s.nodes[f], MAX_NODES_IN_SCENE)
    ba.init(&s.bones[f], MAX_NODES_IN_SCENE)
    ba.init(&s.materials[f], MAX_MATERIALS)
    ba.init(&s.forcefields[f], MAX_FORCE_FIELDS)
  }
  ba.init(&s.meshes, MAX_MESHES)
  ba.init(&s.lights, MAX_NODES_IN_SCENE)
}

@(private)
staging_destroy :: proc(s: ^Staging) {
  for f in 0 ..< gpu.FRAMES_IN_FLIGHT {
    ba.destroy(&s.nodes[f])
    ba.destroy(&s.bones[f])
    ba.destroy(&s.materials[f])
    ba.destroy(&s.forcefields[f])
  }
  ba.destroy(&s.meshes)
  ba.destroy(&s.lights)
}

@(private)
stage :: proc(self: ^Manager, set: ^ba.Bit_Array, index: u32) {
  sync.mutex_lock(&self.internal.staging.mutex)
  ba.set(set, index)
  sync.mutex_unlock(&self.internal.staging.mutex)
}

// Mark `index` in every frame's set.
@(private)
stage_frames :: proc(self: ^Manager, sets: ^[gpu.FRAMES_IN_FLIGHT]ba.Bit_Array, index: u32) {
  sync.mutex_lock(&self.internal.staging.mutex)
  stage_per_frame(sets, index)
  sync.mutex_unlock(&self.internal.staging.mutex)
}

// Mark `index` in every frame's set. Caller holds the staging mutex.
@(private = "file")
stage_per_frame :: proc(sets: ^[gpu.FRAMES_IN_FLIGHT]ba.Bit_Array, index: u32, set_to := true) {
  for &s in sets do ba.set(&s, index, set_to)
}

@(private)
init_instances :: proc(self: ^Manager) {
  // Reserve the full slot range up front so growth never reallocates while
  // the render thread reads instances during flush.
  self.instances = make([dynamic]Instance, 0, MAX_NODES_IN_SCENE)
  staging_init(&self.internal.staging)
}

@(private)
ensure_slot :: proc(self: ^Manager, slot: u32) -> ^Instance {
  assert(slot < MAX_NODES_IN_SCENE, "slot exceeds MAX_NODES_IN_SCENE")
  if int(slot) >= len(self.instances) do builtin.resize(&self.instances, int(slot) + 1)
  return &self.instances[slot]
}

// A slot holding nothing: no attachment and never given a transform.
@(private = "file")
slot_empty :: proc(inst: ^Instance) -> bool {
  return inst.attachment == nil && inst.world_matrix == {} && !inst.visible
}

@(private)
is_light :: proc(a: Attachment) -> bool {
  #partial switch _ in a {
  case PointLightAttachment, DirectionalLightAttachment, SpotLightAttachment:
    return true
  }
  return false
}

// ---------- slot boundary: what the transform owner pushes in ----------

// Set the world transform and effective visibility of every slot in
// `changes`: any struct with `index` (the slot), `world_matrix` and `visible`
// fields, such as world.NodeChange.
stage_transforms :: proc(self: ^Manager, changes: []$T) {
  sync.mutex_lock(&self.internal.staging.mutex)
  defer sync.mutex_unlock(&self.internal.staging.mutex)
  for &c in changes {
    inst := ensure_slot(self, c.index)
    inst.world_matrix = c.world_matrix
    inst.visible = c.visible
    stage_per_frame(&self.internal.staging.nodes, c.index)
  }
}

// Forget everything drawn at a slot. Emitters and force fields owned
// by the attachment are destroyed; meshes and materials are shared and stay.
stage_slot_removal :: proc(self: ^Manager, slot: u32) {
  sync.mutex_lock(&self.internal.staging.mutex)
  defer sync.mutex_unlock(&self.internal.staging.mutex)
  remove_slot(self, slot)
}

// Remove every slot. Use when the transform owner resets all of its slots at
// once (level teardown).
clear_slots :: proc(self: ^Manager) {
  sync.mutex_lock(&self.internal.staging.mutex)
  defer sync.mutex_unlock(&self.internal.staging.mutex)
  for i := len(self.instances) - 1; i >= 0; i -= 1 do remove_slot(self, u32(i))
}

// Caller holds the staging mutex.
@(private = "file")
remove_slot :: proc(self: ^Manager, slot: u32) {
  if int(slot) >= len(self.instances) do return
  staging := &self.internal.staging
  inst := &self.instances[slot]
  #partial switch a in inst.attachment {
  case EmitterAttachment:
    cont.free_deferred(&self.emitters, a.handle)
  case ForceFieldAttachment:
    if cont.free_deferred(&self.forcefields, a.handle) do stage_per_frame(&staging.forcefields, a.handle.index)
  }
  inst^ = {}
  stage_per_frame(&staging.nodes, slot)
  ba.unset(&staging.lights, slot)
  release_bones(self, slot)
}

// Free a slot's skin palette and its bone buffer range. Caller holds the
// staging mutex.
@(private = "file")
release_bones :: proc(self: ^Manager, slot: u32) {
  p, ok := self.internal.bones[slot]
  if !ok do return
  if p.offset != NO_BONES do cont.slab_free(&self.internal.bone_matrix_slab, p.offset)
  delete(p.matrices)
  delete_key(&self.internal.bones, slot)
  stage_per_frame(&self.internal.staging.bones, slot, false)
}

// Skin palette (bone skinning matrices) for the skinned mesh at `slot`.
// The matrices are copied.
stage_bones :: proc(self: ^Manager, slot: u32, matrices: []matrix[4, 4]f32) {
  if len(matrices) == 0 do return
  sync.mutex_lock(&self.internal.staging.mutex)
  defer sync.mutex_unlock(&self.internal.staging.mutex)
  p := self.internal.bones[slot]
  if len(p.matrices) != len(matrices) {
    release_bones(self, slot)
    p.matrices = make([]matrix[4, 4]f32, len(matrices))
    p.offset = alloc_bones(self, u32(len(matrices)))
    self.internal.bones[slot] = p
    // node data carries the bone range offset; refresh it
    stage_per_frame(&self.internal.staging.nodes, slot)
  }
  copy(p.matrices, matrices)
  stage_per_frame(&self.internal.staging.bones, slot)
}

// A bone range of `count` matrices, growing the slab when it is full.
// NO_BONES when no size class fits `count` or the grown buffer would exceed
// the device's storage buffer range. Caller holds the staging mutex.
@(private = "file")
alloc_bones :: proc(self: ^Manager, count: u32) -> u32 {
  if offset, ok := cont.slab_alloc(&self.internal.bone_matrix_slab, count); ok do return offset
  if grow_bones(self) {
    if offset, ok := cont.slab_alloc(&self.internal.bone_matrix_slab, count); ok do return offset
  }
  log.warnf("No bone range for a %d-bone palette; the mesh draws unskinned", count)
  return NO_BONES
}

// Double every bone size class and re-place every palette in the new layout.
// Node data and bone buffers pick the new offsets up as each frame flushes;
// flush_bones resizes a frame's buffer before writing it. Caller holds the
// staging mutex.
@(private = "file")
grow_bones :: proc(self: ^Manager) -> bool {
  slab := &self.internal.bone_matrix_slab
  config: [cont.MAX_SLAB_CLASSES]struct {
    block_size, block_count: u32,
  }
  capacity: u64
  for c, i in slab.classes {
    config[i] = {c.block_size, c.block_count * 2}
    capacity += u64(c.block_size) * u64(c.block_count) * 2
  }
  limit := u64(self.gctx.device_properties.limits.maxStorageBufferRange)
  if capacity * size_of(matrix[4, 4]f32) > limit do return false
  cont.slab_destroy(slab)
  cont.slab_init(slab, config)
  for slot, &p in self.internal.bones {
    offset, ok := cont.slab_alloc(slab, u32(len(p.matrices)))
    p.offset = offset if ok else NO_BONES
    stage_per_frame(&self.internal.staging.nodes, slot)
    stage_per_frame(&self.internal.staging.bones, slot)
  }
  log.infof("Bone buffer grown to %d matrices", slab.capacity)
  return true
}

// ---------- attachments ----------

// Draw `attachment` at `slot`, replacing what the slot drew before. Emitters
// and force fields are bound to the slot's transform.
attach :: proc(self: ^Manager, slot: u32, attachment: Attachment) {
  sync.mutex_lock(&self.internal.staging.mutex)
  defer sync.mutex_unlock(&self.internal.staging.mutex)
  staging := &self.internal.staging
  inst := ensure_slot(self, slot)
  inst.attachment = attachment
  #partial switch a in attachment {
  case EmitterAttachment:
    if em, ok := cont.get(self.emitters, a.handle); ok do em.slot = slot
  case ForceFieldAttachment:
    if ff, ok := cont.get(self.forcefields, a.handle); ok {
      ff.slot = slot
      stage_per_frame(&staging.forcefields, a.handle.index)
    }
  }
  stage_per_frame(&staging.nodes, slot)
  ba.set(&staging.lights, slot, is_light(attachment))
}

// A copy of the attachment of type T at `slot`, e.g.
// attachment(r, slot, MeshAttachment). Edit it and pass it back to attach.
attachment :: proc(
  self: ^Manager,
  slot: u32,
  $T: typeid,
) -> (
  att: T,
  ok: bool,
) #optional_ok {
  sync.mutex_lock(&self.internal.staging.mutex)
  defer sync.mutex_unlock(&self.internal.staging.mutex)
  if int(slot) >= len(self.instances) do return
  return self.instances[slot].attachment.(T)
}

point_light_attachment :: proc(
  color: [4]f32 = {1, 1, 1, 1},
  radius: f32 = 10.0,
  cast_shadow: bool = true,
) -> PointLightAttachment {
  return {color = color, radius = radius, cast_shadow = cast_shadow}
}

directional_light_attachment :: proc(
  color: [4]f32 = {1, 1, 1, 1},
  radius: f32 = 10.0,
  cast_shadow: bool = false,
) -> DirectionalLightAttachment {
  return {color = color, radius = radius, cast_shadow = cast_shadow}
}

spot_light_attachment :: proc(
  color: [4]f32 = {1, 1, 1, 1},
  radius: f32 = 10.0,
  angle: f32 = math.PI * 0.2,
  cast_shadow: bool = true,
) -> SpotLightAttachment {
  return {
    color       = color,
    radius      = radius,
    angle_inner = angle * SPOT_LIGHT_INNER_RATIO,
    angle_outer = angle,
    cast_shadow = cast_shadow,
  }
}

// ---------- flush: drain staging into GPU buffers (render thread) ----------

@(private = "file")
INVALID_NODE :: NodeData {
  material_id           = 0xFFFFFFFF,
  mesh_id               = 0xFFFFFFFF,
  attachment_data_index = 0xFFFFFFFF,
}

@(private = "file")
flush_nodes :: proc(self: ^Manager, frame_index: u32) {
  nodes := frame_table(self, .NODES, NodeData, frame_index)
  staged := &self.internal.staging.nodes[frame_index]
  it := ba.make_iterator(staged)
  // Slots trimmed off the end are still cleared, in case the list grows back
  // over them.
  empty: Instance
  for slot in ba.iterate_by_set(&it) {
    inst := &self.instances[slot] if slot < len(self.instances) else &empty
    nd := INVALID_NODE
    nd.world_matrix = inst.world_matrix
    #partial switch att in inst.attachment {
    case MeshAttachment:
      if p, skinned := self.internal.bones[u32(slot)]; skinned {
        nd.attachment_data_index = p.offset
      }
      nd.material_id = att.material.index
      nd.mesh_id = att.handle.index
      if att.cast_shadow do nd.flags |= {.CASTS_SHADOW}
      if inst.visible do nd.flags |= {.VISIBLE}
    }
    nodes[slot] = nd
  }
  ba.clear(staged)
}

// Upload staged meshes. Destroyed meshes free their GPU allocations in
// mesh_retire, once no frame in flight can draw them.
@(private = "file")
flush_meshes :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  it := ba.make_iterator(&self.internal.staging.meshes)
  for index in ba.iterate_by_set(&it) {
    m := live_at(&self.meshes, index) or_continue
    g := m.cpu_geometry.? or_continue
    if res := upload_mesh(self, gctx, u32(index), m, g); res != .SUCCESS {
      log.errorf("Mesh %d upload failed: %v", index, res)
      continue
    }
    if m.auto_purge_cpu_geometry do mesh_release_memory(m)
  }
  ba.clear(&self.internal.staging.meshes)
}

// Live pool item at a staged slot index; staging is keyed by index alone.
@(private = "file")
live_at :: proc(pool: ^cont.Pool($T), index: int) -> (^T, bool) {
  if index >= len(pool.entries) do return nil, false
  e := &pool.entries[index]
  return &e.item, e.active
}

// Write every staged pool slot into its GPU buffer. Slots no longer live are
// zeroed so the GPU stops using them (a freed emitter stops emitting).
@(private = "file")
flush_pool :: proc(
  staged: ^ba.Bit_Array,
  pool: ^cont.Pool($T),
  table: []$G,
  to_gpu: proc(item: ^T) -> G,
) {
  it := ba.make_iterator(staged)
  for index in ba.iterate_by_set(&it) {
    data: G
    if item, live := live_at(pool, index); live do data = to_gpu(item)
    table[index] = data
  }
  ba.clear(staged)
}

@(private = "file")
material_gpu :: proc(m: ^Material) -> MaterialData {
  return {
    albedo_index = texture_index(m.albedo),
    metallic_roughness_index = texture_index(m.metallic_roughness),
    normal_index = texture_index(m.normal),
    emissive_index = texture_index(m.emissive),
    metallic_value = m.metallic_value,
    roughness_value = m.roughness_value,
    emissive_value = m.emissive_value,
    base_color_factor = m.base_color_factor,
    frame_columns = m.frame_columns,
    frame_rows = m.frame_rows,
    frame_index = m.frame_index,
    type = m.type,
  }
}

@(private = "file")
emitter_gpu :: proc(em: ^Emitter, emit_first: u32) -> EmitterData {
  return {
    initial_velocity = em.initial_velocity,
    size_start = em.size_start,
    color_start = em.color_start,
    color_end = em.color_end,
    particle_lifetime = em.particle_lifetime,
    position_spread = em.position_spread,
    velocity_spread = em.velocity_spread,
    emit_first = emit_first,
    size_end = em.size_end,
    weight = em.weight,
    weight_spread = em.weight_spread,
    texture_index = em.texture_handle.index,
    node_index = em.slot,
  }
}

// Hand the emissions and simulation time accumulated by update to this
// frame. Every emitter is written: the buffer is per frame and emit counts
// change every frame. Emitters take consecutive ranges of the frame's new
// particles, which take consecutive ring slots after the previous frame's.
@(private = "file")
flush_particles :: proc(self: ^Manager, frame_index: u32) {
  emitters := frame_table(self, .EMITTERS, EmitterData, frame_index)
  emitter_count := min(len(self.emitters.entries), MAX_EMITTERS)
  p := &self.internal.particles.params
  p.emit_cursor = (p.emit_cursor + p.emit_total) % MAX_PARTICLES
  total: u32
  for index in 0 ..< emitter_count {
    data := EmitterData {
      emit_first = total,
    }
    if em, live := live_at(&self.emitters, index); live {
      data = emitter_gpu(em, total)
      total += em.pending_emit
      em.pending_emit = 0
    }
    emitters[index] = data
  }
  // A ring slot takes at most one new particle per frame.
  p.emit_total = min(total, MAX_PARTICLES)
  p.emitter_count = u32(emitter_count)
  p.forcefield_count = u32(min(len(self.forcefields.entries), MAX_FORCE_FIELDS))
  p.delta_time = self.internal.staging.particle_time
  p.frame_counter += 1
  self.internal.staging.particle_time = 0
}

@(private = "file")
forcefield_gpu :: proc(ff: ^ForceField) -> ForceFieldData {
  return {
    tangent_strength = ff.tangent_strength if ff.enabled else 0,
    strength = ff.strength if ff.enabled else 0,
    area_of_effect = ff.area_of_effect,
    node_index = ff.slot,
  }
}

@(private = "file")
flush_bones :: proc(self: ^Manager, frame_index: u32) -> vk.Result {
  // wait_frame has returned, so this frame's arena is free to replace.
  capacity := int(self.internal.bone_matrix_slab.capacity)
  if len(frame_table(self, .BONES, matrix[4, 4]f32, frame_index)) < capacity {
    grow_frame_arena(self, frame_index, capacity) or_return
  }
  bones := frame_table(self, .BONES, matrix[4, 4]f32, frame_index)
  staged := &self.internal.staging.bones[frame_index]
  it := ba.make_iterator(staged)
  for slot in ba.iterate_by_set(&it) {
    p := self.internal.bones[u32(slot)] or_continue
    if p.offset != NO_BONES do copy(bones[p.offset:][:len(p.matrices)], p.matrices)
  }
  ba.clear(staged)
  return .SUCCESS
}

@(private = "file")
flush_cameras :: proc(self: ^Manager, frame_index: u32) {
  cameras := frame_table(self, .CAMERAS, CameraGPU, frame_index)
  views := frame_table(self, .VIEWS, ViewGPU, frame_index)
  // This frame's cull writes the lists of the next frame. A slot without a
  // camera keeps an empty view that draws no type.
  next_frame_index := (frame_index + 1) % gpu.FRAMES_IN_FLIGHT
  slot_count := len(self.cameras.entries)
  slice.zero(views[CAMERA_VIEW_BASE:][:slot_count])
  all_types := u32(1 << len(MaterialType) - 1)
  occlusion_mask, _ := material_masks()
  it := cont.iterator(&self.cameras)
  for cam, handle in cont.next(&it, CameraHandle) {
    occlusion_bind_pyramid(&self.gctx, &cam.depth_pyramid[frame_index], &self.texture_manager)
    data := CameraGPU {
      view            = camera_view_matrix(cam),
      projection      = camera_projection_matrix(cam),
      viewport_extent = {f32(cam.extent[0]), f32(cam.extent[1])},
      near            = cam.near,
      far             = cam.far,
      position        = {cam.position.x, cam.position.y, cam.position.z, 1},
    }
    view_projection := data.projection * data.view
    data.inv_view_projection = linalg.inverse(view_projection)
    cameras[handle.index] = data
    pyramid := cam.depth_pyramid[frame_index].texture
    views[CAMERA_VIEW_BASE + handle.index] = {
      planes          = geom.make_frustum(view_projection).planes,
      view_projection = view_projection,
      camera_index    = handle.index,
      pyramid         = pyramid.index,
      occlusion_mask  = occlusion_mask if self.gctx.frame_serial >= cam.ready_serial else 0,
      list_stride     = 1,
      type_mask       = all_types,
      require_flags   = {.VISIBLE},
      draw_list       = cam.draws.slot + next_frame_index,
      list_capacity   = cam.draws.capacity,
    }
  }
}

// Drain staged scene changes into GPU buffers for `frame_index`. Call once per
// frame on the render thread before record_frame.
@(private)
flush :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
  frame_index: u32,
) -> vk.Result {
  {
    sync.mutex_lock(&self.internal.staging.mutex)
    defer sync.mutex_unlock(&self.internal.staging.mutex)
    staging := &self.internal.staging
    flush_nodes(self, frame_index)
    flush_meshes(self, gctx)
    flush_bones(self, frame_index) or_return
    flush_pool(&staging.materials[frame_index], &self.materials, frame_table(self, .MATERIALS, MaterialData, frame_index), material_gpu)
    flush_particles(self, frame_index)
    flush_pool(&staging.forcefields[frame_index], &self.forcefields, frame_table(self, .FORCEFIELDS, ForceFieldData, frame_index), forcefield_gpu)
    collect_lights(self, gctx)
    upload_lights(self, frame_index)
    shadow_atlas_reserve(self, frame_index, self.internal.shadow_view_count) or_return
    // Culling dispatches cover the slots up to the last occupied one.
    for n := len(self.instances); n > 0 && slot_empty(&self.instances[n - 1]); n -= 1 {
      pop(&self.instances)
    }
    self.node_count = min(u32(len(self.instances)), MAX_NODES_IN_SCENE)
  }
  flush_cameras(self, frame_index)
  flush_ui_atlas(self, gctx) or_return
  return .SUCCESS
}
