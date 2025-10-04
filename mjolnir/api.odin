package mjolnir

import "geometry"
import "resources"
import "world"
import vk "vendor:vulkan"

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

// Light creation helpers
create_spot_light :: proc(
  engine: ^Engine,
  handle: resources.Handle,
  color: [4]f32,
  radius: f32,
  angle: f32,
) -> (world.NodeAttachment, bool) #optional_ok {
  return world.create_spot_light_attachment(handle, &engine.resource_manager, &engine.gpu_context, color, radius, angle)
}

create_point_light :: proc(
  engine: ^Engine,
  handle: resources.Handle,
  color: [4]f32,
  radius: f32,
) -> (world.NodeAttachment, bool) #optional_ok {
  return world.create_point_light_attachment(handle, &engine.resource_manager, &engine.gpu_context, color, radius)
}

create_directional_light :: proc(
  engine: ^Engine,
  handle: resources.Handle,
  color: [4]f32,
  cast_shadow: b32 = false,
) -> (world.NodeAttachment, bool) #optional_ok  {
  return world.create_directional_light_attachment(handle, &engine.resource_manager, &engine.gpu_context, color, cast_shadow)
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
get_camera :: proc(engine: ^Engine, handle: resources.Handle) -> (^geometry.Camera, bool) {
  return resources.get_camera(&engine.resource_manager, handle)
}

get_material :: proc(engine: ^Engine, handle: resources.Handle) -> (^resources.Material, bool) {
  return resources.get_material(&engine.resource_manager, handle)
}
