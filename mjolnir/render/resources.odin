package render

import cont "../containers"
import "core:sync"
import "gpu"
import "mesh"
import vk "vendor:vulkan"

@(private)
init_resource_pools :: proc(self: ^Manager) {
  cont.init(&self.meshes, MAX_MESHES, gpu.RETIRE_GRACE)
  cont.init(&self.materials, MAX_MATERIALS, gpu.RETIRE_GRACE)
  cont.init(&self.emitters, MAX_EMITTERS, gpu.RETIRE_GRACE)
  cont.init(&self.forcefields, MAX_FORCE_FIELDS, gpu.RETIRE_GRACE)
  init_builtin_materials(self)
  init_builtin_meshes(self)
}

@(private)
destroy_resource_pools :: proc(self: ^Manager) {
  cont.destroy(&self.meshes)
  cont.destroy(&self.materials)
  cont.destroy(&self.emitters)
  cont.destroy(&self.forcefields)
}

// Advance deferred destruction by one frame: pool slots, textures and loose
// GPU buffers freed gpu.RETIRE_GRACE frames ago are reclaimed. The only place
// retirement advances; frame calls it once per frame, after wait_frame, so
// the pools' tick counts follow frame_serial.
@(private)
tick_resource_pools :: proc(self: ^Manager) {
  gpu.deferred_tick(&self.gctx)
  texture_manager_tick(&self.texture_manager, &self.gctx)
  cont.tick(&self.meshes, self, mesh_retire)
  cont.tick(&self.materials, nil, nil)
  cont.tick(&self.emitters, nil, nil)
  cont.tick(&self.forcefields, nil, nil)
  cont.tick(&self.cameras, nil, nil)
}

// Pointers to a material, emitter or force field. Write changes back with the
// matching set_* proc so they are staged for upload.
material :: proc(r: ^Manager, h: MaterialHandle) -> (^Material, bool) #optional_ok {
  return cont.get(r.materials, h)
}

emitter :: proc(r: ^Manager, h: EmitterHandle) -> (^Emitter, bool) #optional_ok {
  return cont.get(r.emitters, h)
}

forcefield :: proc(r: ^Manager, h: ForceFieldHandle) -> (^ForceField, bool) #optional_ok {
  return cont.get(r.forcefields, h)
}

// Replace a material's values and stage the change.
set_material :: proc(r: ^Manager, h: MaterialHandle, value: Material) -> bool {
  m := cont.get(r.materials, h) or_return
  m^ = value
  stage_frames(r, &r.internal.staging.materials, h.index)
  return true
}

// Replace an emitter's settings; emitters are uploaded every frame. Edit the
// value emitter returns so node_index, set by attach, is kept.
set_emitter :: proc(r: ^Manager, h: EmitterHandle, value: Emitter) -> bool {
  em := cont.get(r.emitters, h) or_return
  em^ = value
  return true
}

// Replace a force field's settings and stage the change. Edit the value
// forcefield returns so node_index, set by attach, is kept.
set_forcefield :: proc(r: ^Manager, h: ForceFieldHandle, value: ForceField) -> bool {
  ff := cont.get(r.forcefields, h) or_return
  ff^ = value
  stage_frames(r, &r.internal.staging.forcefields, h.index)
  return true
}

// ---------- meshes ----------

// Creates a mesh. Geometry ownership is transferred: flush uploads it into
// the mesh arena, then deletes it.
create_mesh :: proc(
  self: ^Manager,
  geometry_data: mesh.Geometry,
) -> (
  handle: MeshHandle,
  ok: bool,
) #optional_ok {
  handle, _, ok = cont.alloc(&self.meshes, MeshHandle)
  if !ok {
    mesh.delete_geometry(geometry_data)
    return
  }
  staging := &self.internal.staging
  sync.mutex_lock(&staging.mutex)
  append(&staging.mesh_handles, handle)
  append(&staging.mesh_geometry, geometry_data)
  sync.mutex_unlock(&staging.mutex)
  return handle, true
}

destroy_mesh :: proc(self: ^Manager, handle: MeshHandle) {
  cont.free_deferred(&self.meshes, handle)
}

// Pool retire callback: no frame in flight reads the mesh any more.
@(private)
mesh_retire :: proc(item: ^MeshData, user: rawptr) {
  free_mesh(&(^Manager)(user).mesh_manager, item^)
}

// ---------- textures ----------


// Load an image file (png, jpg, hdr, ...) into a bindless 2D texture.
create_texture_from_path :: proc(
  self: ^Manager,
  path: string,
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips: bool = false,
) -> (
  handle: TextureHandle,
  ret: vk.Result,
) {
  return create_texture_2d_from_path(&self.gctx, &self.texture_manager, path, format, generate_mips)
}

// Decode an encoded image (png, jpg, ...) held in memory into a bindless 2D texture.
create_texture_from_data :: proc(
  self: ^Manager,
  data: []u8,
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips: bool = false,
) -> (
  handle: TextureHandle,
  ret: vk.Result,
) {
  return create_texture_2d_from_data(&self.gctx, &self.texture_manager, data, format, generate_mips)
}

// Free a texture loaded with create_texture_from_*. Its GPU image is released
// once no frame in flight samples it; teardown frees every texture.
destroy_texture :: proc(self: ^Manager, handle: TextureHandle) {
  free_texture(&self.texture_manager, &self.gctx, handle)
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
  mat: ^Material
  handle, mat = cont.alloc(&self.materials, MaterialHandle) or_return
  mat^ = {
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
  stage_frames(self, &self.internal.staging.materials, handle.index)
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
  m := cont.get(self.materials, handle) or_return
  m.frame_index = frame % (m.frame_columns * m.frame_rows)
  stage_frames(self, &self.internal.staging.materials, handle.index)
  return true
}

destroy_material :: proc(self: ^Manager, handle: MaterialHandle) -> bool {
  cont.free_deferred(&self.materials, handle) or_return
  stage_frames(self, &self.internal.staging.materials, handle.index)
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
  handle, em := cont.alloc(&self.emitters, EmitterHandle) or_return
  staging := &self.internal.staging
  sync.mutex_lock(&staging.mutex)
  staging.emit_accumulator[handle.index] = 0
  staging.emit_pending[handle.index] = 0
  sync.mutex_unlock(&staging.mutex)
  em^ = {
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
  return cont.free_deferred(&self.emitters, handle)
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
  handle, ff := cont.alloc(&self.forcefields, ForceFieldHandle) or_return
  ff^ = {
    tangent_strength = tangent_strength,
    strength         = strength,
    area_of_effect   = area_of_effect,
    enabled          = true,
  }
  stage_frames(self, &self.internal.staging.forcefields, handle.index)
  return handle, true
}

destroy_forcefield :: proc(self: ^Manager, handle: ForceFieldHandle) -> bool {
  cont.free_deferred(&self.forcefields, handle) or_return
  stage_frames(self, &self.internal.staging.forcefields, handle.index)
  return true
}

// Advance the render clock (debug line lifetimes), the particle simulation
// time and emitter accumulators. Call once per update tick; the next frame
// emits and simulates everything accumulated since the previous one.
update :: proc(self: ^Manager, delta_time: f32) {
  debug_line_advance(&self.internal.debug_line_renderer, delta_time)
  if delta_time <= 0 do return
  sync.mutex_lock(&self.internal.staging.mutex)
  defer sync.mutex_unlock(&self.internal.staging.mutex)
  self.internal.staging.particle_time += delta_time
  staging := &self.internal.staging
  it := cont.iterator(&self.emitters)
  for em, h in cont.next(&it, EmitterHandle) {
    accum := &staging.emit_accumulator[h.index]
    accum^ += em.emission_rate * delta_time if em.enabled else 0
    emit := u32(accum^)
    accum^ -= f32(emit)
    staging.emit_pending[h.index] += emit
  }
}
