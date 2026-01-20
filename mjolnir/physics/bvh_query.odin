package physics

import "../geometry"

// Maximum BVH depth for stack allocation (2^32 nodes would need 32 levels max)
BVH_MAX_STACK_DEPTH :: 64

// Optimized BVH query specifically for BroadPhaseEntry
// Avoids calling bounds_func since bounds are already stored in the entry
bvh_query_aabb_fast :: proc(
  bvh: ^geometry.BVH($T),
  query_bounds: geometry.Aabb,
  results: ^[dynamic]T,
) {
  if bvh == nil || results == nil do return
  clear(results)
  if len(bvh.nodes) == 0 do return

  // Fixed-size stack to avoid dynamic array append/pop overhead
  stack: [BVH_MAX_STACK_DEPTH]i32
  stack_size := 1
  stack[0] = 0

  nodes := bvh.nodes[:]
  primitives := bvh.primitives[:]

  #no_bounds_check for stack_size > 0 {
    stack_size -= 1
    node_idx := stack[stack_size]
    node := &nodes[node_idx]

    if !geometry.aabb_intersects(node.bounds, query_bounds) do continue

    if node.primitive_count <= 0 {
      // Internal node - push children
      stack[stack_size] = node.left_child
      stack[stack_size + 1] = node.right_child
      stack_size += 2
      continue
    }

    // Leaf node - check primitives
    prim_end := node.primitive_start + node.primitive_count
    for i in node.primitive_start ..< prim_end {
      prim := primitives[i]
      if geometry.aabb_intersects(prim.bounds, query_bounds) {
        append(results, prim)
      }
    }
  }
}

// Optimized BVH ray query specifically for BroadPhaseEntry
bvh_query_ray_fast :: proc(
  bvh: ^geometry.BVH($T),
  ray: geometry.Ray,
  max_dist: f32,
  results: ^[dynamic]T,
) {
  clear(results)
  if len(bvh.nodes) == 0 do return

  // Fixed-size stack to avoid dynamic array append/pop overhead
  stack: [BVH_MAX_STACK_DEPTH]i32
  stack_size := 1
  stack[0] = 0

  nodes := bvh.nodes[:]
  primitives := bvh.primitives[:]

  #no_bounds_check for stack_size > 0 {
    stack_size -= 1
    node_idx := stack[stack_size]
    node := &nodes[node_idx]

    t_near, t_far := geometry.ray_aabb_intersection(
      ray.origin,
      ray.direction,
      node.bounds,
    )
    if t_near > max_dist || t_far < 0 do continue

    if node.primitive_count <= 0 {
      // Internal node - push children
      stack[stack_size] = node.left_child
      stack[stack_size + 1] = node.right_child
      stack_size += 2
      continue
    }

    // Leaf node - check primitives
    prim_end := node.primitive_start + node.primitive_count
    for i in node.primitive_start ..< prim_end {
      prim := primitives[i]
      // Direct access to cached bounds - no function call!
      prim_t_near, prim_t_far := geometry.ray_aabb_intersection(
        ray.origin,
        ray.direction,
        prim.bounds,
      )
      if prim_t_near <= max_dist && prim_t_far >= 0 {
        append(results, prim)
      }
    }
  }
}
