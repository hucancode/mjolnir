package geometry

import "core:slice"
import "core:math"
import "core:math/linalg"
import "core:log"

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
  clear(&bvh.nodes)
  clear(&bvh.primitives)

  if len(items) == 0 do return

  append(&bvh.primitives, ..items)

  build_prims := make([]BVHPrimitive, len(items))
  defer delete(build_prims)
  for i in 0..<len(items) {
    item := items[i]
    bounds := bvh.bounds_func(item)
    build_prims[i] = BVHPrimitive{
      index = i32(i),
      bounds = bounds,
      centroid = aabb_center(bounds),
    }
  }

  root := build_recursive(build_prims[:], 0, i32(len(items)), max_leaf_size)

  // Reorder the primitives array to match the build_prims order
  for i in 0..<len(build_prims) {
    bvh.primitives[i] = items[build_prims[i].index]
  }

  flatten_bvh_tree(bvh, root)

  free_build_nodes(root)
}

build_recursive :: proc(prims: []BVHPrimitive, start, end: i32, max_leaf_size: i32) -> ^BVHBuildNode {
  node := new(BVHBuildNode)

  node.bounds = AABB_UNDEFINED
  for i in start..<end {
    node.bounds = aabb_union(node.bounds, prims[i].bounds)
  }

  prim_count := end - start

  if prim_count <= max_leaf_size {
    node.prim_start = start
    node.prim_count = prim_count
    // Recalculate bounds from actual primitives in this leaf node
    node.bounds = AABB_UNDEFINED
    for i in start..<end {
      node.bounds = aabb_union(node.bounds, prims[i].bounds)
    }
    return node
  }

  axis, split_pos := split_sah(prims[start:end], node.bounds)

  if axis < 0 || split_pos <= 0 || split_pos >= prim_count {
    node.prim_start = start
    node.prim_count = prim_count
    // Recalculate bounds from actual primitives in this fallback leaf node
    node.bounds = AABB_UNDEFINED
    for i in start..<end {
      node.bounds = aabb_union(node.bounds, prims[i].bounds)
    }
    return node
  }

  mid := start + split_pos

  node.left = build_recursive(prims, start, mid, max_leaf_size)
  node.right = build_recursive(prims, mid, end, max_leaf_size)
  node.prim_start = -1
  node.prim_count = 0

  // Update bounds to be union of child bounds (this is correct for internal nodes)
  node.bounds = aabb_union(node.left.bounds, node.right.bounds)

  return node
}

split_sah :: proc(prims: []BVHPrimitive, node_bounds: Aabb) -> (axis: i32, split_pos: i32) {
  best_cost := f32(F32_MAX)
  best_axis := -1
  best_split := -1

  // Store a copy for each axis test
  prims_copy := make([]BVHPrimitive, len(prims), context.temp_allocator)

  for ax in 0..<3 {
    copy(prims_copy, prims)

    if ax == 0 {
      slice.sort_by(prims_copy, proc(a, b: BVHPrimitive) -> bool {
        return a.centroid[0] < b.centroid[0]
      })
    } else if ax == 1 {
      slice.sort_by(prims_copy, proc(a, b: BVHPrimitive) -> bool {
        return a.centroid[1] < b.centroid[1]
      })
    } else {
      slice.sort_by(prims_copy, proc(a, b: BVHPrimitive) -> bool {
        return a.centroid[2] < b.centroid[2]
      })
    }

    for i in 1..<len(prims_copy) {
      left_bounds := AABB_UNDEFINED
      for j in 0..<i {
        left_bounds = aabb_union(left_bounds, prims_copy[j].bounds)
      }

      right_bounds := AABB_UNDEFINED
      for j in i..<len(prims_copy) {
        right_bounds = aabb_union(right_bounds, prims_copy[j].bounds)
      }

      cost := sah_cost(left_bounds, i32(i), right_bounds, i32(len(prims_copy) - i), node_bounds)

      if cost < best_cost {
        best_cost = cost
        best_axis = ax
        best_split = i
      }
    }
  }

  // Apply the best split to the original array
  if best_axis >= 0 {
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
  }

  return i32(best_axis), i32(best_split)
}

sah_cost :: proc(left_bounds: Aabb, left_count: i32, right_bounds: Aabb, right_count: i32, parent_bounds: Aabb) -> f32 {
  TRAVERSAL_COST :: 1.0
  INTERSECTION_COST :: 1.0

  parent_area := aabb_surface_area(parent_bounds)
  left_area := aabb_surface_area(left_bounds)
  right_area := aabb_surface_area(right_bounds)

  if parent_area == 0 do return F32_MAX

  p_left := left_area / parent_area
  p_right := right_area / parent_area

  return TRAVERSAL_COST + INTERSECTION_COST * (p_left * f32(left_count) + p_right * f32(right_count))
}

count_build_nodes :: proc(node: ^BVHBuildNode) -> i32 {
  if node == nil do return 0
  return 1 + count_build_nodes(node.left) + count_build_nodes(node.right)
}

flatten_bvh_tree :: proc(bvh: ^BVH($T), root: ^BVHBuildNode) {
  node_count := count_build_nodes(root)
  resize(&bvh.nodes, int(node_count))

  next_node_idx: i32 = 0
  flatten_node(bvh, root, &next_node_idx)
}

flatten_node :: proc(bvh: ^BVH($T), build_node: ^BVHBuildNode, next_idx: ^i32) -> i32 {
  node_idx := next_idx^
  next_idx^ += 1

  node := BVHNode{
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

free_build_nodes :: proc(node: ^BVHBuildNode) {
  if node == nil do return

  free_build_nodes(node.left)
  free_build_nodes(node.right)
  free(node)
}

bvh_query_aabb :: proc(bvh: ^BVH($T), query_bounds: Aabb, results: ^[dynamic]T) {
  clear(results)
  if len(bvh.nodes) == 0 do return

  stack := make([dynamic]i32, 0, 64, context.temp_allocator)
  append(&stack, 0)

  for len(stack) > 0 {
    node_idx := pop(&stack)
    node := &bvh.nodes[node_idx]

    if !aabb_intersects(node.bounds, query_bounds) do continue

    if node.primitive_count > 0 {
      for i in node.primitive_start..<node.primitive_start + node.primitive_count {
        prim := bvh.primitives[i]
        prim_bounds := bvh.bounds_func(prim)
        if aabb_intersects(prim_bounds, query_bounds) {
          append(results, prim)
        }
      }
    } else {
      append(&stack, node.left_child)
      append(&stack, node.right_child)
    }
  }
}

ray_aabb_intersection_safe :: proc(origin: [3]f32, direction: [3]f32, aabb: Aabb) -> (t_near, t_far: f32) {
  t_min := [3]f32{-F32_MAX, -F32_MAX, -F32_MAX}
  t_max := [3]f32{F32_MAX, F32_MAX, F32_MAX}

  for i in 0..<3 {
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

bvh_query_ray :: proc(bvh: ^BVH($T), ray: Ray, max_dist: f32, results: ^[dynamic]T) {
  clear(results)
  if len(bvh.nodes) == 0 do return

  stack := make([dynamic]i32, 0, 64, context.temp_allocator)
  append(&stack, 0)

  for len(stack) > 0 {
    node_idx := pop(&stack)
    node := &bvh.nodes[node_idx]

    t_near, t_far := ray_aabb_intersection_safe(ray.origin, ray.direction, node.bounds)
    if t_near > max_dist || t_far < 0 do continue

    if node.primitive_count > 0 {
      for i in node.primitive_start..<node.primitive_start + node.primitive_count {
        prim := bvh.primitives[i]
        prim_bounds := bvh.bounds_func(prim)
        prim_t_near, prim_t_far := ray_aabb_intersection_safe(ray.origin, ray.direction, prim_bounds)
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

bvh_query_sphere :: proc(bvh: ^BVH($T), center: [3]f32, radius: f32, results: ^[dynamic]T) {
  sphere_bounds := Aabb{
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

bvh_query_nearest :: proc(bvh: ^BVH($T), point: [3]f32, max_dist: f32 = F32_MAX) -> (result: T, dist: f32, found: bool) {
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
      for i in node.primitive_start..<node.primitive_start + node.primitive_count {
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

      traversals := [2]BVHTraversal{
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
      for j in node.primitive_start..<node.primitive_start + node.primitive_count {
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

  for i in 0..<len(bvh.nodes) {
    node := bvh.nodes[i]
    if node.left_child >= 0 {
      // Internal node checks
      if node.right_child < 0 {
        log.infof("Node %d: Internal node missing right child", i)
        return false
      }
      if node.primitive_count != -1 {
        log.infof("Node %d: Internal node has primitive count %d", i, node.primitive_count)
        return false
      }
      if node.left_child >= i32(len(bvh.nodes)) {
        log.infof("Node %d: Left child index %d out of bounds (max %d)", i, node.left_child, len(bvh.nodes))
        return false
      }
      if node.right_child >= i32(len(bvh.nodes)) {
        log.infof("Node %d: Right child index %d out of bounds (max %d)", i, node.right_child, len(bvh.nodes))
        return false
      }

      left := bvh.nodes[node.left_child]
      right := bvh.nodes[node.right_child]

      // Check bounds contain children (with some tolerance)
      if !aabb_contains_approx(node.bounds, left.bounds, 1e-3) {
        log.infof("Node %d: Does not contain left child bounds", i)
        log.infof("  Parent: min=%v max=%v", node.bounds.min, node.bounds.max)
        log.infof("  Left:   min=%v max=%v", left.bounds.min, left.bounds.max)
        return false
      }
      if !aabb_contains_approx(node.bounds, right.bounds, 1e-3) {
        log.infof("Node %d: Does not contain right child bounds", i)
        log.infof("  Parent: min=%v max=%v", node.bounds.min, node.bounds.max)
        log.infof("  Right:  min=%v max=%v", right.bounds.min, right.bounds.max)
        return false
      }
    } else {
      // Leaf node checks
      if node.primitive_count <= 0 {
        log.infof("Node %d: Leaf node has invalid primitive count %d", i, node.primitive_count)
        return false
      }
      if node.primitive_start < 0 {
        log.infof("Node %d: Leaf node has invalid primitive start %d", i, node.primitive_start)
        return false
      }
      if node.primitive_start + node.primitive_count > i32(len(bvh.primitives)) {
        log.infof("Node %d: Primitive range out of bounds (start=%d, count=%d, max=%d)",
                  i, node.primitive_start, node.primitive_count, len(bvh.primitives))
        return false
      }
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
      stats.max_leaf_size = stats.max_leaf_size > node.primitive_count ? stats.max_leaf_size : node.primitive_count
      if node.primitive_count == 0 do stats.empty_leaves += 1
    } else {
      stats.internal_nodes += 1
    }
  }

  return stats
}

BVHStats :: struct {
  total_nodes:     i32,
  leaf_nodes:      i32,
  internal_nodes:  i32,
  total_primitives: i32,
  max_leaf_size:   i32,
  empty_leaves:    i32,
}
