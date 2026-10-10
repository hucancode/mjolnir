package render

import "base:builtin"
import "bindless"
import cont "../containers"
import "gpu"
import "core:math"
import "core:sync"
import vk "vendor:vulkan"

// Default inner/outer cone ratio for spot lights. Inner cone is the angular
// region with full intensity; outer cone is the falloff edge.
SPOT_LIGHT_INNER_RATIO :: f32(0.75)

PointLightAttachment :: struct {
  color:       [4]f32, // RGB + intensity
  radius:      f32, // range
  cast_shadow: bool,
  disabled:    bool, // zero-default = enabled; toggle to skip GPU upload without losing color/radius
}

DirectionalLightAttachment :: struct {
  color:       [4]f32, // RGB + intensity
  radius:      f32, // shadow projection radius
  cast_shadow: bool,
  disabled:    bool,
}

SpotLightAttachment :: struct {
  color:       [4]f32, // RGB + intensity
  radius:      f32, // range
  angle_inner: f32, // inner cone angle
  angle_outer: f32, // outer cone angle
  cast_shadow: bool,
  disabled:    bool,
}

MeshAttachment :: struct {
  handle:      MeshHandle,
  material:    MaterialHandle,
  cast_shadow: bool,
}

SpriteAttachment :: struct {
  sprite_handle: SpriteHandle,
  mesh_handle:   MeshHandle,
  material:      MaterialHandle,
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
  SpriteAttachment,
  EmitterAttachment,
  ForceFieldAttachment,
}

// What render draws at one transform slot. The transform itself is owned by
// whoever drives the slot (normally the world module) and pushed in with
// stage_transform.
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

// Dirty sets drained by flush. Every entry is written from the current state
// of its slot or pool entry; a removed one is written empty. Bones live in
// per-frame buffers: a bone entry is re-uploaded until every frame in flight
// has it (the value counts uploads). Everything else is written once.
// Instance writes and their staging happen under `mutex` so flush on the
// render thread never sees a half-written slot.
@(private)
Staging :: struct {
  nodes:       map[u32]struct{},
  meshes:      map[u32]struct{},
  materials:   map[u32]struct{},
  bones:       map[u32]u16,
  sprites:     map[u32]struct{},
  emitters:    map[u32]struct{},
  forcefields: map[u32]struct{},
  mutex:       sync.Mutex,
}

@(private)
staging_destroy :: proc(s: ^Staging) {
  delete(s.nodes)
  delete(s.meshes)
  delete(s.materials)
  delete(s.bones)
  delete(s.sprites)
  delete(s.emitters)
  delete(s.forcefields)
}

@(private)
stage :: proc(
  self: ^Manager,
  m: ^map[u32]struct{},
  index: u32,
) {
  sync.mutex_lock(&self.internal.staging.mutex)
  m[index] = {}
  sync.mutex_unlock(&self.internal.staging.mutex)
}

@(private)
init_instances :: proc(self: ^Manager) {
  // Reserve the full slot range up front so growth never reallocates while
  // the render thread reads instances during flush.
  self.instances = make([dynamic]Instance, 0, MAX_NODES_IN_SCENE)
}

@(private)
ensure_slot :: proc(self: ^Manager, slot: u32) -> ^Instance {
  assert(slot < MAX_NODES_IN_SCENE, "slot exceeds MAX_NODES_IN_SCENE")
  if int(slot) >= len(self.instances) do builtin.resize(&self.instances, int(slot) + 1)
  return &self.instances[slot]
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

// Set the world transform and effective visibility of a slot.
stage_transform :: proc(
  self: ^Manager,
  slot: u32,
  world_matrix: matrix[4, 4]f32,
  visible: bool,
) {
  sync.mutex_lock(&self.internal.staging.mutex)
  defer sync.mutex_unlock(&self.internal.staging.mutex)
  inst := ensure_slot(self, slot)
  inst.world_matrix = world_matrix
  inst.visible = visible
  self.internal.staging.nodes[slot] = {}
}

// Forget everything drawn at a slot. Emitters, force fields and sprites owned
// by the attachment are destroyed; meshes and materials are shared and stay.
stage_slot_removal :: proc(self: ^Manager, slot: u32) {
  if int(slot) >= len(self.instances) do return
  inst := &self.instances[slot]
  #partial switch a in inst.attachment {
  case EmitterAttachment:
    destroy_emitter(self, a.handle)
  case ForceFieldAttachment:
    destroy_forcefield(self, a.handle)
  case SpriteAttachment:
    destroy_sprite(self, a.sprite_handle)
  }
  sync.mutex_lock(&self.internal.staging.mutex)
  defer sync.mutex_unlock(&self.internal.staging.mutex)
  inst^ = {}
  self.internal.staging.nodes[slot] = {}
  delete_key(&self.internal.light_slots, slot)
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
  delete_key(&self.internal.staging.bones, slot)
}

// Remove every slot. Use when the transform owner resets all of its slots at
// once (level teardown).
clear_slots :: proc(self: ^Manager) {
  for i := len(self.instances) - 1; i >= 0; i -= 1 {
    stage_slot_removal(self, u32(i))
  }
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
    offset, ok := cont.slab_alloc(&self.internal.bone_matrix_slab, u32(len(matrices)))
    p.offset = offset if ok else NO_BONES
    self.internal.bones[slot] = p
    // node data carries the bone range offset; refresh it
    self.internal.staging.nodes[slot] = {}
  }
  copy(p.matrices, matrices)
  self.internal.staging.bones[slot] = 0
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
    if em, ok := cont.get(self.emitters, a.handle); ok {
      em.slot = slot
      staging.emitters[a.handle.index] = {}
    }
  case ForceFieldAttachment:
    if ff, ok := cont.get(self.forcefields, a.handle); ok {
      ff.slot = slot
      staging.forcefields[a.handle.index] = {}
    }
  }
  staging.nodes[slot] = {}
  if is_light(attachment) {
    self.internal.light_slots[slot] = {}
  } else {
    delete_key(&self.internal.light_slots, slot)
  }
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
material_type_flags :: proc(t: MaterialType) -> NodeFlagSet {
  switch t {
  case .TRANSPARENT:  return {.MATERIAL_TRANSPARENT}
  case .WIREFRAME:    return {.MATERIAL_WIREFRAME}
  case .RANDOM_COLOR: return {.MATERIAL_RANDOM_COLOR}
  case .PBR:          return {}
  }
  return {}
}

@(private = "file")
flush_nodes :: proc(self: ^Manager) {
  for slot in self.internal.staging.nodes {
    if int(slot) >= len(self.instances) {
      nd := INVALID_NODE
      upload_node_data(self, slot, &nd)
      continue
    }
    inst := &self.instances[slot]
    nd := INVALID_NODE
    nd.world_matrix = inst.world_matrix
    material_handle: MaterialHandle
    has_material := false
    #partial switch att in inst.attachment {
    case MeshAttachment:
      if p, skinned := self.internal.bones[slot]; skinned {
        nd.attachment_data_index = p.offset
      }
      nd.material_id = att.material.index
      nd.mesh_id = att.handle.index
      nd.flags |= {.CULLING_ENABLED}
      if att.cast_shadow do nd.flags |= {.CASTS_SHADOW}
      material_handle, has_material = att.material, true
    case SpriteAttachment:
      nd.material_id = att.material.index
      nd.mesh_id = att.mesh_handle.index
      nd.attachment_data_index = att.sprite_handle.index
      nd.flags |= {.CULLING_ENABLED, .MATERIAL_SPRITE}
      material_handle, has_material = att.material, true
    }
    if has_material {
      if inst.visible do nd.flags |= {.VISIBLE}
      if mat, ok := cont.get(self.materials, material_handle); ok {
        nd.flags |= material_type_flags(mat.type)
      }
    }
    upload_node_data(self, slot, &nd)
  }
  clear(&self.internal.staging.nodes)
}

// Upload staged meshes. Destroyed meshes free their GPU allocations in
// mesh_retire, once no frame in flight can draw them.
@(private = "file")
flush_meshes :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  for index in self.internal.staging.meshes {
    m := live_at(&self.meshes, index) or_continue
    g := m.cpu_geometry.? or_continue
    upload_mesh(self, gctx, index, m, g)
    if m.auto_purge_cpu_geometry do mesh_release_memory(m)
  }
  clear(&self.internal.staging.meshes)
}

// Live pool item at a staged slot index; staging is keyed by index alone.
@(private = "file")
live_at :: proc(pool: ^cont.Pool($T), index: u32) -> (^T, bool) {
  if int(index) >= len(pool.entries) do return nil, false
  e := &pool.entries[index]
  return &e.item, e.active
}

// Write every staged pool slot into its GPU buffer. Slots no longer live are
// zeroed so the GPU stops using them (a freed emitter stops emitting).
@(private = "file")
flush_pool :: proc(
  staged: ^map[u32]struct{},
  pool: ^cont.Pool($T),
  buffer: ^gpu.BindlessBuffer($G),
  to_gpu: proc(item: ^T) -> G,
) {
  for index in staged {
    data: G
    if item, live := live_at(pool, index); live do data = to_gpu(item)
    gpu.write(&buffer.buffer, &data, int(index))
  }
  clear(staged)
}

@(private = "file")
material_gpu :: proc(m: ^Material) -> MaterialData {
  return {
    albedo_index = m.albedo.index,
    metallic_roughness_index = m.metallic_roughness.index,
    normal_index = m.normal.index,
    emissive_index = m.emissive.index,
    features = m.features,
    metallic_value = m.metallic_value,
    roughness_value = m.roughness_value,
    emissive_value = m.emissive_value,
    base_color_factor = m.base_color_factor,
  }
}

@(private = "file")
sprite_gpu :: proc(s: ^Sprite) -> SpriteData {
  return {
    texture_index = s.texture.index,
    frame_columns = s.frame_columns,
    frame_rows = s.frame_rows,
    frame_index = s.frame_index,
  }
}

@(private = "file")
emitter_gpu :: proc(em: ^Emitter) -> EmitterData {
  return {
    initial_velocity = em.initial_velocity,
    size_start = em.size_start,
    color_start = em.color_start,
    color_end = em.color_end,
    particle_lifetime = em.particle_lifetime,
    position_spread = em.position_spread,
    velocity_spread = em.velocity_spread,
    emit_count = em.pending_emit,
    size_end = em.size_end,
    weight = em.weight,
    weight_spread = em.weight_spread,
    texture_index = em.texture_handle.index,
    node_index = em.slot,
  }
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
flush_bones :: proc(self: ^Manager, frame_index: u32) {
  stale := make([dynamic]u32, context.temp_allocator)
  for slot, &age in self.internal.staging.bones {
    p := self.internal.bones[slot]
    if p.offset != NO_BONES do upload_bone_matrices(self, frame_index, p.offset, p.matrices)
    age += 1
    if int(age) >= gpu.FRAMES_IN_FLIGHT do append(&stale, slot)
  }
  for slot in stale do delete_key(&self.internal.staging.bones, slot)
}

@(private = "file")
flush_cameras :: proc(self: ^Manager, frame_index: u32) {
  it := cont.iterator(&self.cameras)
  for cam, handle in cont.next(&it, CameraHandle) {
    near, far := camera_get_near_far(cam)
    upload_camera_data(
      self,
      handle.index,
      camera_view_matrix(cam),
      camera_projection_matrix(cam),
      cam.position,
      cam.extent,
      near,
      far,
      frame_index,
    )
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
  tick_resource_pools(self)
  {
    sync.mutex_lock(&self.internal.staging.mutex)
    defer sync.mutex_unlock(&self.internal.staging.mutex)
    staging := &self.internal.staging
    flush_nodes(self)
    flush_meshes(self, gctx)
    flush_bones(self, frame_index)
    flush_pool(&staging.materials, &self.materials, &self.internal.material_buffer, material_gpu)
    flush_pool(&staging.sprites, &self.sprites, &self.internal.sprite_buffer, sprite_gpu)
    flush_pool(&staging.emitters, &self.emitters, &self.internal.emitter_buffer, emitter_gpu)
    flush_pool(&staging.forcefields, &self.forcefields, &self.internal.forcefield_buffer, forcefield_gpu)
    collect_lights(self, gctx)
  }
  flush_cameras(self, frame_index)
  self.node_count = min(
    u32(len(self.instances)),
    self.internal.visibility.max_draws,
  )
  flush_ui_atlas(self, gctx) or_return
  return .SUCCESS
}
