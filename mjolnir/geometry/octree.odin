package geometry

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
  octree.max_depth = max_depth
  octree.max_items = max_items
  shift_val := u32(1) << u32(max_depth)
  octree.min_size = min_vec3(aabb_size(bounds)) / f32(shift_val)
}

octree_destroy :: proc(octree: ^Octree($T)) {
  node_destroy(octree.root)
  free(octree.root)
  octree.root = nil
}

@(private)
node_destroy :: proc(node: ^OctreeNode($T)) {
  if node == nil do return
  #unroll for i in 0 ..< 8 {
    node_destroy(node.children[i])
    free(node.children[i])
  }
  delete(node.items)
}

@(private)
get_octant :: proc(center: [3]f32, point: [3]f32) -> u32 {
  octant: u32 = 0
  if point.x >= center.x do octant |= 0b001
  if point.y >= center.y do octant |= 0b010
  if point.z >= center.z do octant |= 0b100
  return octant
}

@(private)
get_octant_for_aabb :: proc(node_center: [3]f32, aabb: Aabb) -> (idx: u32, ok: bool) {
  aabb_center := aabb_center(aabb)
  if aabb.min.x < node_center.x && aabb.max.x > node_center.x do return 0, false
  if aabb.min.y < node_center.y && aabb.max.y > node_center.y do return 0, false
  if aabb.min.z < node_center.z && aabb.max.z > node_center.z do return 0, false
  return get_octant(node_center, aabb_center), true
}

@(private)
get_child_bounds :: proc(parent: ^OctreeNode($T), octant: i32) -> Aabb {
  size := (parent.bounds.max - parent.bounds.min) * 0.5
  min := parent.bounds.min
  if octant & 0b001 != 0 do min.x += size.x
  if octant & 0b010 != 0 do min.y += size.y
  if octant & 0b100 != 0 do min.z += size.z
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
  if octant & 0b001 != 0 {
    center.x += offset.x
  } else {
    center.x -= offset.x
  }
  if octant & 0b010 != 0 {
    center.y += offset.y
  } else {
    center.y -= offset.y
  }
  if octant & 0b100 != 0 {
    center.z += offset.z
  } else {
    center.z -= offset.z
  }
  return center
}

@(private)
subdivide :: proc(node: ^OctreeNode($T)) {
  parent_size := node.bounds.max - node.bounds.min
  #unroll for i in 0 ..< 8 {
    child := new(OctreeNode(T))
    child.bounds = get_child_bounds(node, i32(i))
    child.center = get_child_center(node.center, parent_size, i32(i))
    child.depth = node.depth + 1
    node.children[i] = child
  }
}

@(private)
should_subdivide :: proc(octree: ^Octree($T), node: ^OctreeNode(T)) -> bool {
  if node.depth >= octree.max_depth do return false
  size := min_vec3(node.bounds.max - node.bounds.min)
  if size <= octree.min_size do return false
  if i32(len(node.items)) <= octree.max_items do return false
  return true
}

octree_insert :: proc(octree: ^Octree($T), item: T) -> bool {
  bounds := octree.bounds_func(item)
  if !aabb_contains(octree.root.bounds, bounds) do return false
  return node_insert(octree, octree.root, item, bounds)
}

@(private)
node_insert :: proc(
  octree: ^Octree($T),
  node: ^OctreeNode(T),
  item: T,
  bounds: Aabb,
) -> bool {
  if node.depth >= octree.max_depth {
    append(&node.items, item)
    node.total_items += 1
    return true
  }
  if node.children[0] == nil {
    append(&node.items, item)
    node.total_items += 1
    if should_subdivide(octree, node) {
      subdivide(node)
      old_items := node.items[:]
      clear(&node.items)
      node.total_items = 0
      for old_item in old_items {
        old_bounds := octree.bounds_func(old_item)
        if node_insert_to_children_internal(
          octree,
          node,
          old_item,
          old_bounds,
        ) {
          node.total_items += 1
        }
      }
    }
    return true
  }
  if node_insert_to_children(octree, node, item, bounds) {
    node.total_items += 1
    return true
  }
  return false
}

@(private)
node_insert_to_children :: proc(
  octree: ^Octree($T),
  node: ^OctreeNode(T),
  item: T,
  bounds: Aabb,
) -> bool {
  if octant, ok := get_octant_for_aabb(node.center, bounds); ok {
    return node_insert(octree, node.children[octant], item, bounds)
  } else {
    append(&node.items, item)
    node.total_items += 1
    return true
  }
}

@(private)
node_insert_to_children_internal :: proc(
  octree: ^Octree($T),
  node: ^OctreeNode(T),
  item: T,
  bounds: Aabb,
) -> bool {
  if octant, ok := get_octant_for_aabb(node.center, bounds); ok {
    return node_insert(octree, node.children[octant], item, bounds)
  } else {
    append(&node.items, item)
    return true
  }
}

octree_query_aabb :: proc(
  octree: ^Octree($T),
  query_bounds: Aabb,
  results: ^[dynamic]T,
) {
  clear(results)
  node_query_aabb(octree, octree.root, query_bounds, results)
}

octree_query_aabb_limited :: proc(
  octree: ^Octree($T),
  query_bounds: Aabb,
  results: ^[dynamic]T,
  max_results: int,
) {
  clear(results)
  node_query_aabb_limited(
    octree,
    octree.root,
    query_bounds,
    results,
    max_results,
  )
}

@(private)
node_query_aabb :: proc(
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
    #unroll for i in 0 ..< 8 {
      node_query_aabb(octree, node.children[i], query_bounds, results)
    }
  }
}

@(private)
node_query_aabb_limited :: proc(
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
      node_query_aabb_limited(
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
  node_query_sphere(octree, octree.root, center, radius, results)
}

@(private)
node_query_sphere :: proc(
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
    #unroll for i in 0 ..< 8 {
      node_query_sphere(octree, node.children[i], center, radius, results)
    }
  }
}

octree_query_disc :: proc(
  octree: ^Octree($T),
  center: [3]f32,
  normal: [3]f32,
  radius: f32,
  results: ^[dynamic]T,
) {
  clear(results)
  node_query_disc(octree, octree.root, center, normal, radius, results)
}

@(private)
node_query_disc :: proc(
  octree: ^Octree($T),
  node: ^OctreeNode(T),
  center: [3]f32,
  normal: [3]f32,
  radius: f32,
  results: ^[dynamic]T,
) {
  if !aabb_disc_intersects(node.bounds, center, normal, radius) do return
  for item in node.items {
    item_bounds := octree.bounds_func(item)
    if aabb_disc_intersects(item_bounds, center, normal, radius) {
      append(results, item)
    }
  }
  if node.children[0] != nil {
    #unroll for i in 0 ..< 8 {
      node_query_disc(
        octree,
        node.children[i],
        center,
        normal,
        radius,
        results,
      )
    }
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
  inv_dir := 1.0 / ray.direction
  t_min, t_max := ray_aabb_intersection(
    ray.origin,
    inv_dir,
    octree.root.bounds,
  )
  if t_min > max_dist || t_max < 0 do return
  node_query_ray(
    octree,
    octree.root,
    ray,
    inv_dir,
    max(t_min, 0),
    min(t_max, max_dist),
    results,
  )
}

@(private)
node_query_ray :: proc(
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
  #unroll for i in 0 ..< 8 {
    child_t_min, child_t_max := ray_aabb_intersection(
      ray.origin,
      inv_dir,
      node.children[i].bounds,
    )
    if child_t_min <= t_max && child_t_max >= t_min {
      child_intersections[valid_count] = {
        idx   = i32(i),
        t_min = max(child_t_min, t_min),
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
    child_t_max := min(
      t_max,
      ray_aabb_intersection_far(
        ray.origin,
        inv_dir,
        node.children[child_idx].bounds,
      ),
    )
    node_query_ray(
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
  intersection_func: proc(
    ray: Ray,
    primitive: T,
    max_t: f32,
  ) -> (
    hit: bool,
    t: f32,
  ),
) -> RayHit(T) {
  if octree.root == nil do return {}
  best_hit: RayHit(T)
  best_hit.t = max_dist
  inv_dir := 1.0 / ray.direction
  t_min, t_max := ray_aabb_intersection(
    ray.origin,
    inv_dir,
    octree.root.bounds,
  )
  if t_min > max_dist || t_max < 0 do return best_hit
  node_raycast(
    octree,
    octree.root,
    ray,
    inv_dir,
    max(t_min, 0),
    min(t_max, max_dist),
    &best_hit,
    intersection_func,
  )
  return best_hit
}

octree_raycast_single :: proc(
  octree: ^Octree($T),
  ray: Ray,
  max_dist: f32 = F32_MAX,
  intersection_func: proc(
    ray: Ray,
    primitive: T,
    max_t: f32,
  ) -> (
    hit: bool,
    t: f32,
  ),
) -> RayHit(T) {
  if octree.root == nil do return {}
  inv_dir := 1.0 / ray.direction
  t_min, t_max := ray_aabb_intersection(
    ray.origin,
    inv_dir,
    octree.root.bounds,
  )
  if t_min > max_dist || t_max < 0 do return {}
  return node_raycast_single(
    octree,
    octree.root,
    ray,
    inv_dir,
    max(t_min, 0),
    min(t_max, max_dist),
    max_dist,
    intersection_func,
  )
}

octree_raycast_multi :: proc(
  octree: ^Octree($T),
  ray: Ray,
  max_dist: f32 = F32_MAX,
  intersection_func: proc(
    ray: Ray,
    primitive: T,
    max_t: f32,
  ) -> (
    hit: bool,
    t: f32,
  ),
  results: ^[dynamic]RayHit(T),
) {
  clear(results)
  if octree.root == nil do return
  inv_dir := 1.0 / ray.direction
  t_min, t_max := ray_aabb_intersection(
    ray.origin,
    inv_dir,
    octree.root.bounds,
  )
  if t_min > max_dist || t_max < 0 do return
  node_raycast_multi(
    octree,
    octree.root,
    ray,
    inv_dir,
    max(t_min, 0),
    min(t_max, max_dist),
    max_dist,
    intersection_func,
    results,
  )
  if len(results^) > 1 {
    slice.sort_by(results[:], proc(a, b: RayHit(T)) -> bool {
      return a.t < b.t
    })
  }
}

@(private)
node_raycast :: proc(
  octree: ^Octree($T),
  node: ^OctreeNode(T),
  ray: Ray,
  inv_dir: [3]f32,
  t_min, t_max: f32,
  best_hit: ^RayHit(T),
  intersection_func: proc(
    ray: Ray,
    primitive: T,
    max_t: f32,
  ) -> (
    hit: bool,
    t: f32,
  ),
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
  #unroll for i in 0 ..< 8 {
    child_t_min, child_t_max := ray_aabb_intersection(
      ray.origin,
      inv_dir,
      node.children[i].bounds,
    )
    if child_t_min <= best_hit.t && child_t_max >= t_min {
      child_intersections[valid_count] = {
        idx   = i32(i),
        t_min = max(child_t_min, t_min),
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
    child_t_max := min(
      best_hit.t,
      ray_aabb_intersection_far(
        ray.origin,
        inv_dir,
        node.children[child_idx].bounds,
      ),
    )
    node_raycast(
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
node_raycast_single :: proc(
  octree: ^Octree($T),
  node: ^OctreeNode(T),
  ray: Ray,
  inv_dir: [3]f32,
  t_min, t_max: f32,
  max_dist: f32,
  intersection_func: proc(
    ray: Ray,
    primitive: T,
    max_t: f32,
  ) -> (
    hit: bool,
    t: f32,
  ),
) -> RayHit(T) {
  for item in node.items {
    hit, t := intersection_func(ray, item, max_dist)
    if hit && t <= max_dist {
      return RayHit(T){primitive = item, t = t, hit = true}
    }
  }
  if node.children[0] == nil do return {}
  child_intersections: [8]struct {
    idx:   i32,
    t_min: f32,
  }
  valid_count := 0
  #unroll for i in 0 ..< 8 {
    child_t_min, child_t_max := ray_aabb_intersection(
      ray.origin,
      inv_dir,
      node.children[i].bounds,
    )
    if child_t_min <= max_dist && child_t_max >= t_min {
      child_intersections[valid_count] = {
        idx   = i32(i),
        t_min = max(child_t_min, t_min),
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
    child_t_max := min(
      max_dist,
      ray_aabb_intersection_far(
        ray.origin,
        inv_dir,
        node.children[child_idx].bounds,
      ),
    )
    result := node_raycast_single(
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
node_raycast_multi :: proc(
  octree: ^Octree($T),
  node: ^OctreeNode(T),
  ray: Ray,
  inv_dir: [3]f32,
  t_min, t_max: f32,
  max_dist: f32,
  intersection_func: proc(
    ray: Ray,
    primitive: T,
    max_t: f32,
  ) -> (
    hit: bool,
    t: f32,
  ),
  results: ^[dynamic]RayHit(T),
) {
  for item in node.items {
    hit, t := intersection_func(ray, item, max_dist)
    if hit && t <= max_dist {
      append(results, RayHit(T){primitive = item, t = t, hit = true})
    }
  }
  if node.children[0] == nil do return
  #unroll for i in 0 ..< 8 {
    child_t_min, child_t_max := ray_aabb_intersection(
      ray.origin,
      inv_dir,
      node.children[i].bounds,
    )
    if child_t_min <= max_dist && child_t_max >= t_min {
      node_raycast_multi(
        octree,
        node.children[i],
        ray,
        inv_dir,
        max(child_t_min, t_min),
        min(child_t_max, max_dist),
        max_dist,
        intersection_func,
        results,
      )
    }
  }
}

octree_remove :: proc(octree: ^Octree($T), item: T) -> bool {
  bounds := octree.bounds_func(item)
  return node_remove(octree, octree.root, item, bounds)
}

@(private)
node_remove :: proc(
  octree: ^Octree($T),
  node: ^OctreeNode(T),
  item: T,
  bounds: Aabb,
) -> bool {
  if !aabb_intersects(node.bounds, bounds) do return false
  if i, ok := slice.linear_search(node.items[:], item); ok {
    unordered_remove(&node.items, i)
    node.total_items -= 1
    return true
  }
  if node.children[0] == nil do return false
  #unroll for i in 0 ..< 8 {
    if node_remove(octree, node.children[i], item, bounds) {
      node.total_items -= 1
      if should_collapse(node) do collapse(node)
      return true
    }
  }
  return false
}

@(private)
should_collapse :: proc(node: ^OctreeNode($T)) -> bool {
  if node.children[0] == nil do return false
  return node.total_items < 4
}

@(private)
collapse :: proc(node: ^OctreeNode($T)) {
  if node.children[0] == nil do return
  reserve(&node.items, int(node.total_items))
  #unroll for i in 0 ..< 8 {
    collect_items_recursive(node.children[i], &node.items)
  }
  #unroll for i in 0 ..< 8 {
    node_destroy(node.children[i])
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
  if node.children[0] == nil do return
  #unroll for i in 0 ..< 8 {
    collect_items_recursive(node.children[i], results)
  }
}

octree_update :: proc(octree: ^Octree($T), old_item: T, new_item: T) -> bool {
  old_bounds := octree.bounds_func(old_item)
  new_bounds := octree.bounds_func(new_item)
  if aabb_contains(old_bounds, new_bounds) &&
     aabb_contains(new_bounds, old_bounds) {
    return true
  }
  return node_remove(octree, octree.root, old_item, old_bounds) &&
    octree_insert(octree, new_item)
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
    #unroll for i in 0 ..< 8 {
      calculate_stats_recursive(node.children[i], stats, depth + 1)
    }
  }
}
