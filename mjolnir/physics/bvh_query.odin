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
  reserve(results, len(bvh.primitives))
  stack: [BVH_MAX_STACK_DEPTH]i32
  stack_size := 1
  stack[0] = 0
  query_batch: [4]geometry.Aabb
  query_batch[0] = query_bounds
  query_batch[1] = query_bounds
  query_batch[2] = query_bounds
  query_batch[3] = query_bounds
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
    // SIMD batch path - process 4 primitives at once
    for i < batch_end {
      bounds_batch: [4]geometry.Aabb
      bounds_batch[0] = primitives[i + 0].bounds
      bounds_batch[1] = primitives[i + 1].bounds
      bounds_batch[2] = primitives[i + 2].bounds
      bounds_batch[3] = primitives[i + 3].bounds
      intersects := aabb_intersects_batch4(bounds_batch, query_batch)
      #unroll for j in 0 ..< 4 {
        if intersects[j] do append(results, primitives[i + i32(j)])
      }
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
  reserve(results, len(bvh.primitives))

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

// Pair of overlapping primitives
BVHOverlapPair :: struct($T: typeid) {
  a: T,
  b: T,
}

// Optimized self-collision detection for BroadPhaseEntry types
// Finds all overlapping pairs in O(N + K) time instead of O(N log N)
// Uses cached bounds to avoid function calls
bvh_find_all_overlaps_fast :: proc(
  bvh: ^geometry.BVH($T),
  results: ^[dynamic]BVHOverlapPair(T),
) {
  clear(results)
  if len(bvh.nodes) == 0 do return

  // Pre-allocate to avoid many small allocations
  reserve(results, len(bvh.primitives))

  nodes := bvh.nodes[:]
  primitives := bvh.primitives[:]

  // Start self-collision detection from root
  find_overlaps_recursive_fast(nodes, primitives, 0, 0, results)
}

@(private)
find_overlaps_recursive_fast :: proc(
  nodes: []geometry.BVHNode,
  primitives: []$T,
  node_a_idx: i32,
  node_b_idx: i32,
  results: ^[dynamic]BVHOverlapPair(T),
) {
  node_a := &nodes[node_a_idx]
  node_b := &nodes[node_b_idx]

  // Early out if bounds don't overlap
  if !geometry.aabb_intersects(node_a.bounds, node_b.bounds) do return

  a_is_leaf := node_a.primitive_count > 0
  b_is_leaf := node_b.primitive_count > 0

  // Both are leaf nodes - test all primitive pairs
  if a_is_leaf && b_is_leaf {
    prim_a_start := node_a.primitive_start
    prim_a_end := node_a.primitive_start + node_a.primitive_count
    prim_b_start := node_b.primitive_start
    prim_b_end := node_b.primitive_start + node_b.primitive_count

    #no_bounds_check for i in prim_a_start ..< prim_a_end {
      prim_a := primitives[i]
      bounds_a := prim_a.bounds // Direct access to cached bounds

      // Determine the starting index for the inner loop
      // If same node, start after current index to avoid duplicates
      j_start := prim_b_start if node_a_idx != node_b_idx else i + 1

      #no_bounds_check for j in j_start ..< prim_b_end {
        prim_b := primitives[j]
        bounds_b := prim_b.bounds // Direct access to cached bounds

        if geometry.aabb_intersects(bounds_a, bounds_b) {
          append(results, BVHOverlapPair(T){a = prim_a, b = prim_b})
        }
      }
    }
    return
  }

  // One or both are internal nodes - recurse on children
  if a_is_leaf {
    // Only split node_b
    find_overlaps_recursive_fast(nodes, primitives, node_a_idx, node_b.left_child, results)
    find_overlaps_recursive_fast(nodes, primitives, node_a_idx, node_b.right_child, results)
  } else if b_is_leaf {
    // Only split node_a
    find_overlaps_recursive_fast(nodes, primitives, node_a.left_child, node_b_idx, results)
    find_overlaps_recursive_fast(nodes, primitives, node_a.right_child, node_b_idx, results)
  } else {
    // Both are internal - split both and test all combinations
    // When testing the same node against itself, avoid redundant tests
    if node_a_idx == node_b_idx {
      // Self-test: only test unique combinations
      find_overlaps_recursive_fast(nodes, primitives, node_a.left_child, node_a.left_child, results)
      find_overlaps_recursive_fast(nodes, primitives, node_a.left_child, node_a.right_child, results)
      find_overlaps_recursive_fast(nodes, primitives, node_a.right_child, node_a.right_child, results)
    } else {
      // Different nodes: test all combinations
      find_overlaps_recursive_fast(nodes, primitives, node_a.left_child, node_b.left_child, results)
      find_overlaps_recursive_fast(nodes, primitives, node_a.left_child, node_b.right_child, results)
      find_overlaps_recursive_fast(nodes, primitives, node_a.right_child, node_b.left_child, results)
      find_overlaps_recursive_fast(nodes, primitives, node_a.right_child, node_b.right_child, results)
    }
  }
}

// Pair of overlapping primitives from two different BVHs
BVHCrossPair :: struct($T: typeid, $U: typeid) {
  a: T,
  b: U,
}

// Find all overlapping pairs between two different BVHs (tree-vs-tree)
// Useful for dynamic-static collision detection
bvh_find_cross_overlaps_fast :: proc(
  bvh_a: ^geometry.BVH($T),
  bvh_b: ^geometry.BVH($U),
  results: ^[dynamic]BVHCrossPair(T, U),
) {
  clear(results)
  if len(bvh_a.nodes) == 0 || len(bvh_b.nodes) == 0 do return

  nodes_a := bvh_a.nodes[:]
  nodes_b := bvh_b.nodes[:]
  primitives_a := bvh_a.primitives[:]
  primitives_b := bvh_b.primitives[:]

  find_cross_overlaps_recursive_fast(
    nodes_a,
    nodes_b,
    primitives_a,
    primitives_b,
    0,
    0,
    results,
  )
}

@(private)
find_cross_overlaps_recursive_fast :: proc(
  nodes_a: []geometry.BVHNode,
  nodes_b: []geometry.BVHNode,
  primitives_a: []$T,
  primitives_b: []$U,
  node_a_idx: i32,
  node_b_idx: i32,
  results: ^[dynamic]BVHCrossPair(T, U),
) {
  node_a := &nodes_a[node_a_idx]
  node_b := &nodes_b[node_b_idx]

  // Early out if bounds don't overlap
  if !geometry.aabb_intersects(node_a.bounds, node_b.bounds) do return

  a_is_leaf := node_a.primitive_count > 0
  b_is_leaf := node_b.primitive_count > 0

  // Both are leaf nodes - test all primitive pairs
  if a_is_leaf && b_is_leaf {
    prim_a_start := node_a.primitive_start
    prim_a_end := node_a.primitive_start + node_a.primitive_count
    prim_b_start := node_b.primitive_start
    prim_b_end := node_b.primitive_start + node_b.primitive_count

    #no_bounds_check for i in prim_a_start ..< prim_a_end {
      prim_a := primitives_a[i]
      bounds_a := prim_a.bounds

      #no_bounds_check for j in prim_b_start ..< prim_b_end {
        prim_b := primitives_b[j]
        bounds_b := prim_b.bounds

        if geometry.aabb_intersects(bounds_a, bounds_b) {
          append(results, BVHCrossPair(T, U){a = prim_a, b = prim_b})
        }
      }
    }
    return
  }

  // One or both are internal nodes - recurse on children
  if a_is_leaf {
    // Only split node_b
    find_cross_overlaps_recursive_fast(
      nodes_a,
      nodes_b,
      primitives_a,
      primitives_b,
      node_a_idx,
      node_b.left_child,
      results,
    )
    find_cross_overlaps_recursive_fast(
      nodes_a,
      nodes_b,
      primitives_a,
      primitives_b,
      node_a_idx,
      node_b.right_child,
      results,
    )
  } else if b_is_leaf {
    // Only split node_a
    find_cross_overlaps_recursive_fast(
      nodes_a,
      nodes_b,
      primitives_a,
      primitives_b,
      node_a.left_child,
      node_b_idx,
      results,
    )
    find_cross_overlaps_recursive_fast(
      nodes_a,
      nodes_b,
      primitives_a,
      primitives_b,
      node_a.right_child,
      node_b_idx,
      results,
    )
  } else {
    // Both are internal - test all child combinations
    find_cross_overlaps_recursive_fast(
      nodes_a,
      nodes_b,
      primitives_a,
      primitives_b,
      node_a.left_child,
      node_b.left_child,
      results,
    )
    find_cross_overlaps_recursive_fast(
      nodes_a,
      nodes_b,
      primitives_a,
      primitives_b,
      node_a.left_child,
      node_b.right_child,
      results,
    )
    find_cross_overlaps_recursive_fast(
      nodes_a,
      nodes_b,
      primitives_a,
      primitives_b,
      node_a.right_child,
      node_b.left_child,
      results,
    )
    find_cross_overlaps_recursive_fast(
      nodes_a,
      nodes_b,
      primitives_a,
      primitives_b,
      node_a.right_child,
      node_b.right_child,
      results,
    )
  }
}
