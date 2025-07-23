package geometry

import "core:math"
import "core:math/linalg"
import "core:slice"

OctreeNode :: struct($T: typeid) {
  bounds:      Aabb,
  center:      [3]f32,
  children:    [8]^OctreeNode(T),
  items:       [dynamic]T,
  depth:       i32,
  total_items: i32,
}

Octree :: struct($T: typeid) {
  root:        ^OctreeNode(T),
  max_depth:   i32,
  max_items:   i32,
  min_size:    f32,
  bounds_func: proc(t: T) -> Aabb,
  point_func:  proc(t: T) -> [3]f32,
}

octree_init :: proc(
  octree: ^Octree($T),
  bounds: Aabb,
  max_depth: i32 = 8,
  max_items: i32 = 8,
) {
  octree.root = new(OctreeNode(T))
  octree.root.bounds = bounds
  octree.root.center = aabb_center(bounds)
  octree.root.depth = 0
  octree.root.items = make([dynamic]T)
  octree.root.total_items = 0
  octree.max_depth = max_depth
  octree.max_items = max_items
  shift_val := u32(1) << u32(max_depth)
  octree.min_size = min_vec3(aabb_size(bounds)) / f32(shift_val)
}

octree_deinit :: proc(octree: ^Octree($T)) {
  octree_node_deinit(octree.root)
  free(octree.root)
  octree.root = nil
}

@(private)
octree_node_deinit :: proc(node: ^OctreeNode($T)) {
  if node == nil do return
  for i in 0 ..< 8 {
    if node.children[i] != nil {
      octree_node_deinit(node.children[i])
      free(node.children[i])
    }
  }

  delete(node.items)
}

@(private)
get_octant :: proc(center: [3]f32, point: [3]f32) -> i32 {
  octant: i32 = 0
  if point.x >= center.x do octant |= 0b001
  if point.y >= center.y do octant |= 0b010
  if point.z >= center.z do octant |= 0b100
  return octant
}

@(private)
get_octant_for_aabb :: proc(node_center: [3]f32, aabb: Aabb) -> i32 {
  aabb_center := aabb_center(aabb)

  if aabb.min.x < node_center.x && aabb.max.x > node_center.x do return -1
  if aabb.min.y < node_center.y && aabb.max.y > node_center.y do return -1
  if aabb.min.z < node_center.z && aabb.max.z > node_center.z do return -1

  return get_octant(node_center, aabb_center)
}

@(private)
get_child_bounds :: proc(parent: ^OctreeNode($T), octant: i32) -> Aabb {
  size := (parent.bounds.max - parent.bounds.min) * 0.5
  min := parent.bounds.min

  if octant & 1 != 0 do min.x += size.x
  if octant & 2 != 0 do min.y += size.y
  if octant & 4 != 0 do min.z += size.z

  return Aabb{min = min, max = min + size}
}

@(private)
get_child_center :: proc(
  parent_center: [3]f32,
  parent_size: [3]f32,
  octant: i32,
) -> [3]f32 {
  offset := parent_size * 0.25
  center := parent_center

  if octant & 1 != 0 {
    center.x += offset.x
  } else {
    center.x -= offset.x
  }
  if octant & 2 != 0 {
    center.y += offset.y
  } else {
    center.y -= offset.y
  }
  if octant & 4 != 0 {
    center.z += offset.z
  } else {
    center.z -= offset.z
  }

  return center
}

@(private)
octree_subdivide :: proc(node: ^OctreeNode($T)) {
  parent_size := node.bounds.max - node.bounds.min

  for i in 0 ..< 8 {
    child := new(OctreeNode(T))
    child.bounds = get_child_bounds(node, i32(i))
    child.center = get_child_center(node.center, parent_size, i32(i))
    child.depth = node.depth + 1
    child.items = make([dynamic]T)
    child.total_items = 0
    node.children[i] = child
  }
}

@(private)
should_subdivide :: proc(octree: ^Octree($T), node: ^OctreeNode(T)) -> bool {
  if node.depth >= octree.max_depth do return false

  size := min_vec3(node.bounds.max - node.bounds.min)
  if size <= octree.min_size do return false

  if i32(len(node.items)) <= octree.max_items do return false

  octant_counts: [8]i32
  for item in node.items {
    bounds := octree.bounds_func(item)
    octant := get_octant_for_aabb(node.center, bounds)
    if octant >= 0 do octant_counts[octant] += 1
    else do return true
  }

  non_empty := 0
  for count in octant_counts {
    if count > 0 do non_empty += 1
  }

  return non_empty > 1
}

octree_insert :: proc(octree: ^Octree($T), item: T) -> bool {
  bounds := octree.bounds_func(item)

  if !aabb_contains(octree.root.bounds, bounds) do return false

  return octree_node_insert(octree, octree.root, item, bounds)
}

@(private)
octree_node_insert :: proc(
  octree: ^Octree($T),
  node: ^OctreeNode(T),
  item: T,
  bounds: Aabb,
) -> bool {
  if node.children[0] == nil {
    append(&node.items, item)
    node.total_items += 1

    if should_subdivide(octree, node) {
      octree_subdivide(node)

      old_items := node.items[:]
      clear(&node.items)
      node.total_items = i32(len(node.items))

      for old_item in old_items {
        old_bounds := octree.bounds_func(old_item)
        octree_node_insert_to_children(octree, node, old_item, old_bounds)
      }
    }

    return true
  }

  if octree_node_insert_to_children(octree, node, item, bounds) {
    node.total_items += 1
    return true
  }
  return false
}

@(private)
octree_node_insert_to_children :: proc(
  octree: ^Octree($T),
  node: ^OctreeNode(T),
  item: T,
  bounds: Aabb,
) -> bool {
  octant := get_octant_for_aabb(node.center, bounds)

  if octant >= 0 {
    return octree_node_insert(octree, node.children[octant], item, bounds)
  } else {
    append(&node.items, item)
    node.total_items += 1
    return true
  }
}

octree_query_aabb :: proc(
  octree: ^Octree($T),
  query_bounds: Aabb,
  results: ^[dynamic]T,
) {
  clear(results)
  octree_node_query_aabb(octree, octree.root, query_bounds, results)
}

octree_query_aabb_limited :: proc(
  octree: ^Octree($T),
  query_bounds: Aabb,
  results: ^[dynamic]T,
  max_results: int,
) {
  clear(results)
  octree_node_query_aabb_limited(
    octree,
    octree.root,
    query_bounds,
    results,
    max_results,
  )
}

@(private)
octree_node_query_aabb :: proc(
  octree: ^Octree($T),
  node: ^OctreeNode(T),
  query_bounds: Aabb,
  results: ^[dynamic]T,
) {
  if !aabb_intersects(node.bounds, query_bounds) do return
  for item in node.items {
    item_bounds := octree.bounds_func(item)
    if aabb_intersects(item_bounds, query_bounds) {
      append(results, item)
    }
  }
  if node.children[0] != nil {
    octree_node_query_aabb(octree, node.children[0], query_bounds, results)
    octree_node_query_aabb(octree, node.children[1], query_bounds, results)
    octree_node_query_aabb(octree, node.children[2], query_bounds, results)
    octree_node_query_aabb(octree, node.children[3], query_bounds, results)
    octree_node_query_aabb(octree, node.children[4], query_bounds, results)
    octree_node_query_aabb(octree, node.children[5], query_bounds, results)
    octree_node_query_aabb(octree, node.children[6], query_bounds, results)
    octree_node_query_aabb(octree, node.children[7], query_bounds, results)
  }
}

@(private)
octree_node_query_aabb_limited :: proc(
  octree: ^Octree($T),
  node: ^OctreeNode(T),
  query_bounds: Aabb,
  results: ^[dynamic]T,
  max_results: int,
) {
  if !aabb_intersects(node.bounds, query_bounds) do return
  if len(results) >= max_results do return

  for item in node.items {
    if len(results) >= max_results do return
    item_bounds := octree.bounds_func(item)
    if aabb_intersects(item_bounds, query_bounds) {
      append(results, item)
    }
  }

  if node.children[0] != nil {
    for i in 0 ..< 8 {
      if len(results) >= max_results do return
      octree_node_query_aabb_limited(
        octree,
        node.children[i],
        query_bounds,
        results,
        max_results,
      )
    }
  }
}

octree_query_sphere :: proc(
  octree: ^Octree($T),
  center: [3]f32,
  radius: f32,
  results: ^[dynamic]T,
) {
  clear(results)
  octree_node_query_sphere(octree, octree.root, center, radius, results)
}

@(private)
octree_node_query_sphere :: proc(
  octree: ^Octree($T),
  node: ^OctreeNode(T),
  center: [3]f32,
  radius: f32,
  results: ^[dynamic]T,
) {
  if !aabb_sphere_intersects(node.bounds, center, radius) do return
  for item in node.items {
    item_bounds := octree.bounds_func(item)
    if aabb_sphere_intersects(item_bounds, center, radius) {
      append(results, item)
    }
  }
  if node.children[0] != nil {
    octree_node_query_sphere(octree, node.children[0], center, radius, results)
    octree_node_query_sphere(octree, node.children[1], center, radius, results)
    octree_node_query_sphere(octree, node.children[2], center, radius, results)
    octree_node_query_sphere(octree, node.children[3], center, radius, results)
    octree_node_query_sphere(octree, node.children[4], center, radius, results)
    octree_node_query_sphere(octree, node.children[5], center, radius, results)
    octree_node_query_sphere(octree, node.children[6], center, radius, results)
    octree_node_query_sphere(octree, node.children[7], center, radius, results)
  }
}

Ray :: struct {
  origin:    [3]f32,
  direction: [3]f32,
}

octree_query_ray :: proc(
  octree: ^Octree($T),
  ray: Ray,
  max_dist: f32,
  results: ^[dynamic]T,
) {
  clear(results)

  inv_dir := [3]f32 {
    1.0 / ray.direction.x,
    1.0 / ray.direction.y,
    1.0 / ray.direction.z,
  }
  t_min, t_max := ray_aabb_intersection(
    ray.origin,
    inv_dir,
    octree.root.bounds,
  )
  if t_min > max_dist || t_max < 0 do return
  octree_node_query_ray(
    octree,
    octree.root,
    ray,
    inv_dir,
    max_f32(t_min, 0),
    min_f32(t_max, max_dist),
    results,
  )
}

@(private)
octree_node_query_ray :: proc(
  octree: ^Octree($T),
  node: ^OctreeNode(T),
  ray: Ray,
  inv_dir: [3]f32,
  t_min, t_max: f32,
  results: ^[dynamic]T,
) {
  for item in node.items {
    item_bounds := octree.bounds_func(item)
    t_near, t_far := ray_aabb_intersection(ray.origin, inv_dir, item_bounds)
    if t_near <= t_max && t_far >= t_min {
      append(results, item)
    }
  }

  if node.children[0] == nil do return

  child_intersections: [8]struct {
    idx:   i32,
    t_min: f32,
  }
  valid_count := 0

  for i in 0 ..< 8 {
    child_t_min, child_t_max := ray_aabb_intersection(
      ray.origin,
      inv_dir,
      node.children[i].bounds,
    )
    if child_t_min <= t_max && child_t_max >= t_min {
      child_intersections[valid_count] = {
        idx   = i32(i),
        t_min = max_f32(child_t_min, t_min),
      }
      valid_count += 1
    }
  }

  slice.sort_by(child_intersections[:valid_count], proc(a, b: struct {
      idx:   i32,
      t_min: f32,
    }) -> bool {
    return a.t_min < b.t_min
  })
  for i in 0 ..< valid_count {
    child_idx := child_intersections[i].idx
    child_t_min := child_intersections[i].t_min
    child_t_max := min_f32(
      t_max,
      ray_aabb_intersection_far(
        ray.origin,
        inv_dir,
        node.children[child_idx].bounds,
      ),
    )
    octree_node_query_ray(
      octree,
      node.children[child_idx],
      ray,
      inv_dir,
      child_t_min,
      child_t_max,
      results,
    )
  }
}


octree_raycast :: proc(
  octree: ^Octree($T),
  ray: Ray,
  max_dist: f32 = F32_MAX,
  intersection_func: proc(ray: Ray, primitive: T, max_t: f32) -> (hit: bool, t: f32),
) -> RayHit(T) {
  if octree.root == nil do return {}
  
  best_hit: RayHit(T)
  best_hit.t = max_dist
  
  inv_dir := [3]f32 {
    1.0 / ray.direction.x,
    1.0 / ray.direction.y,
    1.0 / ray.direction.z,
  }
  
  t_min, t_max := ray_aabb_intersection(ray.origin, inv_dir, octree.root.bounds)
  if t_min > max_dist || t_max < 0 do return best_hit
  
  octree_node_raycast(octree, octree.root, ray, inv_dir, max_f32(t_min, 0), min_f32(t_max, max_dist), &best_hit, intersection_func)
  
  return best_hit
}

octree_raycast_single :: proc(
  octree: ^Octree($T),
  ray: Ray,
  max_dist: f32 = F32_MAX,
  intersection_func: proc(ray: Ray, primitive: T, max_t: f32) -> (hit: bool, t: f32),
) -> RayHit(T) {
  if octree.root == nil do return {}
  
  inv_dir := [3]f32 {
    1.0 / ray.direction.x,
    1.0 / ray.direction.y,
    1.0 / ray.direction.z,
  }
  
  t_min, t_max := ray_aabb_intersection(ray.origin, inv_dir, octree.root.bounds)
  if t_min > max_dist || t_max < 0 do return {}
  
  return octree_node_raycast_single(octree, octree.root, ray, inv_dir, max_f32(t_min, 0), min_f32(t_max, max_dist), max_dist, intersection_func)
}

octree_raycast_multi :: proc(
  octree: ^Octree($T),
  ray: Ray,
  max_dist: f32 = F32_MAX,
  intersection_func: proc(ray: Ray, primitive: T, max_t: f32) -> (hit: bool, t: f32),
  results: ^[dynamic]RayHit(T),
) {
  clear(results)
  if octree.root == nil do return
  
  inv_dir := [3]f32 {
    1.0 / ray.direction.x,
    1.0 / ray.direction.y,
    1.0 / ray.direction.z,
  }
  
  t_min, t_max := ray_aabb_intersection(ray.origin, inv_dir, octree.root.bounds)
  if t_min > max_dist || t_max < 0 do return
  
  octree_node_raycast_multi(octree, octree.root, ray, inv_dir, max_f32(t_min, 0), min_f32(t_max, max_dist), max_dist, intersection_func, results)
  
  // Sort results by distance
  if len(results^) > 1 {
    slice.sort_by(results[:], proc(a, b: RayHit(T)) -> bool {
      return a.t < b.t
    })
  }
}

@(private)
octree_node_raycast :: proc(
  octree: ^Octree($T),
  node: ^OctreeNode(T),
  ray: Ray,
  inv_dir: [3]f32,
  t_min, t_max: f32,
  best_hit: ^RayHit(T),
  intersection_func: proc(ray: Ray, primitive: T, max_t: f32) -> (hit: bool, t: f32),
) {
  if t_min > best_hit.t do return
  
  for item in node.items {
    hit, t := intersection_func(ray, item, best_hit.t)
    if hit && t < best_hit.t {
      best_hit.primitive = item
      best_hit.t = t
      best_hit.hit = true
    }
  }
  
  if node.children[0] == nil do return
  
  child_intersections: [8]struct {
    idx:   i32,
    t_min: f32,
  }
  valid_count := 0
  
  for i in 0 ..< 8 {
    child_t_min, child_t_max := ray_aabb_intersection(
      ray.origin,
      inv_dir,
      node.children[i].bounds,
    )
    if child_t_min <= best_hit.t && child_t_max >= t_min {
      child_intersections[valid_count] = {
        idx   = i32(i),
        t_min = max_f32(child_t_min, t_min),
      }
      valid_count += 1
    }
  }
  
  slice.sort_by(child_intersections[:valid_count], proc(a, b: struct {
      idx:   i32,
      t_min: f32,
    }) -> bool {
    return a.t_min < b.t_min
  })
  
  for i in 0 ..< valid_count {
    child_idx := child_intersections[i].idx
    child_t_min := child_intersections[i].t_min
    if child_t_min > best_hit.t do break
    
    child_t_max := min_f32(
      best_hit.t,
      ray_aabb_intersection_far(
        ray.origin,
        inv_dir,
        node.children[child_idx].bounds,
      ),
    )
    octree_node_raycast(
      octree,
      node.children[child_idx],
      ray,
      inv_dir,
      child_t_min,
      child_t_max,
      best_hit,
      intersection_func,
    )
  }
}

@(private)
octree_node_raycast_single :: proc(
  octree: ^Octree($T),
  node: ^OctreeNode(T),
  ray: Ray,
  inv_dir: [3]f32,
  t_min, t_max: f32,
  max_dist: f32,
  intersection_func: proc(ray: Ray, primitive: T, max_t: f32) -> (hit: bool, t: f32),
) -> RayHit(T) {
  // Check items in current node first
  for item in node.items {
    hit, t := intersection_func(ray, item, max_dist)
    if hit && t <= max_dist {
      return RayHit(T){
        primitive = item,
        t = t,
        hit = true,
      }
    }
  }
  
  if node.children[0] == nil do return {}
  
  // Sort children by distance for early termination
  child_intersections: [8]struct {
    idx:   i32,
    t_min: f32,
  }
  valid_count := 0
  
  for i in 0 ..< 8 {
    child_t_min, child_t_max := ray_aabb_intersection(
      ray.origin,
      inv_dir,
      node.children[i].bounds,
    )
    if child_t_min <= max_dist && child_t_max >= t_min {
      child_intersections[valid_count] = {
        idx   = i32(i),
        t_min = max_f32(child_t_min, t_min),
      }
      valid_count += 1
    }
  }
  
  slice.sort_by(child_intersections[:valid_count], proc(a, b: struct {
      idx:   i32,
      t_min: f32,
    }) -> bool {
    return a.t_min < b.t_min
  })
  
  for i in 0 ..< valid_count {
    child_idx := child_intersections[i].idx
    child_t_min := child_intersections[i].t_min
    child_t_max := min_f32(
      max_dist,
      ray_aabb_intersection_far(
        ray.origin,
        inv_dir,
        node.children[child_idx].bounds,
      ),
    )
    
    result := octree_node_raycast_single(
      octree,
      node.children[child_idx],
      ray,
      inv_dir,
      child_t_min,
      child_t_max,
      max_dist,
      intersection_func,
    )
    
    if result.hit {
      return result
    }
  }
  
  return {}
}

@(private)
octree_node_raycast_multi :: proc(
  octree: ^Octree($T),
  node: ^OctreeNode(T),
  ray: Ray,
  inv_dir: [3]f32,
  t_min, t_max: f32,
  max_dist: f32,
  intersection_func: proc(ray: Ray, primitive: T, max_t: f32) -> (hit: bool, t: f32),
  results: ^[dynamic]RayHit(T),
) {
  // Check items in current node
  for item in node.items {
    hit, t := intersection_func(ray, item, max_dist)
    if hit && t <= max_dist {
      append(results, RayHit(T){
        primitive = item,
        t = t,
        hit = true,
      })
    }
  }
  
  if node.children[0] == nil do return
  
  // Check all children
  for i in 0 ..< 8 {
    child_t_min, child_t_max := ray_aabb_intersection(
      ray.origin,
      inv_dir,
      node.children[i].bounds,
    )
    if child_t_min <= max_dist && child_t_max >= t_min {
      octree_node_raycast_multi(
        octree,
        node.children[i],
        ray,
        inv_dir,
        max_f32(child_t_min, t_min),
        min_f32(child_t_max, max_dist),
        max_dist,
        intersection_func,
        results,
      )
    }
  }
}

octree_query_sphere_primitives :: proc(
  octree: ^Octree($T),
  sphere: Sphere,
  results: ^[dynamic]T,
  intersection_func: proc(sphere: Sphere, primitive: T) -> bool,
) {
  clear(results)
  if octree.root == nil do return
  octree_node_query_sphere_primitives(octree, octree.root, sphere, results, intersection_func)
}

@(private)
octree_node_query_sphere_primitives :: proc(
  octree: ^Octree($T),
  node: ^OctreeNode(T),
  sphere: Sphere,
  results: ^[dynamic]T,
  intersection_func: proc(sphere: Sphere, primitive: T) -> bool,
) {
  if !aabb_sphere_intersects(node.bounds, sphere.center, sphere.radius) do return
  
  for item in node.items {
    if intersection_func(sphere, item) {
      append(results, item)
    }
  }
  
  if node.children[0] != nil {
    for i in 0 ..< 8 {
      octree_node_query_sphere_primitives(octree, node.children[i], sphere, results, intersection_func)
    }
  }
}

octree_remove :: proc(octree: ^Octree($T), item: T) -> bool {
  bounds := octree.bounds_func(item)
  return octree_node_remove(octree, octree.root, item, bounds)
}

@(private)
octree_node_remove :: proc(
  octree: ^Octree($T),
  node: ^OctreeNode(T),
  item: T,
  bounds: Aabb,
) -> bool {
  if !aabb_intersects(node.bounds, bounds) do return false
  for it, i in node.items {
    if octree_items_equal(item, it) {
      unordered_remove(&node.items, i)
      node.total_items -= 1
      return true
    }
  }

  if node.children[0] != nil {
    for i in 0 ..< 8 {
      if octree_node_remove(octree, node.children[i], item, bounds) {
        node.total_items -= 1
        if should_collapse(node) {
          octree_collapse(node)
        }
        return true
      }
    }
  }

  return false
}

@(private)
octree_items_equal :: proc(a: $T, b: T) -> bool {
  return a == b
}

@(private)
should_collapse :: proc(node: ^OctreeNode($T)) -> bool {
  if node.children[0] == nil do return false
  return node.total_items < 4
}

@(private)
count_items_recursive :: proc(node: ^OctreeNode($T)) -> int {
  if node == nil do return 0

  count := len(node.items)
  if node.children[0] != nil {
    count += count_items_recursive(node.children[0])
    count += count_items_recursive(node.children[1])
    count += count_items_recursive(node.children[2])
    count += count_items_recursive(node.children[3])
    count += count_items_recursive(node.children[4])
    count += count_items_recursive(node.children[5])
    count += count_items_recursive(node.children[6])
    count += count_items_recursive(node.children[7])
  }

  return count
}

@(private)
octree_collapse :: proc(node: ^OctreeNode($T)) {
  if node.children[0] == nil do return

  // Pre-allocate space for all items using cached count
  reserve(&node.items, int(node.total_items))

  // Collect items from children
  for i in 0 ..< 8 {
    collect_items_recursive(node.children[i], &node.items)
  }

  // Clean up children
  for i in 0 ..< 8 {
    octree_node_deinit(node.children[i])
    free(node.children[i])
    node.children[i] = nil
  }
}

@(private)
collect_items_recursive :: proc(node: ^OctreeNode($T), results: ^[dynamic]T) {
  if node == nil do return

  for item in node.items {
    append(results, item)
  }

  if node.children[0] != nil {
    for i in 0 ..< 8 {
      collect_items_recursive(node.children[i], results)
    }
  }
}

octree_update :: proc(octree: ^Octree($T), old_item: T, new_item: T) -> bool {
  old_bounds := octree.bounds_func(old_item)
  new_bounds := octree.bounds_func(new_item)

  if aabb_contains(old_bounds, new_bounds) &&
     aabb_contains(new_bounds, old_bounds) {
    return true
  }

  remove_result := octree_node_remove(
    octree,
    octree.root,
    old_item,
    old_bounds,
  )
  if remove_result {
    insert_result := octree_insert(octree, new_item)
    return insert_result
  }

  return false
}

octree_collect_all :: proc(node: ^OctreeNode($T), results: ^[dynamic]T) {
  if node == nil do return

  for item in node.items {
    append(results, item)
  }

  if node.children[0] != nil {
    for i in 0 ..< 8 {
      octree_collect_all(node.children[i], results)
    }
  }
}

octree_get_stats :: proc(octree: ^Octree($T)) -> OctreeStats {
  stats: OctreeStats
  if octree.root != nil {
    calculate_stats_recursive(octree.root, &stats, 0)
  }
  return stats
}

OctreeStats :: struct {
  total_nodes:    i32,
  leaf_nodes:     i32,
  max_depth:      i32,
  total_items:    i32,
  max_items_node: i32,
  empty_nodes:    i32,
}

@(private)
calculate_stats_recursive :: proc(
  node: ^OctreeNode($T),
  stats: ^OctreeStats,
  depth: i32,
) {
  stats.total_nodes += 1
  stats.total_items += i32(len(node.items))
  stats.max_depth = stats.max_depth > depth ? stats.max_depth : depth
  stats.max_items_node =
    stats.max_items_node > i32(len(node.items)) ? stats.max_items_node : i32(len(node.items))

  if node.children[0] == nil {
    stats.leaf_nodes += 1
    if len(node.items) == 0 do stats.empty_nodes += 1
  } else {
    for i in 0 ..< 8 {
      calculate_stats_recursive(node.children[i], stats, depth + 1)
    }
  }
}
