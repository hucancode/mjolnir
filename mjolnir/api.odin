package mjolnir

import "animation"
import cont "containers"
import "core:math"
import "core:math/ease"
import "core:math/linalg"
import "core:sync"
import "geometry"
import "gpu"
import nav "navigation"
import "navigation/recast"
import "physics"
import "render"
import render_camera "render/camera"
import "render/post_process"
import vk "vendor:vulkan"
import "world"

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
  render_handle, render_ret := gpu.create_texture_2d_from_path(
    &engine.gctx,
    &engine.render.texture_manager,
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
  handle: gpu.Texture2DHandle,
  ok: bool,
) #optional_ok {
  ret: vk.Result
  handle, ret = gpu.create_texture_2d_from_data(
    &engine.gctx,
    &engine.render.texture_manager,
    data,
    format,
    generate_mips,
  )
  return handle, ret == .SUCCESS
}

create_texture_from_pixels :: proc(
  engine: ^Engine,
  pixels: []u8,
  extent: vk.Extent2D,
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips := false,
) -> (
  handle: gpu.Texture2DHandle,
  ok: bool,
) #optional_ok {
  ret: vk.Result
  handle, ret = gpu.allocate_texture_2d_with_data(
    &engine.render.texture_manager,
    &engine.gctx,
    raw_data(pixels),
    vk.DeviceSize(len(pixels)),
    extent,
    format,
    {.SAMPLED},
    generate_mips,
  )
  return handle, ret == .SUCCESS
}

create_texture_empty :: proc(
  engine: ^Engine,
  extent: vk.Extent2D,
  format: vk.Format,
  usage: vk.ImageUsageFlags = {.COLOR_ATTACHMENT, .SAMPLED},
) -> (
  handle: world.Image2DHandle,
  ok: bool,
) #optional_ok {
  ret: vk.Result
  gpu_handle: gpu.Texture2DHandle
  gpu_handle, ret = gpu.allocate_texture_2d(
    &engine.render.texture_manager,
    &engine.gctx,
    extent,
    format,
    usage,
  )
  handle = transmute(world.Image2DHandle)gpu_handle
  return handle, ret == .SUCCESS
}

// Bundles primitive mesh/material lookup with transform setup
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
  mesh := world.get_builtin_mesh(&engine.world, primitive)
  mat := world.get_builtin_material(&engine.world, color)
  handle := world.spawn(
    &engine.world,
    position,
    world.MeshAttachment {
      handle = mesh,
      material = mat,
      cast_shadow = cast_shadow,
    },
  ) or_return
  if rotation_angle != 0 {
    world.rotate(&engine.world, handle, rotation_angle, rotation_axis)
  }
  if scale_factor != 1.0 {
    world.scale(&engine.world, handle, scale_factor)
  }
  return handle, true
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
  camera_handle, camera_ptr := cont.alloc(
    &engine.world.cameras,
    world.CameraHandle,
  ) or_return
  defer if !ok do cont.free(&engine.world.cameras, camera_handle)
  if !world.camera_init(
    camera_ptr,
    width,
    height,
    enabled_passes,
    position,
    target,
    fov,
    near_plane,
    far_plane,
  ) {
    return {}, false
  }
  world.stage_camera_data(&engine.world.staging, camera_handle)
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
  if !cont.is_valid(engine.world.cameras, camera_handle) do return {}, false
  gpu_handle :=
    engine.render.per_camera_data[camera_handle.index].attachments[attachment_type][frame_index]
  return transmute(world.Image2DHandle)gpu_handle, true
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

build_area_types_from_tags :: proc(node_infos: []BakedNodeInfo) -> []u8 {
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
  return(
    (exclude == {} || (tags & exclude) == {}) &&
    (include == {} || (tags & include) != {}) \
  )
}

BakedNodeInfo :: struct {
  tags:         world.NodeTagSet,
  vertex_count: int,
  index_count:  int,
}

bake_geometry :: proc(
  engine: ^Engine,
  include_filter: world.NodeTagSet = {.ENVIRONMENT},
  exclude_filter: world.NodeTagSet = {},
  with_node_info: bool = false,
) -> (
  geom: geometry.Geometry,
  node_infos: []BakedNodeInfo,
  ok: bool,
) {
  vertices := make([dynamic]geometry.Vertex, 0, 4096)
  indices := make([dynamic]u32, 0, 16384)
  infos := make([dynamic]BakedNodeInfo, 0, 64) if with_node_info else nil
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
      append(&infos, BakedNodeInfo{tags = node.tags, vertex_count = len(mesh_geom.vertices), index_count = len(mesh_geom.indices)})
    }
  }
  if len(vertices) == 0 {
    delete(vertices)
    delete(indices)
    if with_node_info do delete(infos)
    return {}, nil, false
  }
  geom = geometry.Geometry {
    vertices = vertices[:],
    indices  = indices[:],
    aabb     = geometry.aabb_from_vertices(vertices[:]),
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
  mesh_handle, _, ok = world.create_mesh(&engine.world, baked_geom, true)
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
  if !nav.build_navmesh(&engine.nav.nav_mesh, nav_geom, recast_config) {
    return false
  }
  if !nav.init(&engine.nav) {
    return false
  }
  return true
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
