package mjolnir

import "core:strings"
import "core:math"
import "core:math/linalg"
import "geometry"
import "resources"
import "world"
import "render/post_process"
import "navigation/recast"
import vk "vendor:vulkan"
import "vendor:glfw"

// ============================================================================
// USER API - Simplified entry points hiding internal managers
// ============================================================================

// Texture creation - hide gpu_context and resource_manager
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
) -> (resources.Handle, bool) #optional_ok {
  return resources.create_texture_from_path_handle(
    &engine.gpu_context,
    &engine.resource_manager,
    path,
    format,
    generate_mips,
    usage,
    is_hdr,
  )
}

create_texture_from_data :: proc(
  engine: ^Engine,
  data: []u8,
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips := false,
) -> (resources.Handle, bool) #optional_ok {
  return resources.create_texture_from_data_handle(
    &engine.gpu_context,
    &engine.resource_manager,
    data,
    format,
    generate_mips,
  )
}

create_texture_from_pixels :: proc(
  engine: ^Engine,
  pixels: []u8,
  width: int,
  height: int,
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips := false,
) -> (resources.Handle, bool) #optional_ok {
  return resources.create_texture_from_pixels_handle(
    &engine.gpu_context,
    &engine.resource_manager,
    pixels,
    width,
    height,
    format,
    generate_mips,
  )
}

create_texture_empty :: proc(
  engine: ^Engine,
  width, height: u32,
  format: vk.Format,
  usage: vk.ImageUsageFlags = {.COLOR_ATTACHMENT, .SAMPLED},
) -> (resources.Handle, bool) #optional_ok {
  return resources.create_empty_texture_2d_handle(
    &engine.gpu_context,
    &engine.resource_manager,
    width,
    height,
    format,
    usage,
  )
}

create_material :: proc(
  engine: ^Engine,
  features: resources.ShaderFeatureSet = {},
  type: resources.MaterialType = .PBR,
  albedo_handle: resources.Handle = {},
  metallic_roughness_handle: resources.Handle = {},
  normal_handle: resources.Handle = {},
  emissive_handle: resources.Handle = {},
  occlusion_handle: resources.Handle = {},
  metallic_value: f32 = 0.0,
  roughness_value: f32 = 1.0,
  emissive_value: f32 = 0.0,
  base_color_factor: [4]f32 = {1.0, 1.0, 1.0, 1.0},
) -> (resources.Handle, bool) #optional_ok {
  return resources.create_material_handle(
    &engine.resource_manager,
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
  )
}

create_mesh :: proc(engine: ^Engine, geom: geometry.Geometry) -> (resources.Handle, bool) #optional_ok {
  return resources.create_mesh_handle(&engine.gpu_context, &engine.resource_manager, geom)
}

// Node spawning - hide world and resource_manager
spawn :: proc(
  engine: ^Engine,
  attachment: world.NodeAttachment = nil,
) -> (resources.Handle, ^world.Node, bool) {
  return world.spawn(&engine.world, attachment, &engine.resource_manager)
}

spawn_at :: proc(
  engine: ^Engine,
  position: [3]f32,
  attachment: world.NodeAttachment = nil,
) -> (resources.Handle, ^world.Node, bool) {
  return world.spawn_at(&engine.world, position, attachment, &engine.resource_manager)
}

spawn_child :: proc(
  engine: ^Engine,
  parent: resources.Handle,
  attachment: world.NodeAttachment = nil,
) -> (resources.Handle, ^world.Node, bool) {
  return world.spawn_child(&engine.world, parent, attachment, &engine.resource_manager)
}

// World/node manipulation
load_gltf :: proc(engine: ^Engine, path: string) -> ([]resources.Handle, bool) {
  nodes, result := world.load_gltf(&engine.world, &engine.resource_manager, &engine.gpu_context, path)
  return nodes[:], result == .success
}

get_node :: proc(engine: ^Engine, handle: resources.Handle) -> ^world.Node {
  return resources.get(engine.world.nodes, handle)
}

despawn :: proc(engine: ^Engine, handle: resources.Handle) {
  world.despawn(&engine.world, handle)
}

translate_handle :: proc(engine: ^Engine, handle: resources.Handle, x: f32 = 0, y: f32 = 0, z: f32 = 0) {
  world.translate(&engine.world, handle, x, y, z)
}

translate_node :: proc(node: ^world.Node, x: f32 = 0, y: f32 = 0, z: f32 = 0) {
  world.translate(node, x, y, z)
}

translate :: proc {
    translate_node,
    translate_handle,
}

translate_by_handle :: proc(engine: ^Engine, handle: resources.Handle, x: f32 = 0, y: f32 = 0, z: f32 = 0) {
  world.translate_by(&engine.world, handle, x, y, z)
}

translate_by_node :: proc(node: ^world.Node, x: f32 = 0, y: f32 = 0, z: f32 = 0) {
  world.translate_by(node, x, y, z)
}

translate_by :: proc {
    translate_by_node,
    translate_by_handle,
}

rotate_handle :: proc(engine: ^Engine, handle: resources.Handle, angle: f32, axis: [3]f32 = {0, 1, 0}) {
  world.rotate(&engine.world, handle, angle, axis)
}

rotate_node :: proc(node: ^world.Node, angle: f32, axis: [3]f32 = {0, 1, 0}) {
  world.rotate(node, angle, axis)
}

rotate :: proc {
    rotate_node,
    rotate_handle,
}

rotate_by_handle :: proc(engine: ^Engine, handle: resources.Handle, angle: f32, axis: [3]f32 = {0, 1, 0}) {
  world.rotate_by(&engine.world, handle, angle, axis)
}

rotate_by_node :: proc(node: ^world.Node, angle: f32, axis: [3]f32 = {0, 1, 0}) {
  world.rotate_by(node, angle, axis)
}

rotate_by :: proc {
    rotate_by_node,
    rotate_by_handle,
}

scale_node :: proc(node: ^world.Node, s: f32) {
  world.scale(node, s)
}

scale_handle :: proc(engine: ^Engine, handle: resources.Handle, s: f32) {
  world.scale(&engine.world, handle, s)
}

scale :: proc {
    scale_node,
    scale_handle,
}

scale_by_handle :: proc(engine: ^Engine, handle: resources.Handle, s: f32) {
  world.scale_by(&engine.world, handle, s)
}

scale_by_node :: proc(node: ^world.Node, s: f32) {
  world.scale_by(node, s)
}

scale_by :: proc {
    scale_by_node,
    scale_by_handle,
}

// Light spawning - creates node with light attachment
spawn_spot_light :: proc(
  engine: ^Engine,
  color: [4]f32,
  radius: f32,
  angle: f32,
  position: [3]f32 = {0, 0, 0},
) -> (handle: resources.Handle, node: ^world.Node, ok: bool) {
  handle, node, ok = spawn(engine, nil)
  if !ok do return

  attachment := world.create_spot_light_attachment(handle, &engine.resource_manager, &engine.gpu_context, color, radius, angle) or_return
  node.attachment = attachment

  if position != {0, 0, 0} {
    translate(node, position.x, position.y, position.z)
  }

  return
}

spawn_point_light :: proc(
  engine: ^Engine,
  color: [4]f32,
  radius: f32,
  position: [3]f32 = {0, 0, 0},
) -> (handle: resources.Handle, node: ^world.Node, ok: bool) {
  handle, node, ok = spawn(engine, nil)
  if !ok do return

  attachment := world.create_point_light_attachment(handle, &engine.resource_manager, &engine.gpu_context, color, radius) or_return
  node.attachment = attachment

  if position != {0, 0, 0} {
    translate(node, position.x, position.y, position.z)
  }

  return
}

spawn_directional_light :: proc(
  engine: ^Engine,
  color: [4]f32,
  cast_shadow := true,
  position: [3]f32 = {0, 0, 0},
) -> (handle: resources.Handle, node: ^world.Node, ok: bool) {
  handle, node, ok = spawn(engine, nil)
  if !ok do return

  attachment := world.create_directional_light_attachment(handle, &engine.resource_manager, &engine.gpu_context, color, b32(cast_shadow))
  node.attachment = attachment

  if position != {0, 0, 0} {
    translate(node, position.x, position.y, position.z)
  }

  return
}

// Emitter creation
create_emitter :: proc(
  engine: ^Engine,
  owner: resources.Handle,
  emitter: resources.Emitter,
) -> (resources.Handle, bool) #optional_ok {
  return resources.create_emitter_handle(&engine.resource_manager, owner, emitter)
}

// Forcefield creation
create_forcefield :: proc(
  engine: ^Engine,
  owner: resources.Handle,
  forcefield: resources.ForceField,
) -> (resources.Handle, bool) #optional_ok {
  return resources.create_forcefield_handle(&engine.resource_manager, owner, forcefield)
}

// Animation
play_animation :: proc(
  engine: ^Engine,
  handle: resources.Handle,
  name: string,
) {
  world.play_animation(&engine.world, &engine.resource_manager, handle, name)
}

// Resource getters
get_camera :: proc(engine: ^Engine, handle: resources.Handle) -> (^resources.Camera, bool) {
  return resources.get_camera(&engine.resource_manager, handle)
}

get_material :: proc(engine: ^Engine, handle: resources.Handle) -> (^resources.Material, bool) {
  return resources.get_material(&engine.resource_manager, handle)
}

// Camera management
create_camera :: proc(
  engine: ^Engine,
  width, height: u32,
  enabled_passes: resources.PassTypeSet = {.SHADOW, .GEOMETRY, .LIGHTING, .TRANSPARENCY, .PARTICLES, .POST_PROCESS},
  position: [3]f32 = {0, 0, 3},
  target: [3]f32 = {0, 0, 0},
  fov: f32 = 1.57079632679,
  near_plane: f32 = 0.1,
  far_plane: f32 = 100.0,
) -> (resources.Handle, bool) #optional_ok {
  camera_handle, camera_ptr, camera_ok := resources.alloc(&engine.resource_manager.cameras)
  if !camera_ok {
    return {}, false
  }

  init_result := resources.camera_init(
    camera_ptr,
    &engine.gpu_context,
    &engine.resource_manager,
    width,
    height,
    engine.swapchain.format.format,
    .D32_SFLOAT,
    enabled_passes,
    position,
    target,
    fov,
    near_plane,
    far_plane,
  )

  if init_result != .SUCCESS {
    resources.free(&engine.resource_manager.cameras, camera_handle)
    return {}, false
  }

  return camera_handle, true
}

get_camera_attachment :: proc(
  engine: ^Engine,
  camera_handle: resources.Handle,
  attachment_type: resources.AttachmentType,
  frame_index: u32 = 0,
) -> (resources.Handle, bool) #optional_ok {
  camera, camera_ok := resources.get_camera(&engine.resource_manager, camera_handle)
  if !camera_ok {
    return {}, false
  }

  handle := resources.camera_get_attachment(camera, attachment_type, frame_index)
  if handle.generation == 0 {
    return {}, false
  }

  return handle, true
}

update_material_texture :: proc(
  engine: ^Engine,
  material_handle: resources.Handle,
  texture_type: resources.ShaderFeature,
  texture_handle: resources.Handle,
) -> bool {
  material, material_ok := resources.get_material(&engine.resource_manager, material_handle)
  if !material_ok {
    return false
  }

  // Update the appropriate texture based on type
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

  // Update GPU data
  result := resources.material_write_to_gpu(&engine.resource_manager, material_handle, material)
  return result == .SUCCESS
}

set_main_camera_look_at :: proc(engine: ^Engine, from: [3]f32, to: [3]f32, world_up: [3]f32 = {0, 1, 0}) -> bool {
  main_camera := get_main_camera(engine)
  if main_camera == nil {
    return false
  }
  resources.camera_look_at(main_camera, from, to, world_up)
  return true
}

set_main_camera_position :: proc(engine: ^Engine, position: [3]f32) -> bool {
  main_camera := get_main_camera(engine)
  if main_camera == nil {
    return false
  }
  resources.camera_set_position(main_camera, position)
  return true
}

set_main_camera_rotation :: proc(engine: ^Engine, rotation: quaternion128) -> bool {
  main_camera := get_main_camera(engine)
  if main_camera == nil {
    return false
  }
  resources.camera_set_rotation(main_camera, rotation)
  return true
}

move_main_camera :: proc(engine: ^Engine, delta: [3]f32) -> bool {
  main_camera := get_main_camera(engine)
  if main_camera == nil {
    return false
  }
  resources.camera_move(main_camera, delta)
  return true
}

rotate_main_camera :: proc(engine: ^Engine, delta_yaw, delta_pitch: f32) -> bool {
  main_camera := get_main_camera(engine)
  if main_camera == nil {
    return false
  }
  resources.camera_rotate(main_camera, delta_yaw, delta_pitch)
  return true
}

set_main_camera_aspect_ratio :: proc(engine: ^Engine, aspect_ratio: f32) -> bool {
  main_camera := get_main_camera(engine)
  if main_camera == nil {
    return false
  }
  resources.camera_update_aspect_ratio(main_camera, aspect_ratio)
  return true
}

// Camera manipulation - users should directly use geometry.camera_* functions

// Node transform getters - these add value by providing safe access to node properties

get_node_position :: proc(engine: ^Engine, handle: resources.Handle) -> ([3]f32, bool) {
  node := get_node(engine, handle)
  if node == nil {
    return {}, false
  }
  return node.transform.position, true
}

set_node_position :: proc(engine: ^Engine, handle: resources.Handle, position: [3]f32) -> bool {
  node := get_node(engine, handle)
  if node == nil {
    return false
  }
  node.transform.position = position
  return true
}

get_node_rotation :: proc(engine: ^Engine, handle: resources.Handle) -> (quaternion128, bool) {
  node := get_node(engine, handle)
  if node == nil {
    return quaternion128{}, false
  }
  return node.transform.rotation, true
}

set_node_rotation :: proc(engine: ^Engine, handle: resources.Handle, rotation: quaternion128) -> bool {
  node := get_node(engine, handle)
  if node == nil {
    return false
  }
  node.transform.rotation = rotation
  return true
}

get_node_scale :: proc(engine: ^Engine, handle: resources.Handle) -> ([3]f32, bool) {
  node := get_node(engine, handle)
  if node == nil {
    return {}, false
  }
  return node.transform.scale, true
}

set_node_scale :: proc(engine: ^Engine, handle: resources.Handle, scale: [3]f32) -> bool {
  node := get_node(engine, handle)
  if node == nil {
    return false
  }
  node.transform.scale = scale
  return true
}

set_node_scale_uniform :: proc(engine: ^Engine, handle: resources.Handle, scale: f32) -> bool {
  return set_node_scale(engine, handle, {scale, scale, scale})
}

// Navigation mesh creation and pathfinding
build_navigation_mesh_from_world :: proc(
  engine: ^Engine,
  cell_size: f32 = 0.3,
  cell_height: f32 = 0.2,
  agent_height: f32 = 2.0,
  agent_radius: f32 = 0.6,
  agent_max_climb: f32 = 0.9,
  agent_max_slope: f32 = 45.0,
  region_min_size: f32 = 8.0,
  region_merge_size: f32 = 20.0,
  edge_max_len: f32 = 12.0,
  edge_max_error: f32 = 1.3,
  verts_per_poly: f32 = 6.0,
  detail_sample_dist: f32 = 6.0,
  detail_sample_max_error: f32 = 1.0,
) -> (resources.Handle, bool) #optional_ok {
  config := recast.Config{}
  config.cs = cell_size
  config.ch = cell_height
  config.walkable_height = i32(math.ceil(f64(agent_height / config.ch)))
  config.walkable_radius = i32(math.ceil(f64(agent_radius / config.cs)))
  config.walkable_climb = i32(math.floor(f64(agent_max_climb / config.ch)))
  config.walkable_slope_angle = agent_max_slope
  config.min_region_area = i32(math.floor(f64(region_min_size * region_min_size)))
  config.merge_region_area = i32(math.floor(f64(region_merge_size * region_merge_size)))
  config.max_edge_len = i32(math.floor(f64(edge_max_len / config.cs)))
  config.max_simplification_error = edge_max_error
  config.max_verts_per_poly = i32(verts_per_poly)
  config.detail_sample_dist = detail_sample_dist
  config.detail_sample_max_error = detail_sample_max_error

  return world.build_navigation_mesh_from_world(
    &engine.world,
    &engine.resource_manager,
    &engine.gpu_context,
    config,
  )
}

create_navigation_context :: proc(
  engine: ^Engine,
  nav_mesh_handle: resources.Handle,
) -> (resources.Handle, bool) #optional_ok {
  return world.create_navigation_context(&engine.world, &engine.resource_manager, &engine.gpu_context, nav_mesh_handle)
}

nav_find_path :: proc(
  engine: ^Engine,
  nav_context_handle: resources.Handle,
  start_pos: [3]f32,
  end_pos: [3]f32,
  max_path_length: i32 = 256,
) -> [][3]f32 {
  path, success := world.nav_find_path(&engine.world, &engine.resource_manager, &engine.gpu_context, nav_context_handle, start_pos, end_pos, max_path_length)
  if !success {
    return nil
  }
  return path
}

nav_is_position_walkable :: proc(
  engine: ^Engine,
  nav_context_handle: resources.Handle,
  position: [3]f32,
) -> bool {
  return world.nav_is_position_walkable(&engine.world, &engine.resource_manager, &engine.gpu_context, nav_context_handle, position)
}

spawn_nav_agent_at :: proc(
  engine: ^Engine,
  position: [3]f32,
  radius: f32 = 0.6,
  height: f32 = 2.0,
) -> (resources.Handle, bool) #optional_ok {
  handle, _ := world.spawn_nav_agent_at(&engine.world, &engine.resource_manager, &engine.gpu_context, position, radius, height)
  return handle, handle.index != 0xFFFFFFFF
}

nav_agent_set_target :: proc(
  engine: ^Engine,
  agent_handle: resources.Handle,
  target_pos: [3]f32,
  nav_context_handle: resources.Handle = {},
) -> bool {
  return world.nav_agent_set_target(&engine.world, &engine.resource_manager, &engine.gpu_context, agent_handle, target_pos, nav_context_handle)
}

// Animation - use world.play_animation() directly

// Post-processing effects - add effects to the render pipeline
add_bloom :: proc(
  engine: ^Engine,
  threshold: f32 = 0.2,
  intensity: f32 = 1.0,
  blur_radius: f32 = 4.0,
) {
  post_process.add_bloom(&engine.render.post_process, threshold, intensity, blur_radius)
}

add_tonemap :: proc(
  engine: ^Engine,
  exposure: f32 = 1.0,
  gamma: f32 = 2.2,
) {
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

add_blur :: proc(
  engine: ^Engine,
  radius: f32,
  gaussian: bool = true,
) {
  post_process.add_blur(&engine.render.post_process, radius, gaussian)
}

add_outline :: proc(
  engine: ^Engine,
  thickness: f32,
  color: [3]f32,
) {
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
  post_process.add_crosshatch(&engine.render.post_process, resolution, hatch_offset_y, lum_threshold_01, lum_threshold_02, lum_threshold_03, lum_threshold_04)
}

add_dof :: proc(
  engine: ^Engine,
  focus_distance: f32 = 10.0,
  focus_range: f32 = 2.0,
  blur_strength: f32 = 1.0,
  bokeh_intensity: f32 = 0.5,
) {
  post_process.add_dof(&engine.render.post_process, focus_distance, focus_range, blur_strength, bokeh_intensity)
}

// Clear all post-processing effects
clear_post_process_effects :: proc(engine: ^Engine) {
  post_process.clear_effects(&engine.render.post_process)
}

// Engine utility functions

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
  return u32(len(engine.world.nodes.entries) - len(engine.world.nodes.free_indices))
}

get_material_count :: proc(engine: ^Engine) -> u32 {
  return u32(len(engine.resource_manager.materials.entries) - len(engine.resource_manager.materials.free_indices))
}

get_mesh_count :: proc(engine: ^Engine) -> u32 {
  return u32(len(engine.resource_manager.meshes.entries) - len(engine.resource_manager.meshes.free_indices))
}

get_texture_count :: proc(engine: ^Engine) -> u32 {
  return u32(len(engine.resource_manager.image_2d_buffers.entries) - len(engine.resource_manager.image_2d_buffers.free_indices))
}

set_debug_ui_enabled :: proc(engine: ^Engine, enabled: bool) {
  engine.debug_ui_enabled = enabled
}

get_debug_ui_enabled :: proc(engine: ^Engine) -> bool {
  return engine.debug_ui_enabled
}
