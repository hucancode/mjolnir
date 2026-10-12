package render

import cont "../containers"
import "core:log"
import "core:sync"
import "gpu"
import "mesh"

// An emitter, stored as the emit shader reads it. std430 rounds the struct to
// 16 bytes (it holds vec4s); #align(16) keeps the Odin array stride equal to
// the GLSL one.
Emitter :: struct #align(16) {
  initial_velocity:  [3]f32,
  size_start:        f32,
  color_start:       [4]f32,
  color_end:         [4]f32,
  particle_lifetime: f32,
  position_spread:   f32,
  velocity_spread:   f32,
  // first of this emitter's particles among the frame's new particles;
  // render writes it every frame
  emit_first:        u32,
  size_end:          f32,
  weight:            f32,
  weight_spread:     f32,
  // bindless texture of the particles (texture_index), NO_TEXTURE for none
  texture_index:     u32,
  // transform slot the particles spawn from, set by attach
  node_index:        u32,
  // particles per second while enabled
  emission_rate:     f32,
  enabled:           b32,
  // fraction of a particle carried to the next frame; render writes it
  emit_carry:        f32,
}
#assert(size_of(Emitter) == 96)

// A force field, stored as the simulation reads it.
ForceField :: struct {
  tangent_strength: f32,
  strength:         f32,
  area_of_effect:   f32,
  // transform slot the field is centered on, set by attach
  node_index:       u32,
  enabled:          b32,
}

@(private)
init_resource_pools :: proc(self: ^Manager) {
  cont.slots_init(&self.mesh_slots, MAX_MESHES, gpu.RETIRE_GRACE)
  cont.slots_init(&self.material_slots, MAX_MATERIALS, gpu.RETIRE_GRACE)
  cont.slots_init(&self.emitter_slots, MAX_EMITTERS, gpu.RETIRE_GRACE)
  cont.slots_init(&self.forcefield_slots, MAX_FORCE_FIELDS, gpu.RETIRE_GRACE)
  self.meshes = make([]MeshData, MAX_MESHES)
}

// The builtin materials and meshes. Call once the frame tables exist.
@(private)
init_builtins :: proc(self: ^Manager) {
  init_builtin_materials(self)
  init_builtin_meshes(self)
}

@(private)
destroy_resource_pools :: proc(self: ^Manager) {
  cont.slots_destroy(&self.mesh_slots)
  cont.slots_destroy(&self.material_slots)
  cont.slots_destroy(&self.emitter_slots)
  cont.slots_destroy(&self.forcefield_slots)
  delete(self.meshes)
}

// Advance deferred destruction by one frame: pool slots, textures and loose
// GPU buffers freed gpu.RETIRE_GRACE frames ago are reclaimed. The only place
// retirement advances; frame calls it once per frame, after wait_frame, so
// the pools' tick counts follow frame_serial.
@(private)
tick_resource_pools :: proc(self: ^Manager) {
  gpu.deferred_tick(&self.gctx)
  textures_tick(self)
  // no frame in flight draws a reclaimed mesh any more
  for i in cont.slots_tick(&self.mesh_slots) {
    free_mesh(self, self.meshes[i])
    self.meshes[i] = {}
  }
  cont.slots_tick(&self.material_slots)
  cont.slots_tick(&self.emitter_slots)
  cont.slots_tick(&self.forcefield_slots)
  cont.slots_tick(&self.camera_slots)
}

// Pointers to a material, emitter or force field in the table the next frame
// draws from: edit them in place. A pointer is valid until the next frame;
// edits from another thread than frame's happen between lock and unlock.
material :: proc(r: ^Manager, h: MaterialHandle) -> (^Material, bool) #optional_ok {
  if !cont.slots_valid(&r.material_slots, h) do return nil, false
  mark_dirty(r, .MATERIALS, Material, int(h.index))
  return &write_table(r, .MATERIALS, Material)[h.index], true
}

emitter :: proc(r: ^Manager, h: EmitterHandle) -> (^Emitter, bool) #optional_ok {
  if !cont.slots_valid(&r.emitter_slots, h) do return nil, false
  mark_dirty(r, .EMITTERS, Emitter, int(h.index))
  return &write_table(r, .EMITTERS, Emitter)[h.index], true
}

forcefield :: proc(r: ^Manager, h: ForceFieldHandle) -> (^ForceField, bool) #optional_ok {
  if !cont.slots_valid(&r.forcefield_slots, h) do return nil, false
  mark_dirty(r, .FORCEFIELDS, ForceField, int(h.index))
  return &write_table(r, .FORCEFIELDS, ForceField)[h.index], true
}

// Zero a freed entry so the GPU stops using it. Caller holds the render
// mutex.
@(private = "file")
clear_entry :: proc(r: ^Manager, b: SceneBinding, $T: typeid, index: u32) {
  write_table(r, b, T)[index] = {}
  mark_dirty(r, b, T, int(index))
}

// ---------- meshes ----------

// Creates a mesh. Geometry ownership is transferred: it is uploaded into the
// mesh arena and deleted.
create_mesh :: proc(
  self: ^Manager,
  geometry_data: mesh.Geometry,
) -> (
  handle: MeshHandle,
  ok: bool,
) #optional_ok {
  defer mesh.delete_geometry(geometry_data)
  sync.recursive_mutex_lock(&self.mutex)
  defer sync.recursive_mutex_unlock(&self.mutex)
  handle = cont.slots_alloc(&self.mesh_slots, MeshHandle) or_return
  if res := upload_mesh(self, &self.gctx, handle.index, &self.meshes[handle.index], geometry_data); res != .SUCCESS {
    log.errorf("Mesh %d upload failed: %v", handle.index, res)
    cont.slots_free(&self.mesh_slots, handle)
    return {}, false
  }
  return handle, true
}

destroy_mesh :: proc(self: ^Manager, handle: MeshHandle) {
  cont.slots_free(&self.mesh_slots, handle)
}

// ---------- materials ----------

// Materials are app-lifetime but textures are level-lifetime: destroy a
// material that samples textures before teardown.
create_material :: proc(
  self: ^Manager,
  type: MaterialType = .PBR,
  albedo_handle: TextureHandle = {},
  metallic_roughness_handle: TextureHandle = {},
  normal_handle: TextureHandle = {},
  emissive_handle: TextureHandle = {},
  metallic_value: f32 = 0.0,
  roughness_value: f32 = 1.0,
  emissive_value: f32 = 0.0,
  base_color_factor: [4]f32 = {1.0, 1.0, 1.0, 1.0},
  frame_columns: u32 = 1,
  frame_rows: u32 = 1,
) -> (
  handle: MaterialHandle,
  ok: bool,
) #optional_ok {
  sync.recursive_mutex_lock(&self.mutex)
  defer sync.recursive_mutex_unlock(&self.mutex)
  handle = cont.slots_alloc(&self.material_slots, MaterialHandle) or_return
  material(self, handle)^ = {
    type                     = type,
    albedo_index             = texture_index(albedo_handle),
    metallic_roughness_index = texture_index(metallic_roughness_handle),
    normal_index             = texture_index(normal_handle),
    emissive_index           = texture_index(emissive_handle),
    metallic_value           = metallic_value,
    roughness_value          = roughness_value,
    emissive_value           = emissive_value,
    base_color_factor        = base_color_factor,
    frame_columns            = max(frame_columns, 1),
    frame_rows               = max(frame_rows, 1),
  }
  return handle, true
}

// Solid-color PBR material from metallic/roughness/emissive scalars.
material_pbr :: proc(
  self: ^Manager,
  base_color: [4]f32 = {1, 1, 1, 1},
  metallic: f32 = 0.0,
  roughness: f32 = 1.0,
  emissive: f32 = 0.0,
) -> (MaterialHandle, bool) #optional_ok {
  return create_material(
    self,
    type              = .PBR,
    base_color_factor = base_color,
    metallic_value    = metallic,
    roughness_value   = roughness,
    emissive_value    = emissive,
  )
}

material_wireframe :: proc(
  self: ^Manager,
  base_color: [4]f32 = {1, 1, 1, 1},
) -> (MaterialHandle, bool) #optional_ok {
  return create_material(self, type = .WIREFRAME, base_color_factor = base_color)
}

material_transparent :: proc(
  self: ^Manager,
  base_color: [4]f32 = {1, 1, 1, 0.5},
) -> (MaterialHandle, bool) #optional_ok {
  return create_material(self, type = .TRANSPARENT, base_color_factor = base_color)
}

// Sprite-sheet material of `frame_columns` x `frame_rows` cells, tinted by
// `tint`. Attach it with the builtin QUAD_XY mesh; it always faces the camera.
material_sprite :: proc(
  self: ^Manager,
  texture: TextureHandle,
  frame_columns: u32 = 1,
  frame_rows: u32 = 1,
  tint: [4]f32 = {1, 1, 1, 1},
) -> (MaterialHandle, bool) #optional_ok {
  return create_material(
    self,
    type = .SPRITE,
    albedo_handle = texture,
    base_color_factor = tint,
    frame_columns = frame_columns,
    frame_rows = frame_rows,
  )
}

// Show cell `frame` (row-major, wrapped to the sheet size) of a sprite
// material. Animate by calling this as time advances.
set_sprite_frame :: proc(self: ^Manager, handle: MaterialHandle, frame: u32) -> bool {
  sync.recursive_mutex_lock(&self.mutex)
  defer sync.recursive_mutex_unlock(&self.mutex)
  m := material(self, handle) or_return
  m.frame_index = frame % (m.frame_columns * m.frame_rows)
  return true
}

destroy_material :: proc(self: ^Manager, handle: MaterialHandle) -> bool {
  sync.recursive_mutex_lock(&self.mutex)
  defer sync.recursive_mutex_unlock(&self.mutex)
  cont.slots_free(&self.material_slots, handle) or_return
  clear_entry(self, .MATERIALS, Material, handle.index)
  return true
}

// ---------- builtins ----------

// A builtin primitive mesh drawn with a builtin color material.
primitive :: proc(
  self: ^Manager,
  shape: Primitive = .CUBE,
  color: Color = .WHITE,
  cast_shadow := true,
) -> MeshAttachment {
  return {
    handle = self.builtin_meshes[shape],
    material = self.builtin_materials[color],
    cast_shadow = cast_shadow,
  }
}

@(private)
init_builtin_materials :: proc(self: ^Manager) {
  colors := [Color][4]f32 {
    .WHITE = {1.0, 1.0, 1.0, 1.0},
    .BLACK = {0.0, 0.0, 0.0, 1.0},
    .GRAY = {0.3, 0.3, 0.3, 1.0},
    .RED = {1.0, 0.0, 0.0, 1.0},
    .GREEN = {0.0, 1.0, 0.0, 1.0},
    .BLUE = {0.0, 0.0, 1.0, 1.0},
    .YELLOW = {1.0, 1.0, 0.0, 1.0},
    .CYAN = {0.0, 1.0, 1.0, 1.0},
    .MAGENTA = {1.0, 0.0, 1.0, 1.0},
  }
  for color, i in colors {
    self.builtin_materials[i] = material_pbr(self, base_color = color) or_continue
  }
}

@(private)
init_builtin_meshes :: proc(self: ^Manager) {
  self.builtin_meshes[.CUBE] = create_mesh(self, mesh.make_cube())
  self.builtin_meshes[.SPHERE] = create_mesh(self, mesh.make_sphere())
  self.builtin_meshes[.QUAD_XZ] = create_mesh(self, mesh.make_quad())
  self.builtin_meshes[.QUAD_XY] = create_mesh(self, mesh.make_billboard_quad())
  self.builtin_meshes[.CONE] = create_mesh(self, mesh.make_cone())
  self.builtin_meshes[.CYLINDER] = create_mesh(self, mesh.make_cylinder())
}

// ---------- emitters ----------

create_emitter :: proc(
  self: ^Manager,
  texture_handle: TextureHandle = {},
  emission_rate: f32 = 50.0,
  initial_velocity: [3]f32 = {0, 1, 0},
  velocity_spread: f32 = 0.5,
  color_start: [4]f32 = {1, 1, 1, 1},
  color_end: [4]f32 = {1, 1, 1, 0},
  particle_lifetime: f32 = 2.0,
  position_spread: f32 = 0.0,
  size_start: f32 = 100.0,
  size_end: f32 = 100.0,
  weight: f32 = 1.0,
  weight_spread: f32 = 0.0,
) -> (
  ret: EmitterHandle,
  ok: bool,
) #optional_ok {
  sync.recursive_mutex_lock(&self.mutex)
  defer sync.recursive_mutex_unlock(&self.mutex)
  handle := cont.slots_alloc(&self.emitter_slots, EmitterHandle) or_return
  emitter(self, handle)^ = {
    emission_rate     = emission_rate,
    initial_velocity  = initial_velocity,
    velocity_spread   = velocity_spread,
    color_start       = color_start,
    color_end         = color_end,
    particle_lifetime = particle_lifetime,
    position_spread   = position_spread,
    size_start        = size_start,
    size_end          = size_end,
    weight            = weight,
    weight_spread     = weight_spread,
    texture_index     = texture_index(texture_handle),
    enabled           = true,
  }
  return handle, true
}

destroy_emitter :: proc(self: ^Manager, handle: EmitterHandle) -> bool {
  sync.recursive_mutex_lock(&self.mutex)
  defer sync.recursive_mutex_unlock(&self.mutex)
  cont.slots_free(&self.emitter_slots, handle) or_return
  clear_entry(self, .EMITTERS, Emitter, handle.index)
  return true
}

// ---------- force fields ----------

create_forcefield :: proc(
  self: ^Manager,
  area_of_effect: f32 = 5.0,
  strength: f32 = 1.0,
  tangent_strength: f32 = 0.0,
) -> (
  ret: ForceFieldHandle,
  ok: bool,
) #optional_ok {
  sync.recursive_mutex_lock(&self.mutex)
  defer sync.recursive_mutex_unlock(&self.mutex)
  handle := cont.slots_alloc(&self.forcefield_slots, ForceFieldHandle) or_return
  forcefield(self, handle)^ = {
    tangent_strength = tangent_strength,
    strength         = strength,
    area_of_effect   = area_of_effect,
    enabled          = true,
  }
  return handle, true
}

destroy_forcefield :: proc(self: ^Manager, handle: ForceFieldHandle) -> bool {
  sync.recursive_mutex_lock(&self.mutex)
  defer sync.recursive_mutex_unlock(&self.mutex)
  cont.slots_free(&self.forcefield_slots, handle) or_return
  clear_entry(self, .FORCEFIELDS, ForceField, handle.index)
  return true
}

// Advance the render clock (debug line lifetimes) and the particle
// simulation time. Call once per update tick; the next frame emits and
// simulates everything accumulated since the previous one.
update :: proc(self: ^Manager, delta_time: f32) {
  debug_line_advance(&self.debug_line_renderer, delta_time)
  if delta_time <= 0 do return
  sync.recursive_mutex_lock(&self.mutex)
  self.particle_time += delta_time
  sync.recursive_mutex_unlock(&self.mutex)
}
