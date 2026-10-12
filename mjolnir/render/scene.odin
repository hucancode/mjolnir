package render

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

// Selects the light branch of the lighting shaders (specialization constant 0).
// AMBIENT is the environment light: image-based lighting, emissive and the
// skybox, one per frame.
LightType :: enum u16 {
  POINT,
  SPOT,
  DIRECTIONAL,
  AMBIENT,
}

// A light, stored as the lighting shaders read it from the light buffer.
// Attached to a slot it shines from the slot's transform along its forward
// axis: render fills position, direction, shadow_map and shadow_texel each
// frame. Point lights ignore direction and angles; directional lights shade
// with neither position, radius nor angles, which place and size their
// shadow map. AMBIENT is the environment light render adds itself.
Light :: struct {
  color:        [4]f32, // RGB + intensity
  position:     [3]f32,
  // range of a point or spot light; half extent of a directional light's
  // shadow box centered on the light
  radius:       f32,
  direction:    [3]f32, // normalized
  angle_inner:  f32, // spot cone angles
  angle_outer:  f32,
  // view table index of the shadow map's first face, NO_SHADOW without one
  shadow_map:   u32,
  // world size of a shadow texel; per unit of view depth for point and spot
  shadow_texel: f32,
  // the shaders' last u32, which they don't read
  type:         LightType,
  cast_shadow:  b16,
}
#assert(size_of(Light) == 64)

// shadow_map value for a light without a shadow map.
NO_SHADOW :: 0xFFFFFFFF

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

// A slot's skin palette: `count` matrices from `offset` of the bone table.
// `offset` is NO_BONES when the slab is full.
@(private)
BonePalette :: struct {
  offset: u32,
  count:  u32,
}

@(private)
NO_BONES :: 0xFFFFFFFF

// Hold off the render thread's frame while editing scene data through the
// pointers material, emitter and forcefield return. Only needed when another
// thread than the one calling frame edits; the stage_*, create_* and
// destroy_* procs lock themselves. frame holds the lock from flush through
// the hand-off to the next write frame.
lock :: proc(self: ^Manager) {
  sync.recursive_mutex_lock(&self.mutex)
}

unlock :: proc(self: ^Manager) {
  sync.recursive_mutex_unlock(&self.mutex)
}

@(private)
init_instances :: proc(self: ^Manager) {
  // Reserve the full slot range up front so growth never reallocates while
  // the render thread reads attachments during flush.
  self.attachments = make([dynamic]Attachment, 0, MAX_NODES_IN_SCENE)
  ba.init(&self.light_slots, MAX_NODES_IN_SCENE)
}

// The node record of a slot no attachment or transform has touched.
@(private)
INVALID_NODE :: NodeData {
  material_id           = 0xFFFFFFFF,
  mesh_id               = 0xFFFFFFFF,
  attachment_data_index = NO_BONES,
}

// Slot `slot`'s node record in the write frame's node table, growing the
// slot range to cover it. Caller holds the render mutex and marks what it
// changes.
@(private)
slot_node :: proc(self: ^Manager, slot: u32) -> ^NodeData {
  assert(slot < MAX_NODES_IN_SCENE, "slot exceeds MAX_NODES_IN_SCENE")
  nodes := write_table(self, .NODES, NodeData)
  if n := len(self.attachments); int(slot) >= n {
    resize(&self.attachments, int(slot) + 1)
    for &node in nodes[n:][:int(slot) + 1 - n] do node = INVALID_NODE
    mark_dirty(self, .NODES, NodeData, n, int(slot) + 1 - n)
  }
  return &nodes[slot]
}

// A slot holding nothing: no attachment and never given a transform.
@(private = "file")
slot_empty :: proc(self: ^Manager, slot: int) -> bool {
  return self.attachments[slot] == nil && write_table(self, .NODES, NodeData)[slot] == INVALID_NODE
}

// ---------- slot boundary: what the transform owner pushes in ----------

// Set the world transform and effective visibility of every slot in
// `changes`: any struct with `index` (the slot), `world_matrix` and `visible`
// fields, such as world.NodeChange.
stage_transforms :: proc(self: ^Manager, changes: []$T) {
  sync.recursive_mutex_lock(&self.mutex)
  defer sync.recursive_mutex_unlock(&self.mutex)
  for &c in changes {
    node := slot_node(self, c.index)
    node.world_matrix = c.world_matrix
    if c.visible do node.flags += {.VISIBLE}
    else do node.flags -= {.VISIBLE}
    mark_dirty(self, .NODES, NodeData, int(c.index))
  }
}

// Forget everything drawn at a slot. Emitters and force fields owned
// by the attachment are destroyed; meshes and materials are shared and stay.
stage_slot_removal :: proc(self: ^Manager, slot: u32) {
  sync.recursive_mutex_lock(&self.mutex)
  defer sync.recursive_mutex_unlock(&self.mutex)
  remove_slot(self, slot)
}

// Remove every slot. Use when the transform owner resets all of its slots at
// once (level teardown).
clear_slots :: proc(self: ^Manager) {
  sync.recursive_mutex_lock(&self.mutex)
  defer sync.recursive_mutex_unlock(&self.mutex)
  for i := len(self.attachments) - 1; i >= 0; i -= 1 do remove_slot(self, u32(i))
}

// Caller holds the render mutex.
@(private = "file")
remove_slot :: proc(self: ^Manager, slot: u32) {
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
  ba.unset(&self.light_slots, slot)
}

// Free a slot's skin palette and its bone table range. Caller holds the
// render mutex.
@(private = "file")
release_bones :: proc(self: ^Manager, slot: u32) {
  p, ok := self.bones[slot]
  if !ok do return
  if p.offset != NO_BONES do cont.slab_free(&self.bone_matrix_slab, p.offset)
  delete_key(&self.bones, slot)
  slot_node(self, slot).attachment_data_index = NO_BONES
  mark_dirty(self, .NODES, NodeData, int(slot))
}

// Skin palette (bone skinning matrices) for the skinned mesh at `slot`.
// The matrices are copied.
stage_bones :: proc(self: ^Manager, slot: u32, matrices: []matrix[4, 4]f32) {
  if len(matrices) == 0 do return
  sync.recursive_mutex_lock(&self.mutex)
  defer sync.recursive_mutex_unlock(&self.mutex)
  p, ok := self.bones[slot]
  if !ok || int(p.count) != len(matrices) {
    release_bones(self, slot)
    p = {alloc_bones(self, u32(len(matrices))), u32(len(matrices))}
    self.bones[slot] = p
    slot_node(self, slot).attachment_data_index = p.offset
    mark_dirty(self, .NODES, NodeData, int(slot))
  }
  if p.offset == NO_BONES do return
  copy(write_table(self, .BONES, matrix[4, 4]f32)[p.offset:][:p.count], matrices)
  mark_dirty(self, .BONES, matrix[4, 4]f32, int(p.offset), int(p.count))
}

// A bone range of `count` matrices, growing the slab when it is full.
// NO_BONES when no size class fits `count` or the grown buffer would exceed
// the device's storage buffer range. Caller holds the render mutex.
@(private = "file")
alloc_bones :: proc(self: ^Manager, count: u32) -> u32 {
  if offset, ok := cont.slab_alloc(&self.bone_matrix_slab, count); ok do return offset
  if grow_bones(self) == .SUCCESS {
    if offset, ok := cont.slab_alloc(&self.bone_matrix_slab, count); ok do return offset
  }
  log.warnf("No bone range for a %d-bone palette; the mesh draws unskinned", count)
  return NO_BONES
}

// Double every bone size class and re-place every palette in the new layout:
// the write frame's bone buffer is replaced at once with the palettes moved
// to their new offsets, the other frames' buffers at their hand-off. Caller
// holds the render mutex.
@(private = "file")
grow_bones :: proc(self: ^Manager) -> vk.Result {
  slab := &self.bone_matrix_slab
  config: [cont.MAX_SLAB_CLASSES]struct {
    block_size, block_count: u32,
  }
  capacity: u64
  for c, i in slab.classes {
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
  self.bone_buffers[w] = grown
  scene_write_binding(self, .BONES, int(w))
  old_bones := gpu.mapped(&old, matrix[4, 4]f32)
  cont.slab_destroy(slab)
  cont.slab_init(slab, config)
  bones := write_table(self, .BONES, matrix[4, 4]f32)
  for slot, &p in self.bones {
    offset, ok := cont.slab_alloc(slab, p.count)
    if p.offset != NO_BONES && ok do copy(bones[offset:][:p.count], old_bones[p.offset:][:p.count])
    p.offset = offset if ok else NO_BONES
    slot_node(self, slot).attachment_data_index = p.offset
    mark_dirty(self, .NODES, NodeData, int(slot))
  }
  mark_table_dirty(self, .BONES)
  log.infof("Bone buffer grown to %d matrices", slab.capacity)
  return .SUCCESS
}

// ---------- attachments ----------

// Draw `attachment` at `slot`, replacing what the slot drew before. Emitters
// and force fields are bound to the slot's transform.
attach :: proc(self: ^Manager, slot: u32, attachment: Attachment) {
  sync.recursive_mutex_lock(&self.mutex)
  defer sync.recursive_mutex_unlock(&self.mutex)
  node := slot_node(self, slot)
  self.attachments[slot] = attachment
  node.mesh_id, node.material_id = INVALID_NODE.mesh_id, INVALID_NODE.material_id
  node.flags -= {.CASTS_SHADOW}
  switch a in attachment {
  case MeshAttachment:
    node.mesh_id, node.material_id = a.handle.index, a.material.index
    if a.cast_shadow do node.flags += {.CASTS_SHADOW}
  case EmitterHandle:
    if em, ok := emitter(self, a); ok do em.node_index = slot
  case ForceFieldHandle:
    if ff, ok := forcefield(self, a); ok do ff.node_index = slot
  case Light:
  }
  mark_dirty(self, .NODES, NodeData, int(slot))
  _, is_light := attachment.(Light)
  ba.set(&self.light_slots, slot, is_light)
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
  sync.recursive_mutex_lock(&self.mutex)
  defer sync.recursive_mutex_unlock(&self.mutex)
  if int(slot) >= len(self.attachments) do return
  return self.attachments[slot].(T)
}

point_light_attachment :: proc(
  color: [4]f32 = {1, 1, 1, 1},
  radius: f32 = 10.0,
  cast_shadow: bool = true,
) -> Light {
  return {type = .POINT, color = color, radius = radius, cast_shadow = b16(cast_shadow)}
}

directional_light_attachment :: proc(
  color: [4]f32 = {1, 1, 1, 1},
  shadow_radius: f32 = 10.0,
  cast_shadow: bool = false,
) -> Light {
  return {type = .DIRECTIONAL, color = color, radius = shadow_radius, cast_shadow = b16(cast_shadow)}
}

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

// ---------- flush: render-generated data ----------

// Hand the simulation time accumulated by update to this frame, and each
// enabled emitter the whole particles its rate makes of it. Emitters take
// consecutive ranges of the frame's new particles, which take consecutive
// ring slots after the previous frame's. A destroyed emitter is zeroed, so
// disabled.
@(private = "file")
flush_particles :: proc(self: ^Manager) {
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
  // A ring slot takes at most one new particle per frame.
  p.emit_total = min(total, MAX_PARTICLES)
  p.emitter_count = u32(len(emitters))
  p.forcefield_count = self.forcefield_slots.high_water
  p.delta_time = self.particle_time
  p.frame_counter += 1
  self.particle_time = 0
}

@(private = "file")
flush_cameras :: proc(self: ^Manager, frame_index: u32) {
  views := frame_table(self, .VIEWS, ViewGPU, frame_index)
  // This frame's cull writes the lists of the next frame. A slot without a
  // camera keeps an empty view that draws no type.
  next_frame_index := (frame_index + 1) % gpu.FRAMES_IN_FLIGHT
  slot_count := self.camera_slots.high_water
  slice.zero(views[CAMERA_VIEW_BASE:][:slot_count])
  all_types := u32(1 << len(MaterialType) - 1)
  occlusion_mask, _ := material_masks()
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
      pyramid             = cam.depth_pyramid[frame_index].texture.index,
      occlusion_mask      = occlusion_mask if self.gctx.frame_serial >= cam.ready_serial else 0,
      list_stride         = 1,
      type_mask           = all_types,
      require_flags       = {.VISIBLE},
      draw_list           = cam.draws.slot + next_frame_index,
      list_capacity       = cam.draws.capacity,
    }
    for a in AttachmentType do v.attachments[a] = cam.attachments[a][frame_index].index
  }
}

// Write this frame's render-generated tables (views, lights, particle
// inputs). Call once per frame on the render thread, under the render
// mutex, before record_frame.
@(private)
flush :: proc(self: ^Manager, frame_index: u32) -> vk.Result {
  // before the lights: shadow casters are ranked by the camera views
  flush_cameras(self, frame_index)
  flush_particles(self)
  collect_lights(self, frame_index)
  shadow_atlas_reserve(self, frame_index, self.shadow_view_count) or_return
  // Culling dispatches cover the slots up to the last occupied one.
  for n := len(self.attachments); n > 0 && slot_empty(self, n - 1); n -= 1 {
    pop(&self.attachments)
  }
  self.node_count = u32(len(self.attachments))
  flush_ui_atlas(self) or_return
  return .SUCCESS
}
