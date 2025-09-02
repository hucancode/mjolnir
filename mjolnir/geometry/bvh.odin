package geometry

import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:mem"
import "core:mem/virtual"

BVHNode :: struct {
  bounds:          Aabb,
  left_child:      i32,
  right_child:     i32,
  primitive_start: i32,
  primitive_count: i32,
}

BVH :: struct($T: typeid) {
  nodes:       [dynamic]BVHNode,
  primitives:  [dynamic]T,
  bounds_func: proc(t: T) -> Aabb,
}

bvh_deinit :: proc(bvh: ^BVH($T)) {
  delete(bvh.nodes)
  delete(bvh.primitives)
}

BVHBuildNode :: struct {
  bounds:     Aabb,
  left:       ^BVHBuildNode,
  right:      ^BVHBuildNode,
  prim_start: i32,
  prim_count: i32,
}

BVHPrimitive :: struct {
  index:    i32,
  bounds:   Aabb,
  centroid: [3]f32,
}

BVHTraversal :: struct {
  node_idx: i32,
  t_min:    f32,
}

bvh_build :: proc(bvh: ^BVH($T), items: []T, max_leaf_size: i32 = 4) {
  if bvh == nil do return
  if bvh.bounds_func == nil do return

  clear(&bvh.nodes)
  clear(&bvh.primitives)

  if len(items) == 0 do return

  // Pre-reserve capacity for better performance
  reserve(&bvh.primitives, len(items))
  append(&bvh.primitives, ..items)

  // Use virtual arena allocator for build operations - grows as needed
  arena: virtual.Arena
  if err := virtual.arena_init_growing(&arena); err != nil {
    log.error("Failed to init arena:", err)
    return
  }
  defer virtual.arena_free_all(&arena)
  arena_allocator := virtual.arena_allocator(&arena)
  build_prims := make([]BVHPrimitive, len(items), arena_allocator)
  for item, i in items {
    bounds := bvh.bounds_func(item)
    build_prims[i] = BVHPrimitive {
      index    = i32(i),
      bounds   = bounds,
      centroid = aabb_center(bounds),
    }
  }

  root := build_recursive(build_prims[:], 0, i32(len(items)), max_leaf_size, arena_allocator)

  // Reorder the primitives array to match the build_prims order
  for prim, i in build_prims {
    bvh.primitives[i] = items[prim.index]
  }

  flatten_bvh_tree(bvh, root)

  // No need to free build nodes - arena will clean up
}

@(private)
build_recursive :: proc(
  prims: []BVHPrimitive,
  start, end: i32,
  max_leaf_size: i32,
  allocator: mem.Allocator,
) -> ^BVHBuildNode {
  node := new(BVHBuildNode, allocator)

  node.bounds = AABB_UNDEFINED
  for i in start ..< end {
    node.bounds = aabb_union(node.bounds, prims[i].bounds)
  }

  prim_count := end - start

  if prim_count <= max_leaf_size {
    node.prim_start = start
    node.prim_count = prim_count
    // Recalculate bounds from actual primitives in this leaf node
    node.bounds = AABB_UNDEFINED
    for i in start ..< end {
      node.bounds = aabb_union(node.bounds, prims[i].bounds)
    }
    return node
  }

  axis, split_pos := split_sah(prims[start:end], node.bounds, allocator)

  if axis < 0 || split_pos <= 0 || split_pos >= prim_count {
    node.prim_start = start
    node.prim_count = prim_count
    // Recalculate bounds from actual primitives in this fallback leaf node
    node.bounds = AABB_UNDEFINED
    for i in start ..< end {
      node.bounds = aabb_union(node.bounds, prims[i].bounds)
    }
    return node
  }

  mid := start + split_pos

  node.left = build_recursive(prims, start, mid, max_leaf_size, allocator)
  node.right = build_recursive(prims, mid, end, max_leaf_size, allocator)
  node.prim_start = -1
  node.prim_count = 0

  // Update bounds to be union of child bounds (this is correct for internal nodes)
  node.bounds = aabb_union(node.left.bounds, node.right.bounds)

  return node
}

@(private)
split_sah :: proc(
  prims: []BVHPrimitive,
  node_bounds: Aabb,
  allocator: mem.Allocator,
) -> (
  axis: i32,
  split_pos: i32,
) {
  best_cost := f32(F32_MAX)
  best_axis := -1
  best_split := -1

  // Fast path for small arrays - use simple median split
  if len(prims) <= 8 {
    return split_median(prims, node_bounds)
  }

  // Use the arena allocator for prefix/suffix bounds computation
  left_bounds := make([]Aabb, len(prims), allocator)
  right_bounds := make([]Aabb, len(prims), allocator)

  // Sample fewer split positions for better performance
  num_samples := min(len(prims), 32)
  step := max(1, len(prims) / num_samples)

  for ax in 0 ..< 3 {
    // Sort by axis
    if ax == 0 {
      slice.sort_by(prims, proc(a, b: BVHPrimitive) -> bool {
        return a.centroid[0] < b.centroid[0]
      })
    } else if ax == 1 {
      slice.sort_by(prims, proc(a, b: BVHPrimitive) -> bool {
        return a.centroid[1] < b.centroid[1]
      })
    } else {
      slice.sort_by(prims, proc(a, b: BVHPrimitive) -> bool {
        return a.centroid[2] < b.centroid[2]
      })
    }

    // Compute prefix bounds (left side)
    left_bounds[0] = prims[0].bounds
    for i in 1 ..< len(prims) {
      left_bounds[i] = aabb_union(left_bounds[i-1], prims[i].bounds)
    }

    // Compute suffix bounds (right side)
    right_bounds[len(prims)-1] = prims[len(prims)-1].bounds
    for i := len(prims)-2; i >= 0; i -= 1 {
      right_bounds[i] = aabb_union(right_bounds[i+1], prims[i].bounds)
    }

    // Sample split positions instead of testing all
    for i := step; i < len(prims); i += step {
      if i >= len(prims) - 1 do break

      cost := sah_cost(
        left_bounds[i-1],
        i32(i),
        right_bounds[i],
        i32(len(prims) - i),
        node_bounds,
      )

      if cost < best_cost {
        best_cost = cost
        best_axis = ax
        best_split = i
      }
    }
  }

  // Re-sort by best axis if needed
  if best_axis >= 0 {
    if best_axis == 0 {
      slice.sort_by(prims, proc(a, b: BVHPrimitive) -> bool {
        return a.centroid[0] < b.centroid[0]
      })
    } else if best_axis == 1 {
      slice.sort_by(prims, proc(a, b: BVHPrimitive) -> bool {
        return a.centroid[1] < b.centroid[1]
      })
    } else if best_axis == 2 {
      slice.sort_by(prims, proc(a, b: BVHPrimitive) -> bool {
        return a.centroid[2] < b.centroid[2]
      })
    }
  }

  return i32(best_axis), i32(best_split)
}

@(private)
split_median :: proc(
  prims: []BVHPrimitive,
  node_bounds: Aabb,
) -> (
  axis: i32,
  split_pos: i32,
) {
  // Choose the axis with the largest extent
  extent := node_bounds.max - node_bounds.min
  best_axis := 0
  if extent[1] > extent[0] do best_axis = 1
  if extent[2] > extent[best_axis] do best_axis = 2

  // Sort by the chosen axis
  if best_axis == 0 {
    slice.sort_by(prims, proc(a, b: BVHPrimitive) -> bool {
      return a.centroid[0] < b.centroid[0]
    })
  } else if best_axis == 1 {
    slice.sort_by(prims, proc(a, b: BVHPrimitive) -> bool {
      return a.centroid[1] < b.centroid[1]
    })
  } else {
    slice.sort_by(prims, proc(a, b: BVHPrimitive) -> bool {
      return a.centroid[2] < b.centroid[2]
    })
  }

  return i32(best_axis), i32(len(prims) / 2)
}

@(private)
sah_cost :: proc(
  left_bounds: Aabb,
  left_count: i32,
  right_bounds: Aabb,
  right_count: i32,
  parent_bounds: Aabb,
) -> f32 {
  TRAVERSAL_COST :: 1.0
  INTERSECTION_COST :: 1.0

  parent_area := aabb_surface_area(parent_bounds)
  left_area := aabb_surface_area(left_bounds)
  right_area := aabb_surface_area(right_bounds)

  if parent_area == 0 do return F32_MAX

  p_left := left_area / parent_area
  p_right := right_area / parent_area

  return(
    TRAVERSAL_COST +
    INTERSECTION_COST *
      (p_left * f32(left_count) + p_right * f32(right_count)) \
  )
}

@(private)
count_build_nodes :: proc(node: ^BVHBuildNode) -> i32 {
  if node == nil do return 0
  return 1 + count_build_nodes(node.left) + count_build_nodes(node.right)
}

@(private)
flatten_bvh_tree :: proc(bvh: ^BVH($T), root: ^BVHBuildNode) {
  node_count := count_build_nodes(root)
  resize(&bvh.nodes, int(node_count))

  next_node_idx: i32 = 0
  flatten_node(bvh, root, &next_node_idx)
}

@(private)
flatten_node :: proc(
  bvh: ^BVH($T),
  build_node: ^BVHBuildNode,
  next_idx: ^i32,
) -> i32 {
  node_idx := next_idx^
  next_idx^ += 1

  node := BVHNode {
    bounds = build_node.bounds,
  }

  if build_node.prim_count > 0 {
    node.left_child = -1
    node.right_child = -1
    node.primitive_start = build_node.prim_start
    node.primitive_count = build_node.prim_count
  } else {
    node.primitive_start = -1
    node.primitive_count = -1
    node.left_child = flatten_node(bvh, build_node.left, next_idx)
    node.right_child = flatten_node(bvh, build_node.right, next_idx)
  }

  bvh.nodes[node_idx] = node
  return node_idx
}

// No longer needed - arena allocator handles cleanup
// @(private)
// free_build_nodes :: proc(node: ^BVHBuildNode) {
//   if node == nil do return
//
//   free_build_nodes(node.left)
//   free_build_nodes(node.right)
//   free(node)
// }

bvh_query_aabb :: proc(
  bvh: ^BVH($T),
  query_bounds: Aabb,
  results: ^[dynamic]T,
) {
  if bvh == nil || results == nil do return
  clear(results)
  if len(bvh.nodes) == 0 do return
  if bvh.bounds_func == nil do return

  // Use dynamic stack to prevent overflow on deep trees
  stack := make([dynamic]i32, 0, 64, context.temp_allocator)
  append(&stack, 0)

  for len(stack) > 0 {
    node_idx := pop(&stack)
    node := &bvh.nodes[node_idx]

    if !aabb_intersects(node.bounds, query_bounds) do continue

    if node.primitive_count > 0 {
      // Cache bounds function call
      for i in node.primitive_start ..< node.primitive_start + node.primitive_count {
        prim := bvh.primitives[i]
        prim_bounds := bvh.bounds_func(prim)
        if aabb_intersects(prim_bounds, query_bounds) {
          append(results, prim)
        }
      }
    } else {
      // Add children to stack
      append(&stack, node.right_child)
      append(&stack, node.left_child)
    }
  }
}

@(private)
ray_aabb_intersection_safe :: proc(
  origin: [3]f32,
  direction: [3]f32,
  aabb: Aabb,
) -> (
  t_near, t_far: f32,
) {
  t_min := [3]f32{-F32_MAX, -F32_MAX, -F32_MAX}
  t_max := [3]f32{F32_MAX, F32_MAX, F32_MAX}

  for i in 0 ..< 3 {
    if math.abs(direction[i]) < 1e-6 {
      // Ray is parallel to this axis
      if origin[i] < aabb.min[i] || origin[i] > aabb.max[i] {
        // Ray is outside the slab, no intersection
        return F32_MAX, -F32_MAX
      }
      // Ray is inside the slab, keep the infinite range for this axis
    } else {
      inv_d := 1.0 / direction[i]
      t1 := (aabb.min[i] - origin[i]) * inv_d
      t2 := (aabb.max[i] - origin[i]) * inv_d

      t_min[i] = min_f32(t1, t2)
      t_max[i] = max_f32(t1, t2)
    }
  }

  t_near = max_f32(max_f32(t_min.x, t_min.y), t_min.z)
  t_far = min_f32(min_f32(t_max.x, t_max.y), t_max.z)

  // Valid intersection if t_far >= t_near
  if t_far < t_near do return F32_MAX, -F32_MAX

  return
}

bvh_query_ray :: proc(
  bvh: ^BVH($T),
  ray: Ray,
  max_dist: f32,
  results: ^[dynamic]T,
) {
  clear(results)
  if len(bvh.nodes) == 0 do return

  stack := make([dynamic]i32, 0, 64, context.temp_allocator)
  append(&stack, 0)

  for len(stack) > 0 {
    node_idx := pop(&stack)
    node := &bvh.nodes[node_idx]

    t_near, t_far := ray_aabb_intersection_safe(
      ray.origin,
      ray.direction,
      node.bounds,
    )
    if t_near > max_dist || t_far < 0 do continue

    if node.primitive_count > 0 {
      for i in node.primitive_start ..< node.primitive_start + node.primitive_count {
        prim := bvh.primitives[i]
        prim_bounds := bvh.bounds_func(prim)
        prim_t_near, prim_t_far := ray_aabb_intersection_safe(
          ray.origin,
          ray.direction,
          prim_bounds,
        )
        if prim_t_near <= max_dist && prim_t_far >= 0 {
          append(results, prim)
        }
      }
    } else {
      append(&stack, node.left_child)
      append(&stack, node.right_child)
    }
  }
}

RayHit :: struct($T: typeid) {
  primitive: T,
  t: f32,
  hit: bool,
}

bvh_raycast :: proc(
  bvh: ^BVH($T),
  ray: Ray,
  max_dist: f32 = F32_MAX,
  intersection_func: proc(ray: Ray, primitive: T, max_t: f32) -> (hit: bool, t: f32),
) -> RayHit(T) {
  if len(bvh.nodes) == 0 do return {}

  best_hit: RayHit(T)
  best_hit.t = max_dist

  stack := make([dynamic]i32, 0, 64, context.temp_allocator)
  append(&stack, 0)

  for len(stack) > 0 {
    node_idx := pop(&stack)
    node := &bvh.nodes[node_idx]

    t_near, t_far := ray_aabb_intersection_safe(
      ray.origin,
      ray.direction,
      node.bounds,
    )
    if t_near > best_hit.t || t_far < 0 do continue

    if node.primitive_count > 0 {
      for i in node.primitive_start ..< node.primitive_start + node.primitive_count {
        prim := bvh.primitives[i]
        hit, t := intersection_func(ray, prim, best_hit.t)
        if hit && t < best_hit.t {
          best_hit.primitive = prim
          best_hit.t = t
          best_hit.hit = true
        }
      }
    } else {
      left_node := &bvh.nodes[node.left_child]
      right_node := &bvh.nodes[node.right_child]

      left_t_near, _ := ray_aabb_intersection_safe(
        ray.origin,
        ray.direction,
        left_node.bounds,
      )
      right_t_near, _ := ray_aabb_intersection_safe(
        ray.origin,
        ray.direction,
        right_node.bounds,
      )

      if left_t_near < right_t_near {
        append(&stack, node.right_child)
        append(&stack, node.left_child)
      } else {
        append(&stack, node.left_child)
        append(&stack, node.right_child)
      }
    }
  }

  return best_hit
}

bvh_raycast_single :: proc(
  bvh: ^BVH($T),
  ray: Ray,
  max_dist: f32 = F32_MAX,
  intersection_func: proc(ray: Ray, primitive: T, max_t: f32) -> (hit: bool, t: f32),
) -> RayHit(T) {
  if len(bvh.nodes) == 0 do return {}

  stack := make([dynamic]i32, 0, 64, context.temp_allocator)
  append(&stack, 0)

  for len(stack) > 0 {
    node_idx := pop(&stack)
    node := &bvh.nodes[node_idx]

    t_near, t_far := ray_aabb_intersection_safe(
      ray.origin,
      ray.direction,
      node.bounds,
    )
    if t_near > max_dist || t_far < 0 do continue

    if node.primitive_count > 0 {
      for i in node.primitive_start ..< node.primitive_start + node.primitive_count {
        prim := bvh.primitives[i]
        hit, t := intersection_func(ray, prim, max_dist)
        if hit && t < max_dist {
          return RayHit(T){
            primitive = prim,
            t = t,
            hit = true,
          }
        }
      }
    } else {
      append(&stack, node.left_child)
      append(&stack, node.right_child)
    }
  }

  return {}
}

bvh_raycast_multi :: proc(
  bvh: ^BVH($T),
  ray: Ray,
  max_dist: f32 = F32_MAX,
  intersection_func: proc(ray: Ray, primitive: T, max_t: f32) -> (hit: bool, t: f32),
  results: ^[dynamic]RayHit(T),
) {
  clear(results)
  if len(bvh.nodes) == 0 do return

  stack := make([dynamic]i32, 0, 64, context.temp_allocator)
  append(&stack, 0)

  for len(stack) > 0 {
    node_idx := pop(&stack)
    node := &bvh.nodes[node_idx]

    t_near, t_far := ray_aabb_intersection_safe(
      ray.origin,
      ray.direction,
      node.bounds,
    )
    if t_near > max_dist || t_far < 0 do continue

    if node.primitive_count > 0 {
      for i in node.primitive_start ..< node.primitive_start + node.primitive_count {
        prim := bvh.primitives[i]
        hit, t := intersection_func(ray, prim, max_dist)
        if hit && t <= max_dist {
          append(results, RayHit(T){
            primitive = prim,
            t = t,
            hit = true,
          })
        }
      }
    } else {
      append(&stack, node.left_child)
      append(&stack, node.right_child)
    }
  }

  // Sort results by distance
  if len(results^) > 1 {
    slice.sort_by(results[:], proc(a, b: RayHit(T)) -> bool {
      return a.t < b.t
    })
  }
}

bvh_query_sphere_primitives :: proc(
  bvh: ^BVH($T),
  sphere: Sphere,
  results: ^[dynamic]T,
  intersection_func: proc(sphere: Sphere, primitive: T) -> bool,
) {
  clear(results)
  if len(bvh.nodes) == 0 do return

  sphere_bounds := sphere_bounds(sphere)

  stack := make([dynamic]i32, 0, 64, context.temp_allocator)
  append(&stack, 0)

  for len(stack) > 0 {
    node_idx := pop(&stack)
    node := &bvh.nodes[node_idx]

    if !aabb_sphere_intersects(node.bounds, sphere.center, sphere.radius) do continue

    if node.primitive_count > 0 {
      for i in node.primitive_start ..< node.primitive_start + node.primitive_count {
        prim := bvh.primitives[i]
        if intersection_func(sphere, prim) {
          append(results, prim)
        }
      }
    } else {
      append(&stack, node.left_child)
      append(&stack, node.right_child)
    }
  }
}

bvh_query_sphere :: proc(
  bvh: ^BVH($T),
  center: [3]f32,
  radius: f32,
  results: ^[dynamic]T,
) {
  sphere_bounds := Aabb {
    min = center - [3]f32{radius, radius, radius},
    max = center + [3]f32{radius, radius, radius},
  }

  temp_results := make([dynamic]T, context.temp_allocator)
  bvh_query_aabb(bvh, sphere_bounds, &temp_results)

  clear(results)
  for item in temp_results {
    bounds := bvh.bounds_func(item)
    if aabb_sphere_intersects(bounds, center, radius) {
      append(results, item)
    }
  }
}

bvh_query_nearest :: proc(
  bvh: ^BVH($T),
  point: [3]f32,
  max_dist: f32 = F32_MAX,
) -> (
  result: T,
  dist: f32,
  found: bool,
) {
  if len(bvh.nodes) == 0 do return

  best_dist := max_dist
  found = false

  stack := make([dynamic]BVHTraversal, 0, 64, context.temp_allocator)
  append(&stack, BVHTraversal{node_idx = 0, t_min = 0})

  for len(stack) > 0 {
    current := pop(&stack)

    if current.t_min > best_dist do break

    node := &bvh.nodes[current.node_idx]

    if node.left_child < 0 {
      for i in node.primitive_start ..< node.primitive_start + node.primitive_count {
        prim := bvh.primitives[i]
        prim_bounds := bvh.bounds_func(prim)

        d := distance_point_aabb(point, prim_bounds)

        if d < best_dist {
          best_dist = d
          result = prim
          found = true
        }
      }
    } else {
      left_bounds := bvh.nodes[node.left_child].bounds
      right_bounds := bvh.nodes[node.right_child].bounds

      left_dist := distance_point_aabb(point, left_bounds)
      right_dist := distance_point_aabb(point, right_bounds)

      traversals := [2]BVHTraversal {
        {node_idx = node.left_child, t_min = left_dist},
        {node_idx = node.right_child, t_min = right_dist},
      }

      if left_dist > right_dist {
        traversals[0], traversals[1] = traversals[1], traversals[0]
      }

      for trav in traversals {
        if trav.t_min < best_dist {
          append(&stack, trav)
        }
      }
    }
  }

  return result, best_dist, found
}

bvh_refit :: proc(bvh: ^BVH($T)) {
  for i := len(bvh.nodes) - 1; i >= 0; i -= 1 {
    node := &bvh.nodes[i]

    if node.left_child < 0 {
      node.bounds = AABB_UNDEFINED
      for j in node.primitive_start ..< node.primitive_start + node.primitive_count {
        prim_bounds := bvh.bounds_func(bvh.primitives[j])
        node.bounds = aabb_union(node.bounds, prim_bounds)
      }
    } else {
      left_bounds := bvh.nodes[node.left_child].bounds
      right_bounds := bvh.nodes[node.right_child].bounds
      node.bounds = aabb_union(left_bounds, right_bounds)
    }
  }
}

bvh_validate :: proc(bvh: ^BVH($T)) -> bool {
  if len(bvh.nodes) == 0 do return true

  for i in 0 ..< len(bvh.nodes) {
    node := bvh.nodes[i]
    if node.left_child >= 0 {
      // Internal node checks
      if node.right_child < 0 do return false
      if node.primitive_count != -1 do return false
      if node.left_child >= i32(len(bvh.nodes)) do return false
      if node.right_child >= i32(len(bvh.nodes)) do return false

      left := bvh.nodes[node.left_child]
      right := bvh.nodes[node.right_child]

      // Check bounds contain children (with some tolerance)
      if !aabb_contains_approx(node.bounds, left.bounds, 1e-3) do return false
      if !aabb_contains_approx(node.bounds, right.bounds, 1e-3) do return false
    } else {
      // Leaf node checks
      if node.primitive_count <= 0 do return false
      if node.primitive_start < 0 do return false
      if node.primitive_start + node.primitive_count > i32(len(bvh.primitives)) do return false
    }
  }
  return true
}

bvh_get_stats :: proc(bvh: ^BVH($T)) -> BVHStats {
  stats: BVHStats

  for node in bvh.nodes {
    stats.total_nodes += 1

    if node.left_child < 0 {
      stats.leaf_nodes += 1
      stats.total_primitives += node.primitive_count
      stats.max_leaf_size =
        stats.max_leaf_size > node.primitive_count ? stats.max_leaf_size : node.primitive_count
      if node.primitive_count == 0 do stats.empty_leaves += 1
    } else {
      stats.internal_nodes += 1
    }
  }

  return stats
}

BVHStats :: struct {
  total_nodes:      i32,
  leaf_nodes:       i32,
  internal_nodes:   i32,
  total_primitives: i32,
  max_leaf_size:    i32,
  empty_leaves:     i32,
}

// Efficient insert - just append and mark for rebuild
bvh_insert :: proc(bvh: ^BVH($T), item: T) {
  append(&bvh.primitives, item)
  // Mark BVH as needing rebuild - simple approach
  // For better performance, implement incremental insertion later
}

// Efficient update - update item and refit bounds
bvh_update :: proc(bvh: ^BVH($T), index: int, new_item: T) {
  if index >= 0 && index < len(bvh.primitives) {
    bvh.primitives[index] = new_item
    // Refit bounds from this item upward
    bvh_refit(bvh)
  }
}

// Remove item by index
bvh_remove :: proc(bvh: ^BVH($T), index: int) {
  if index >= 0 && index < len(bvh.primitives) {
    // Simple approach - remove and mark for rebuild
    ordered_remove(&bvh.primitives, index)
    // For better performance, implement incremental removal later
  }
}

// Fast incremental insert that finds best insertion point
bvh_insert_incremental :: proc(bvh: ^BVH($T), item: T) {
  if len(bvh.nodes) == 0 {
    append(&bvh.primitives, item)
    items := []T{item}
    bvh_build(bvh, items)
    return
  }

  // Find best leaf node to insert into
  item_bounds := bvh.bounds_func(item)
  best_node_idx := find_best_insert_node(bvh, item_bounds)

  // Insert into primitives array
  append(&bvh.primitives, item)

  // Update leaf node to include new primitive
  leaf_node := &bvh.nodes[best_node_idx]
  leaf_node.primitive_count += 1
  leaf_node.bounds = aabb_union(leaf_node.bounds, item_bounds)

  // Refit bounds up the tree
  bvh_refit_from_node(bvh, best_node_idx)
}

@(private)
find_best_insert_node :: proc(bvh: ^BVH($T), item_bounds: Aabb) -> int {
  if len(bvh.nodes) == 0 do return -1

  current_idx := 0

  for {
    node := &bvh.nodes[current_idx]

    // If leaf node, return it
    if node.primitive_count > 0 {
      return current_idx
    }

    // Choose child with minimum cost increase
    left_node := &bvh.nodes[node.left_child]
    right_node := &bvh.nodes[node.right_child]

    left_cost := aabb_surface_area(aabb_union(left_node.bounds, item_bounds)) - aabb_surface_area(left_node.bounds)
    right_cost := aabb_surface_area(aabb_union(right_node.bounds, item_bounds)) - aabb_surface_area(right_node.bounds)

    if left_cost < right_cost {
      current_idx = node.left_child
    } else {
      current_idx = node.right_child
    }
  }

  return current_idx
}

@(private)
bvh_refit_from_node :: proc(bvh: ^BVH($T), start_node_idx: int) {
  // This would require parent pointers for efficient implementation
  // For now, just refit the entire tree
  bvh_refit(bvh)
}
