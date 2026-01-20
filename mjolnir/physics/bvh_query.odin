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
    // Leaf node - check primitives with SIMD batching
    prim_end := node.primitive_start + node.primitive_count
    prim_count := prim_end - node.primitive_start

    // Process in batches of 4 using SIMD
    i := node.primitive_start
    batch_end := node.primitive_start + (prim_count / 4) * 4

    // SIMD batch path - process 4 primitives at once (with runtime detection)
    for i < batch_end {
        // Load 4 primitive bounds
        bounds_batch: [4]geometry.Aabb
        bounds_batch[0] = primitives[i + 0].bounds
        bounds_batch[1] = primitives[i + 1].bounds
        bounds_batch[2] = primitives[i + 2].bounds
        bounds_batch[3] = primitives[i + 3].bounds

        // Batch query bounds for SIMD comparison
        query_batch: [4]geometry.Aabb
        query_batch[0] = query_bounds
        query_batch[1] = query_bounds
        query_batch[2] = query_bounds
        query_batch[3] = query_bounds

        // Test all 4 AABBs at once
        intersects := aabb_intersects_batch4(bounds_batch, query_batch)

        // Append matching primitives
        if intersects[0] do append(results, primitives[i + 0])
        if intersects[1] do append(results, primitives[i + 1])
        if intersects[2] do append(results, primitives[i + 2])
        if intersects[3] do append(results, primitives[i + 3])

        i += 4
      }

    // Handle remaining primitives (less than 4) with scalar path
    for i < prim_end {
      prim := primitives[i]
      if geometry.aabb_intersects(prim.bounds, query_bounds) {
        append(results, prim)
      }
      i += 1
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
