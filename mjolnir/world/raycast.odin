package world

import "../geometry"
import "../resources"

// Node raycast hit result
NodeRayHit :: struct {
  node_handle: resources.Handle,
  t:           f32,
  hit:         bool,
}

// World raycast - finds closest mesh node hit by ray
// tag_filter: Only test nodes that have ALL specified tags
world_raycast :: proc(
  world: ^World,
  rm: ^resources.Manager,
  ray: geometry.Ray,
  tag_filter: NodeTagSet = {},
  config: geometry.RaycastConfig = geometry.DEFAULT_RAYCAST_CONFIG,
) -> NodeRayHit {
  if world.node_octree.root == nil do return {}
  intersection_func :: proc(
    ray: geometry.Ray,
    entry: NodeEntry,
    max_t: f32,
  ) -> (
    hit: bool,
    t: f32,
  ) {
    if .MESH not_in entry.tags do return false, 0
    inv_dir := [3]f32 {
      1.0 / ray.direction.x,
      1.0 / ray.direction.y,
      1.0 / ray.direction.z,
    }
    t_near, t_far := geometry.ray_aabb_intersection(
      ray.origin,
      inv_dir,
      entry.bounds,
    )
    // No intersection if t_near > t_far (ray misses box)
    if t_near > t_far do return false, 0
    // No hit if box is entirely behind ray
    if t_far < 0 do return false, 0
    // No hit if intersection is beyond max distance
    if t_near > max_t do return false, 0
    // If ray origin is inside box, use t=0 as hit point
    hit_t := max(0, t_near)
    if hit_t > max_t do return false, 0
    return true, hit_t
  }
  result := geometry.octree_raycast(
    &world.node_octree,
    ray,
    config.max_dist,
    intersection_func,
  )
  if result.hit {
    if tag_filter != {} && (tag_filter & result.primitive.tags) != tag_filter do return {}
    return NodeRayHit {
      node_handle = result.primitive.handle,
      t = result.t,
      hit = true,
    }
  }
  return {}
}

// World raycast - finds any mesh node hit by ray (early exit)
// tag_filter: Only test nodes that have ALL specified tags
world_raycast_single :: proc(
  world: ^World,
  rm: ^resources.Manager,
  ray: geometry.Ray,
  tag_filter: NodeTagSet = {},
  config: geometry.RaycastConfig = geometry.DEFAULT_RAYCAST_CONFIG,
) -> NodeRayHit {
  if world.node_octree.root == nil do return {}
  intersection_func :: proc(
    ray: geometry.Ray,
    entry: NodeEntry,
    max_t: f32,
  ) -> (
    hit: bool,
    t: f32,
  ) {
    if .MESH not_in entry.tags do return false, 0
    inv_dir := [3]f32 {
      1.0 / ray.direction.x,
      1.0 / ray.direction.y,
      1.0 / ray.direction.z,
    }
    t_near, t_far := geometry.ray_aabb_intersection(
      ray.origin,
      inv_dir,
      entry.bounds,
    )
    // No intersection if t_near > t_far (ray misses box)
    if t_near > t_far do return false, 0
    // No hit if box is entirely behind ray
    if t_far < 0 do return false, 0
    // No hit if intersection is beyond max distance
    if t_near > max_t do return false, 0
    // If ray origin is inside box, use t=0 as hit point
    hit_t := max(0, t_near)
    if hit_t > max_t do return false, 0
    return true, hit_t
  }
  result := geometry.octree_raycast_single(
    &world.node_octree,
    ray,
    config.max_dist,
    intersection_func,
  )
  if result.hit {
    if tag_filter != {} && (tag_filter & result.primitive.tags) != tag_filter do return {}
    return NodeRayHit {
      node_handle = result.primitive.handle,
      t = result.t,
      hit = true,
    }
  }
  return {}
}

world_raycast_multi :: proc(
  world: ^World,
  rm: ^resources.Manager,
  ray: geometry.Ray,
  tag_filter: NodeTagSet = {},
  config: geometry.RaycastConfig = geometry.DEFAULT_RAYCAST_CONFIG,
  results: ^[dynamic]NodeRayHit,
) {
  clear(results)
  if world.node_octree.root == nil do return
  intersection_func :: proc(
    ray: geometry.Ray,
    entry: NodeEntry,
    max_t: f32,
  ) -> (
    hit: bool,
    t: f32,
  ) {
    if .MESH not_in entry.tags do return false, 0
    inv_dir := [3]f32 {
      1.0 / ray.direction.x,
      1.0 / ray.direction.y,
      1.0 / ray.direction.z,
    }
    t_near, t_far := geometry.ray_aabb_intersection(
      ray.origin,
      inv_dir,
      entry.bounds,
    )
    // No intersection if t_near > t_far (ray misses box)
    if t_near > t_far do return false, 0
    // No hit if box is entirely behind ray
    if t_far < 0 do return false, 0
    // No hit if intersection is beyond max distance
    if t_near > max_t do return false, 0
    // If ray origin is inside box, use t=0 as hit point
    hit_t := max(0, t_near)
    if hit_t > max_t do return false, 0
    return true, hit_t
  }
  entry_results := make(
    [dynamic]geometry.RayHit(NodeEntry),
    context.temp_allocator,
  )
  geometry.octree_raycast_multi(
    &world.node_octree,
    ray,
    config.max_dist,
    intersection_func,
    &entry_results,
  )
  for hit in entry_results {
    if hit.hit {
      if tag_filter != {} && (tag_filter & hit.primitive.tags) != tag_filter do continue
      append(
        results,
        NodeRayHit{node_handle = hit.primitive.handle, t = hit.t, hit = true},
      )
    }
  }
}

// Camera-based world raycast - finds closest mesh node from viewport coordinates
// tag_filter: Only test nodes that have ALL specified tags
camera_world_raycast :: proc(
  world: ^World,
  rm: ^resources.Manager,
  camera: ^resources.Camera,
  mouse_x, mouse_y: f32,
  tag_filter: NodeTagSet = {},
  config: geometry.RaycastConfig = geometry.DEFAULT_RAYCAST_CONFIG,
) -> NodeRayHit {
  ray_origin, ray_dir := resources.camera_viewport_to_world_ray(
    camera,
    mouse_x,
    mouse_y,
  )
  ray := geometry.Ray {
    origin    = ray_origin,
    direction = ray_dir,
  }
  return world_raycast(world, rm, ray, tag_filter, config)
}

// Camera-based world raycast - finds any mesh node from viewport coordinates (early exit)
// tag_filter: Only test nodes that have ALL specified tags
camera_world_raycast_single :: proc(
  world: ^World,
  rm: ^resources.Manager,
  camera: ^resources.Camera,
  mouse_x, mouse_y: f32,
  tag_filter: NodeTagSet = {},
  config: geometry.RaycastConfig = geometry.DEFAULT_RAYCAST_CONFIG,
) -> NodeRayHit {
  ray_origin, ray_dir := resources.camera_viewport_to_world_ray(
    camera,
    mouse_x,
    mouse_y,
  )
  ray := geometry.Ray {
    origin    = ray_origin,
    direction = ray_dir,
  }
  return world_raycast_single(world, rm, ray, tag_filter, config)
}

// Camera-based world raycast - finds all mesh nodes from viewport coordinates
// tag_filter: Only test nodes that have ALL specified tags
camera_world_raycast_multi :: proc(
  world: ^World,
  rm: ^resources.Manager,
  camera: ^resources.Camera,
  mouse_x, mouse_y: f32,
  tag_filter: NodeTagSet = {},
  config: geometry.RaycastConfig = geometry.DEFAULT_RAYCAST_CONFIG,
  results: ^[dynamic]NodeRayHit,
) {
  ray_origin, ray_dir := resources.camera_viewport_to_world_ray(
    camera,
    mouse_x,
    mouse_y,
  )
  ray := geometry.Ray {
    origin    = ray_origin,
    direction = ray_dir,
  }
  world_raycast_multi(world, rm, ray, tag_filter, config, results)
}
