package mjolnir

import "animation"
import cont "containers"
import "core:math"
import "core:math/ease"
import "core:math/linalg"
import "core:strings"
import "core:sync"
import "core:time"
import "geometry"
import "gpu"
import "level_manager"
import nav "navigation"
import "navigation/recast"
import "physics"
import "render"
import render_camera "render/camera"
import "render/debug_draw"
import "render/post_process"
import "render/ui"
import "vendor:glfw"
import vk "vendor:vulkan"
import "world"

// Backward compatibility: Re-export types from level_manager
Level_Descriptor :: level_manager.Level_Descriptor
Level_Setup_Proc :: level_manager.Level_Setup_Proc
Level_Teardown_Proc :: level_manager.Level_Teardown_Proc
Level_Finished_Proc :: level_manager.Level_Finished_Proc
Setup_Mode :: level_manager.Setup_Mode
Teardown_Mode :: level_manager.Teardown_Mode
Transition_Pattern :: level_manager.Transition_Pattern
Level_State :: level_manager.Level_State
Level_Manager :: level_manager.Level_Manager

NodeHandle :: world.NodeHandle
MeshHandle :: world.MeshHandle
MaterialHandle :: world.MaterialHandle
Image2DHandle :: world.Image2DHandle
ImageCubeHandle :: world.ImageCubeHandle
CameraHandle :: world.CameraHandle
SphereCameraHandle :: world.SphereCameraHandle
EmitterHandle :: world.EmitterHandle
ForceFieldHandle :: world.ForceFieldHandle
ClipHandle :: world.ClipHandle
SpriteHandle :: world.SpriteHandle
LightHandle :: world.LightHandle
LightType :: world.LightType
DebugObjectHandle :: debug_draw.DebugObjectHandle
DebugRenderStyle :: debug_draw.RenderStyle

// UI types
UIWidgetHandle :: ui.UIWidgetHandle
Mesh2DHandle :: ui.Mesh2DHandle
Quad2DHandle :: ui.Quad2DHandle
Text2DHandle :: ui.Text2DHandle
BoxHandle :: ui.BoxHandle
UIWidget :: ui.Widget
Mesh2D :: ui.Mesh2D
Quad2D :: ui.Quad2D
Text2D :: ui.Text2D
Box :: ui.Box
Vertex2D :: ui.Vertex2D
HorizontalAlign :: ui.HorizontalAlign
VerticalAlign :: ui.VerticalAlign
MouseEvent :: ui.MouseEvent
KeyEvent :: ui.KeyEvent
EventHandlers :: ui.EventHandlers

// NavMeshQuality controls navmesh generation precision vs performance tradeoff
NavMeshQuality :: enum {
  LOW, // Fast generation, coarse mesh - good for large open areas
  MEDIUM, // Balanced quality and performance - recommended default
  HIGH, // Higher precision - better for detailed environments
  ULTRA, // Maximum precision - use for small intricate spaces
}

// NavMeshConfig provides user-friendly agent-centric parameters
// All Recast internals are derived automatically from quality level
NavMeshConfig :: struct {
  agent_height:    f32,
  agent_radius:    f32,
  agent_max_climb: f32,
  agent_max_slope: f32,
  quality:         NavMeshQuality,
}

DEFAULT_NAVMESH_CONFIG :: NavMeshConfig {
  agent_height    = 2.0,
  agent_radius    = 0.6,
  agent_max_climb = 0.9,
  agent_max_slope = math.PI * 0.25,
  quality         = .MEDIUM,
}

// Backward compatibility: Convenience wrappers
init_level_manager :: level_manager.init
is_level_transitioning :: level_manager.is_transitioning
should_show_loading_screen :: level_manager.should_show_loading
get_current_level_id :: level_manager.get_current_level_id
load_level :: level_manager.load_level

create_texture :: proc {
  create_texture_from_path,
  create_texture_from_data,
  create_texture_from_pixels,
  create_texture_empty,
}

create_texture_from_path :: proc(
  engine: ^Engine,
  path: string,
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips := false,
  usage: vk.ImageUsageFlags = {.SAMPLED},
  is_hdr := false,
) -> (
  handle: world.Image2DHandle,
  ok: bool,
) #optional_ok {
  ret: vk.Result
  render_handle, render_ret := render.create_texture_from_path(
    &engine.gctx,
    &engine.render,
    path,
    format,
    generate_mips,
    usage,
    is_hdr,
  )
  handle = transmute(world.Image2DHandle)render_handle
  ret = render_ret
  return handle, ret == .SUCCESS
}

create_texture_from_data :: proc(
  engine: ^Engine,
  data: []u8,
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips := false,
) -> (
  handle: world.Image2DHandle,
  ok: bool,
) #optional_ok {
  ret: vk.Result
  render_handle, render_ret := render.create_texture_from_data(
    &engine.gctx,
    &engine.render,
    data,
    format,
    generate_mips,
  )
  handle = transmute(world.Image2DHandle)render_handle
  ret = render_ret
  return handle, ret == .SUCCESS
}

create_texture_from_pixels :: proc(
  engine: ^Engine,
  pixels: []u8,
  width: int,
  height: int,
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips := false,
) -> (
  handle: world.Image2DHandle,
  ok: bool,
) #optional_ok {
  ret: vk.Result
  render_handle, render_ret := render.create_texture_from_pixels(
    &engine.gctx,
    &engine.render,
    pixels,
    width,
    height,
    format,
    generate_mips,
  )
  handle = transmute(world.Image2DHandle)render_handle
  ret = render_ret
  return handle, ret == .SUCCESS
}

create_texture_empty :: proc(
  engine: ^Engine,
  width, height: u32,
  format: vk.Format,
  usage: vk.ImageUsageFlags = {.COLOR_ATTACHMENT, .SAMPLED},
) -> (
  handle: world.Image2DHandle,
  ok: bool,
) #optional_ok {
  ret: vk.Result
  render_handle, render_ret := render.create_empty_texture_2d(
    &engine.gctx,
    &engine.render,
    width,
    height,
    format,
    usage,
  )
  handle = transmute(world.Image2DHandle)render_handle
  ret = render_ret
  return handle, ret == .SUCCESS
}

create_material :: proc(
  engine: ^Engine,
  features: world.ShaderFeatureSet = {},
  type: world.MaterialType = .PBR,
  albedo_handle: world.Image2DHandle = {},
  metallic_roughness_handle: world.Image2DHandle = {},
  normal_handle: world.Image2DHandle = {},
  emissive_handle: world.Image2DHandle = {},
  occlusion_handle: world.Image2DHandle = {},
  metallic_value: f32 = 0.0,
  roughness_value: f32 = 1.0,
  emissive_value: f32 = 0.0,
  base_color_factor: [4]f32 = {1.0, 1.0, 1.0, 1.0},
) -> (
  handle: world.MaterialHandle,
  ok: bool,
) #optional_ok {
  handle = world.create_material(
    &engine.world,
    features,
    type,
    albedo_handle,
    metallic_roughness_handle,
    normal_handle,
    emissive_handle,
    occlusion_handle,
    metallic_value,
    roughness_value,
    emissive_value,
    base_color_factor,
  ) or_return
  world.stage_material_data(&engine.world.staging, handle)
  return handle, true
}

create_mesh :: proc(
  engine: ^Engine,
  geom: geometry.Geometry,
  auto_purge: bool = true,
) -> (
  handle: world.MeshHandle,
  ok: bool,
) #optional_ok {
  handle, _, ok = world.create_mesh(&engine.world, geom, auto_purge)
  if !ok do return
  world.stage_mesh_data(&engine.world.staging, handle)
  return handle, true
}

get_builtin_mesh :: proc(
  engine: ^Engine,
  primitive: world.Primitive,
) -> world.MeshHandle {
  return world.get_builtin_mesh(&engine.world, primitive)
}

get_builtin_material :: proc(
  engine: ^Engine,
  color: world.Color,
) -> world.MaterialHandle {
  return world.get_builtin_material(&engine.world, color)
}

spawn :: proc(
  engine: ^Engine,
  position: [3]f32 = {0, 0, 0},
  attachment: world.NodeAttachment = nil,
) -> (
  ret: NodeHandle,
  ok: bool,
) #optional_ok {
  return world.spawn(&engine.world, position, attachment)
}

spawn_child :: proc(
  engine: ^Engine,
  parent: world.NodeHandle,
  position: [3]f32 = {0, 0, 0},
  attachment: world.NodeAttachment = nil,
) -> (
  world.NodeHandle,
  bool,
) #optional_ok {
  return world.spawn_child(
    &engine.world,
    parent,
    position,
    attachment,
  )
}

spawn_primitive_mesh :: proc(
  engine: ^Engine,
  primitive: world.Primitive = .CUBE,
  color: world.Color = .WHITE,
  position: [3]f32 = {0, 0, 0},
  rotation_angle: f32 = 0,
  rotation_axis: [3]f32 = {0, 1, 0},
  scale_factor: f32 = 1.0,
  cast_shadow := true,
) -> (
  ret: world.NodeHandle,
  ok: bool,
) #optional_ok {
  mesh := get_builtin_mesh(engine, primitive)
  mat := get_builtin_material(engine, color)
  handle := spawn(
    engine,
    position,
    world.MeshAttachment {
      handle = mesh,
      material = mat,
      cast_shadow = cast_shadow,
    },
  ) or_return
  if rotation_angle != 0 {
    rotate(engine, handle, rotation_angle, rotation_axis)
  }
  if scale_factor != 1.0 {
    scale(engine, handle, scale_factor)
  }
  return handle, true
}

spawn_cube :: proc(
  engine: ^Engine,
  color: world.Color = .WHITE,
  position: [3]f32 = {0, 0, 0},
  rotation_angle: f32 = 0,
  rotation_axis: [3]f32 = {0, 1, 0},
  scale_factor: f32 = 1.0,
  cast_shadow := true,
) -> (
  ret: world.NodeHandle,
  ok: bool,
) #optional_ok {
  return spawn_primitive_mesh(
    engine,
    .CUBE,
    color,
    position,
    rotation_angle,
    rotation_axis,
    scale_factor,
    cast_shadow,
  )
}

spawn_sphere :: proc(
  engine: ^Engine,
  color: world.Color = .WHITE,
  position: [3]f32 = {0, 0, 0},
  rotation_angle: f32 = 0,
  rotation_axis: [3]f32 = {0, 1, 0},
  scale_factor: f32 = 1.0,
  cast_shadow := true,
) -> (
  ret: world.NodeHandle,
  ok: bool,
) #optional_ok {
  return spawn_primitive_mesh(
    engine,
    .SPHERE,
    color,
    position,
    rotation_angle,
    rotation_axis,
    scale_factor,
    cast_shadow,
  )
}

spawn_cylinder :: proc(
  engine: ^Engine,
  color: world.Color = .WHITE,
  position: [3]f32 = {0, 0, 0},
  rotation_angle: f32 = 0,
  rotation_axis: [3]f32 = {0, 1, 0},
  scale_factor: f32 = 1.0,
  cast_shadow := true,
) -> (
  ret: world.NodeHandle,
  ok: bool,
) #optional_ok {
  return spawn_primitive_mesh(
    engine,
    .CYLINDER,
    color,
    position,
    rotation_angle,
    rotation_axis,
    scale_factor,
    cast_shadow,
  )
}

spawn_quad :: proc(
  engine: ^Engine,
  color: world.Color = .WHITE,
  position: [3]f32 = {0, 0, 0},
  rotation_angle: f32 = 0,
  rotation_axis: [3]f32 = {0, 1, 0},
  scale_factor: f32 = 1.0,
  cast_shadow := true,
) -> (
  ret: world.NodeHandle,
  ok: bool,
) #optional_ok {
  return spawn_primitive_mesh(
    engine,
    .QUAD_XZ,
    color,
    position,
    rotation_angle,
    rotation_axis,
    scale_factor,
    cast_shadow,
  )
}

spawn_cone :: proc(
  engine: ^Engine,
  color: world.Color = .WHITE,
  position: [3]f32 = {0, 0, 0},
  rotation_angle: f32 = 0,
  rotation_axis: [3]f32 = {0, 1, 0},
  scale_factor: f32 = 1.0,
  cast_shadow := true,
) -> (
  ret: world.NodeHandle,
  ok: bool,
) #optional_ok {
  return spawn_primitive_mesh(
    engine,
    .CONE,
    color,
    position,
    rotation_angle,
    rotation_axis,
    scale_factor,
    cast_shadow,
  )
}

get_node :: proc(
  engine: ^Engine,
  handle: world.NodeHandle,
) -> (
  ret: ^world.Node,
  ok: bool,
) #optional_ok {
  return cont.get(engine.world.nodes, handle)
}

despawn :: proc(engine: ^Engine, handle: world.NodeHandle) {
  world.despawn(&engine.world, handle)
}

// Thread-safe: Queue a node for deletion from background threads
// The actual despawn will happen on the main thread during process_pending_deletions
queue_node_deletion :: proc(engine: ^Engine, handle: world.NodeHandle) {
  sync.mutex_lock(&engine.world.pending_deletions_mutex)
  defer sync.mutex_unlock(&engine.world.pending_deletions_mutex)
  append(&engine.world.pending_node_deletions, handle)
}

translate :: proc(
  engine: ^Engine,
  handle: world.NodeHandle,
  x: f32 = 0,
  y: f32 = 0,
  z: f32 = 0,
) {
  world.translate(&engine.world, handle, x, y, z)
}

translate_by :: proc(
  engine: ^Engine,
  handle: world.NodeHandle,
  x: f32 = 0,
  y: f32 = 0,
  z: f32 = 0,
) {
  world.translate_by(&engine.world, handle, x, y, z)
}

rotate :: proc(
  engine: ^Engine,
  handle: world.NodeHandle,
  angle: f32,
  axis: [3]f32 = {0, 1, 0},
) {
  world.rotate(&engine.world, handle, angle, axis)
}

rotate_by :: proc(
  engine: ^Engine,
  handle: world.NodeHandle,
  angle: f32,
  axis: [3]f32 = linalg.VECTOR3F32_Y_AXIS,
) {
  world.rotate_by(&engine.world, handle, angle, axis)
}

scale :: proc(engine: ^Engine, handle: world.NodeHandle, s: f32) {
  world.scale(&engine.world, handle, s)
}

scale_by :: proc(engine: ^Engine, handle: world.NodeHandle, s: f32) {
  world.scale_by(&engine.world, handle, s)
}

get_position :: proc(
  engine: ^Engine,
  handle: world.NodeHandle,
) -> (
  ret: [3]f32,
  ok: bool,
) #optional_ok {
  node := get_node(engine, handle) or_return
  return node.transform.position, true
}

get_world_position :: proc(
  engine: ^Engine,
  handle: world.NodeHandle,
) -> (
  ret: [3]f32,
  ok: bool,
) #optional_ok {
  node := get_node(engine, handle) or_return
  return node.transform.world_matrix[3].xyz, true
}

get_rotation :: proc(
  engine: ^Engine,
  handle: world.NodeHandle,
) -> (
  ret: quaternion128,
  ok: bool,
) #optional_ok {
  node := get_node(engine, handle) or_return
  return node.transform.rotation, true
}

get_scale :: proc(
  engine: ^Engine,
  handle: world.NodeHandle,
) -> (
  ret: [3]f32,
  ok: bool,
) #optional_ok {
  node := get_node(engine, handle) or_return
  return node.transform.scale, true
}

spawn_spot_light :: proc(
  engine: ^Engine,
  color: [4]f32,
  radius: f32,
  angle: f32,
  position: [3]f32 = {0, 0, 0},
  cast_shadow := true,
) -> (
  handle: world.NodeHandle,
  ok: bool,
) #optional_ok {
  handle = spawn(engine) or_return
  node := get_node(engine, handle) or_return
  attachment := world.create_spot_light_attachment(
    handle,
    &engine.world,
    color,
    radius,
    angle,
    b32(cast_shadow),
  ) or_return
  node.attachment = attachment
  if light, exists := cont.get(engine.world.lights, attachment.handle); exists {
    world.stage_light_data(&engine.world.staging, attachment.handle)
  }
  translate(engine, handle, position.x, position.y, position.z)
  ok = true
  return
}

spawn_child_spot_light :: proc(
  engine: ^Engine,
  color: [4]f32,
  radius: f32,
  angle: f32,
  parent: world.NodeHandle,
  position: [3]f32 = {0, 0, 0},
  cast_shadow := true,
) -> (
  handle: world.NodeHandle,
  ok: bool,
) #optional_ok {
  handle = spawn_child(engine, parent, position) or_return
  node := get_node(engine, handle) or_return
  attachment := world.create_spot_light_attachment(
    handle,
    &engine.world,
    color,
    radius,
    angle,
    b32(cast_shadow),
  ) or_return
  node.attachment = attachment
  if light, exists := cont.get(engine.world.lights, attachment.handle); exists {
    world.stage_light_data(&engine.world.staging, attachment.handle)
  }
  ok = true
  return
}

spawn_point_light :: proc(
  engine: ^Engine,
  color: [4]f32,
  radius: f32,
  position: [3]f32 = {0, 0, 0},
  cast_shadow := true,
) -> (
  handle: world.NodeHandle,
  ok: bool,
) #optional_ok {
  handle = spawn(engine, position) or_return
  node := get_node(engine, handle) or_return
  attachment := world.create_point_light_attachment(
    handle,
    &engine.world,
    color,
    radius,
    b32(cast_shadow),
  ) or_return
  node.attachment = attachment
  if light, exists := cont.get(engine.world.lights, attachment.handle); exists {
    world.stage_light_data(&engine.world.staging, attachment.handle)
  }
  ok = true
  return
}

spawn_child_point_light :: proc(
  engine: ^Engine,
  color: [4]f32,
  radius: f32,
  parent: world.NodeHandle,
  position: [3]f32 = {0, 0, 0},
  cast_shadow := true,
) -> (
  handle: world.NodeHandle,
  ok: bool,
) #optional_ok {
  handle = spawn_child(engine, parent, position) or_return
  node := get_node(engine, handle) or_return
  attachment := world.create_point_light_attachment(
    handle,
    &engine.world,
    color,
    radius,
    b32(cast_shadow),
  ) or_return
  node.attachment = attachment
  if light, exists := cont.get(engine.world.lights, attachment.handle); exists {
    world.stage_light_data(&engine.world.staging, attachment.handle)
  }
  ok = true
  return
}

spawn_directional_light :: proc(
  engine: ^Engine,
  color: [4]f32,
  rotation: quaternion128 = linalg.QUATERNIONF32_IDENTITY, // Rotation of the light (identity = pointing down -Z)
  cast_shadow := true,
) -> (
  handle: world.NodeHandle,
  ok: bool,
) #optional_ok {
  // Position doesn't matter for directional lights (infinite distance)
  handle = spawn(engine, {0, 0, 0}) or_return
  node := get_node(engine, handle) or_return

  // Set rotation directly
  node.transform.rotation = rotation
  node.transform.is_dirty = true

  attachment := world.create_directional_light_attachment(
    handle,
    &engine.world,
    color,
    b32(cast_shadow),
  ) or_return
  node.attachment = attachment
  if light, exists := cont.get(engine.world.lights, attachment.handle); exists {
    world.stage_light_data(&engine.world.staging, attachment.handle)
  }
  ok = true
  return
}

create_emitter :: proc(
  engine: ^Engine,
  owner: world.NodeHandle,
  texture_handle: world.Image2DHandle,
  emission_rate: f32,
  initial_velocity: [3]f32,
  velocity_spread: f32,
  color_start: [4]f32,
  color_end: [4]f32,
  aabb_min: [3]f32,
  aabb_max: [3]f32,
  particle_lifetime: f32,
  position_spread: f32,
  size_start: f32,
  size_end: f32,
  weight: f32,
  weight_spread: f32,
) -> (
  handle: world.EmitterHandle,
  ok: bool,
) #optional_ok {
  handle = world.create_emitter(
    &engine.world,
    owner,
    texture_handle,
    emission_rate,
    initial_velocity,
    velocity_spread,
    color_start,
    color_end,
    aabb_min,
    aabb_max,
    particle_lifetime,
    position_spread,
    size_start,
    size_end,
    weight,
    weight_spread,
  ) or_return
  world.stage_emitter_data(&engine.world.staging, handle)
  return handle, true
}

create_forcefield :: proc(
  engine: ^Engine,
  owner: world.NodeHandle,
  area_of_effect: f32 = 1.0,
  strength: f32 = 1.0,
  tangent_strength: f32 = 0.0,
) -> (
  handle: world.ForceFieldHandle,
  ok: bool,
) #optional_ok {
  handle = world.create_forcefield(
    &engine.world,
    owner,
    area_of_effect,
    strength,
    tangent_strength,
  ) or_return
  world.stage_forcefield_data(&engine.world.staging, handle)
  return handle, true
}

create_light :: proc(
  engine: ^Engine,
  light_type: LightType,
  node_handle: world.NodeHandle,
  color: [4]f32 = {1, 1, 1, 1},
  radius: f32 = 10.0,
  angle_inner: f32 = 0.0,
  angle_outer: f32 = 0.0,
  cast_shadow: b32 = true,
) -> (
  light_handle: world.LightHandle,
  ok: bool,
) #optional_ok {
  // Create the light resource
  light_handle = world.create_light(
    &engine.world,
    light_type,
    node_handle,
    color,
    radius,
    angle_inner,
    angle_outer,
    cast_shadow,
  ) or_return
  if light, exists := cont.get(engine.world.lights, light_handle); exists {
    world.stage_light_data(&engine.world.staging, light_handle)
  }
  // If the light casts shadows, create a camera for it
  if cast_shadow {
    create_light_camera(engine, light_handle) or_return
  }
  return light_handle, true
}

// Create an animation clip with automatic allocation and initialization
// Use init_animation_channel to populate the channels after creation
create_animation_clip :: proc(
  engine: ^Engine,
  channel_count: int,
  duration: f32 = 1.0,
  name: string = "",
) -> (
  handle: world.ClipHandle,
  ok: bool,
) #optional_ok {
  return world.create_animation_clip(
    &engine.world,
    channel_count,
    duration,
    name,
  )
}

// Initialize an animation channel with callback functions for generating keyframe values
// Callbacks take index and return the value for that keyframe
// This allows procedural generation of keyframe values without manual loops
init_animation_channel :: proc(
  engine: ^Engine,
  clip_handle: world.ClipHandle,
  channel_idx: int,
  position_count: int = 0,
  rotation_count: int = 0,
  scale_count: int = 0,
  position_fn: proc(i: int) -> [3]f32 = nil,
  rotation_fn: proc(i: int) -> quaternion128 = nil,
  scale_fn: proc(i: int) -> [3]f32 = nil,
  position_interpolation: animation.InterpolationMode = .LINEAR,
  rotation_interpolation: animation.InterpolationMode = .LINEAR,
  scale_interpolation: animation.InterpolationMode = .LINEAR,
) {
  // Get clip from handle
  clip, clip_ok := cont.get(engine.world.animation_clips, clip_handle)
  if !clip_ok do return
  // Initialize channel structure with defaults
  animation.channel_init(
    &clip.channels[channel_idx],
    position_count = position_count,
    rotation_count = rotation_count,
    scale_count = scale_count,
    position_interpolation = position_interpolation,
    rotation_interpolation = rotation_interpolation,
    scale_interpolation = scale_interpolation,
    duration = clip.duration,
  )
  channel := &clip.channels[channel_idx]
  // Apply position callback if provided
  if position_fn != nil {
    for &kf, i in channel.positions {
      switch &variant in kf {
      case animation.LinearKeyframe([3]f32):
        variant.value = position_fn(i)
      case animation.StepKeyframe([3]f32):
        variant.value = position_fn(i)
      case animation.CubicSplineKeyframe([3]f32):
        variant.value = position_fn(i)
      }
    }
  }
  // Apply rotation callback if provided
  if rotation_fn != nil {
    for &kf, i in channel.rotations {
      switch &variant in kf {
      case animation.LinearKeyframe(quaternion128):
        variant.value = rotation_fn(i)
      case animation.StepKeyframe(quaternion128):
        variant.value = rotation_fn(i)
      case animation.CubicSplineKeyframe(quaternion128):
        variant.value = rotation_fn(i)
      }
    }
  }
  // Apply scale callback if provided
  if scale_fn != nil {
    for &kf, i in channel.scales {
      switch &variant in kf {
      case animation.LinearKeyframe([3]f32):
        variant.value = scale_fn(i)
      case animation.StepKeyframe([3]f32):
        variant.value = scale_fn(i)
      case animation.CubicSplineKeyframe([3]f32):
        variant.value = scale_fn(i)
      }
    }
  }
}

play_animation :: proc(
  engine: ^Engine,
  handle: world.NodeHandle,
  name: string,
) -> bool {
  return world.play_animation(&engine.world, handle, name)
}

// Add an animation layer to a skinned mesh node
add_animation_layer :: proc(
  engine: ^Engine,
  handle: world.NodeHandle,
  animation_name: string,
  weight: f32 = 1.0,
  mode: animation.PlayMode = .LOOP,
  speed: f32 = 1.0,
  layer_index: int = -1, // -1 to append, >= 0 to replace existing layer
  blend_mode: animation.BlendMode = .REPLACE,
) -> bool {
  return world.add_animation_layer(
    &engine.world,
    handle,
    animation_name,
    weight,
    mode,
    speed,
    layer_index,
    blend_mode,
  )
}

// Remove an animation layer from a skinned mesh node
remove_animation_layer :: proc(
  engine: ^Engine,
  handle: world.NodeHandle,
  layer_index: int,
) -> bool {
  return world.remove_animation_layer(&engine.world, handle, layer_index)
}

// Set the blend weight for an animation layer
set_animation_layer_weight :: proc(
  engine: ^Engine,
  handle: world.NodeHandle,
  layer_index: int,
  weight: f32,
) -> bool {
  return world.set_animation_layer_weight(
    &engine.world,
    handle,
    layer_index,
    weight,
  )
}

// Clear all animation layers from a skinned mesh node
clear_animation_layers :: proc(
  engine: ^Engine,
  handle: world.NodeHandle,
) -> bool {
  return world.clear_animation_layers(&engine.world, handle)
}

// Set bone mask on animation layer to filter which bones are affected
set_animation_layer_bone_mask :: proc(
  engine: ^Engine,
  node: world.NodeHandle,
  layer_index: int,
  bone_names: []string,
) -> bool {
  // Get the mesh to create bone mask
  node_ptr := cont.get(engine.world.nodes, node) or_return
  mesh_attachment, ok := &node_ptr.attachment.(world.MeshAttachment)
  if !ok do return false
  mesh := cont.get(engine.world.meshes, mesh_attachment.handle) or_return

  // Create bone mask from bone names
  mask := world.create_bone_mask(mesh, bone_names) or_return

  // Set mask on layer
  return world.set_animation_layer_bone_mask(
    &engine.world,
    node,
    layer_index,
    mask,
  )
}

// Transition smoothly from current animation to a new animation
transition_to_animation :: proc(
  engine: ^Engine,
  node: world.NodeHandle,
  animation_name: string,
  duration: f32,
  curve: ease.Ease = .Linear,
) -> bool {
  return world.transition_to_animation(
    &engine.world,
    node,
    animation_name,
    duration,
    0, // from_layer
    1, // to_layer
    curve,
  )
}

// Add an IK layer to control specific bones
// IK targets are in world space and will be converted internally
add_ik_layer :: proc(
  engine: ^Engine,
  handle: world.NodeHandle,
  bone_names: []string,
  target_pos: [3]f32,
  pole_pos: [3]f32,
  weight: f32 = 1.0,
  max_iterations: int = 10,
  tolerance: f32 = 0.001,
  layer_index: int = -1, // -1 to append, >= 0 to replace existing layer
) -> bool {
  return world.add_ik_layer(
    &engine.world,
    handle,
    bone_names,
    target_pos,
    pole_pos,
    weight,
    max_iterations,
    tolerance,
    layer_index,
  )
}

// Update IK target position and pole vector for an existing IK layer
set_ik_layer_target :: proc(
  engine: ^Engine,
  handle: world.NodeHandle,
  layer_index: int,
  target_pos: [3]f32,
  pole_pos: [3]f32,
) -> bool {
  return world.set_ik_layer_target(
    &engine.world,
    handle,
    layer_index,
    target_pos,
    pole_pos,
  )
}

// Enable or disable an IK layer
set_ik_layer_enabled :: proc(
  engine: ^Engine,
  handle: world.NodeHandle,
  layer_index: int,
  enabled: bool,
) -> bool {
  return world.set_ik_layer_enabled(
    &engine.world,
    handle,
    layer_index,
    enabled,
  )
}

create_camera :: proc(
  engine: ^Engine,
  width, height: u32,
  enabled_passes: world.PassTypeSet = {
    .SHADOW,
    .GEOMETRY,
    .LIGHTING,
    .TRANSPARENCY,
    .PARTICLES,
    .POST_PROCESS,
  },
  position: [3]f32 = {0, 0, 3},
  target: [3]f32 = {0, 0, 0},
  fov: f32 = 1.57079632679,
  near_plane: f32 = 0.1,
  far_plane: f32 = 100.0,
) -> (
  handle: world.CameraHandle,
  ok: bool,
) #optional_ok {
  render_enabled_passes := transmute(render_camera.PassTypeSet)enabled_passes
  camera_handle, camera_ptr := cont.alloc(
    &engine.world.cameras,
    world.CameraHandle,
  ) or_return
  defer if !ok do cont.free(&engine.world.cameras, camera_handle)
  if world.camera_init(
       camera_ptr,
       width,
       height,
       enabled_passes,
       position,
       target,
       fov,
       near_plane,
       far_plane,
     ) !=
     .SUCCESS {
    return {}, false
  }
  world.stage_camera_data(&engine.world.staging, camera_handle)
  camera_gpu := &engine.render.cameras_gpu[camera_handle.index]
  descriptor_set := engine.render.textures_descriptor_set
  set_descriptor :: proc(gctx: ^gpu.GPUContext, index: u32, view: vk.ImageView) {
    desc_set := (cast(^vk.DescriptorSet)context.user_ptr)^
    render.set_texture_2d_descriptor(gctx, desc_set, index, view)
  }
  context.user_ptr = &descriptor_set
  if render_camera.init_gpu(
       &engine.gctx,
       camera_gpu,
       &engine.render.texture_manager,
       width,
       height,
       engine.swapchain.format.format,
       vk.Format.D32_SFLOAT,
       render_enabled_passes,
       camera_ptr.enable_depth_pyramid,
       world.MAX_NODES_IN_SCENE,
     ) !=
     .SUCCESS {
    return {}, false
  }
  if render_camera.allocate_descriptors(
       &engine.gctx,
       camera_gpu,
       &engine.render.texture_manager,
       &engine.render.visibility.normal_cam_descriptor_layout,
       &engine.render.visibility.depth_reduce_descriptor_layout,
       &engine.render.node_data_buffer,
       &engine.render.mesh_data_buffer,
       &engine.render.world_matrix_buffer,
       &engine.render.camera_buffer,
     ) !=
     .SUCCESS {
    return {}, false
  }
  return camera_handle, true
}

get_camera_attachment :: proc(
  engine: ^Engine,
  camera_handle: world.CameraHandle,
  attachment_type: render_camera.AttachmentType,
  frame_index: u32 = 0,
) -> (
  handle: world.Image2DHandle,
  ok: bool,
) #optional_ok {
  if _, exists := cont.get(engine.world.cameras, camera_handle); !exists do return {}, false
  render_handle := render.get_camera_attachment(
    &engine.render,
    transmute(render.CameraHandle)camera_handle,
    attachment_type,
    frame_index,
  )
  return transmute(world.Image2DHandle)render_handle, true
}

update_material_texture :: proc(
  engine: ^Engine,
  material_handle: world.MaterialHandle,
  texture_type: world.ShaderFeature,
  texture_handle: world.Image2DHandle,
) -> bool {
  material := cont.get(engine.world.materials, material_handle) or_return
  switch texture_type {
  case .ALBEDO_TEXTURE:
    material.albedo = texture_handle
  case .METALLIC_ROUGHNESS_TEXTURE:
    material.metallic_roughness = texture_handle
  case .NORMAL_TEXTURE:
    material.normal = texture_handle
  case .EMISSIVE_TEXTURE:
    material.emissive = texture_handle
  case .OCCLUSION_TEXTURE:
    material.occlusion = texture_handle
  }
  world.stage_material_data(&engine.world.staging, material_handle)
  return true
}

// Derive Recast parameters from quality level and agent dimensions
// This hides all Recast implementation details from the user
@(private)
navmesh_config_to_recast :: proc(cfg: NavMeshConfig) -> recast.Config {
  // Quality presets - derived from agent_radius for proportional scaling
  // cell_size determines voxel resolution (smaller = more precise but slower)
  cell_size: f32
  cell_height: f32
  min_region_area: i32
  merge_region_area: i32
  max_edge_length: f32
  max_edge_error: f32
  detail_sample_dist: f32
  detail_sample_max_error: f32
  max_verts_per_poly: i32

  switch cfg.quality {
  case .LOW:
    // Coarse mesh - fast generation, suitable for large open areas
    cell_size = cfg.agent_radius * 0.5 // ~0.3 for radius 0.6
    cell_height = cfg.agent_radius * 0.33 // ~0.2 for radius 0.6
    min_region_area = 32
    merge_region_area = 200
    max_edge_length = 20.0
    max_edge_error = 2.0
    detail_sample_dist = 4.0
    detail_sample_max_error = 2.0
    max_verts_per_poly = 4
  case .MEDIUM:
    // Balanced quality - recommended default
    cell_size = cfg.agent_radius * 0.5
    cell_height = cfg.agent_radius * 0.33
    min_region_area = 64
    merge_region_area = 400
    max_edge_length = 12.0
    max_edge_error = 1.3
    detail_sample_dist = 6.0
    detail_sample_max_error = 1.0
    max_verts_per_poly = 6
  case .HIGH:
    // Higher precision for detailed environments
    cell_size = cfg.agent_radius * 0.33
    cell_height = cfg.agent_radius * 0.25
    min_region_area = 100
    merge_region_area = 600
    max_edge_length = 8.0
    max_edge_error = 1.0
    detail_sample_dist = 8.0
    detail_sample_max_error = 0.5
    max_verts_per_poly = 6
  case .ULTRA:
    // Maximum precision - small intricate spaces
    cell_size = cfg.agent_radius * 0.25
    cell_height = cfg.agent_radius * 0.2
    min_region_area = 150
    merge_region_area = 800
    max_edge_length = 6.0
    max_edge_error = 0.8
    detail_sample_dist = 10.0
    detail_sample_max_error = 0.25
    max_verts_per_poly = 6
  }

  return recast.Config {
    cs = cell_size,
    ch = cell_height,
    walkable_slope = cfg.agent_max_slope,
    walkable_height = i32(math.ceil_f32(cfg.agent_height / cell_height)),
    walkable_climb = i32(math.floor_f32(cfg.agent_max_climb / cell_height)),
    walkable_radius = i32(math.ceil_f32(cfg.agent_radius / cell_size)),
    max_edge_len = i32(max_edge_length / cell_size),
    max_simplification_error = max_edge_error,
    min_region_area = min_region_area,
    merge_region_area = merge_region_area,
    max_verts_per_poly = max_verts_per_poly,
    detail_sample_dist = detail_sample_dist * cell_size,
    detail_sample_max_error = detail_sample_max_error * cell_height,
    border_size = 0,
  }
}

build_area_types_from_tags :: proc(
  node_infos: []world.BakedNodeInfo,
) -> []u8 {
  area_types := make([dynamic]u8, 0, len(node_infos) * 10)
  for info in node_infos {
    triangle_count := info.index_count / 3
    area_type :=
      .NAVMESH_OBSTACLE in info.tags ? u8(recast.RC_NULL_AREA) : u8(recast.RC_WALKABLE_AREA)
    for _ in 0 ..< triangle_count {
      append(&area_types, area_type)
    }
  }
  return area_types[:]
}

@(private)
match_bake_node_filter :: proc(
  tags: world.NodeTagSet,
  include: world.NodeTagSet,
  exclude: world.NodeTagSet,
) -> bool {
  return (exclude == {} || (tags & exclude) == {}) && (include == {} || (tags & include) != {})
}

bake_geometry :: proc(
  engine: ^Engine,
  include_filter: world.NodeTagSet = {.ENVIRONMENT},
  exclude_filter: world.NodeTagSet = {},
  with_node_info: bool = false,
) -> (
  geom: geometry.Geometry,
  node_infos: []world.BakedNodeInfo,
  ok: bool,
) {
  vertices := make([dynamic]geometry.Vertex, 0, 4096)
  indices := make([dynamic]u32, 0, 16384)
  infos := make([dynamic]world.BakedNodeInfo, 0, 64) if with_node_info else nil
  for &entry in engine.world.nodes.entries do if entry.active {
    node := &entry.item
    if !match_bake_node_filter(node.tags, include_filter, exclude_filter) do continue
    mesh_attachment, is_mesh := node.attachment.(world.MeshAttachment)
    if !is_mesh do continue
    mesh := cont.get(engine.world.meshes, mesh_attachment.handle) or_continue
    mesh_geom, has_geom := mesh.cpu_geometry.?
    if !has_geom do continue
    vertex_base := u32(len(vertices))
    for v in mesh_geom.vertices {
      p := node.transform.world_matrix * [4]f32{v.position.x, v.position.y, v.position.z, 1.0}
      append(&vertices, geometry.Vertex{position = p.xyz})
    }
    for src_index in mesh_geom.indices {
      append(&indices, vertex_base + src_index)
    }
    if with_node_info {
      append(&infos, world.BakedNodeInfo{
        tags = node.tags,
        vertex_count = len(mesh_geom.vertices),
        index_count = len(mesh_geom.indices),
      })
    }
  }
  if len(vertices) == 0 {
    delete(vertices)
    delete(indices)
    if with_node_info do delete(infos)
    return {}, nil, false
  }
  geom = geometry.Geometry{
    vertices = vertices[:],
    indices = indices[:],
    aabb = geometry.aabb_from_vertices(vertices[:]),
  }
  if with_node_info {
    node_infos = infos[:]
  } else {
    node_infos = nil
  }
  return geom, node_infos, true
}

bake :: proc(
  engine: ^Engine,
  include_filter: world.NodeTagSet = {.ENVIRONMENT},
  exclude_filter: world.NodeTagSet = {},
) -> (
  mesh_handle: world.MeshHandle,
  ok: bool,
) #optional_ok {
  baked_geom, _, baked_ok := bake_geometry(
    engine,
    include_filter,
    exclude_filter,
  )
  if !baked_ok do return
  defer {
    delete(baked_geom.vertices)
    delete(baked_geom.indices)
  }
  mesh_handle, ok = create_mesh(engine, baked_geom, false)
  return
}

setup_navmesh :: proc(
  engine: ^Engine,
  config: NavMeshConfig = DEFAULT_NAVMESH_CONFIG,
  include_filter: world.NodeTagSet = {},
  exclude_filter: world.NodeTagSet = {},
) -> bool {
  world.traverse(&engine.world)
  baked_geom, node_infos, bake_ok := bake_geometry(
    engine,
    include_filter,
    exclude_filter,
    true,
  )
  if !bake_ok {
    return false
  }
  defer {
    delete(baked_geom.vertices)
    delete(baked_geom.indices)
    delete(node_infos)
  }
  nav_vertices, nav_indices := nav.convert_geometry_to_nav(
    baked_geom.vertices,
    baked_geom.indices,
  )
  defer {
    delete(nav_vertices)
    delete(nav_indices)
  }
  area_types := build_area_types_from_tags(node_infos)
  defer delete(area_types)
  recast_config := navmesh_config_to_recast(config)
  nav_geom := nav.NavigationGeometry {
    vertices   = nav_vertices,
    indices    = nav_indices,
    area_types = area_types,
  }
  if !nav.build_navmesh(&engine.nav_sys.nav_mesh, nav_geom, recast_config) {
    return false
  }
  if !nav.init(&engine.nav_sys) {
    return false
  }
  return true
}

find_path :: proc(
  engine: ^Engine,
  start_pos: [3]f32,
  end_pos: [3]f32,
  max_path_length: i32 = 256,
) -> (
  path: [][3]f32,
  ok: bool,
) #optional_ok {
  return nav.find_path(&engine.nav_sys, start_pos, end_pos, max_path_length)
}

nav_is_position_walkable :: proc(engine: ^Engine, position: [3]f32) -> bool {
  return nav.is_position_walkable(&engine.nav_sys, position)
}

nav_find_nearest_point :: proc(
  engine: ^Engine,
  position: [3]f32,
  search_extents: [3]f32 = {2.0, 4.0, 2.0},
) -> (
  nearest_pos: [3]f32,
  found: bool,
) {
  return nav.find_nearest_point(&engine.nav_sys, position, search_extents)
}

add_bloom :: proc(
  engine: ^Engine,
  threshold: f32 = 0.2,
  intensity: f32 = 1.0,
  blur_radius: f32 = 4.0,
) {
  post_process.add_bloom(
    &engine.render.post_process,
    threshold,
    intensity,
    blur_radius,
  )
}

add_tonemap :: proc(engine: ^Engine, exposure: f32 = 1.0, gamma: f32 = 2.2) {
  post_process.add_tonemap(&engine.render.post_process, exposure, gamma)
}

add_fog :: proc(
  engine: ^Engine,
  color: [3]f32 = {0.7, 0.7, 0.8},
  density: f32 = 0.02,
  start: f32 = 10.0,
  end: f32 = 100.0,
) {
  post_process.add_fog(&engine.render.post_process, color, density, start, end)
}

add_grayscale :: proc(
  engine: ^Engine,
  strength: f32 = 1.0,
  weights: [3]f32 = {0.299, 0.587, 0.114},
) {
  post_process.add_grayscale(&engine.render.post_process, strength, weights)
}

add_blur :: proc(engine: ^Engine, radius: f32, gaussian: bool = true) {
  post_process.add_blur(&engine.render.post_process, radius, gaussian)
}

add_outline :: proc(engine: ^Engine, thickness: f32, color: [3]f32) {
  post_process.add_outline(&engine.render.post_process, thickness, color)
}

add_crosshatch :: proc(
  engine: ^Engine,
  resolution: [2]f32 = {800, 600},
  hatch_offset_y: f32 = 0.0,
  lum_threshold_01: f32 = 0.2,
  lum_threshold_02: f32 = 0.4,
  lum_threshold_03: f32 = 0.6,
  lum_threshold_04: f32 = 0.8,
) {
  post_process.add_crosshatch(
    &engine.render.post_process,
    resolution,
    hatch_offset_y,
    lum_threshold_01,
    lum_threshold_02,
    lum_threshold_03,
    lum_threshold_04,
  )
}

add_dof :: proc(
  engine: ^Engine,
  focus_distance: f32 = 10.0,
  focus_range: f32 = 2.0,
  blur_strength: f32 = 1.0,
  bokeh_intensity: f32 = 0.5,
) {
  post_process.add_dof(
    &engine.render.post_process,
    focus_distance,
    focus_range,
    blur_strength,
    bokeh_intensity,
  )
}

clear_post_process_effects :: proc(engine: ^Engine) {
  post_process.clear_effects(&engine.render.post_process)
}

get_window_size :: proc(engine: ^Engine) -> (i32, i32) {
  width, height := glfw.GetWindowSize(engine.window)
  return i32(width), i32(height)
}

set_window_title :: proc(engine: ^Engine, title: string) {
  title_cstr := strings.clone_to_cstring(title)
  defer delete(title_cstr)
  glfw.SetWindowTitle(engine.window, title_cstr)
}

get_fps :: proc(engine: ^Engine) -> f32 {
  delta := get_delta_time(engine)
  if delta <= 0 {
    return 0
  }
  return 1.0 / delta
}

get_node_count :: proc(engine: ^Engine) -> u32 {
  return u32(
    len(engine.world.nodes.entries) - len(engine.world.nodes.free_indices),
  )
}

get_material_count :: proc(engine: ^Engine) -> u32 {
  return u32(
    len(engine.world.materials.entries) - len(engine.world.materials.free_indices),
  )
}

get_mesh_count :: proc(engine: ^Engine) -> u32 {
  return u32(
    len(engine.world.meshes.entries) - len(engine.world.meshes.free_indices),
  )
}

get_texture_count :: proc(engine: ^Engine) -> u32 {
  return u32(render.active_texture_2d_count(&engine.render))
}

set_visibility_stats :: proc(engine: ^Engine, enabled: bool) {
  engine.render.visibility.stats_enabled = enabled
}

camera_look_at :: world.camera_look_at

CameraControllerType :: world.CameraControllerType

switch_camera_controller :: proc(engine: ^Engine, type: CameraControllerType) {
  main_camera := get_main_camera(engine)
  if main_camera == nil do return
  switch type {
  case .ORBIT:
    world.camera_controller_sync(&engine.orbit_controller, main_camera)
    engine.active_controller = &engine.orbit_controller
  case .FREE:
    world.camera_controller_sync(&engine.free_controller, main_camera)
    engine.active_controller = &engine.free_controller
  case .FOLLOW, .CINEMATIC:
  }
}

update_camera_controller :: proc(engine: ^Engine, delta_time: f32) {
  if engine.active_controller == nil do return
  main_camera := get_main_camera(engine)
  if main_camera == nil do return
  switch engine.active_controller.type {
  case .ORBIT:
    world.camera_controller_orbit_update(
      engine.active_controller,
      main_camera,
      delta_time,
    )
  case .FREE:
    world.camera_controller_free_update(
      engine.active_controller,
      main_camera,
      delta_time,
    )
  case .FOLLOW:
    world.camera_controller_follow_update(
      engine.active_controller,
      main_camera,
      delta_time,
    )
  case .CINEMATIC:
  }
}

get_active_camera_controller_type :: proc(
  engine: ^Engine,
) -> CameraControllerType {
  if engine.active_controller == nil do return .ORBIT
  return engine.active_controller.type
}

set_orbit_camera_target :: proc(engine: ^Engine, target: [3]f32) {
  world.camera_controller_orbit_set_target(&engine.orbit_controller, target)
}

set_orbit_camera_distance :: proc(engine: ^Engine, distance: f32) {
  world.camera_controller_orbit_set_distance(
    &engine.orbit_controller,
    distance,
  )
}

set_orbit_camera_angles :: proc(engine: ^Engine, yaw, pitch: f32) {
  world.camera_controller_orbit_set_yaw_pitch(
    &engine.orbit_controller,
    yaw,
    pitch,
  )
}

set_free_camera_speed :: proc(engine: ^Engine, speed: f32) {
  world.camera_controller_free_set_speed(&engine.free_controller, speed)
}

set_free_camera_sensitivity :: proc(engine: ^Engine, sensitivity: f32) {
  world.camera_controller_free_set_sensitivity(
    &engine.free_controller,
    sensitivity,
  )
}

get_main_camera :: proc(engine: ^Engine) -> ^world.Camera {
  return cont.get(
    engine.world.cameras,
    transmute(world.CameraHandle)engine.render.main_camera,
  )
}

sync_camera_controller :: proc(engine: ^Engine, type: CameraControllerType) {
  main_camera := get_main_camera(engine)
  if main_camera == nil do return
  switch type {
  case .ORBIT:
    world.camera_controller_sync(&engine.orbit_controller, main_camera)
  case .FREE:
    world.camera_controller_sync(&engine.free_controller, main_camera)
  case .FOLLOW, .CINEMATIC:
  }
}

sync_active_camera_controller :: proc(engine: ^Engine) {
  if engine.active_controller == nil do return
  main_camera := get_main_camera(engine)
  if main_camera == nil do return
  world.camera_controller_sync(engine.active_controller, main_camera)
}

@(private)
find_node_by_body_handle :: proc(
  engine: ^Engine,
  body_handle: physics.BodyHandleResult,
) -> (
  handle: world.NodeHandle,
  ok: bool,
) {
  #partial switch h in body_handle {
  case physics.DynamicRigidBodyHandle:
    for &entry, i in engine.world.nodes.entries do if entry.active {
      if attachment, is_rb := entry.item.attachment.(world.RigidBodyAttachment); is_rb {
        if attachment.body_handle == h {
          return world.NodeHandle{index = u32(i), generation = entry.generation}, true
        }
      }
    }
  case physics.StaticRigidBodyHandle:
  }
  return {}, false
}

raycast :: proc(
  engine: ^Engine,
  physics_world: ^physics.World,
  origin: [3]f32,
  direction: [3]f32,
  max_distance: f32 = 1000.0,
) -> (
  hit: bool,
  distance: f32,
  normal: [3]f32,
  handle: world.NodeHandle,
) {
  dir := linalg.normalize(direction)
  ray := geometry.Ray {
    origin    = origin,
    direction = dir,
  }
  physics_hit := physics.raycast(physics_world, ray, max_distance)
  if !physics_hit.hit {
    return false, 0, {0, 0, 0}, {}
  }
  node_handle, found := find_node_by_body_handle(
    engine,
    physics_hit.body_handle,
  )
  if !found {
    return false, 0, {0, 0, 0}, {}
  }
  return true, physics_hit.t, physics_hit.normal, node_handle
}

query_sphere :: proc(
  engine: ^Engine,
  physics_world: ^physics.World,
  center: [3]f32,
  radius: f32,
) -> []world.NodeHandle {
  results := make(
    [dynamic]physics.DynamicRigidBodyHandle,
    context.temp_allocator,
  )
  physics.query_sphere(physics_world, center, radius, &results)
  node_handles := make([dynamic]world.NodeHandle, context.temp_allocator)
  for body_handle in results {
    if node_handle, ok := find_node_by_body_handle(engine, body_handle); ok {
      append(&node_handles, node_handle)
    }
  }
  return node_handles[:]
}

query_box :: proc(
  engine: ^Engine,
  physics_world: ^physics.World,
  min: [3]f32,
  max: [3]f32,
) -> []world.NodeHandle {
  bounds := geometry.Aabb {
    min = min,
    max = max,
  }
  results := make(
    [dynamic]physics.DynamicRigidBodyHandle,
    context.temp_allocator,
  )
  physics.query_box(physics_world, bounds, &results)
  node_handles := make([dynamic]world.NodeHandle, context.temp_allocator)
  for body_handle in results {
    if node_handle, ok := find_node_by_body_handle(engine, body_handle); ok {
      append(&node_handles, node_handle)
    }
  }
  return node_handles[:]
}

draw_debug_line :: proc(
  engine: ^Engine,
  from: [3]f32,
  to: [3]f32,
  color: [4]f32 = {1, 1, 1, 1},
  duration: f32 = 0.0,
) {
  // TODO: Spawn a line mesh with wireframe material
  // Schedule for removal after duration (0 = one frame)
  // Need to create custom line geometry or use cylinder
}

draw_debug_box :: proc(
  engine: ^Engine,
  center: [3]f32,
  size: [3]f32,
  color: [4]f32 = {1, 1, 1, 1},
  duration: f32 = 0.0,
) {
  // TODO: Spawn cube primitive with wireframe material at center
  // Set scale to size
  // Schedule for removal after duration (0 = one frame)
  // Need wireframe material support in ShaderFeatureSet
}

draw_debug_sphere :: proc(
  engine: ^Engine,
  center: [3]f32,
  radius: f32,
  color: [4]f32 = {1, 1, 1, 1},
  duration: f32 = 0.0,
) {
  // TODO: Spawn sphere primitive with wireframe material at center
  // Set scale to radius
  // Schedule for removal after duration (0 = one frame)
  // Need wireframe material support in ShaderFeatureSet
}

draw_debug_aabb :: proc(
  engine: ^Engine,
  min: [3]f32,
  max: [3]f32,
  color: [4]f32 = {1, 1, 1, 1},
  duration: f32 = 0.0,
) {
  center := (min + max) * 0.5
  size := max - min
  draw_debug_box(engine, center, size, color, duration)
}

// Debug Draw API - Spawn debug objects for visualization

debug_draw_spawn_mesh :: proc(
  engine: ^Engine,
  mesh_handle: MeshHandle,
  transform: matrix[4, 4]f32,
  color: [4]f32 = {1.0, 0.0, 0.75, 1.0},
  style: DebugRenderStyle = .UNIFORM_COLOR,
  bypass_depth := false,
) -> (
  handle: DebugObjectHandle,
  ok: bool,
) #optional_ok {
  return debug_draw.spawn_mesh(
    &engine.render.debug_draw,
    transmute(render.MeshHandle)mesh_handle,
    transform,
    color,
    style,
    bypass_depth,
  )
}

// TODO: Re-enable when debug_draw.spawn_line_strip is refactored to not do GPU work
/*
debug_draw_spawn_line_strip :: proc(
  engine: ^Engine,
  points: []geometry.Vertex,
  color: [4]f32 = {1.0, 0.0, 0.75, 1.0},
  bypass_depth := false,
) -> (
  handle: DebugObjectHandle,
  ok: bool,
) #optional_ok {
  return debug_draw.spawn_line_strip(
    &engine.render.debug_draw,
    points,
    &engine.gctx,
    &engine.world,
    color,
    bypass_depth,
  )
}
*/

debug_draw_spawn_mesh_temporary :: proc(
  engine: ^Engine,
  mesh_handle: MeshHandle,
  transform: matrix[4, 4]f32,
  duration_seconds: f64,
  color: [4]f32 = {1.0, 0.0, 0.75, 1.0},
  style: DebugRenderStyle = .UNIFORM_COLOR,
  bypass_depth := false,
) -> (
  handle: DebugObjectHandle,
  ok: bool,
) #optional_ok {
  return debug_draw.spawn_mesh_temporary(
    &engine.render.debug_draw,
    transmute(render.MeshHandle)mesh_handle,
    transform,
    duration_seconds,
    color,
    style,
    bypass_depth,
  )
}

// TODO: Re-enable when debug_draw.spawn_line_strip_temporary is refactored to not do GPU work
/*
debug_draw_spawn_line_strip_temporary :: proc(
  engine: ^Engine,
  points: []geometry.Vertex,
  duration_seconds: f64,
  color: [4]f32 = {1.0, 0.0, 0.75, 1.0},
  bypass_depth := false,
) -> (
  handle: DebugObjectHandle,
  ok: bool,
) #optional_ok {
  return debug_draw.spawn_line_strip_temporary(
    &engine.render.debug_draw,
    points,
    &engine.gctx,
    &engine.world,
    duration_seconds,
    color,
    bypass_depth,
  )
}
*/

debug_draw_destroy :: proc(engine: ^Engine, handle: DebugObjectHandle) {
  debug_draw.destroy(
    &engine.render.debug_draw,
    handle,
    &engine.world,
    proc(ctx: rawptr, mesh_handle: render.MeshHandle) {
      world_ptr := cast(^world.World)ctx
      world.destroy_mesh(world_ptr, transmute(world.MeshHandle)mesh_handle)
    },
  )
}

// ============================================================================
// UI System API
// ============================================================================

ui_create_mesh2d :: proc(
  engine: ^Engine,
  position: [2]f32,
  vertices: []ui.Vertex2D,
  indices: []u32,
  texture: Image2DHandle = {},
  z_order: i32 = 0,
) -> (
  Mesh2DHandle,
  bool,
) #optional_ok {
  return ui.create_mesh2d(
    &engine.render.ui_system,
    position,
    vertices,
    indices,
    transmute(render.Image2DHandle)texture,
    z_order,
  )
}

ui_create_quad2d :: proc(
  engine: ^Engine,
  position: [2]f32,
  size: [2]f32,
  texture: Image2DHandle = {},
  color: [4]u8 = {255, 255, 255, 255},
  z_order: i32 = 0,
) -> (
  Quad2DHandle,
  bool,
) #optional_ok {
  return ui.create_quad2d(
    &engine.render.ui_system,
    position,
    size,
    transmute(render.Image2DHandle)texture,
    color,
    z_order,
  )
}

ui_create_text2d :: proc(
  engine: ^Engine,
  position: [2]f32,
  text: string,
  font_size: f32,
  color: [4]u8 = {255, 255, 255, 255},
  z_order: i32 = 0,
  bounds: [2]f32 = {0, 0},
  h_align: HorizontalAlign = .Left,
  v_align: VerticalAlign = .Top,
) -> (
  Text2DHandle,
  bool,
) #optional_ok {
  return ui.create_text2d(
    &engine.render.ui_system,
    &engine.render.ui,
    position,
    text,
    font_size,
    color,
    z_order,
    bounds,
    h_align,
    v_align,
  )
}

ui_create_box :: proc(
  engine: ^Engine,
  position: [2]f32,
  size: [2]f32,
  background_color: [4]u8 = {0, 0, 0, 0},
  z_order: i32 = 0,
) -> (
  BoxHandle,
  bool,
) #optional_ok {
  return ui.create_box(
    &engine.render.ui_system,
    position,
    size,
    background_color,
    z_order,
  )
}

ui_get_widget :: proc(engine: ^Engine, handle: UIWidgetHandle) -> ^UIWidget {
  return ui.get_widget(&engine.render.ui_system, handle)
}

ui_get_mesh2d :: proc(engine: ^Engine, handle: Mesh2DHandle) -> ^Mesh2D {
  return ui.get_mesh2d(&engine.render.ui_system, handle)
}

ui_get_quad2d :: proc(engine: ^Engine, handle: Quad2DHandle) -> ^Quad2D {
  return ui.get_quad2d(&engine.render.ui_system, handle)
}

ui_get_text2d :: proc(engine: ^Engine, handle: Text2DHandle) -> ^Text2D {
  return ui.get_text2d(&engine.render.ui_system, handle)
}

ui_get_box :: proc(engine: ^Engine, handle: BoxHandle) -> ^Box {
  return ui.get_box(&engine.render.ui_system, handle)
}

ui_set_position :: proc(widget: ^UIWidget, position: [2]f32) {
  ui.set_position(widget, position)
}

ui_set_z_order :: proc(widget: ^UIWidget, z: i32) {
  ui.set_z_order(widget, z)
}

ui_set_visible :: proc(widget: ^UIWidget, visible: bool) {
  ui.set_visible(widget, visible)
}

ui_set_event_handler :: proc(widget: ^UIWidget, handlers: EventHandlers) {
  ui.set_event_handler(widget, handlers)
}

ui_set_user_data :: proc(widget: ^UIWidget, data: rawptr) {
  ui.set_user_data(widget, data)
}

ui_destroy_widget :: proc(engine: ^Engine, handle: UIWidgetHandle) {
  ui.destroy_widget(&engine.render.ui_system, handle)
}

ui_box_add_child :: proc(
  engine: ^Engine,
  box_handle: BoxHandle,
  child_handle: UIWidgetHandle,
) {
  ui.box_add_child(&engine.render.ui_system, box_handle, child_handle)
}

ui_set_text :: proc(engine: ^Engine, handle: Text2DHandle, text: string) {
  ui.set_text(&engine.render.ui_system, &engine.render.ui, handle, text)
}
