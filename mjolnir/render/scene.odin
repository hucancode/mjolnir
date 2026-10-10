package render

import "base:builtin"
import cont "../containers"
import "gpu"
import "core:math"
import "core:math/linalg"
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
Instance :: struct {
  world_matrix: matrix[4, 4]f32,
  visible:      bool,
  attachment:   Attachment,
}

@(private)
StagingOp :: enum u16 {
  Update,
  Remove,
}

@(private)
StagingEntry :: struct {
  age: u16,
  op:  StagingOp,
}

// Dirty sets drained by flush. Each entry is re-uploaded until every frame
// in flight has it (`age` counts uploads), then dropped.
@(private)
Staging :: struct {
  nodes:       map[u32]StagingEntry,
  meshes:      map[u32]StagingEntry,
  materials:   map[u32]StagingEntry,
  bones:       map[u32]StagingEntry,
  sprites:     map[u32]StagingEntry,
  emitters:    map[u32]StagingEntry,
  forcefields: map[u32]StagingEntry,
  lights:      map[u32]StagingEntry,
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
  delete(s.lights)
}

@(private)
stage :: proc(
  self: ^Manager,
  m: ^map[u32]StagingEntry,
  index: u32,
  op: StagingOp = .Update,
) {
  sync.mutex_lock(&self.internal.staging.mutex)
  m[index] = {op = op}
  sync.mutex_unlock(&self.internal.staging.mutex)
}

// Instance writes and their staging happen under the staging mutex so flush
// on the render thread never sees a half-written slot.
@(private)
lock_slots :: proc(self: ^Manager) {
  sync.mutex_lock(&self.internal.staging.mutex)
}

@(private)
unlock_slots :: proc(self: ^Manager) {
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
  lock_slots(self)
  defer unlock_slots(self)
  inst := ensure_slot(self, slot)
  inst.world_matrix = world_matrix
  inst.visible = visible
  self.internal.staging.nodes[slot] = {}
  if is_light(inst.attachment) do self.internal.staging.lights[slot] = {}
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
  inst^ = {}
  stage(self, &self.internal.staging.nodes, slot, .Remove)
  stage(self, &self.internal.staging.lights, slot, .Remove)
  stage(self, &self.internal.staging.bones, slot, .Remove)
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
  palette := self.internal.bone_matrices[slot]
  if len(palette) != len(matrices) {
    delete(palette)
    palette = make([]matrix[4, 4]f32, len(matrices))
    self.internal.bone_matrices[slot] = palette
    // node data carries the bone range offset; refresh it
    self.internal.staging.nodes[slot] = {}
  }
  copy(palette, matrices)
  self.internal.staging.bones[slot] = {}
}

// ---------- attachments ----------

// Draw `attachment` at `slot`. Emitters and force fields are bound to the
// slot's transform.
attach :: proc(self: ^Manager, slot: u32, attachment: Attachment) {
  lock_slots(self)
  defer unlock_slots(self)
  staging := &self.internal.staging
  inst := ensure_slot(self, slot)
  was_light := is_light(inst.attachment)
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
  if was_light || is_light(attachment) do staging.lights[slot] = {}
}

instance :: proc(self: ^Manager, slot: u32) -> (^Instance, bool) #optional_ok {
  if int(slot) >= len(self.instances) do return nil, false
  return &self.instances[slot], true
}

// The attachment of type T at `slot`, e.g. attachment(r, slot, MeshAttachment).
attachment :: proc(
  self: ^Manager,
  slot: u32,
  $T: typeid,
) -> (
  att: ^T,
  ok: bool,
) #optional_ok {
  inst := instance(self, slot)
  if inst == nil do return
  return &inst.attachment.(T)
}

mark_slot_dirty :: proc(self: ^Manager, slot: u32) {
  stage(self, &self.internal.staging.nodes, slot)
  if inst, ok := instance(self, slot); ok && is_light(inst.attachment) {
    stage(self, &self.internal.staging.lights, slot)
  }
}

// Light field setters. Mutate + stage. No-op when value unchanged so
// per-frame UI bindings don't churn the dirty queue.
set_light_color :: proc(self: ^Manager, slot: u32, color: [4]f32) {
  inst := instance(self, slot)
  if inst == nil do return
  target: ^[4]f32
  #partial switch &a in inst.attachment {
  case PointLightAttachment:       target = &a.color
  case DirectionalLightAttachment: target = &a.color
  case SpotLightAttachment:        target = &a.color
  case:                            return
  }
  if target^ == color do return
  target^ = color
  stage(self, &self.internal.staging.lights, slot)
}

set_light_intensity :: proc(self: ^Manager, slot: u32, intensity: f32) {
  inst := instance(self, slot)
  if inst == nil do return
  target: ^f32
  #partial switch &a in inst.attachment {
  case PointLightAttachment:       target = &a.color[3]
  case DirectionalLightAttachment: target = &a.color[3]
  case SpotLightAttachment:        target = &a.color[3]
  case:                            return
  }
  if target^ == intensity do return
  target^ = intensity
  stage(self, &self.internal.staging.lights, slot)
}

set_light_radius :: proc(self: ^Manager, slot: u32, radius: f32) {
  inst := instance(self, slot)
  if inst == nil do return
  target: ^f32
  #partial switch &a in inst.attachment {
  case PointLightAttachment: target = &a.radius
  case SpotLightAttachment:  target = &a.radius
  case:                      return
  }
  if target^ == radius do return
  target^ = radius
  stage(self, &self.internal.staging.lights, slot)
}

// Toggle a light without losing its configured color/radius/cone.
set_light_enabled :: proc(self: ^Manager, slot: u32, enabled: bool) {
  inst := instance(self, slot)
  if inst == nil do return
  target: ^bool
  #partial switch &a in inst.attachment {
  case PointLightAttachment:       target = &a.disabled
  case DirectionalLightAttachment: target = &a.disabled
  case SpotLightAttachment:        target = &a.disabled
  case:                            return
  }
  want := !enabled
  if target^ == want do return
  target^ = want
  stage(self, &self.internal.staging.lights, slot)
}

// Set spot-light cone angles. Pass `inner = nil` to default it to
// `outer * SPOT_LIGHT_INNER_RATIO`.
set_spot_light_cone :: proc(
  self: ^Manager,
  slot: u32,
  outer: f32,
  inner: Maybe(f32) = nil,
) -> bool {
  att := attachment(self, slot, SpotLightAttachment) or_return
  inner_angle := inner.? or_else outer * SPOT_LIGHT_INNER_RATIO
  if att.angle_outer == outer && att.angle_inner == inner_angle do return true
  att.angle_outer = outer
  att.angle_inner = inner_angle
  stage(self, &self.internal.staging.lights, slot)
  return true
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

// Mesh attachment setters. Mutate + stage. Leave sibling fields untouched.
set_mesh_handle :: proc(self: ^Manager, slot: u32, mesh: MeshHandle) {
  a := attachment(self, slot, MeshAttachment)
  if a == nil do return
  if a.handle == mesh do return
  a.handle = mesh
  stage(self, &self.internal.staging.nodes, slot)
}

set_material_handle :: proc(self: ^Manager, slot: u32, material: MaterialHandle) {
  a := attachment(self, slot, MeshAttachment)
  if a == nil do return
  if a.material == material do return
  a.material = material
  stage(self, &self.internal.staging.nodes, slot)
}

// ---------- flush: drain staging into GPU buffers (render thread) ----------

@(private = "file")
INVALID_NODE :: NodeData {
  material_id           = 0xFFFFFFFF,
  mesh_id               = 0xFFFFFFFF,
  attachment_data_index = 0xFFFFFFFF,
}

@(private = "file")
age_and_mark :: proc(
  m: ^map[u32]StagingEntry,
  index: u32,
  prev_age: u16,
  stale: ^[dynamic]u32,
) {
  new_age := prev_age + 1
  m[index] = {new_age, .Update}
  if int(new_age) >= gpu.FRAMES_IN_FLIGHT do append(stale, index)
}

@(private = "file")
material_type_flags :: proc(t: MaterialType) -> NodeFlagSet {
  switch t {
  case .TRANSPARENT:  return {.MATERIAL_TRANSPARENT}
  case .WIREFRAME:    return {.MATERIAL_WIREFRAME}
  case .RANDOM_COLOR: return {.MATERIAL_RANDOM_COLOR}
  case .LINE_STRIP:   return {.MATERIAL_LINE_STRIP}
  case .PBR, .UNLIT:  return {}
  }
  return {}
}

@(private = "file")
flush_nodes :: proc(self: ^Manager) {
  stale := make([dynamic]u32, context.temp_allocator)
  for slot, entry in self.internal.staging.nodes {
    if entry.op == .Remove || int(slot) >= len(self.instances) {
      nd := INVALID_NODE
      upload_node_data(self, slot, &nd)
      release_bone_matrix_range_for_node(self, slot)
      append(&stale, slot)
      continue
    }
    inst := &self.instances[slot]
    nd := INVALID_NODE
    nd.world_matrix = inst.world_matrix
    material_handle: MaterialHandle
    has_material := false
    #partial switch att in inst.attachment {
    case MeshAttachment:
      if palette, skinned := self.internal.bone_matrices[slot]; skinned {
        nd.attachment_data_index = ensure_bone_matrix_range_for_node(
          self,
          slot,
          u32(len(palette)),
        )
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
    age_and_mark(&self.internal.staging.nodes, slot, entry.age, &stale)
  }
  for slot in stale do delete_key(&self.internal.staging.nodes, slot)
}

// Meshes age on every iteration regardless of op; the stale step
// distinguishes Update (purge CPU geometry) from Remove (free GPU mesh slot).
@(private = "file")
flush_meshes :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  stale := make([dynamic]u32, context.temp_allocator)
  for index, entry in self.internal.staging.meshes {
    new_age := entry.age + 1
    self.internal.staging.meshes[index] = {new_age, entry.op}
    if int(new_age) >= gpu.FRAMES_IN_FLIGHT {
      append(&stale, index)
      continue
    }
    if entry.op != .Update do continue
    m := mesh_at(self, index) or_continue
    if g, has_geom := m.cpu_geometry.?; has_geom {
      sync_mesh_geometry_for_handle(gctx, self, index, g)
    }
  }
  for index in stale {
    entry := self.internal.staging.meshes[index]
    if entry.op == .Remove {
      mesh_destroy(self, index)
    } else if m, ok := mesh_at(self, index); ok && m.auto_purge_cpu_geometry {
      mesh_release_memory(m)
    }
    delete_key(&self.internal.staging.meshes, index)
  }
}

@(private = "file")
mesh_at :: proc(self: ^Manager, index: u32) -> (^Mesh, bool) {
  if int(index) >= len(self.meshes.entries) do return nil, false
  e := &self.meshes.entries[index]
  if !e.active do return nil, false
  return &e.item, true
}

@(private = "file")
flush_materials :: proc(self: ^Manager) {
  stale := make([dynamic]u32, context.temp_allocator)
  for index, entry in self.internal.staging.materials {
    if entry.op == .Remove || int(index) >= len(self.materials.entries) || !self.materials.entries[index].active {
      append(&stale, index)
      continue
    }
    m := &self.materials.entries[index].item
    upload_material_data(
      self,
      index,
      &MaterialData {
        albedo_index = m.albedo.index,
        metallic_roughness_index = m.metallic_roughness.index,
        normal_index = m.normal.index,
        emissive_index = m.emissive.index,
        features = m.features,
        metallic_value = m.metallic_value,
        roughness_value = m.roughness_value,
        emissive_value = m.emissive_value,
        base_color_factor = m.base_color_factor,
      },
    )
    age_and_mark(&self.internal.staging.materials, index, entry.age, &stale)
  }
  for index in stale do delete_key(&self.internal.staging.materials, index)
}

@(private = "file")
flush_bones :: proc(self: ^Manager, frame_index: u32) {
  stale := make([dynamic]u32, context.temp_allocator)
  for slot, entry in self.internal.staging.bones {
    if entry.op == .Remove {
      if palette, ok := self.internal.bone_matrices[slot]; ok {
        delete(palette)
        delete_key(&self.internal.bone_matrices, slot)
      }
      append(&stale, slot)
      continue
    }
    palette, ok := self.internal.bone_matrices[slot]
    if !ok {
      append(&stale, slot)
      continue
    }
    offset := ensure_bone_matrix_range_for_node(self, slot, u32(len(palette)))
    if offset != 0xFFFFFFFF {
      upload_bone_matrices(self, frame_index, offset, palette)
    }
    age_and_mark(&self.internal.staging.bones, slot, entry.age, &stale)
  }
  for slot in stale do delete_key(&self.internal.staging.bones, slot)
}

@(private = "file")
flush_sprites :: proc(self: ^Manager) {
  stale := make([dynamic]u32, context.temp_allocator)
  for index, entry in self.internal.staging.sprites {
    if entry.op == .Remove || int(index) >= len(self.sprites.entries) || !self.sprites.entries[index].active {
      append(&stale, index)
      continue
    }
    s := &self.sprites.entries[index].item
    anim, has_anim := s.animation.?
    upload_sprite_data(
      self,
      index,
      &SpriteData {
        texture_index = s.texture.index,
        frame_columns = s.frame_columns,
        frame_rows = s.frame_rows,
        frame_index = anim.current_frame if has_anim else 0,
      },
    )
    age_and_mark(&self.internal.staging.sprites, index, entry.age, &stale)
  }
  for index in stale do delete_key(&self.internal.staging.sprites, index)
}

@(private = "file")
flush_emitters :: proc(self: ^Manager) {
  stale := make([dynamic]u32, context.temp_allocator)
  for index, entry in self.internal.staging.emitters {
    if entry.op == .Remove || int(index) >= len(self.emitters.entries) || !self.emitters.entries[index].active {
      append(&stale, index)
      continue
    }
    em := &self.emitters.entries[index].item
    upload_emitter_data(
      self,
      index,
      &EmitterData {
        initial_velocity = em.initial_velocity,
        size_start = em.size_start,
        color_start = em.color_start,
        color_end = em.color_end,
        aabb_min = em.aabb_min,
        emission_rate = em.emission_rate,
        aabb_max = em.aabb_max,
        particle_lifetime = em.particle_lifetime,
        position_spread = em.position_spread,
        velocity_spread = em.velocity_spread,
        emit_count = em.pending_emit,
        size_end = em.size_end,
        weight = em.weight,
        weight_spread = em.weight_spread,
        texture_index = em.texture_handle.index,
        node_index = em.slot,
      },
    )
    age_and_mark(&self.internal.staging.emitters, index, entry.age, &stale)
  }
  for index in stale do delete_key(&self.internal.staging.emitters, index)
}

@(private = "file")
flush_forcefields :: proc(self: ^Manager) {
  stale := make([dynamic]u32, context.temp_allocator)
  for index, entry in self.internal.staging.forcefields {
    if entry.op == .Remove || int(index) >= len(self.forcefields.entries) || !self.forcefields.entries[index].active {
      append(&stale, index)
      continue
    }
    ff := &self.forcefields.entries[index].item
    upload_forcefield_data(
      self,
      index,
      &ForceFieldData {
        tangent_strength = ff.tangent_strength if ff.enabled else 0,
        strength = ff.strength if ff.enabled else 0,
        area_of_effect = ff.area_of_effect,
        node_index = ff.slot,
      },
    )
    age_and_mark(&self.internal.staging.forcefields, index, entry.age, &stale)
  }
  for index in stale do delete_key(&self.internal.staging.forcefields, index)
}

// GPU light derived from a light attachment placed at `world_matrix`.
// ok=false when the attachment is not a light or the light is disabled.
@(private = "file")
light_from_attachment :: proc(
  a: Attachment,
  world_matrix: matrix[4, 4]f32,
) -> (
  light: Light,
  cast_shadow: bool,
  ok: bool,
) {
  position := world_matrix[3].xyz
  raw_dir := world_matrix[2].xyz
  direction := [3]f32{0, -1, 0}
  if linalg.dot(raw_dir, raw_dir) >= 1e-6 do direction = linalg.normalize(raw_dir)
  #partial switch att in a {
  case PointLightAttachment:
    if att.disabled do return
    return PointLight{color = att.color, position = position, radius = att.radius}, att.cast_shadow, true
  case DirectionalLightAttachment:
    if att.disabled do return
    return DirectionalLight {
        color = att.color,
        position = position,
        direction = direction,
        radius = att.radius,
      },
      att.cast_shadow,
      true
  case SpotLightAttachment:
    if att.disabled do return
    return SpotLight {
        color = att.color,
        position = position,
        direction = direction,
        radius = att.radius,
        angle_inner = att.angle_inner,
        angle_outer = att.angle_outer,
      },
      att.cast_shadow,
      true
  }
  return
}

@(private = "file")
flush_lights :: proc(self: ^Manager, gctx: ^gpu.GPUContext) -> vk.Result {
  stale := make([dynamic]u32, context.temp_allocator)
  for slot, entry in self.internal.staging.lights {
    if entry.op == .Remove || int(slot) >= len(self.instances) {
      remove_light_entry(self, gctx, slot)
      append(&stale, slot)
      continue
    }
    inst := &self.instances[slot]
    light, cast_shadow, ok := light_from_attachment(inst.attachment, inst.world_matrix)
    if !ok {
      remove_light_entry(self, gctx, slot)
      append(&stale, slot)
      continue
    }
    upsert_light_entry(self, gctx, slot, &light, cast_shadow) or_return
    age_and_mark(&self.internal.staging.lights, slot, entry.age, &stale)
  }
  for slot in stale do delete_key(&self.internal.staging.lights, slot)
  return .SUCCESS
}

@(private = "file")
flush_cameras :: proc(self: ^Manager, frame_index: u32) {
  for &entry, index in self.cameras.entries {
    if !entry.active do continue
    cam := &entry.item
    near, far := camera_get_near_far(cam)
    upload_camera_data(
      self,
      u32(index),
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
    flush_nodes(self)
    flush_meshes(self, gctx)
    flush_materials(self)
    flush_bones(self, frame_index)
    flush_sprites(self)
    flush_emitters(self)
    flush_forcefields(self)
    flush_lights(self, gctx) or_return
  }
  flush_cameras(self, frame_index)
  set_node_count(self, u32(len(self.instances)))
  flush_ui_atlas(self, gctx) or_return
  return .SUCCESS
}
