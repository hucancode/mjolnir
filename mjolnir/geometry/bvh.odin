package geometry

import "base:intrinsics"
import "core:log"
import "core:math"
import "core:mem"
import "core:slice"
import "core:sync"
import "core:thread"
import "core:time"

// BVHNode is a flattened BVH node; a leaf has left_child < 0 and owns primitive_count primitives from primitive_start.
BVHNode :: struct {
  bounds:          Aabb,
  left_child:      i32,
  right_child:     i32,
  primitive_start: i32,
  primitive_count: i32,
}

// BVH is a bounding volume hierarchy over items of type T, bounded by bounds_func.
BVH :: struct($T: typeid) {
  nodes:       [dynamic]BVHNode,
  primitives:  [dynamic]T,
  bounds_func: proc(t: T) -> Aabb,
  // Level-order traversal data for parallel refit
  node_levels: [dynamic][dynamic]i32,
  max_depth:   i32,
}

// bvh_destroy frees the memory held by bvh.
bvh_destroy :: proc(bvh: ^BVH($T)) {
  delete(bvh.nodes)
  delete(bvh.primitives)
  for &level in bvh.node_levels {
    delete(level)
  }
  delete(bvh.node_levels)
}

@(private = "file")
BVHBuildNode :: struct {
  bounds:     Aabb,
  left:       ^BVHBuildNode,
  right:      ^BVHBuildNode,
  prim_start: i32,
  prim_count: i32,
}

@(private = "file")
BVHPrimitive :: struct {
  index:    i32,
  bounds:   Aabb,
  centroid: [3]f32,
}

// Parallel BVH build configuration
@(private = "file")
PARALLEL_BUILD_THRESHOLD :: 1000 // Min items for parallelism
@(private = "file")
PARALLEL_TASK_THRESHOLD :: 250 // Min items to spawn subtasks
@(private = "file")
PARALLEL_DEPTH_THRESHOLD :: 4 // Max depth for parallel tasks

// Task data for parallel recursive build
@(private = "file")
BVH_Build_Task_Data :: struct {
  prims:         []BVHPrimitive,
  start:         i32,
  end:           i32,
  max_leaf_size: i32,
  allocator:     mem.Allocator,
  result_ptr:    ^^BVHBuildNode, // Pointer to the result pointer for atomic writes
  depth:         i32,
  thread_pool:   ^thread.Pool,
}

// bvh_build rebuilds bvh over items; leaves hold at most max_leaf_size items.
bvh_build :: proc(bvh: ^BVH($T), items: []T, max_leaf_size: i32 = 4) {
  if bvh == nil do return
  if bvh.bounds_func == nil do return
  clear(&bvh.nodes)
  clear(&bvh.primitives)
  if len(items) == 0 do return
  reserve(&bvh.primitives, len(items))
  append(&bvh.primitives, ..items)
  arena: mem.Dynamic_Arena
  mem.dynamic_arena_init(&arena)
  defer mem.dynamic_arena_destroy(&arena)
  arena_allocator := mem.dynamic_arena_allocator(&arena)
  build_prims := make([]BVHPrimitive, len(items), arena_allocator)
  for item, i in items {
    bounds := bvh.bounds_func(item)
    build_prims[i] = BVHPrimitive {
      index    = i32(i),
      bounds   = bounds,
      centroid = aabb_center(bounds),
    }
  }
  root := build_recursive(
    build_prims[:],
    0,
    i32(len(items)),
    max_leaf_size,
    arena_allocator,
  )
  for prim, i in build_prims {
    bvh.primitives[i] = items[prim.index]
  }
  flatten_bvh(bvh, root)
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
  node.bounds = aabb_union(node.left.bounds, node.right.bounds)
  return node
}

@(private = "file")
SAHBin :: struct {
  bounds: Aabb,
  count:  i32,
}

@(private)
split_sah_binned :: proc(
  prims: []BVHPrimitive,
  node_bounds: Aabb,
  allocator: mem.Allocator,
) -> (
  axis: i32,
  split_pos: i32,
) {
  NUM_BINS :: 16
  if len(prims) <= 8 {
    return split_median(prims, node_bounds)
  }
  best_cost := f32(F32_MAX)
  best_axis := -1
  best_split_bin := -1
  extent := node_bounds.max - node_bounds.min
  #unroll for ax in 0 ..< 3 {
    if extent[ax] < 0.0001 {
    } else {
    bins := make([]SAHBin, NUM_BINS, context.temp_allocator)
    for &bin in bins {
      bin.bounds = AABB_UNDEFINED
      bin.count = 0
    }
    bin_scale := f32(NUM_BINS) / extent[ax]
    for prim in prims {
      bin_idx := i32((prim.centroid[ax] - node_bounds.min[ax]) * bin_scale)
      bin_idx = clamp(bin_idx, 0, NUM_BINS - 1)
      bins[bin_idx].count += 1
      bins[bin_idx].bounds = aabb_union(bins[bin_idx].bounds, prim.bounds)
    }
    left_counts := make([]i32, NUM_BINS - 1, context.temp_allocator)
    left_bounds_array := make([]Aabb, NUM_BINS - 1, context.temp_allocator)
    running_count: i32 = 0
    running_bounds := AABB_UNDEFINED
    for i in 0 ..< NUM_BINS - 1 {
      running_count += bins[i].count
      running_bounds = aabb_union(running_bounds, bins[i].bounds)
      left_counts[i] = running_count
      left_bounds_array[i] = running_bounds
    }
    right_counts := make([]i32, NUM_BINS - 1, context.temp_allocator)
    right_bounds_array := make([]Aabb, NUM_BINS - 1, context.temp_allocator)
    running_count = 0
    running_bounds = AABB_UNDEFINED
    for i := NUM_BINS - 1; i > 0; i -= 1 {
      running_count += bins[i].count
      running_bounds = aabb_union(running_bounds, bins[i].bounds)
      right_counts[i - 1] = running_count
      right_bounds_array[i - 1] = running_bounds
    }
    for i in 0 ..< NUM_BINS - 1 {
      if left_counts[i] == 0 || right_counts[i] == 0 do continue
      cost := sah_cost(left_bounds_array[i], left_counts[i], right_bounds_array[i], right_counts[i], node_bounds)
      if cost < best_cost {
        best_cost = cost
        best_axis = ax
        best_split_bin = i
      }
    }
    }
  }
  if best_axis < 0 || best_split_bin < 0 {
    return split_median(prims, node_bounds)
  }
  bin_scale := f32(NUM_BINS) / (node_bounds.max[best_axis] - node_bounds.min[best_axis])
  split_threshold := node_bounds.min[best_axis] + f32(best_split_bin + 1) / bin_scale
  split_idx := 0
  for i in 0 ..< len(prims) {
    if prims[i].centroid[best_axis] < split_threshold {
      if i != split_idx {
        prims[split_idx], prims[i] = prims[i], prims[split_idx]
      }
      split_idx += 1
    }
  }
  if split_idx == 0 || split_idx >= len(prims) {
    return split_median(prims, node_bounds)
  }
  return i32(best_axis), i32(split_idx)
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
  return split_sah_binned(prims, node_bounds, allocator)
}

@(private)
split_median :: proc(
  prims: []BVHPrimitive,
  node_bounds: Aabb,
) -> (
  axis: i32,
  split_pos: i32,
) {
  extent := node_bounds.max - node_bounds.min
  best_axis := 0
  if extent[1] > extent[0] do best_axis = 1
  if extent[2] > extent[best_axis] do best_axis = 2
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
flatten_bvh :: proc(bvh: ^BVH($T), root: ^BVHBuildNode) {
  node_count := count_build_nodes(root)
  resize(&bvh.nodes, int(node_count))
  next_node_idx: i32 = 0
  flatten_node(bvh, root, &next_node_idx)
  compute_bvh_levels(bvh)
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

// bvh_query_aabb replaces results with the items whose bounds overlap query_bounds.
bvh_query_aabb :: proc(
  bvh: ^BVH($T),
  query_bounds: Aabb,
  results: ^[dynamic]T,
) {
  if bvh == nil || results == nil do return
  clear(results)
  if len(bvh.nodes) == 0 do return

  BVH_MAX_STACK_DEPTH :: 64
  stack: [BVH_MAX_STACK_DEPTH]i32
  stack_size := 1
  stack[0] = 0

  for stack_size > 0 {
    stack_size -= 1
    node_idx := stack[stack_size]
    node := &bvh.nodes[node_idx]

    if !aabb_intersects(node.bounds, query_bounds) do continue

    if node.primitive_count > 0 {
      prim_start := node.primitive_start
      prim_end := node.primitive_start + node.primitive_count

      when intrinsics.type_has_field(T, "bounds") {
        #no_bounds_check for i in prim_start ..< prim_end {
          if aabb_intersects(bvh.primitives[i].bounds, query_bounds) {
            append(results, bvh.primitives[i])
          }
        }
      } else {
        if bvh.bounds_func == nil do continue
        for i in prim_start ..< prim_end {
          prim := bvh.primitives[i]
          prim_bounds := bvh.bounds_func(prim)
          if aabb_intersects(prim_bounds, query_bounds) {
            append(results, prim)
          }
        }
      }
    } else {
      stack[stack_size] = node.left_child
      stack_size += 1
      stack[stack_size] = node.right_child
      stack_size += 1
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
  #unroll for i in 0 ..< 3 {
    if math.abs(direction[i]) < 1e-6 {
      if origin[i] < aabb.min[i] || origin[i] > aabb.max[i] {
        return F32_MAX, -F32_MAX
      }
    } else {
      inv_d := 1.0 / direction[i]
      t1 := (aabb.min[i] - origin[i]) * inv_d
      t2 := (aabb.max[i] - origin[i]) * inv_d
      t_min[i] = min(t1, t2)
      t_max[i] = max(t1, t2)
    }
  }
  t_near = max(t_min.x, t_min.y, t_min.z)
  t_far = min(t_max.x, t_max.y, t_max.z)
  if t_far < t_near do return F32_MAX, -F32_MAX
  return
}

// bvh_query_ray replaces results with the items whose bounds the ray crosses within max_dist.
bvh_query_ray :: proc(
  bvh: ^BVH($T),
  ray: Ray,
  max_dist: f32,
  results: ^[dynamic]T,
) {
  clear(results)
  if len(bvh.nodes) == 0 do return

  BVH_MAX_STACK_DEPTH :: 64
  stack: [BVH_MAX_STACK_DEPTH]i32
  stack_size := 1
  stack[0] = 0

  for stack_size > 0 {
    stack_size -= 1
    node_idx := stack[stack_size]
    node := &bvh.nodes[node_idx]

    t_near, t_far := ray_aabb_intersection_safe(
      ray.origin,
      ray.direction,
      node.bounds,
    )
    if t_near > max_dist || t_far < 0 do continue

    if node.primitive_count > 0 {
      prim_start := node.primitive_start
      prim_end := node.primitive_start + node.primitive_count

      when intrinsics.type_has_field(T, "bounds") {
        #no_bounds_check for i in prim_start ..< prim_end {
          prim := bvh.primitives[i]
          prim_t_near, prim_t_far := ray_aabb_intersection_safe(
            ray.origin,
            ray.direction,
            prim.bounds,
          )
          if prim_t_near <= max_dist && prim_t_far >= 0 {
            append(results, prim)
          }
        }
      } else {
        if bvh.bounds_func == nil do continue
        for i in prim_start ..< prim_end {
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
      }
    } else {
      stack[stack_size] = node.left_child
      stack_size += 1
      stack[stack_size] = node.right_child
      stack_size += 1
    }
  }
}

// RayHit is a ray query result: the primitive hit, the hit distance t, and whether anything was hit.
RayHit :: struct($T: typeid) {
  primitive: T,
  t:         f32,
  hit:       bool,
}

// bvh_refit recomputes node bounds bottom-up after items moved, keeping the tree shape.
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

@(private)
compute_bvh_levels :: proc(bvh: ^BVH($T)) {
  if len(bvh.nodes) == 0 do return
  for &level in bvh.node_levels {
    delete(level)
  }
  clear(&bvh.node_levels)
  queue := make([dynamic]struct{idx: i32, depth: i32}, context.temp_allocator)
  append(&queue, struct{idx: i32, depth: i32}{idx = 0, depth = 0})
  bvh.max_depth = 0
  for len(queue) > 0 {
    current := queue[0]
    ordered_remove(&queue, 0)
    for i32(len(bvh.node_levels)) <= current.depth {
      append(&bvh.node_levels, make([dynamic]i32))
    }
    append(&bvh.node_levels[current.depth], current.idx)
    bvh.max_depth = max(bvh.max_depth, current.depth)
    node := &bvh.nodes[current.idx]
    if node.left_child >= 0 {
      append(&queue, struct{idx: i32, depth: i32}{idx = node.left_child, depth = current.depth + 1})
      append(&queue, struct{idx: i32, depth: i32}{idx = node.right_child, depth = current.depth + 1})
    }
  }
}

// BVHOverlapPair is a pair of overlapping primitives found by bvh_find_all_overlaps.
BVHOverlapPair :: struct($T: typeid) {
  a: T,
  b: T,
}

// BVHCrossPair is a pair of overlapping primitives found by bvh_find_cross_overlaps.
BVHCrossPair :: struct($T: typeid, $U: typeid) {
  a: T,
  b: U,
}

// bvh_find_all_overlaps finds all overlapping pairs within a single BVH in O(N + K).
bvh_find_all_overlaps :: proc(
  bvh: ^BVH($T),
  results: ^[dynamic]BVHOverlapPair(T),
) {
  clear(results)
  if len(bvh.nodes) == 0 do return
  if bvh.bounds_func == nil do return

  find_overlaps_recursive(bvh, 0, 0, results)
}

@(private)
find_overlaps_recursive :: proc(
  bvh: ^BVH($T),
  node_a_idx: i32,
  node_b_idx: i32,
  results: ^[dynamic]BVHOverlapPair(T),
) {
  node_a := &bvh.nodes[node_a_idx]
  node_b := &bvh.nodes[node_b_idx]

  if !aabb_intersects(node_a.bounds, node_b.bounds) do return

  a_is_leaf := node_a.primitive_count > 0
  b_is_leaf := node_b.primitive_count > 0

  if a_is_leaf && b_is_leaf {
    prim_a_start := node_a.primitive_start
    prim_a_end := node_a.primitive_start + node_a.primitive_count
    prim_b_start := node_b.primitive_start
    prim_b_end := node_b.primitive_start + node_b.primitive_count

    when intrinsics.type_has_field(T, "bounds") {
      #no_bounds_check for i in prim_a_start ..< prim_a_end {
        prim_a := bvh.primitives[i]
        bounds_a := prim_a.bounds

        // If same node, start after current index to avoid duplicates
        j_start := prim_b_start if node_a_idx != node_b_idx else i + 1

        #no_bounds_check for j in j_start ..< prim_b_end {
          prim_b := bvh.primitives[j]
          bounds_b := prim_b.bounds

          if aabb_intersects(bounds_a, bounds_b) {
            append(results, BVHOverlapPair(T){a = prim_a, b = prim_b})
          }
        }
      }
    } else {
      for i in prim_a_start ..< prim_a_end {
        prim_a := bvh.primitives[i]
        bounds_a := bvh.bounds_func(prim_a)

        // If same node, start after current index to avoid duplicates
        j_start := prim_b_start if node_a_idx != node_b_idx else i + 1

        for j in j_start ..< prim_b_end {
          prim_b := bvh.primitives[j]
          bounds_b := bvh.bounds_func(prim_b)

          if aabb_intersects(bounds_a, bounds_b) {
            append(results, BVHOverlapPair(T){a = prim_a, b = prim_b})
          }
        }
      }
    }
    return
  }

  if a_is_leaf {
    find_overlaps_recursive(bvh, node_a_idx, node_b.left_child, results)
    find_overlaps_recursive(bvh, node_a_idx, node_b.right_child, results)
  } else if b_is_leaf {
    find_overlaps_recursive(bvh, node_a.left_child, node_b_idx, results)
    find_overlaps_recursive(bvh, node_a.right_child, node_b_idx, results)
  } else {
    if node_a_idx == node_b_idx {
      find_overlaps_recursive(bvh, node_a.left_child, node_a.left_child, results)
      find_overlaps_recursive(bvh, node_a.left_child, node_a.right_child, results)
      find_overlaps_recursive(bvh, node_a.right_child, node_a.right_child, results)
    } else {
      find_overlaps_recursive(bvh, node_a.left_child, node_b.left_child, results)
      find_overlaps_recursive(bvh, node_a.left_child, node_b.right_child, results)
      find_overlaps_recursive(bvh, node_a.right_child, node_b.left_child, results)
      find_overlaps_recursive(bvh, node_a.right_child, node_b.right_child, results)
    }
  }
}

// bvh_find_cross_overlaps finds all overlapping pairs between two BVHs in O(N + M + K).
bvh_find_cross_overlaps :: proc(
  bvh_a: ^BVH($T),
  bvh_b: ^BVH($U),
  results: ^[dynamic]BVHCrossPair(T, U),
) {
  clear(results)
  if len(bvh_a.nodes) == 0 || len(bvh_b.nodes) == 0 do return
  find_cross_overlaps_recursive(bvh_a, bvh_b, 0, 0, results)
}

@(private)
find_cross_overlaps_recursive :: proc(
  bvh_a: ^BVH($T),
  bvh_b: ^BVH($U),
  node_a_idx: i32,
  node_b_idx: i32,
  results: ^[dynamic]BVHCrossPair(T, U),
) {
  node_a := &bvh_a.nodes[node_a_idx]
  node_b := &bvh_b.nodes[node_b_idx]

  if !aabb_intersects(node_a.bounds, node_b.bounds) do return

  a_is_leaf := node_a.primitive_count > 0
  b_is_leaf := node_b.primitive_count > 0

  if a_is_leaf && b_is_leaf {
    prim_a_start := node_a.primitive_start
    prim_a_end := node_a.primitive_start + node_a.primitive_count
    prim_b_start := node_b.primitive_start
    prim_b_end := node_b.primitive_start + node_b.primitive_count

    when intrinsics.type_has_field(T, "bounds") &&
         intrinsics.type_has_field(U, "bounds") {
      #no_bounds_check for i in prim_a_start ..< prim_a_end {
        prim_a := bvh_a.primitives[i]
        bounds_a := prim_a.bounds

        #no_bounds_check for j in prim_b_start ..< prim_b_end {
          prim_b := bvh_b.primitives[j]
          bounds_b := prim_b.bounds

          if aabb_intersects(bounds_a, bounds_b) {
            append(results, BVHCrossPair(T, U){a = prim_a, b = prim_b})
          }
        }
      }
    } else when intrinsics.type_has_field(T, "bounds") {
      #no_bounds_check for i in prim_a_start ..< prim_a_end {
        prim_a := bvh_a.primitives[i]
        bounds_a := prim_a.bounds

        for j in prim_b_start ..< prim_b_end {
          prim_b := bvh_b.primitives[j]
          bounds_b := bvh_b.bounds_func(prim_b)

          if aabb_intersects(bounds_a, bounds_b) {
            append(results, BVHCrossPair(T, U){a = prim_a, b = prim_b})
          }
        }
      }
    } else when intrinsics.type_has_field(U, "bounds") {
      for i in prim_a_start ..< prim_a_end {
        prim_a := bvh_a.primitives[i]
        bounds_a := bvh_a.bounds_func(prim_a)

        #no_bounds_check for j in prim_b_start ..< prim_b_end {
          prim_b := bvh_b.primitives[j]
          bounds_b := prim_b.bounds

          if aabb_intersects(bounds_a, bounds_b) {
            append(results, BVHCrossPair(T, U){a = prim_a, b = prim_b})
          }
        }
      }
    } else {
      for i in prim_a_start ..< prim_a_end {
        prim_a := bvh_a.primitives[i]
        bounds_a := bvh_a.bounds_func(prim_a)

        for j in prim_b_start ..< prim_b_end {
          prim_b := bvh_b.primitives[j]
          bounds_b := bvh_b.bounds_func(prim_b)

          if aabb_intersects(bounds_a, bounds_b) {
            append(results, BVHCrossPair(T, U){a = prim_a, b = prim_b})
          }
        }
      }
    }
    return
  }

  if a_is_leaf {
    find_cross_overlaps_recursive(bvh_a, bvh_b, node_a_idx, node_b.left_child, results)
    find_cross_overlaps_recursive(bvh_a, bvh_b, node_a_idx, node_b.right_child, results)
  } else if b_is_leaf {
    find_cross_overlaps_recursive(bvh_a, bvh_b, node_a.left_child, node_b_idx, results)
    find_cross_overlaps_recursive(bvh_a, bvh_b, node_a.right_child, node_b_idx, results)
  } else {
    find_cross_overlaps_recursive(bvh_a, bvh_b, node_a.left_child, node_b.left_child, results)
    find_cross_overlaps_recursive(bvh_a, bvh_b, node_a.left_child, node_b.right_child, results)
    find_cross_overlaps_recursive(bvh_a, bvh_b, node_a.right_child, node_b.left_child, results)
    find_cross_overlaps_recursive(bvh_a, bvh_b, node_a.right_child, node_b.right_child, results)
  }
}

// Parallel BVH Building Implementation

// Phase 1: Parallel primitive preparation (simplified - sequential for now)
// TODO: Can be parallelized using SIMD in the future
@(private)
parallel_prepare_primitives :: proc(
  items: []$T,
  bounds_func: proc(t: T) -> Aabb,
  pool: ^thread.Pool,
  num_threads: int,
  allocator: mem.Allocator,
) -> []BVHPrimitive {
  build_prims := make([]BVHPrimitive, len(items), allocator)

  // For now, compute sequentially since thread tasks can't handle polymorphic types easily
  // This is still fast (< 5% of total build time)
  for item, i in items {
    bounds := bounds_func(item)
    build_prims[i] = BVHPrimitive {
      index    = i32(i),
      bounds   = bounds,
      centroid = aabb_center(bounds),
    }
  }

  return build_prims
}

// Task procedure for parallel recursive build
@(private)
bvh_build_task :: proc(task: thread.Task) {
  data := (^BVH_Build_Task_Data)(task.data)

  node := new(BVHBuildNode, data.allocator)
  node.bounds = AABB_UNDEFINED

  for i in data.start ..< data.end {
    node.bounds = aabb_union(node.bounds, data.prims[i].bounds)
  }

  prim_count := data.end - data.start

  if prim_count <= data.max_leaf_size {
    node.prim_start = data.start
    node.prim_count = prim_count
    node.bounds = AABB_UNDEFINED
    for i in data.start ..< data.end {
      node.bounds = aabb_union(node.bounds, data.prims[i].bounds)
    }
    sync.atomic_store(data.result_ptr, node)
    return
  }

  axis, split_pos := split_sah(data.prims[data.start:data.end], node.bounds, data.allocator)

  if axis < 0 || split_pos <= 0 || split_pos >= prim_count {
    node.prim_start = data.start
    node.prim_count = prim_count
    node.bounds = AABB_UNDEFINED
    for i in data.start ..< data.end {
      node.bounds = aabb_union(node.bounds, data.prims[i].bounds)
    }
    sync.atomic_store(data.result_ptr, node)
    return
  }

  mid := data.start + split_pos

  if data.depth >= PARALLEL_DEPTH_THRESHOLD || prim_count < PARALLEL_TASK_THRESHOLD {
    node.left = build_recursive(
      data.prims,
      data.start,
      mid,
      data.max_leaf_size,
      data.allocator,
    )
    node.right = build_recursive(
      data.prims,
      mid,
      data.end,
      data.max_leaf_size,
      data.allocator,
    )
    node.prim_start = -1
    node.prim_count = 0
    node.bounds = aabb_union(node.left.bounds, node.right.bounds)
    sync.atomic_store(data.result_ptr, node)
    return
  }

  left_result: ^BVHBuildNode = nil
  right_result: ^BVHBuildNode = nil

  left_task_data := BVH_Build_Task_Data {
    prims         = data.prims,
    start         = data.start,
    end           = mid,
    max_leaf_size = data.max_leaf_size,
    allocator     = data.allocator,
    result_ptr    = &left_result,
    depth         = data.depth + 1,
    thread_pool   = data.thread_pool,
  }

  right_task_data := BVH_Build_Task_Data {
    prims         = data.prims,
    start         = mid,
    end           = data.end,
    max_leaf_size = data.max_leaf_size,
    allocator     = data.allocator,
    result_ptr    = &right_result,
    depth         = data.depth + 1,
    thread_pool   = data.thread_pool,
  }

  thread.pool_add_task(
    data.thread_pool,
    mem.nil_allocator(),
    bvh_build_task,
    &left_task_data,
    0,
  )
  thread.pool_add_task(
    data.thread_pool,
    mem.nil_allocator(),
    bvh_build_task,
    &right_task_data,
    0,
  )
  for sync.atomic_load(&left_result) == nil || sync.atomic_load(&right_result) == nil {
    if queued_task, ok := thread.pool_pop_waiting(data.thread_pool); ok {
      thread.pool_do_work(data.thread_pool, queued_task)
      continue
    }
    time.sleep(time.Microsecond * 100)
  }

  node.left = left_result
  node.right = right_result
  node.prim_start = -1
  node.prim_count = 0
  node.bounds = aabb_union(node.left.bounds, node.right.bounds)
  sync.atomic_store(data.result_ptr, node)
}

// Phase 2: Parallel recursive build
@(private)
parallel_build_recursive :: proc(
  prims: []BVHPrimitive,
  max_leaf_size: i32,
  allocator: mem.Allocator,
  pool: ^thread.Pool,
) -> ^BVHBuildNode {
  result: ^BVHBuildNode = nil

  task_data := BVH_Build_Task_Data {
    prims         = prims,
    start         = 0,
    end           = i32(len(prims)),
    max_leaf_size = max_leaf_size,
    allocator     = allocator,
    result_ptr    = &result,
    depth         = 0,
    thread_pool   = pool,
  }

  thread.pool_add_task(
    pool,
    mem.nil_allocator(),
    bvh_build_task,
    &task_data,
    0,
  )

  for sync.atomic_load(&result) == nil {
    if queued_task, ok := thread.pool_pop_waiting(pool); ok {
      thread.pool_do_work(pool, queued_task)
      continue
    }
    time.sleep(time.Microsecond * 100)
  }

  return result
}

// bvh_build_parallel builds the BVH on the thread pool, falling back to a sequential build for small inputs.
bvh_build_parallel :: proc(
  bvh: ^BVH($T),
  items: []T,
  thread_pool: ^thread.Pool,
  max_leaf_size: i32 = 4,
  parallel_threshold: int = PARALLEL_BUILD_THRESHOLD,
) {
  if bvh == nil do return
  if bvh.bounds_func == nil do return

  clear(&bvh.nodes)
  clear(&bvh.primitives)
  if len(items) == 0 do return

  if len(items) < parallel_threshold || thread_pool == nil || !thread_pool.is_running || len(thread_pool.threads) == 0 {
    bvh_build(bvh, items, max_leaf_size)
    return
  }

  reserve(&bvh.primitives, len(items))
  append(&bvh.primitives, ..items)

  // Setup per-thread arenas for thread-safe memory allocation
  num_threads := len(thread_pool.threads)
  if num_threads == 0 do num_threads = 1

  arena: mem.Dynamic_Arena
  mem.dynamic_arena_init(&arena)
  defer mem.dynamic_arena_destroy(&arena)
  arena_mutex: mem.Mutex_Allocator
  mem.mutex_allocator_init(&arena_mutex, mem.dynamic_arena_allocator(&arena))
  arena_allocator := mem.mutex_allocator(&arena_mutex)

  build_prims := parallel_prepare_primitives(
    items,
    bvh.bounds_func,
    thread_pool,
    num_threads,
    arena_allocator,
  )

  root := parallel_build_recursive(
    build_prims[:],
    max_leaf_size,
    arena_allocator,
    thread_pool,
  )

  for prim, i in build_prims {
    bvh.primitives[i] = items[prim.index]
  }

  flatten_bvh(bvh, root)
}
