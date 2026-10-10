package render

import "bindless"
import cont "../containers"
import "mesh"
import "core:math"
import vk "vendor:vulkan"

// CPU-side mesh. GPU vertex/index allocations live in mesh_data_buffer at the
// same index and are (re)built from cpu_geometry by flush.
Mesh :: struct {
  aabb_min:                [3]f32,
  aabb_max:                [3]f32,
  cpu_geometry:            Maybe(mesh.Geometry),
  auto_purge_cpu_geometry: bool,
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
  occlusion:          bindless.Texture2DHandle,
}

Sprite :: struct {
  texture:       bindless.Texture2DHandle,
  frame_columns: u32, // Number of columns in sprite sheet
  frame_rows:    u32, // Number of rows in sprite sheet
  animation:     Maybe(SpriteAnimation),
}

Emitter :: struct {
  initial_velocity:  [3]f32,
  size_start:        f32,
  color_start:       [4]f32,
  color_end:         [4]f32,
  aabb_min:          [3]f32,
  emission_rate:     f32,
  aabb_max:          [3]f32,
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
  cont.tick(&self.meshes, nil, mesh_retire)
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
// is uploaded by flush. With auto_purge the CPU geometry is released once
// every frame in flight has the upload.
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
  m.aabb_min = geometry_data.aabb.min
  m.aabb_max = geometry_data.aabb.max
  m.cpu_geometry = geometry_data
  m.auto_purge_cpu_geometry = auto_purge
  stage(self, &self.internal.staging.meshes, handle.index)
  return handle, true
}

destroy_mesh :: proc(self: ^Manager, handle: MeshHandle) {
  if cont.get(self.meshes, handle) == nil do return
  stage(self, &self.internal.staging.meshes, handle.index, .Remove)
  cont.free_deferred(&self.meshes, handle)
}

@(private)
mesh_release_memory :: proc(self: ^Mesh) {
  g, has_geom := self.cpu_geometry.?
  if !has_geom do return
  mesh.delete_geometry(g)
  self.cpu_geometry = nil
}

@(private)
mesh_retire :: proc(item: ^Mesh, user: rawptr) {
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
  occlusion_handle: bindless.Texture2DHandle = {},
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
    occlusion          = occlusion_handle,
    metallic_value     = metallic_value,
    roughness_value    = roughness_value,
    emissive_value     = emissive_value,
    base_color_factor  = base_color_factor,
  }
  stage(self, &self.internal.staging.materials, handle.index)
  return handle, true
}

// Focused PBR constructor: solid color + metallic/roughness/emissive scalars.
// For textured variants use `material_textured`. For non-PBR use
// `material_unlit`, `material_wireframe`, etc.
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

// Textured PBR material. Pass any subset of texture handles; pass `{}` to skip.
material_textured :: proc(
  self: ^Manager,
  albedo: bindless.Texture2DHandle = {},
  metallic_roughness: bindless.Texture2DHandle = {},
  normal: bindless.Texture2DHandle = {},
  emissive_tex: bindless.Texture2DHandle = {},
  occlusion: bindless.Texture2DHandle = {},
  base_color: [4]f32 = {1, 1, 1, 1},
  metallic: f32 = 0.0,
  roughness: f32 = 1.0,
  emissive: f32 = 0.0,
) -> (MaterialHandle, bool) #optional_ok {
  features: ShaderFeatureSet
  if albedo             != {} do features += {.ALBEDO_TEXTURE}
  if metallic_roughness != {} do features += {.METALLIC_ROUGHNESS_TEXTURE}
  if normal             != {} do features += {.NORMAL_TEXTURE}
  if emissive_tex       != {} do features += {.EMISSIVE_TEXTURE}
  if occlusion          != {} do features += {.OCCLUSION_TEXTURE}
  return create_material(
    self,
    features                  = features,
    type                      = .PBR,
    albedo_handle             = albedo,
    metallic_roughness_handle = metallic_roughness,
    normal_handle             = normal,
    emissive_handle           = emissive_tex,
    occlusion_handle          = occlusion,
    metallic_value            = metallic,
    roughness_value           = roughness,
    emissive_value            = emissive,
    base_color_factor         = base_color,
  )
}

material_unlit :: proc(
  self: ^Manager,
  base_color: [4]f32 = {1, 1, 1, 1},
  albedo: bindless.Texture2DHandle = {},
) -> (MaterialHandle, bool) #optional_ok {
  features: ShaderFeatureSet
  if albedo != {} do features += {.ALBEDO_TEXTURE}
  return create_material(
    self,
    features          = features,
    type              = .UNLIT,
    albedo_handle     = albedo,
    base_color_factor = base_color,
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
  if cont.get(self.materials, handle) == nil do return false
  stage(self, &self.internal.staging.materials, handle.index, .Remove)
  return cont.free_deferred(&self.materials, handle)
}

// Mutate-and-stage an existing material. Only non-nil Maybe fields update.
set_material_pbr_params :: proc(
  self: ^Manager,
  handle: MaterialHandle,
  metallic: Maybe(f32) = nil,
  roughness: Maybe(f32) = nil,
  emissive: Maybe(f32) = nil,
  base_color: Maybe([4]f32) = nil,
) -> bool {
  mat := cont.get(self.materials, handle) or_return
  if v, has := metallic.?;   has do mat.metallic_value    = v
  if v, has := roughness.?;  has do mat.roughness_value   = v
  if v, has := emissive.?;   has do mat.emissive_value    = v
  if v, has := base_color.?; has do mat.base_color_factor = v
  stage(self, &self.internal.staging.materials, handle.index)
  return true
}

// Stage a material whose fields were edited directly through `material`.
mark_material_dirty :: proc(self: ^Manager, handle: MaterialHandle) {
  stage(self, &self.internal.staging.materials, handle.index)
}

// ---------- builtins ----------

get_builtin_material :: proc(self: ^Manager, color: Color) -> MaterialHandle {
  return self.builtin_materials[color]
}

get_builtin_mesh :: proc(self: ^Manager, primitive: Primitive) -> MeshHandle {
  return self.builtin_meshes[primitive]
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
  self.builtin_meshes[.CAPSULE] = create_mesh(self, mesh.make_capsule(), true)
  self.builtin_meshes[.CYLINDER] = create_mesh(self, mesh.make_cylinder(), true)
  self.builtin_meshes[.TORUS] = create_mesh(self, mesh.make_torus(), true)
}

// ---------- sprites ----------

create_sprite :: proc(
  self: ^Manager,
  texture: bindless.Texture2DHandle,
  frame_columns: u32 = 1,
  frame_rows: u32 = 1,
  animation: Maybe(SpriteAnimation) = nil,
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
    animation     = animation,
  }
  stage(self, &self.internal.staging.sprites, handle.index)
  return handle, true
}

destroy_sprite :: proc(self: ^Manager, handle: SpriteHandle) {
  cont.free_deferred(&self.sprites, handle)
}

SpriteAnimationState :: enum {
  PLAYING,
  PAUSED,
  STOPPED,
}

SpriteAnimationMode :: enum {
  ONCE,
  LOOP,
  PINGPONG,
}

SpriteAnimation :: struct {
  frame_count:   u32,
  current_frame: u32,
  fps:           f32,
  time:          f32,
  state:         SpriteAnimationState,
  mode:          SpriteAnimationMode,
  forward:       bool,
}

sprite_animation_init :: proc(
  frame_count: u32,
  fps: f32 = 12.0,
  mode: SpriteAnimationMode = .LOOP,
  forward: bool = true,
) -> SpriteAnimation {
  initial_frame := forward ? 0 : frame_count - 1
  return SpriteAnimation {
    frame_count = frame_count,
    current_frame = initial_frame,
    fps = fps,
    time = 0.0,
    state = .PLAYING,
    mode = mode,
    forward = forward,
  }
}

sprite_animation_update :: proc(anim: ^SpriteAnimation, delta_time: f32) {
  if anim.state != .PLAYING do return
  if anim.frame_count <= 1 do return
  if anim.fps <= 0 do return
  if delta_time <= 0 || delta_time > 1.0 do return
  anim.time += delta_time
  frame_duration := 1.0 / anim.fps
  max_iterations := anim.frame_count * 2
  iteration := u32(0)
  for anim.time >= frame_duration {
    if iteration >= max_iterations {
      frames_to_skip := u32(anim.time / frame_duration)
      anim.time = math.mod(anim.time, frame_duration)
      switch anim.mode {
      case .ONCE:
        if anim.forward {
          anim.current_frame = min(frames_to_skip, anim.frame_count - 1)
        } else {
          if frames_to_skip >= anim.frame_count {
            anim.current_frame = 0
          } else {
            anim.current_frame = anim.frame_count - 1 - frames_to_skip
          }
        }
        anim.state = .STOPPED
      case .LOOP:
        if anim.forward {
          anim.current_frame = frames_to_skip % anim.frame_count
        } else {
          anim.current_frame =
            anim.frame_count - 1 - (frames_to_skip % anim.frame_count)
        }
      case .PINGPONG:
        cycle_length := max(1, (anim.frame_count - 1) * 2)
        position := frames_to_skip % cycle_length
        if position < anim.frame_count {
          anim.current_frame = position
          anim.forward = true
        } else {
          anim.current_frame = cycle_length - position
          anim.forward = false
        }
      }
      break
    }
    anim.time -= frame_duration
    if anim.forward {
      anim.current_frame += 1
      if anim.current_frame >= anim.frame_count {
        switch anim.mode {
        case .ONCE:
          anim.current_frame = anim.frame_count - 1
          anim.state = .STOPPED
          break
        case .LOOP:
          anim.current_frame = 0
        case .PINGPONG:
          anim.current_frame = anim.frame_count - 1
          anim.forward = false
        }
      }
    } else {
      if anim.current_frame == 0 {
        switch anim.mode {
        case .ONCE:
          anim.state = .STOPPED
          break
        case .LOOP:
          anim.current_frame = anim.frame_count - 1
        case .PINGPONG:
          anim.forward = true
        }
      } else {
        anim.current_frame -= 1
      }
    }
    iteration += 1
  }
}

sprite_animation_play :: proc(anim: ^SpriteAnimation) {
  anim.state = .PLAYING
}

sprite_animation_pause :: proc(anim: ^SpriteAnimation) {
  anim.state = .PAUSED
}

sprite_animation_stop :: proc(anim: ^SpriteAnimation) {
  anim.state = .STOPPED
  anim.time = 0.0
  anim.current_frame = anim.forward ? 0 : anim.frame_count - 1
}

sprite_animation_set_frame :: proc(anim: ^SpriteAnimation, frame: u32) {
  anim.current_frame = min(frame, anim.frame_count - 1)
}

sprite_animation_set_mode :: proc(
  anim: ^SpriteAnimation,
  mode: SpriteAnimationMode,
) {
  anim.mode = mode
}

sprite_animation_set_direction :: proc(anim: ^SpriteAnimation, forward: bool) {
  anim.forward = forward
  if anim.state == .STOPPED {
    anim.current_frame = forward ? 0 : anim.frame_count - 1
  }
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
  aabb_min: [3]f32 = {-10, -10, -10},
  aabb_max: [3]f32 = {10, 10, 10},
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
    aabb_min          = aabb_min,
    aabb_max          = aabb_max,
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
  return cont.free_deferred(&self.emitters, handle)
}

// Mutate-and-stage an existing emitter. Only fields with non-nil Maybe values are updated.
set_emitter :: proc(
  self: ^Manager,
  handle: EmitterHandle,
  texture: Maybe(bindless.Texture2DHandle) = nil,
  enabled: Maybe(bool) = nil,
  emission_rate: Maybe(f32) = nil,
  particle_lifetime: Maybe(f32) = nil,
  size_start: Maybe(f32) = nil,
  size_end: Maybe(f32) = nil,
  weight: Maybe(f32) = nil,
  weight_spread: Maybe(f32) = nil,
  position_spread: Maybe(f32) = nil,
  initial_velocity: Maybe([3]f32) = nil,
  velocity_spread: Maybe(f32) = nil,
  color_start: Maybe([4]f32) = nil,
  color_end: Maybe([4]f32) = nil,
  aabb_min: Maybe([3]f32) = nil,
  aabb_max: Maybe([3]f32) = nil,
) -> bool {
  em := cont.get(self.emitters, handle) or_return
  if v, has := texture.?;           has do em.texture_handle    = v
  if v, has := enabled.?;           has do em.enabled           = b32(v)
  if v, has := emission_rate.?;     has do em.emission_rate     = v
  if v, has := particle_lifetime.?; has do em.particle_lifetime = v
  if v, has := size_start.?;        has do em.size_start        = v
  if v, has := size_end.?;          has do em.size_end          = v
  if v, has := weight.?;            has do em.weight            = v
  if v, has := weight_spread.?;     has do em.weight_spread     = v
  if v, has := position_spread.?;   has do em.position_spread   = v
  if v, has := initial_velocity.?;  has do em.initial_velocity  = v
  if v, has := velocity_spread.?;   has do em.velocity_spread   = v
  if v, has := color_start.?;       has do em.color_start       = v
  if v, has := color_end.?;         has do em.color_end         = v
  if v, has := aabb_min.?;          has do em.aabb_min          = v
  if v, has := aabb_max.?;          has do em.aabb_max          = v
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
  return cont.free_deferred(&self.forcefields, handle)
}

// Mutate-and-stage an existing forcefield. `enabled` toggles without losing config.
set_forcefield :: proc(
  self: ^Manager,
  handle: ForceFieldHandle,
  strength: Maybe(f32) = nil,
  tangent_strength: Maybe(f32) = nil,
  area_of_effect: Maybe(f32) = nil,
  enabled: Maybe(bool) = nil,
) -> bool {
  ff := cont.get(self.forcefields, handle) or_return
  if v, has := strength.?;         has do ff.strength         = v
  if v, has := tangent_strength.?; has do ff.tangent_strength = v
  if v, has := area_of_effect.?;   has do ff.area_of_effect   = v
  if v, has := enabled.?;          has do ff.enabled          = b32(v)
  stage(self, &self.internal.staging.forcefields, handle.index)
  return true
}

// Advance sprite animations and emitter accumulators. Call once per update
// tick; `flush` uploads the results.
update :: proc(self: ^Manager, delta_time: f32) {
  if delta_time <= 0 do return
  for &entry, i in self.sprites.entries {
    if !entry.active do continue
    anim_inst, has_anim := &entry.item.animation.?
    if !has_anim do continue
    sprite_animation_update(anim_inst, delta_time)
    stage(self, &self.internal.staging.sprites, u32(i))
  }
  for &entry, i in self.emitters.entries {
    if !entry.active do continue
    em := &entry.item
    if !bool(em.enabled) {
      em.time_accumulator = 0
      em.pending_emit = 0
    } else {
      em.time_accumulator += em.emission_rate * delta_time
      emit := u32(em.time_accumulator)
      em.time_accumulator -= f32(emit)
      em.pending_emit = emit
    }
    stage(self, &self.internal.staging.emitters, u32(i))
  }
  set_particle_params(
    self,
    {
      delta_time       = delta_time,
      emitter_count    = u32(min(len(self.emitters.entries), MAX_EMITTERS)),
      forcefield_count = u32(min(len(self.forcefields.entries), MAX_FORCE_FIELDS)),
    },
  )
}
