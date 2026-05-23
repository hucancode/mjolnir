package mjolnir

// Engine-rooted shortcuts: every public proc that today takes ^World,
// ^physics.World, or ^nav.NavigationSystem also has a sibling here that
// takes ^Engine. Pure forwarders — zero behavior change.
//
// Naming policy: same name as the underlying world/physics/nav proc unless
// it would shadow an existing mjolnir top-level. Eliminates the &engine.world
// / &engine.physics / &engine.nav plumbing from user code.

import "animation"
import "gpu"
import nav "navigation"
import "physics"
import "world"

// Re-export common handle/enum types so user code only imports `mjolnir`.
// These are plain aliases — same memory layout, interchangeable with the
// originals in `world.*`.
NodeHandle     :: world.NodeHandle
MeshHandle     :: world.MeshHandle
MaterialHandle :: world.MaterialHandle
CameraHandle   :: world.CameraHandle
ClipHandle     :: world.ClipHandle
EmitterHandle  :: world.EmitterHandle
SpriteHandle   :: world.SpriteHandle
Primitive      :: world.Primitive
Color          :: world.Color
NodeTag        :: world.NodeTag
NodeTagSet     :: world.NodeTagSet
MeshAttachment :: world.MeshAttachment
NodeAttachment :: world.NodeAttachment
SpiderLegSpec  :: world.SpiderLegSpec

// ---------- spawn / despawn / attach ----------

spawn :: proc(
  engine: ^Engine,
  position: [3]f32 = {0, 0, 0},
  attachment: world.NodeAttachment = nil,
) -> (world.NodeHandle, bool) #optional_ok {
  return world.spawn(&engine.world, position, attachment)
}

spawn_child :: proc(
  engine: ^Engine,
  parent: world.NodeHandle,
  position: [3]f32 = {0, 0, 0},
  attachment: world.NodeAttachment = nil,
) -> (world.NodeHandle, bool) #optional_ok {
  return world.spawn_child(&engine.world, parent, position, attachment)
}

spawn_mesh :: proc(
  engine: ^Engine,
  mesh_handle: world.MeshHandle,
  material_handle: world.MaterialHandle,
  position: [3]f32 = {0, 0, 0},
  cast_shadow: bool = true,
) -> (world.NodeHandle, bool) #optional_ok {
  return world.spawn_mesh(&engine.world, mesh_handle, material_handle, position, cast_shadow)
}

spawn_primitive_mesh :: proc(
  engine: ^Engine,
  primitive: world.Primitive = .CUBE,
  color: world.Color = .WHITE,
  position: [3]f32 = {0, 0, 0},
  rotation_angle: f32 = 0,
  rotation_axis: [3]f32 = {0, 1, 0},
  scale_factor: f32 = 1.0,
  cast_shadow: bool = true,
) -> (world.NodeHandle, bool) #optional_ok {
  return world.spawn_primitive_mesh(
    &engine.world, primitive, color, position,
    rotation_angle, rotation_axis, scale_factor, cast_shadow,
  )
}

spawn_light_directional :: proc(
  engine: ^Engine,
  position: [3]f32 = {0, 0, 0},
  color: [4]f32 = {1, 1, 1, 1},
  radius: f32 = 10.0,
  cast_shadow: bool = false,
) -> (world.NodeHandle, bool) #optional_ok {
  return world.spawn_light_directional(&engine.world, position, color, radius, cast_shadow)
}

spawn_light_point :: proc(
  engine: ^Engine,
  position: [3]f32 = {0, 0, 0},
  color: [4]f32 = {1, 1, 1, 1},
  radius: f32 = 10.0,
  cast_shadow: bool = true,
) -> (world.NodeHandle, bool) #optional_ok {
  return world.spawn_light_point(&engine.world, position, color, radius, cast_shadow)
}

spawn_light_spot :: proc(
  engine: ^Engine,
  position: [3]f32 = {0, 0, 0},
  color: [4]f32 = {1, 1, 1, 1},
  radius: f32 = 10.0,
  angle: f32 = 0.628318530718, // math.PI * 0.2
  cast_shadow: bool = true,
) -> (world.NodeHandle, bool) #optional_ok {
  return world.spawn_light_spot(&engine.world, position, color, radius, angle, cast_shadow)
}

spawn_emitter :: proc(
  engine: ^Engine,
  position: [3]f32 = {0, 0, 0},
  texture: gpu.Texture2DHandle = {},
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
) -> (world.NodeHandle, bool) #optional_ok {
  return world.spawn_emitter(
    &engine.world, position, texture, emission_rate,
    initial_velocity, velocity_spread, color_start, color_end,
    aabb_min, aabb_max, particle_lifetime, position_spread,
    size_start, size_end, weight, weight_spread,
  )
}

spawn_forcefield :: proc(
  engine: ^Engine,
  position: [3]f32 = {0, 0, 0},
  area_of_effect: f32 = 5.0,
  strength: f32 = 1.0,
  tangent_strength: f32 = 0.0,
) -> (world.NodeHandle, bool) #optional_ok {
  return world.spawn_forcefield(&engine.world, position, area_of_effect, strength, tangent_strength)
}

despawn :: proc(engine: ^Engine, handle: world.NodeHandle) -> bool {
  return world.despawn(&engine.world, handle)
}

attach :: proc(engine: ^Engine, parent, child: world.NodeHandle) {
  world.attach(engine.world.nodes, parent, child)
}

// ---------- transforms ----------

@(private="file") _translate_xyz :: proc(e: ^Engine, h: world.NodeHandle, x: f32 = 0, y: f32 = 0, z: f32 = 0) {
  world.translate(&e.world, h, x, y, z)
}
@(private="file") _translate_vec :: proc(e: ^Engine, h: world.NodeHandle, v: [3]f32) {
  world.translate(&e.world, h, v)
}
translate :: proc { _translate_xyz, _translate_vec }

@(private="file") _translate_by_xyz :: proc(e: ^Engine, h: world.NodeHandle, x: f32 = 0, y: f32 = 0, z: f32 = 0) {
  world.translate_by(&e.world, h, x, y, z)
}
@(private="file") _translate_by_vec :: proc(e: ^Engine, h: world.NodeHandle, v: [3]f32) {
  world.translate_by(&e.world, h, v)
}
translate_by :: proc { _translate_by_xyz, _translate_by_vec }

@(private="file") _rotate_quat :: proc(e: ^Engine, h: world.NodeHandle, q: quaternion128) {
  world.rotate(&e.world, h, q)
}
@(private="file") _rotate_angle :: proc(e: ^Engine, h: world.NodeHandle, angle: f32, axis: [3]f32 = {0, 1, 0}) {
  world.rotate(&e.world, h, angle, axis)
}
rotate :: proc { _rotate_quat, _rotate_angle }

@(private="file") _rotate_by_quat :: proc(e: ^Engine, h: world.NodeHandle, q: quaternion128) {
  world.rotate_by(&e.world, h, q)
}
@(private="file") _rotate_by_angle :: proc(e: ^Engine, h: world.NodeHandle, angle: f32, axis: [3]f32 = {0, 1, 0}) {
  world.rotate_by(&e.world, h, angle, axis)
}
rotate_by :: proc { _rotate_by_quat, _rotate_by_angle }

@(private="file") _scale_uniform :: proc(e: ^Engine, h: world.NodeHandle, s: f32) {
  world.scale(&e.world, h, s)
}
@(private="file") _scale_vec :: proc(e: ^Engine, h: world.NodeHandle, v: [3]f32) {
  world.scale(&e.world, h, v)
}
scale :: proc { _scale_uniform, _scale_vec }

scale_xyz :: proc(e: ^Engine, h: world.NodeHandle, x, y, z: f32) {
  world.scale_xyz(&e.world, h, x, y, z)
}

// ---------- accessors ----------

node :: proc(engine: ^Engine, h: world.NodeHandle) -> (^world.Node, bool) #optional_ok {
  return world.node(&engine.world, h)
}

mesh :: proc(engine: ^Engine, h: world.MeshHandle) -> (^world.Mesh, bool) #optional_ok {
  return world.mesh(&engine.world, h)
}

material :: proc(engine: ^Engine, h: world.MaterialHandle) -> (^world.Material, bool) #optional_ok {
  return world.material(&engine.world, h)
}

camera :: proc(engine: ^Engine, h: world.CameraHandle) -> (^world.Camera, bool) #optional_ok {
  return world.camera(&engine.world, h)
}

main_camera :: proc(engine: ^Engine) -> (^world.Camera, bool) #optional_ok {
  return world.camera(&engine.world, engine.world.main_camera)
}

main_camera_handle :: proc(engine: ^Engine) -> world.CameraHandle {
  return engine.world.main_camera
}

valid :: proc(engine: ^Engine, h: world.NodeHandle) -> bool {
  return world.valid(&engine.world, h)
}

point_light :: proc(engine: ^Engine, h: world.NodeHandle) -> (^world.PointLightAttachment, bool) #optional_ok {
  return world.point_light(&engine.world, h)
}

directional_light :: proc(engine: ^Engine, h: world.NodeHandle) -> (^world.DirectionalLightAttachment, bool) #optional_ok {
  return world.directional_light(&engine.world, h)
}

spot_light :: proc(engine: ^Engine, h: world.NodeHandle) -> (^world.SpotLightAttachment, bool) #optional_ok {
  return world.spot_light(&engine.world, h)
}

// First child of `root` that carries a mesh attachment. Returns just the child
// node handle — collapses the 3-line traversal common in animation examples.
mesh_child :: proc(engine: ^Engine, root: world.NodeHandle) -> (world.NodeHandle, bool) #optional_ok {
  child, _, _, ok := world.find_first_mesh_child(&engine.world, root)
  return child, ok
}

// First skinned-mesh child of `root`. Walks `root`'s children, returns the
// first that carries a MeshAttachment whose mesh has skinning data.
// Collapses the 7-line setup boilerplate from animation/IK/tail/spider examples.
skinned_mesh :: proc(engine: ^Engine, root: world.NodeHandle) -> (world.NodeHandle, bool) #optional_ok {
  child, _, att, ok := world.find_first_mesh_child(&engine.world, root)
  if !ok do return {}, false
  m, has_m := world.mesh(&engine.world, att.handle)
  if !has_m do return {}, false
  if _, has_skin := m.skinning.?; !has_skin do return {}, false
  return child, true
}

bone_rest_position :: proc(engine: ^Engine, mesh_handle: world.MeshHandle, name: string) -> (pos: [3]f32, ok: bool) #optional_ok {
  m, has_m := world.mesh(&engine.world, mesh_handle)
  if !has_m do return {}, false
  return world.bone_rest_position(m, name)
}

bone_rest_offset :: proc(engine: ^Engine, mesh_handle: world.MeshHandle, root_name, tip_name: string) -> (off: [3]f32, ok: bool) #optional_ok {
  m, has_m := world.mesh(&engine.world, mesh_handle)
  if !has_m do return {}, false
  return world.bone_rest_offset(m, root_name, tip_name)
}

node_mesh :: proc(engine: ^Engine, h: world.NodeHandle) -> (^world.Mesh, bool) #optional_ok {
  att, ok := world.mesh_attachment(&engine.world, h)
  if !ok do return nil, false
  return world.mesh(&engine.world, att.handle)
}

tag :: proc(engine: ^Engine, h: world.NodeHandle, tags: world.NodeTagSet) -> bool {
  return world.tag_node(&engine.world, h, tags)
}

untag :: proc(engine: ^Engine, h: world.NodeHandle, tags: world.NodeTagSet) -> bool {
  return world.untag_node(&engine.world, h, tags)
}

// ---------- camera ----------

main_camera_look_at :: proc(engine: ^Engine, from, to: [3]f32) {
  world.main_camera_look_at(&engine.world, from, to)
}

mark_camera_dirty :: proc(engine: ^Engine, h: world.CameraHandle) {
  world.mark_camera_dirty(&engine.world, h)
}

// ---------- materials & meshes ----------

material_pbr :: proc(
  engine: ^Engine,
  base_color: [4]f32 = {1, 1, 1, 1},
  metallic: f32 = 0.0,
  roughness: f32 = 1.0,
  emissive: f32 = 0.0,
) -> (world.MaterialHandle, bool) #optional_ok {
  return world.material_pbr(&engine.world, base_color, metallic, roughness, emissive)
}

material_textured :: proc(
  engine: ^Engine,
  albedo: gpu.Texture2DHandle = {},
  metallic_roughness: gpu.Texture2DHandle = {},
  normal: gpu.Texture2DHandle = {},
  emissive_tex: gpu.Texture2DHandle = {},
  occlusion: gpu.Texture2DHandle = {},
  base_color: [4]f32 = {1, 1, 1, 1},
  metallic: f32 = 0.0,
  roughness: f32 = 1.0,
  emissive: f32 = 0.0,
) -> (world.MaterialHandle, bool) #optional_ok {
  return world.material_textured(
    &engine.world, albedo, metallic_roughness, normal, emissive_tex, occlusion,
    base_color, metallic, roughness, emissive,
  )
}

material_unlit :: proc(
  engine: ^Engine,
  base_color: [4]f32 = {1, 1, 1, 1},
  albedo: gpu.Texture2DHandle = {},
) -> (world.MaterialHandle, bool) #optional_ok {
  return world.material_unlit(&engine.world, base_color, albedo)
}

material_wireframe :: proc(
  engine: ^Engine,
  base_color: [4]f32 = {1, 1, 1, 1},
) -> (world.MaterialHandle, bool) #optional_ok {
  return world.material_wireframe(&engine.world, base_color)
}

material_transparent :: proc(
  engine: ^Engine,
  base_color: [4]f32 = {1, 1, 1, 0.5},
) -> (world.MaterialHandle, bool) #optional_ok {
  return world.material_transparent(&engine.world, base_color)
}

create_material :: proc(
  engine: ^Engine,
  features: world.ShaderFeatureSet = {},
  type: world.MaterialType = .PBR,
  albedo_handle: gpu.Texture2DHandle = {},
  metallic_roughness_handle: gpu.Texture2DHandle = {},
  normal_handle: gpu.Texture2DHandle = {},
  emissive_handle: gpu.Texture2DHandle = {},
  occlusion_handle: gpu.Texture2DHandle = {},
  metallic_value: f32 = 0.0,
  roughness_value: f32 = 1.0,
  emissive_value: f32 = 0.0,
  base_color_factor: [4]f32 = {1, 1, 1, 1},
) -> (world.MaterialHandle, bool) #optional_ok {
  return world.create_material(
    &engine.world, features, type, albedo_handle,
    metallic_roughness_handle, normal_handle, emissive_handle, occlusion_handle,
    metallic_value, roughness_value, emissive_value, base_color_factor,
  )
}

builtin_mesh :: proc(engine: ^Engine, primitive: world.Primitive) -> world.MeshHandle {
  return world.get_builtin_mesh(&engine.world, primitive)
}

builtin_material :: proc(engine: ^Engine, color: world.Color) -> world.MaterialHandle {
  return world.get_builtin_material(&engine.world, color)
}

create_mesh :: proc(
  engine: ^Engine,
  geom: $T,
  auto_purge_cpu: bool = true,
) -> (world.MeshHandle, bool) #optional_ok {
  return world.create_mesh(&engine.world, geom, auto_purge_cpu)
}

// ---------- setters (mutate + auto-stage) ----------

set_light_color :: proc(engine: ^Engine, h: world.NodeHandle, color: [4]f32) {
  world.set_light_color(&engine.world, h, color)
}

set_light_intensity :: proc(engine: ^Engine, h: world.NodeHandle, intensity: f32) {
  world.set_light_intensity(&engine.world, h, intensity)
}

set_light_radius :: proc(engine: ^Engine, h: world.NodeHandle, radius: f32) {
  world.set_light_radius(&engine.world, h, radius)
}

// Mark an existing light's GPU data dirty. Use after mutating fields without
// a dedicated setter (e.g. SpotLightAttachment.angle_outer / angle_inner).
mark_light_dirty :: proc(engine: ^Engine, h: world.NodeHandle) {
  world.mark_light_dirty(&engine.world, h)
}

set_material_handle :: proc(engine: ^Engine, h: world.NodeHandle, m: world.MaterialHandle) {
  world.set_material_handle(&engine.world, h, m)
}

set_mesh_handle :: proc(engine: ^Engine, h: world.NodeHandle, m: world.MeshHandle) {
  world.set_mesh_handle(&engine.world, h, m)
}

stage_material_data :: proc(engine: ^Engine, h: world.MaterialHandle) {
  world.stage_material_data(&engine.world.staging, h)
}

// ---------- animation ----------

play_animation :: proc(
  engine: ^Engine,
  node_handle: world.NodeHandle,
  name: string,
  mode: animation.PlayMode = .LOOP,
  speed: f32 = 1.0,
) -> bool {
  return world.play_animation(&engine.world, node_handle, name, mode, speed)
}

add_animation_layer :: proc(
  engine: ^Engine,
  node_handle: world.NodeHandle,
  animation_name: string,
  weight: f32 = 1.0,
  mode: animation.PlayMode = .LOOP,
  speed: f32 = 1.0,
  layer_index: int = -1,
  blend_mode: animation.BlendMode = .REPLACE,
) -> (int, bool) #optional_ok {
  return world.add_animation_layer(
    &engine.world, node_handle, animation_name,
    weight, mode, speed, layer_index, blend_mode,
  )
}

set_animation_layer_weight :: proc(
  engine: ^Engine,
  node_handle: world.NodeHandle,
  layer_index: int,
  weight: f32,
) -> bool {
  return world.set_animation_layer_weight(&engine.world, node_handle, layer_index, weight)
}

transition_to_animation :: proc(
  engine: ^Engine,
  node_handle: world.NodeHandle,
  animation_name: string,
  duration: f32,
  from_layer: int = 0,
  to_layer: int = 1,
  mode: animation.PlayMode = .LOOP,
  speed: f32 = 1.0,
) -> bool {
  return world.transition_to_animation(
    &engine.world, node_handle, animation_name, duration,
    from_layer, to_layer, .Linear, .REPLACE, mode, speed,
  )
}

add_ik_layer :: proc(
  engine: ^Engine,
  node_handle: world.NodeHandle,
  bone_names: []string,
  target_pos: [3]f32,
  pole_pos: [3]f32,
  weight: f32 = 1.0,
  max_iterations: int = 10,
  tolerance: f32 = 0.001,
  layer_index: int = -1,
  space: animation.IKTargetSpace = .LOCAL,
) -> (int, bool) #optional_ok {
  return world.add_ik_layer(
    &engine.world, node_handle, bone_names, target_pos, pole_pos,
    weight, max_iterations, tolerance, layer_index, space,
  )
}

add_ik_layer_chain :: proc(
  engine: ^Engine,
  node_handle: world.NodeHandle,
  root_name, tip_name: string,
  target_pos: [3]f32,
  pole_pos: [3]f32,
  weight: f32 = 1.0,
  max_iterations: int = 10,
  tolerance: f32 = 0.001,
  layer_index: int = -1,
  constraints: []animation.IKBoneConstraint = nil,
  space: animation.IKTargetSpace = .LOCAL,
) -> (int, world.AnimationError) {
  return world.add_ik_layer_chain(
    &engine.world, node_handle, root_name, tip_name, target_pos, pole_pos,
    weight, max_iterations, tolerance, layer_index, constraints, space,
  )
}

set_ik_layer_target :: proc(
  engine: ^Engine,
  node_handle: world.NodeHandle,
  layer_index: int,
  target_pos: [3]f32,
  pole_pos: [3]f32,
) -> bool {
  return world.set_ik_layer_target(&engine.world, node_handle, layer_index, target_pos, pole_pos)
}

add_tail_modifier_layer :: proc(
  engine: ^Engine,
  node_handle: world.NodeHandle,
  root_bone_name: string,
  tail_length: u32,
  propagation_speed: f32 = 0.5,
  damping: f32 = 0.9,
  weight: f32 = 1.0,
  layer_index: int = -1,
  reverse_chain: bool = false,
  stretch: bool = false,
) -> (int, bool) #optional_ok {
  return world.add_tail_modifier_layer(
    &engine.world, node_handle, root_bone_name, tail_length,
    propagation_speed, damping, weight, layer_index, reverse_chain, stretch,
  )
}

set_tail_modifier_params :: proc(
  engine: ^Engine,
  node_handle: world.NodeHandle,
  layer_index: int,
  propagation_speed: Maybe(f32) = nil,
  damping: Maybe(f32) = nil,
  stretch: Maybe(bool) = nil,
) -> bool {
  return world.set_tail_modifier_params(
    &engine.world, node_handle, layer_index, propagation_speed, damping, stretch,
  )
}

add_path_modifier_layer :: proc(
  engine: ^Engine,
  node_handle: world.NodeHandle,
  root_bone_name: string,
  tail_length: u32,
  path: [][3]f32,
  offset: f32 = 0.0,
  length: f32 = 0.0,
  speed: f32 = 0.0,
  loop: bool = false,
  closed: bool = false,
  weight: f32 = 1.0,
  layer_index: int = -1,
) -> (int, bool) #optional_ok {
  return world.add_path_modifier_layer(
    &engine.world, node_handle, root_bone_name, tail_length, path,
    offset, length, speed, loop, closed, weight, layer_index,
  )
}

set_path_modifier_params :: proc(
  engine: ^Engine,
  node_handle: world.NodeHandle,
  layer_index: int,
  path: Maybe([][3]f32) = nil,
  offset: Maybe(f32) = nil,
  length: Maybe(f32) = nil,
  speed: Maybe(f32) = nil,
  loop: Maybe(bool) = nil,
  closed: Maybe(bool) = nil,
) -> bool {
  return world.set_path_modifier_params(
    &engine.world, node_handle, layer_index,
    path, offset, length, speed, loop, closed,
  )
}

add_spider_leg_modifier_layer :: proc(
  engine: ^Engine,
  node_handle: world.NodeHandle,
  legs_spec: []world.SpiderLegSpec,
  weight: f32 = 1.0,
  layer_index: int = -1,
) -> (int, bool) #optional_ok {
  return world.add_spider_leg_modifier_layer(&engine.world, node_handle, legs_spec, weight, layer_index)
}

set_spider_leg_modifier_params :: proc(
  engine: ^Engine,
  node_handle: world.NodeHandle,
  layer_index: int,
  leg_index: int,
  lift_height: Maybe(f32) = nil,
  lift_frequency: Maybe(f32) = nil,
  lift_duration: Maybe(f32) = nil,
  time_offset: Maybe(f32) = nil,
) -> bool {
  return world.set_spider_leg_modifier_params(
    &engine.world, node_handle, layer_index, leg_index,
    lift_height, lift_frequency, lift_duration, time_offset,
  )
}

get_spider_leg_target :: proc(
  engine: ^Engine,
  node_handle: world.NodeHandle,
  layer_index: int,
  leg_index: int,
) -> (^[3]f32, bool) #optional_ok {
  return world.get_spider_leg_target(&engine.world, node_handle, layer_index, leg_index)
}

// ---------- navigation ----------

find_path :: proc(
  engine: ^Engine,
  start, goal: [3]f32,
  max_points: i32 = 256,
) -> [][3]f32 {
  return nav.find_path(&engine.nav, start, goal, max_points)
}

find_nearest_point :: proc(
  engine: ^Engine,
  pos: [3]f32,
  extents: [3]f32 = {1, 1, 1},
) -> ([3]f32, bool) #optional_ok {
  return nav.find_nearest_point(&engine.nav, pos, extents)
}

// ---------- physics ----------

create_static_body :: proc(
  engine: ^Engine,
  position: [3]f32,
  rotation: quaternion128,
  collider: physics.Collider,
) -> physics.StaticRigidBodyHandle {
  return physics.create_static_body(&engine.physics, position, rotation, collider)
}

create_dynamic_body :: proc(
  engine: ^Engine,
  position: [3]f32,
  rotation: quaternion128,
  mass: f32,
  collider: physics.Collider,
) -> physics.DynamicRigidBodyHandle {
  return physics.create_dynamic_body(&engine.physics, position, rotation, mass, collider)
}

get_dynamic_body :: #force_inline proc(
  engine: ^Engine,
  h: physics.DynamicRigidBodyHandle,
) -> (^physics.DynamicRigidBody, bool) #optional_ok {
  return physics.get_dynamic_body(&engine.physics, h)
}

spawn_static :: proc(
  engine: ^Engine,
  position: [3]f32,
  collider: physics.Collider,
  mesh: world.MeshHandle = {},
  material: world.MaterialHandle = {},
  visual_scale: [3]f32 = {1, 1, 1},
  cast_shadow: bool = true,
) -> world.NodeHandle {
  parent, _ := world.spawn(&engine.world, position)
  n, _ := world.node(&engine.world, parent)
  physics.create_static_body(&engine.physics, n.transform.position, n.transform.rotation, collider)
  if mesh.generation != 0 {
    visual, _ := world.spawn_child(&engine.world, parent, attachment = world.mesh_attach(mesh, material, cast_shadow))
    if visual_scale != {1, 1, 1} {
      scale_xyz(engine, visual, visual_scale.x, visual_scale.y, visual_scale.z)
    }
  }
  return parent
}

spawn_dynamic :: proc(
  engine: ^Engine,
  position: [3]f32,
  mass: f32,
  collider: physics.Collider,
  mesh: world.MeshHandle = {},
  material: world.MaterialHandle = {},
  visual_scale: [3]f32 = {1, 1, 1},
  cast_shadow: bool = true,
) -> (parent: world.NodeHandle, body: physics.DynamicRigidBodyHandle) {
  parent, _ = world.spawn(&engine.world, position)
  n, _ := world.node(&engine.world, parent)
  body = physics.create_dynamic_body(&engine.physics, n.transform.position, n.transform.rotation, mass, collider)
  if b, ok := physics.get_dynamic_body(&engine.physics, body); ok {
    physics.set_inertia_from_collider(b, collider)
  }
  n.attachment = world.RigidBodyAttachment{body_handle = body}
  if mesh.generation != 0 {
    visual, _ := world.spawn_child(&engine.world, parent, attachment = world.mesh_attach(mesh, material, cast_shadow))
    if visual_scale != {1, 1, 1} {
      scale_xyz(engine, visual, visual_scale.x, visual_scale.y, visual_scale.z)
    }
  }
  return
}
