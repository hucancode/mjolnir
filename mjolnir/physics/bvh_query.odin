package physics

import "../geometry"

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
  stack := make([dynamic]i32, 0, 64, context.temp_allocator)
  append(&stack, 0)
  for len(stack) > 0 {
    node_idx := pop(&stack)
    node := &bvh.nodes[node_idx]
    if !geometry.aabb_intersects(node.bounds, query_bounds) do continue
    if node.primitive_count > 0 {
      for i in node.primitive_start ..< node.primitive_start + node.primitive_count {
        prim := bvh.primitives[i]
        // Direct access to cached bounds - no function call!
        if geometry.aabb_intersects(prim.bounds, query_bounds) {
          append(results, prim)
        }
      }
    } else {
      append(&stack, node.right_child, node.left_child)
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
  stack := make([dynamic]i32, 0, 64, context.temp_allocator)
  append(&stack, 0)
  for len(stack) > 0 {
    node_idx := pop(&stack)
    node := &bvh.nodes[node_idx]
    t_near, t_far := geometry.ray_aabb_intersection(
      ray.origin,
      ray.direction,
      node.bounds,
    )
    if t_near > max_dist || t_far < 0 do continue
    if node.primitive_count > 0 {
      for i in node.primitive_start ..< node.primitive_start + node.primitive_count {
        prim := bvh.primitives[i]
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
    } else {
      append(&stack, node.right_child, node.left_child)
    }
  }
}
