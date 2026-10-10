package render

import "bindless"
import cont "../containers"
import "mesh"
import "debug_line"
import "particles"
import vk "vendor:vulkan"

// CPU-side mesh. flush uploads cpu_geometry into the mesh manager and
// describes it in mesh_data_buffer at the same index.
Mesh :: struct {
  cpu_geometry:            Maybe(mesh.Geometry),
  auto_purge_cpu_geometry: bool,
  allocations:             bindless.MeshAllocations,
}

Material :: struct {
  features:           ShaderFeatureSet,
  base_color_factor:  [4]f32,
  metallic_value:     f32,
  roughness_value:    f32,
  emissive_value:     f32,
  type:               MaterialType,
  albedo:             bindless.Texture2DHandle,
  metallic_roughness: bindless.Texture2DHandle,
  normal:             bindless.Texture2DHandle,
  emissive:           bindless.Texture2DHandle,
}

Sprite :: struct {
  texture:       bindless.Texture2DHandle,
  frame_columns: u32, // Number of columns in sprite sheet
  frame_rows:    u32, // Number of rows in sprite sheet
  frame_index:   u32, // Cell shown, row-major
}

Emitter :: struct {
  initial_velocity:  [3]f32,
  size_start:        f32,
  color_start:       [4]f32,
  color_end:         [4]f32,
  emission_rate:     f32,
  particle_lifetime: f32,
  position_spread:   f32,
  velocity_spread:   f32,
  size_end:          f32,
  weight:            f32,
  weight_spread:     f32,
  // Fractional carryover of emissions; advanced each tick by update. Lives on
  // CPU so per-frame restaging does not clobber sub-particle progress when
  // emission_rate * delta_time < 1.
  time_accumulator:  f32,
  pending_emit:      u32,
  enabled:           b32,
  texture_handle:    bindless.Texture2DHandle,
  // Transform slot the particles spawn from. Set by attach.
  slot:              u32,
}

ForceField :: struct {
  tangent_strength: f32,
  strength:         f32,
  area_of_effect:   f32,
  enabled:          b32,
  // Transform slot the field is centered on. Set by attach.
  slot:             u32,
}

@(private)
init_resource_pools :: proc(self: ^Manager) {
  cont.init(&self.meshes, MAX_MESHES, RETIRE_GRACE)
  cont.init(&self.materials, MAX_MATERIALS, RETIRE_GRACE)
  cont.init(&self.sprites, MAX_SPRITES, RETIRE_GRACE)
  cont.init(&self.emitters, MAX_EMITTERS, RETIRE_GRACE)
  cont.init(&self.forcefields, MAX_FORCE_FIELDS, RETIRE_GRACE)
  init_builtin_materials(self)
  init_builtin_meshes(self)
}

@(private)
destroy_resource_pools :: proc(self: ^Manager) {
  // the mesh manager is already gone: release CPU memory only
  cont.flush(&self.meshes, nil, mesh_retire)
  cont.flush(&self.materials, nil, nil)
  cont.destroy(&self.meshes, mesh_release_memory)
  cont.destroy(&self.materials, proc(_: ^Material) {})
  cont.destroy(&self.sprites, proc(_: ^Sprite) {})
  cont.destroy(&self.emitters, proc(_: ^Emitter) {})
  cont.destroy(&self.forcefields, proc(_: ^ForceField) {})
}

@(private)
tick_resource_pools :: proc(self: ^Manager) {
  cont.tick(&self.meshes, self, mesh_retire)
  cont.tick(&self.materials, nil, nil)
  cont.tick(&self.emitters, nil, nil)
  cont.tick(&self.forcefields, nil, nil)
  cont.tick(&self.sprites, nil, nil)
}

// Boundary accessors. Keep `containers` invisible to user code.
mesh :: proc(r: ^Manager, h: MeshHandle) -> (^Mesh, bool) #optional_ok {
  return cont.get(r.meshes, h)
}

material :: proc(r: ^Manager, h: MaterialHandle) -> (^Material, bool) #optional_ok {
  return cont.get(r.materials, h)
}

sprite :: proc(r: ^Manager, h: SpriteHandle) -> (^Sprite, bool) #optional_ok {
  return cont.get(r.sprites, h)
}

emitter :: proc(r: ^Manager, h: EmitterHandle) -> (^Emitter, bool) #optional_ok {
  return cont.get(r.emitters, h)
}

forcefield :: proc(r: ^Manager, h: ForceFieldHandle) -> (^ForceField, bool) #optional_ok {
  return cont.get(r.forcefields, h)
}

// ---------- meshes ----------

// Creates a mesh. Geometry ownership is transferred to the mesh; the GPU copy
// is uploaded by flush. With auto_purge the CPU geometry is released right
// after that upload.
create_mesh :: proc(
  self: ^Manager,
  geometry_data: mesh.Geometry,
  auto_purge: bool = false,
) -> (
  handle: MeshHandle,
  ok: bool,
) #optional_ok {
  m: ^Mesh
  handle, m, ok = cont.alloc(&self.meshes, MeshHandle)
  if !ok {
    mesh.delete_geometry(geometry_data)
    return
  }
  m.cpu_geometry = geometry_data
  m.auto_purge_cpu_geometry = auto_purge
  stage(self, &self.internal.staging.meshes, handle.index)
  return handle, true
}

destroy_mesh :: proc(self: ^Manager, handle: MeshHandle) {
  cont.free_deferred(&self.meshes, handle)
}

@(private)
mesh_release_memory :: proc(self: ^Mesh) {
  g, has_geom := self.cpu_geometry.?
  if !has_geom do return
  mesh.delete_geometry(g)
  self.cpu_geometry = nil
}

// Pool retire callback: no frame in flight reads the mesh any more. `user` is
// the Manager, or nil once the mesh manager is destroyed.
@(private)
mesh_retire :: proc(item: ^Mesh, user: rawptr) {
  if self := (^Manager)(user); self != nil {
    bindless.free_mesh(&self.mesh_manager, item.allocations)
  }
  mesh_release_memory(item)
}

// ---------- textures ----------

Texture2DHandle :: bindless.Texture2DHandle

// Load an image file (png, jpg, hdr, ...) into a bindless 2D texture.
create_texture_from_path :: proc(
  self: ^Manager,
  path: string,
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips: bool = false,
) -> (
  handle: Texture2DHandle,
  ret: vk.Result,
) {
  return bindless.create_texture_2d_from_path(&self.gctx, &self.texture_manager, path, format, generate_mips)
}

// Decode an encoded image (png, jpg, ...) held in memory into a bindless 2D texture.
create_texture_from_data :: proc(
  self: ^Manager,
  data: []u8,
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips: bool = false,
) -> (
  handle: Texture2DHandle,
  ret: vk.Result,
) {
  return bindless.create_texture_2d_from_data(&self.gctx, &self.texture_manager, data, format, generate_mips)
}

destroy_texture :: proc(self: ^Manager, handle: Texture2DHandle) {
  bindless.free_texture_2d(&self.texture_manager, &self.gctx, handle)
}

// ---------- materials ----------

create_material :: proc(
  self: ^Manager,
  features: ShaderFeatureSet = {},
  type: MaterialType = .PBR,
  albedo_handle: bindless.Texture2DHandle = {},
  metallic_roughness_handle: bindless.Texture2DHandle = {},
  normal_handle: bindless.Texture2DHandle = {},
  emissive_handle: bindless.Texture2DHandle = {},
  metallic_value: f32 = 0.0,
  roughness_value: f32 = 1.0,
  emissive_value: f32 = 0.0,
  base_color_factor: [4]f32 = {1.0, 1.0, 1.0, 1.0},
) -> (
  handle: MaterialHandle,
  ok: bool,
) #optional_ok {
  mat: ^Material
  handle, mat = cont.alloc(&self.materials, MaterialHandle) or_return
  mat^ = {
    type               = type,
    features           = features,
    albedo             = albedo_handle,
    metallic_roughness = metallic_roughness_handle,
    normal             = normal_handle,
    emissive           = emissive_handle,
    metallic_value     = metallic_value,
    roughness_value    = roughness_value,
    emissive_value     = emissive_value,
    base_color_factor  = base_color_factor,
  }
  stage(self, &self.internal.staging.materials, handle.index)
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

destroy_material :: proc(self: ^Manager, handle: MaterialHandle) -> bool {
  cont.free_deferred(&self.materials, handle) or_return
  stage(self, &self.internal.staging.materials, handle.index)
  return true
}

// Stage a material whose fields were edited directly through `material`.
mark_material_dirty :: proc(self: ^Manager, handle: MaterialHandle) {
  stage(self, &self.internal.staging.materials, handle.index)
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
  self.builtin_meshes[.CUBE] = create_mesh(self, mesh.make_cube(), true)
  self.builtin_meshes[.SPHERE] = create_mesh(self, mesh.make_sphere(), true)
  self.builtin_meshes[.QUAD_XZ] = create_mesh(self, mesh.make_quad(), true)
  self.builtin_meshes[.QUAD_XY] = create_mesh(self, mesh.make_billboard_quad(), true)
  self.builtin_meshes[.CONE] = create_mesh(self, mesh.make_cone(), true)
  self.builtin_meshes[.CYLINDER] = create_mesh(self, mesh.make_cylinder(), true)
}

// ---------- sprites ----------

create_sprite :: proc(
  self: ^Manager,
  texture: bindless.Texture2DHandle,
  frame_columns: u32 = 1,
  frame_rows: u32 = 1,
) -> (
  handle: SpriteHandle,
  ok: bool,
) #optional_ok {
  s: ^Sprite
  handle, s = cont.alloc(&self.sprites, SpriteHandle) or_return
  s^ = {
    texture       = texture,
    frame_columns = frame_columns,
    frame_rows    = frame_rows,
  }
  stage(self, &self.internal.staging.sprites, handle.index)
  return handle, true
}

destroy_sprite :: proc(self: ^Manager, handle: SpriteHandle) {
  if cont.free_deferred(&self.sprites, handle) {
    stage(self, &self.internal.staging.sprites, handle.index)
  }
}

// Show cell `frame` (row-major, wrapped to the sheet size) of the sprite
// sheet. Animate by calling this as time advances.
set_sprite_frame :: proc(self: ^Manager, handle: SpriteHandle, frame: u32) -> bool {
  s := cont.get(self.sprites, handle) or_return
  s.frame_index = frame % max(s.frame_columns * s.frame_rows, 1)
  stage(self, &self.internal.staging.sprites, handle.index)
  return true
}

// ---------- emitters ----------

create_emitter :: proc(
  self: ^Manager,
  texture_handle: bindless.Texture2DHandle = {},
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
    texture_handle    = texture_handle,
    enabled           = true,
  }
  stage(self, &self.internal.staging.emitters, handle.index)
  return handle, true
}

destroy_emitter :: proc(self: ^Manager, handle: EmitterHandle) -> bool {
  cont.free_deferred(&self.emitters, handle) or_return
  stage(self, &self.internal.staging.emitters, handle.index)
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
  handle, ff := cont.alloc(&self.forcefields, ForceFieldHandle) or_return
  ff^ = {
    tangent_strength = tangent_strength,
    strength         = strength,
    area_of_effect   = area_of_effect,
    enabled          = true,
  }
  stage(self, &self.internal.staging.forcefields, handle.index)
  return handle, true
}

destroy_forcefield :: proc(self: ^Manager, handle: ForceFieldHandle) -> bool {
  cont.free_deferred(&self.forcefields, handle) or_return
  stage(self, &self.internal.staging.forcefields, handle.index)
  return true
}

// Advance the render clock (debug line lifetimes) and emitter accumulators,
// and stage every emitter and force field, so edits made through `emitter`
// and `forcefield` reach the GPU. Call once per update tick; `flush` uploads
// the results.
update :: proc(self: ^Manager, delta_time: f32) {
  debug_line.advance(&self.internal.debug_line_renderer, delta_time)
  if delta_time <= 0 do return
  it := cont.iterator(&self.emitters)
  for em, handle in cont.next(&it, EmitterHandle) {
    if !bool(em.enabled) {
      em.time_accumulator = 0
      em.pending_emit = 0
    } else {
      em.time_accumulator += em.emission_rate * delta_time
      emit := u32(em.time_accumulator)
      em.time_accumulator -= f32(emit)
      em.pending_emit = emit
    }
    stage(self, &self.internal.staging.emitters, handle.index)
  }
  ff_it := cont.iterator(&self.forcefields)
  for _, handle in cont.next(&ff_it, ForceFieldHandle) {
    stage(self, &self.internal.staging.forcefields, handle.index)
  }
  particles.set_params(
    &self.internal.particles,
    u32(min(len(self.emitters.entries), MAX_EMITTERS)),
    u32(min(len(self.forcefields.entries), MAX_FORCE_FIELDS)),
    delta_time,
  )
}
