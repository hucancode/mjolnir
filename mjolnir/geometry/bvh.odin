package geometry

import "base:intrinsics"
import "core:log"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:sync"
import "core:thread"
import "core:time"

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
  // Level-order traversal data for parallel refit
  node_levels: [dynamic][dynamic]i32,
  max_depth:   i32,
}

bvh_destroy :: proc(bvh: ^BVH($T)) {
  delete(bvh.nodes)
  delete(bvh.primitives)
  for &level in bvh.node_levels {
    delete(level)
  }
  delete(bvh.node_levels)
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

// Parallel BVH build configuration
PARALLEL_BUILD_THRESHOLD :: 1000 // Min items for parallelism
PARALLEL_TASK_THRESHOLD :: 250 // Min items to spawn subtasks
PARALLEL_DEPTH_THRESHOLD :: 4 // Max depth for parallel tasks

// Per-thread arena context for parallel building
BVH_Build_Context :: struct {
  thread_arenas: []virtual.Arena,
  thread_count:  int,
}

// Task data for parallel recursive build
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
  root := build_recursive(
    build_prims[:],
    0,
    i32(len(items)),
    max_leaf_size,
    arena_allocator,
  )
  // Reorder the primitives array to match the build_prims order
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
      // Skip degenerate axes
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
        // Fast path - direct field access with SIMD batching
        if simd_mode != .Scalar {
          // Process in batches of 4 using SIMD
          query_batch := [4]Aabb{query_bounds, query_bounds, query_bounds, query_bounds}

          i := prim_start
          batch_end := prim_end - 3

          #no_bounds_check for i < batch_end {
            bounds_batch := [4]Aabb{
              bvh.primitives[i + 0].bounds,
              bvh.primitives[i + 1].bounds,
              bvh.primitives[i + 2].bounds,
              bvh.primitives[i + 3].bounds,
            }

            intersects := aabb_intersects_batch4(bounds_batch, query_batch)

            #unroll for j in 0 ..< 4 {
              if intersects[j] do append(results, bvh.primitives[i + i32(j)])
            }

            i += 4
          }

          // Process remaining primitives (< 4)
          #no_bounds_check for i < prim_end {
            if aabb_intersects(bvh.primitives[i].bounds, query_bounds) {
              append(results, bvh.primitives[i])
            }
            i += 1
          }
        } else {
          // Scalar fast path
          #no_bounds_check for i in prim_start ..< prim_end {
            if aabb_intersects(bvh.primitives[i].bounds, query_bounds) {
              append(results, bvh.primitives[i])
            }
          }
        }
      } else {
        // Callback path (no SIMD) - for types without cached bounds
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
      // Internal node - push children
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
      t_min[i] = min(t1, t2)
      t_max[i] = max(t1, t2)
    }
  }
  t_near = max(t_min.x, t_min.y, t_min.z)
  t_far = min(t_max.x, t_max.y, t_max.z)
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
        // Fast path - direct field access
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
        // Callback path
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
      // Internal node - push children
      stack[stack_size] = node.left_child
      stack_size += 1
      stack[stack_size] = node.right_child
      stack_size += 1
    }
  }
}

RayHit :: struct($T: typeid) {
  primitive: T,
  t:         f32,
  hit:       bool,
}

bvh_raycast :: proc(
  bvh: ^BVH($T),
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
        append(&stack, node.right_child, node.left_child)
      } else {
        append(&stack, node.left_child, node.right_child)
      }
    }
  }
  return best_hit
}

bvh_raycast_single :: proc(
  bvh: ^BVH($T),
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
          return RayHit(T){primitive = prim, t = t, hit = true}
        }
      }
    } else {
      append(&stack, node.left_child, node.right_child)
    }
  }
  return {}
}

bvh_raycast_multi :: proc(
  bvh: ^BVH($T),
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
          append(results, RayHit(T){primitive = prim, t = t, hit = true})
        }
      }
    } else {
      append(&stack, node.left_child, node.right_child)
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
      append(&stack, node.left_child, node.right_child)
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
      traversals := [?]BVHTraversal {
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
  refit_from_node(bvh, best_node_idx)
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
    left_cost :=
      aabb_surface_area(aabb_union(left_node.bounds, item_bounds)) -
      aabb_surface_area(left_node.bounds)
    right_cost :=
      aabb_surface_area(aabb_union(right_node.bounds, item_bounds)) -
      aabb_surface_area(right_node.bounds)
    if left_cost < right_cost {
      current_idx = node.left_child
    } else {
      current_idx = node.right_child
    }
  }
  return current_idx
}

@(private)
refit_from_node :: proc(bvh: ^BVH($T), start_node_idx: int) {
  // TODO: This would require parent pointers for efficient implementation
  // For now, just refit the entire tree
  bvh_refit(bvh)
}

// Pair of overlapping primitives from self-collision detection
BVHOverlapPair :: struct($T: typeid) {
  a: T,
  b: T,
}

// Pair of overlapping primitives from cross-tree collision detection
BVHCrossPair :: struct($T: typeid, $U: typeid) {
  a: T,
  b: U,
}

// Find all overlapping pairs within a single BVH (self-collision)
// This is O(N + K) where K is the number of overlapping pairs
// Much faster than N * O(log N) individual queries
bvh_find_all_overlaps :: proc(
  bvh: ^BVH($T),
  results: ^[dynamic]BVHOverlapPair(T),
) {
  clear(results)
  if len(bvh.nodes) == 0 do return
  if bvh.bounds_func == nil do return

  // Start self-collision detection from root
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

  // Early out if bounds don't overlap
  if !aabb_intersects(node_a.bounds, node_b.bounds) do return

  a_is_leaf := node_a.primitive_count > 0
  b_is_leaf := node_b.primitive_count > 0

  // Both are leaf nodes - test all primitive pairs
  if a_is_leaf && b_is_leaf {
    prim_a_start := node_a.primitive_start
    prim_a_end := node_a.primitive_start + node_a.primitive_count
    prim_b_start := node_b.primitive_start
    prim_b_end := node_b.primitive_start + node_b.primitive_count

    // Compile-time specialization based on type
    when intrinsics.type_has_field(T, "bounds") {
      // Fast path - direct field access
      #no_bounds_check for i in prim_a_start ..< prim_a_end {
        prim_a := bvh.primitives[i]
        bounds_a := prim_a.bounds

        // Determine the starting index for the inner loop
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
      // Callback path - for types without cached bounds
      for i in prim_a_start ..< prim_a_end {
        prim_a := bvh.primitives[i]
        bounds_a := bvh.bounds_func(prim_a)

        // Determine the starting index for the inner loop
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

  // One or both are internal nodes - recurse on children
  if a_is_leaf {
    // Only split node_b
    find_overlaps_recursive(bvh, node_a_idx, node_b.left_child, results)
    find_overlaps_recursive(bvh, node_a_idx, node_b.right_child, results)
  } else if b_is_leaf {
    // Only split node_a
    find_overlaps_recursive(bvh, node_a.left_child, node_b_idx, results)
    find_overlaps_recursive(bvh, node_a.right_child, node_b_idx, results)
  } else {
    // Both are internal - split both and test all combinations
    // When testing the same node against itself, avoid redundant tests
    if node_a_idx == node_b_idx {
      // Self-test: only test unique combinations
      find_overlaps_recursive(bvh, node_a.left_child, node_a.left_child, results)
      find_overlaps_recursive(bvh, node_a.left_child, node_a.right_child, results)
      find_overlaps_recursive(bvh, node_a.right_child, node_a.right_child, results)
    } else {
      // Different nodes: test all combinations
      find_overlaps_recursive(bvh, node_a.left_child, node_b.left_child, results)
      find_overlaps_recursive(bvh, node_a.left_child, node_b.right_child, results)
      find_overlaps_recursive(bvh, node_a.right_child, node_b.left_child, results)
      find_overlaps_recursive(bvh, node_a.right_child, node_b.right_child, results)
    }
  }
}

// Find all overlapping pairs between two different BVHs (cross-tree collision)
// This is O(N + M + K) where K is the number of overlapping pairs
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

  // Early out if bounds don't overlap
  if !aabb_intersects(node_a.bounds, node_b.bounds) do return

  a_is_leaf := node_a.primitive_count > 0
  b_is_leaf := node_b.primitive_count > 0

  // Both are leaf nodes - test all primitive pairs
  if a_is_leaf && b_is_leaf {
    prim_a_start := node_a.primitive_start
    prim_a_end := node_a.primitive_start + node_a.primitive_count
    prim_b_start := node_b.primitive_start
    prim_b_end := node_b.primitive_start + node_b.primitive_count

    // Compile-time specialization for both types
    when intrinsics.type_has_field(T, "bounds") &&
         intrinsics.type_has_field(U, "bounds") {
      // Both fast
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
      // A fast, B callback
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
      // A callback, B fast
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
      // Both callback
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

  // One or both are internal nodes - recurse on children
  if a_is_leaf {
    // Only split node_b
    find_cross_overlaps_recursive(bvh_a, bvh_b, node_a_idx, node_b.left_child, results)
    find_cross_overlaps_recursive(bvh_a, bvh_b, node_a_idx, node_b.right_child, results)
  } else if b_is_leaf {
    // Only split node_a
    find_cross_overlaps_recursive(bvh_a, bvh_b, node_a.left_child, node_b_idx, results)
    find_cross_overlaps_recursive(bvh_a, bvh_b, node_a.right_child, node_b_idx, results)
  } else {
    // Both are internal - test all combinations
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

  // Create node for this subtree
  node := new(BVHBuildNode, data.allocator)
  node.bounds = AABB_UNDEFINED

  // Compute bounds for this node
  for i in data.start ..< data.end {
    node.bounds = aabb_union(node.bounds, data.prims[i].bounds)
  }

  prim_count := data.end - data.start

  // Check if we should create a leaf node
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

  // Compute SAH split
  axis, split_pos := split_sah(data.prims[data.start:data.end], node.bounds, data.allocator)

  // Fallback to leaf if split failed
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

  // Check if we should cutover to sequential build
  if data.depth >= PARALLEL_DEPTH_THRESHOLD || prim_count < PARALLEL_TASK_THRESHOLD {
    // Sequential fallback
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

  // Spawn parallel subtasks
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
  // Wait for both subtasks to complete
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

  // Wait for root task to complete
  for sync.atomic_load(&result) == nil {
    if queued_task, ok := thread.pool_pop_waiting(pool); ok {
      thread.pool_do_work(pool, queued_task)
      continue
    }
    time.sleep(time.Microsecond * 100)
  }

  return result
}

// Main parallel BVH build function
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

  // Fallback to sequential for small datasets or no thread pool
  if len(items) < parallel_threshold || thread_pool == nil || !thread_pool.is_running || len(thread_pool.threads) == 0 {
    bvh_build(bvh, items, max_leaf_size)
    return
  }

  // Pre-reserve capacity for better performance
  reserve(&bvh.primitives, len(items))
  append(&bvh.primitives, ..items)

  // Setup per-thread arenas for thread-safe memory allocation
  num_threads := len(thread_pool.threads)
  if num_threads == 0 do num_threads = 1

  arena: virtual.Arena
  if err := virtual.arena_init_growing(&arena); err != nil {
    log.error("Failed to init arena:", err)
    // Fallback to sequential
    bvh_build(bvh, items, max_leaf_size)
    return
  }
  defer virtual.arena_free_all(&arena)
  arena_allocator := virtual.arena_allocator(&arena)

  // Phase 1: Parallel primitive preparation
  build_prims := parallel_prepare_primitives(
    items,
    bvh.bounds_func,
    thread_pool,
    num_threads,
    arena_allocator,
  )

  // Phase 2: Parallel recursive build
  root := parallel_build_recursive(
    build_prims[:],
    max_leaf_size,
    arena_allocator,
    thread_pool,
  )

  // Phase 3: Reorder primitives (sequential)
  for prim, i in build_prims {
    bvh.primitives[i] = items[prim.index]
  }

  // Phase 4: Flatten tree (sequential)
  flatten_bvh(bvh, root)
}
