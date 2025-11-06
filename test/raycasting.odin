package tests

import "../mjolnir/geometry"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:slice"
import "core:testing"
import "core:time"

@(test)
test_ray_triangle_intersection :: proc(t: ^testing.T) {
  tri := geometry.Triangle {
    v0 = {0, 0, 0},
    v1 = {1, 0, 0},
    v2 = {0, 1, 0},
  }
  // Basic hit
  ray := geometry.Ray {
    origin    = {0.25, 0.25, 1},
    direction = {0, 0, -1},
  }
  hit, dist := geometry.ray_triangle_intersection(ray, tri)
  testing.expect(t, hit, "Ray should hit triangle")
  testing.expect_value(t, dist, 1.0)
  // Basic miss
  ray2 := geometry.Ray {
    origin    = {2, 2, 1},
    direction = {0, 0, -1},
  }
  hit2, _ := geometry.ray_triangle_intersection(ray2, tri)
  testing.expect(t, !hit2, "Ray should miss triangle")
  // Edge cases
  // Parallel ray
  ray_parallel := geometry.Ray {
    origin    = {0, 0, 1},
    direction = {1, 0, 0},
  }
  hit3, _ := geometry.ray_triangle_intersection(ray_parallel, tri)
  testing.expect(t, !hit3, "Parallel ray should miss triangle")
  // Ray hitting edge
  ray_edge := geometry.Ray {
    origin    = {0.5, 0, 1},
    direction = {0, 0, -1},
  }
  hit4, dist4 := geometry.ray_triangle_intersection(ray_edge, tri)
  testing.expect(t, hit4, "Ray should hit triangle edge")
  testing.expect_value(t, dist4, 1.0)
  // Ray hitting vertex
  ray_vertex := geometry.Ray {
    origin    = {0, 0, 1},
    direction = {0, 0, -1},
  }
  hit5, dist5 := geometry.ray_triangle_intersection(ray_vertex, tri)
  testing.expect(t, hit5, "Ray should hit triangle vertex")
  testing.expect_value(t, dist5, 1.0)
  // Ray behind triangle
  ray_behind := geometry.Ray {
    origin    = {0.25, 0.25, -1},
    direction = {0, 0, -1},
  }
  hit6, _ := geometry.ray_triangle_intersection(ray_behind, tri)
  testing.expect(t, !hit6, "Ray pointing away should miss")
}

@(test)
test_ray_sphere_intersection :: proc(t: ^testing.T) {
  sphere := geometry.Sphere {
    center = {0, 0, 0},
    radius = 1,
  }
  // Basic hit
  ray := geometry.Ray {
    origin    = {0, 0, 5},
    direction = {0, 0, -1},
  }
  hit, dist := geometry.ray_sphere_intersection(ray, sphere)
  testing.expect(t, hit, "Ray should hit sphere")
  testing.expect_value(t, dist, 4.0)
  // Basic miss
  ray2 := geometry.Ray {
    origin    = {2, 0, 5},
    direction = {0, 0, -1},
  }
  hit2, _ := geometry.ray_sphere_intersection(ray2, sphere)
  testing.expect(t, !hit2, "Ray should miss sphere")
  // Edge cases
  // Tangent ray
  ray_tangent := geometry.Ray {
    origin    = {1, 0, 5},
    direction = {0, 0, -1},
  }
  hit3, dist3 := geometry.ray_sphere_intersection(ray_tangent, sphere)
  testing.expect(t, hit3, "Tangent ray should hit sphere")
  testing.expect_value(t, dist3, 5.0)
  // Ray starting inside
  ray_inside := geometry.Ray {
    origin    = {0, 0, 0},
    direction = {1, 0, 0},
  }
  hit4, dist4 := geometry.ray_sphere_intersection(ray_inside, sphere)
  testing.expect(t, hit4, "Ray from inside should hit")
  testing.expect_value(t, dist4, 1.0)
  // Very small sphere
  tiny_sphere := geometry.Sphere {
    center = {0, 0, 0},
    radius = 0.001,
  }
  ray_tiny := geometry.Ray {
    origin    = {0, 0, 1},
    direction = {0, 0, -1},
  }
  hit5, _ := geometry.ray_sphere_intersection(ray_tiny, tiny_sphere)
  testing.expect(t, hit5, "Should hit tiny sphere")
}

@(test)
test_sphere_sphere_intersection :: proc(t: ^testing.T) {
  // Basic cases
  s1 := geometry.Sphere {
    center = {0, 0, 0},
    radius = 1,
  }
  s2 := geometry.Sphere {
    center = {1.5, 0, 0},
    radius = 1,
  }
  s3 := geometry.Sphere {
    center = {3, 0, 0},
    radius = 1,
  }
  testing.expect(
    t,
    geometry.sphere_sphere_intersection(s1, s2),
    "Spheres should intersect",
  )
  testing.expect(
    t,
    !geometry.sphere_sphere_intersection(s1, s3),
    "Spheres should not intersect",
  )
  // Edge cases
  // Identical spheres
  testing.expect(
    t,
    geometry.sphere_sphere_intersection(s1, s1),
    "Identical spheres should intersect",
  )
  // Touching spheres
  s4 := geometry.Sphere {
    center = {2, 0, 0},
    radius = 1,
  }
  testing.expect(
    t,
    geometry.sphere_sphere_intersection(s1, s4),
    "Touching spheres should intersect",
  )
  // One inside another
  s5 := geometry.Sphere {
    center = {0, 0, 0},
    radius = 2,
  }
  s6 := geometry.Sphere {
    center = {0.5, 0, 0},
    radius = 0.5,
  }
  testing.expect(
    t,
    geometry.sphere_sphere_intersection(s5, s6),
    "Nested spheres should intersect",
  )
}

@(test)
test_sphere_triangle_intersection :: proc(t: ^testing.T) {
  tri := geometry.Triangle {
    v0 = {0, 0, 0},
    v1 = {2, 0, 0},
    v2 = {0, 2, 0},
  }
  // Basic cases
  s1 := geometry.Sphere {
    center = {0.5, 0.5, 0},
    radius = 0.4,
  }
  s2 := geometry.Sphere {
    center = {5, 5, 0},
    radius = 0.4,
  }
  testing.expect(
    t,
    geometry.sphere_triangle_intersection(s1, tri),
    "Sphere should intersect triangle",
  )
  testing.expect(
    t,
    !geometry.sphere_triangle_intersection(s2, tri),
    "Sphere should not intersect triangle",
  )
  // Edge cases
  // Touching vertex
  s3 := geometry.Sphere {
    center = {-0.5, -0.5, 0},
    radius = 0.71,
  }
  testing.expect(
    t,
    geometry.sphere_triangle_intersection(s3, tri),
    "Sphere should touch vertex",
  )
  // Touching edge
  s4 := geometry.Sphere {
    center = {1, -0.5, 0},
    radius = 0.5,
  }
  testing.expect(
    t,
    geometry.sphere_triangle_intersection(s4, tri),
    "Sphere should touch edge",
  )
  // Centered on triangle
  s5 := geometry.Sphere {
    center = {0.5, 0.5, 0},
    radius = 0.1,
  }
  testing.expect(
    t,
    geometry.sphere_triangle_intersection(s5, tri),
    "Sphere on triangle should intersect",
  )
  // Passing through plane but not touching
  s6 := geometry.Sphere {
    center = {3, 3, 0},
    radius = 0.5,
  }
  testing.expect(
    t,
    !geometry.sphere_triangle_intersection(s6, tri),
    "Sphere should not touch triangle",
  )
}

@(test)
test_bvh_basic_raycasting :: proc(t: ^testing.T) {
  primitives: [dynamic]geometry.Primitive
  append(
    &primitives,
    geometry.Primitive {
      type = .Triangle,
      data = geometry.Triangle{v0 = {0, 0, 0}, v1 = {1, 0, 0}, v2 = {0, 1, 0}},
    },
  )
  append(
    &primitives,
    geometry.Primitive {
      type = .Sphere,
      data = geometry.Sphere{center = {3, 0, 0}, radius = 1},
    },
  )
  append(
    &primitives,
    geometry.Primitive {
      type = .Triangle,
      data = geometry.Triangle{v0 = {5, 0, 0}, v1 = {6, 0, 0}, v2 = {5, 1, 0}},
    },
  )
  bvh: geometry.BVH(geometry.Primitive)
  bvh.bounds_func = geometry.primitive_bounds
  geometry.bvh_build(&bvh, primitives[:])
  ray := geometry.Ray {
    origin    = {0.25, 0.25, 1},
    direction = {0, 0, -1},
  }
  hit := geometry.bvh_raycast(
    &bvh,
    ray,
    100.0,
    geometry.ray_primitive_intersection,
  )
  testing.expect(t, hit.hit, "Ray should hit something in BVH")
  testing.expect_value(t, hit.t, 1.0)
  ray2 := geometry.Ray {
    origin    = {3, 0, 5},
    direction = {0, 0, -1},
  }
  hit2 := geometry.bvh_raycast(
    &bvh,
    ray2,
    100.0,
    geometry.ray_primitive_intersection,
  )
  testing.expect(t, hit2.hit, "Ray should hit sphere in BVH")
  testing.expect_value(t, hit2.t, 4.0)
  geometry.bvh_destroy(&bvh)
  delete(primitives)
}

@(test)
test_bvh_single_vs_multi_raycast :: proc(t: ^testing.T) {
  primitives: [dynamic]geometry.Primitive
  // Create overlapping shapes along a ray path
  append(
    &primitives,
    geometry.Primitive {
      type = .Triangle,
      data = geometry.Triangle{v0 = {0, 0, 1}, v1 = {1, 0, 1}, v2 = {0, 1, 1}},
    },
  )
  append(
    &primitives,
    geometry.Primitive {
      type = .Sphere,
      data = geometry.Sphere{center = {0.5, 0.5, 3}, radius = 0.5},
    },
  )
  append(
    &primitives,
    geometry.Primitive {
      type = .Triangle,
      data = geometry.Triangle{v0 = {0, 0, 5}, v1 = {1, 0, 5}, v2 = {0, 1, 5}},
    },
  )
  bvh: geometry.BVH(geometry.Primitive)
  bvh.bounds_func = geometry.primitive_bounds
  geometry.bvh_build(&bvh, primitives[:])
  ray := geometry.Ray {
    origin    = {0.25, 0.25, 0},
    direction = {0, 0, 1},
  }
  // Test single raycast - should only return the first hit
  single_hit := geometry.bvh_raycast_single(
    &bvh,
    ray,
    100.0,
    geometry.ray_primitive_intersection,
  )
  testing.expect(t, single_hit.hit, "Single raycast should hit")
  testing.expect_value(t, single_hit.t, 1.0) // First triangle at z=1
  // Test multi raycast - should return all hits
  multi_hits: [dynamic]geometry.RayHit(geometry.Primitive)
  geometry.bvh_raycast_multi(
    &bvh,
    ray,
    100.0,
    geometry.ray_primitive_intersection,
    &multi_hits,
  )
  testing.expect_value(t, len(multi_hits), 3) // Should hit all 3 objects
  testing.expect_value(t, multi_hits[0].t, 1.0) // First triangle
  testing.expect(
    t,
    multi_hits[1].t > 2.0 && multi_hits[1].t < 3.0,
    "Sphere hit should be between 2 and 3",
  )
  testing.expect_value(t, multi_hits[2].t, 5.0) // Second triangle
  // Verify single matches first multi
  testing.expect_value(t, single_hit.t, multi_hits[0].t)
  geometry.bvh_destroy(&bvh)
  delete(primitives)
  delete(multi_hits)
}

@(test)
test_bvh_max_distance :: proc(t: ^testing.T) {
  primitives: [dynamic]geometry.Primitive
  // Triangle at distance 5
  append(
    &primitives,
    geometry.Primitive {
      type = .Triangle,
      data = geometry.Triangle{v0 = {0, 0, 5}, v1 = {1, 0, 5}, v2 = {0, 1, 5}},
    },
  )
  // Sphere at distance 10
  append(
    &primitives,
    geometry.Primitive {
      type = .Sphere,
      data = geometry.Sphere{center = {0.5, 0.5, 10}, radius = 0.5},
    },
  )
  bvh: geometry.BVH(geometry.Primitive)
  bvh.bounds_func = geometry.primitive_bounds
  geometry.bvh_build(&bvh, primitives[:])
  ray := geometry.Ray {
    origin    = {0.25, 0.25, 0},
    direction = {0, 0, 1},
  }
  // Test with max distance that excludes sphere
  hit_limited := geometry.bvh_raycast_single(
    &bvh,
    ray,
    7.0,
    geometry.ray_primitive_intersection,
  )
  testing.expect(t, hit_limited.hit, "Should hit triangle within range")
  testing.expect_value(t, hit_limited.t, 5.0)
  // Test multi raycast with limited distance
  multi_hits: [dynamic]geometry.RayHit(geometry.Primitive)
  geometry.bvh_raycast_multi(
    &bvh,
    ray,
    7.0,
    geometry.ray_primitive_intersection,
    &multi_hits,
  )
  testing.expect_value(t, len(multi_hits), 1)
  // Test with unlimited distance
  clear(&multi_hits)
  geometry.bvh_raycast_multi(
    &bvh,
    ray,
    100.0,
    geometry.ray_primitive_intersection,
    &multi_hits,
  )
  testing.expect_value(t, len(multi_hits), 2)
  geometry.bvh_destroy(&bvh)
  delete(primitives)
  delete(multi_hits)
}

@(test)
test_bvh_sphere_query :: proc(t: ^testing.T) {
  primitives: [dynamic]geometry.Primitive
  append(
    &primitives,
    geometry.Primitive {
      type = .Triangle,
      data = geometry.Triangle{v0 = {0, 0, 0}, v1 = {1, 0, 0}, v2 = {0, 1, 0}},
    },
  )
  append(
    &primitives,
    geometry.Primitive {
      type = .Sphere,
      data = geometry.Sphere{center = {3, 0, 0}, radius = 0.5},
    },
  )
  bvh: geometry.BVH(geometry.Primitive)
  bvh.bounds_func = geometry.primitive_bounds
  geometry.bvh_build(&bvh, primitives[:])
  query_sphere := geometry.Sphere {
    center = {0.5, 0.5, 0},
    radius = 0.6,
  }
  results: [dynamic]geometry.Primitive
  geometry.bvh_query_sphere_primitives(
    &bvh,
    query_sphere,
    &results,
    geometry.sphere_primitive_intersection,
  )
  testing.expect_value(t, len(results), 1)
  query_sphere2 := geometry.Sphere {
    center = {3, 0, 0},
    radius = 0.6,
  }
  clear(&results)
  geometry.bvh_query_sphere_primitives(
    &bvh,
    query_sphere2,
    &results,
    geometry.sphere_primitive_intersection,
  )
  testing.expect_value(t, len(results), 1)
  geometry.bvh_destroy(&bvh)
  delete(primitives)
  delete(results)
}

@(test)
test_bvh_aabb_query :: proc(t: ^testing.T) {
  primitives: [dynamic]geometry.Primitive
  // Triangle fully inside query AABB
  append(
    &primitives,
    geometry.Primitive {
      type = .Triangle,
      data = geometry.Triangle{v0 = {1, 1, 1}, v1 = {2, 1, 1}, v2 = {1, 2, 1}},
    },
  )
  // Sphere partially overlapping
  append(
    &primitives,
    geometry.Primitive {
      type = .Sphere,
      data = geometry.Sphere{center = {3, 0, 0}, radius = 1.5},
    },
  )
  // Triangle outside query
  append(
    &primitives,
    geometry.Primitive {
      type = .Triangle,
      data = geometry.Triangle {
        v0 = {10, 10, 10},
        v1 = {11, 10, 10},
        v2 = {10, 11, 10},
      },
    },
  )
  bvh: geometry.BVH(geometry.Primitive)
  bvh.bounds_func = geometry.primitive_bounds
  geometry.bvh_build(&bvh, primitives[:])
  // Query that should find first two primitives
  query_aabb := geometry.Aabb {
    min = {0, 0, 0},
    max = {3, 3, 3},
  }
  results: [dynamic]geometry.Primitive
  geometry.bvh_query_aabb(&bvh, query_aabb, &results)
  testing.expect_value(t, len(results), 2)
  // Small query that finds nothing
  small_query := geometry.Aabb {
    min = {5, 5, 5},
    max = {6, 6, 6},
  }
  clear(&results)
  geometry.bvh_query_aabb(&bvh, small_query, &results)
  testing.expect_value(t, len(results), 0)
  geometry.bvh_destroy(&bvh)
  delete(primitives)
  delete(results)
}

@(test)
test_bvh_empty :: proc(t: ^testing.T) {
  empty_bvh: geometry.BVH(geometry.Primitive)
  empty_bvh.bounds_func = geometry.primitive_bounds
  geometry.bvh_build(&empty_bvh, []geometry.Primitive{})
  ray := geometry.Ray {
    origin    = {0, 0, 0},
    direction = {0, 0, 1},
  }
  hit := geometry.bvh_raycast_single(
    &empty_bvh,
    ray,
    100.0,
    geometry.ray_primitive_intersection,
  )
  testing.expect(t, !hit.hit, "Empty BVH should return no hit")
  multi_hits: [dynamic]geometry.RayHit(geometry.Primitive)
  geometry.bvh_raycast_multi(
    &empty_bvh,
    ray,
    100.0,
    geometry.ray_primitive_intersection,
    &multi_hits,
  )
  testing.expect_value(t, len(multi_hits), 0)
  geometry.bvh_destroy(&empty_bvh)
  delete(multi_hits)
}

@(test)
test_octree_basic_raycasting :: proc(t: ^testing.T) {
  primitives: [dynamic]geometry.Primitive
  append(
    &primitives,
    geometry.Primitive {
      type = .Triangle,
      data = geometry.Triangle{v0 = {0, 0, 0}, v1 = {1, 0, 0}, v2 = {0, 1, 0}},
    },
  )
  append(
    &primitives,
    geometry.Primitive {
      type = .Sphere,
      data = geometry.Sphere{center = {3, 0, 0}, radius = 1},
    },
  )
  octree: geometry.Octree(geometry.Primitive)
  octree.bounds_func = geometry.primitive_bounds
  octree.point_func = proc(p: geometry.Primitive) -> [3]f32 {
    switch prim in p.data {
    case geometry.Triangle:
      return (prim.v0 + prim.v1 + prim.v2) / 3.0
    case geometry.Sphere:
      return prim.center
    }
    return {}
  }
  bounds := geometry.Aabb {
    min = {-10, -10, -10},
    max = {10, 10, 10},
  }
  geometry.octree_init(&octree, bounds, 6, 4)
  for prim in primitives {
    geometry.octree_insert(&octree, prim)
  }
  ray := geometry.Ray {
    origin    = {0.25, 0.25, 1},
    direction = {0, 0, -1},
  }
  hit := geometry.octree_raycast(
    &octree,
    ray,
    100.0,
    geometry.ray_primitive_intersection,
  )
  testing.expect(t, hit.hit, "Ray should hit something in octree")
  testing.expect_value(t, hit.t, 1.0)
  ray2 := geometry.Ray {
    origin    = {3, 0, 5},
    direction = {0, 0, -1},
  }
  hit2 := geometry.octree_raycast(
    &octree,
    ray2,
    100.0,
    geometry.ray_primitive_intersection,
  )
  testing.expect(t, hit2.hit, "Ray should hit sphere in octree")
  testing.expect_value(t, hit2.t, 4.0)
  geometry.octree_destroy(&octree)
  delete(primitives)
}

@(test)
test_octree_single_vs_multi_raycast :: proc(t: ^testing.T) {
  primitives: [dynamic]geometry.Primitive
  // Create overlapping shapes along a ray path
  append(
    &primitives,
    geometry.Primitive {
      type = .Triangle,
      data = geometry.Triangle{v0 = {0, 0, 1}, v1 = {1, 0, 1}, v2 = {0, 1, 1}},
    },
  )
  append(
    &primitives,
    geometry.Primitive {
      type = .Sphere,
      data = geometry.Sphere{center = {0.5, 0.5, 3}, radius = 0.5},
    },
  )
  append(
    &primitives,
    geometry.Primitive {
      type = .Triangle,
      data = geometry.Triangle{v0 = {0, 0, 5}, v1 = {1, 0, 5}, v2 = {0, 1, 5}},
    },
  )
  octree: geometry.Octree(geometry.Primitive)
  octree.bounds_func = geometry.primitive_bounds
  octree.point_func = proc(p: geometry.Primitive) -> [3]f32 {
    switch prim in p.data {
    case geometry.Triangle:
      return (prim.v0 + prim.v1 + prim.v2) / 3.0
    case geometry.Sphere:
      return prim.center
    }
    return {}
  }
  bounds := geometry.Aabb {
    min = {-10, -10, -10},
    max = {10, 10, 10},
  }
  geometry.octree_init(&octree, bounds, 6, 4)
  for prim in primitives {
    geometry.octree_insert(&octree, prim)
  }
  ray := geometry.Ray {
    origin    = {0.25, 0.25, 0},
    direction = {0, 0, 1},
  }
  // Test single raycast - should only return the first hit
  single_hit := geometry.octree_raycast_single(
    &octree,
    ray,
    100.0,
    geometry.ray_primitive_intersection,
  )
  testing.expect(t, single_hit.hit, "Single raycast should hit")
  testing.expect_value(t, single_hit.t, 1.0) // First triangle at z=1
  // Test multi raycast - should return all hits
  multi_hits: [dynamic]geometry.RayHit(geometry.Primitive)
  geometry.octree_raycast_multi(
    &octree,
    ray,
    100.0,
    geometry.ray_primitive_intersection,
    &multi_hits,
  )
  testing.expect_value(t, len(multi_hits), 3) // Should hit all 3 objects
  testing.expect_value(t, multi_hits[0].t, 1.0) // First triangle
  testing.expect(
    t,
    multi_hits[1].t > 2.0 && multi_hits[1].t < 3.0,
    "Sphere hit should be between 2 and 3",
  )
  testing.expect_value(t, multi_hits[2].t, 5.0) // Second triangle
  geometry.octree_destroy(&octree)
  delete(primitives)
  delete(multi_hits)
}

@(test)
test_octree_sphere_query :: proc(t: ^testing.T) {
  primitives: [dynamic]geometry.Primitive
  append(
    &primitives,
    geometry.Primitive {
      type = .Triangle,
      data = geometry.Triangle{v0 = {0, 0, 0}, v1 = {1, 0, 0}, v2 = {0, 1, 0}},
    },
  )
  append(
    &primitives,
    geometry.Primitive {
      type = .Sphere,
      data = geometry.Sphere{center = {3, 0, 0}, radius = 0.5},
    },
  )
  octree: geometry.Octree(geometry.Primitive)
  octree.bounds_func = geometry.primitive_bounds
  octree.point_func = proc(p: geometry.Primitive) -> [3]f32 {
    switch prim in p.data {
    case geometry.Triangle:
      return (prim.v0 + prim.v1 + prim.v2) / 3.0
    case geometry.Sphere:
      return prim.center
    }
    return {}
  }
  bounds := geometry.Aabb {
    min = {-10, -10, -10},
    max = {10, 10, 10},
  }
  geometry.octree_init(&octree, bounds, 6, 4)
  for prim in primitives {
    geometry.octree_insert(&octree, prim)
  }
  query_sphere := geometry.Sphere {
    center = {0.5, 0.5, 0},
    radius = 0.6,
  }
  results: [dynamic]geometry.Primitive
  geometry.octree_query_sphere_primitives(
    &octree,
    query_sphere,
    &results,
    geometry.sphere_primitive_intersection,
  )
  testing.expect_value(t, len(results), 1)
  query_sphere2 := geometry.Sphere {
    center = {3, 0, 0},
    radius = 0.6,
  }
  clear(&results)
  geometry.octree_query_sphere_primitives(
    &octree,
    query_sphere2,
    &results,
    geometry.sphere_primitive_intersection,
  )
  testing.expect_value(t, len(results), 1)
  geometry.octree_destroy(&octree)
  delete(primitives)
  delete(results)
}

@(test)
test_octree_subdivision_with_raycast :: proc(t: ^testing.T) {
  primitives: [dynamic]geometry.Primitive
  // Create clustered primitives to force subdivision
  for i in 0 ..< 10 {
    fi := f32(i) * 0.1
    append(
      &primitives,
      geometry.Primitive {
        type = .Sphere,
        data = geometry.Sphere{center = {fi, fi, fi}, radius = 0.05},
      },
    )
  }
  octree: geometry.Octree(geometry.Primitive)
  octree.bounds_func = geometry.primitive_bounds
  octree.point_func = proc(p: geometry.Primitive) -> [3]f32 {
    switch prim in p.data {
    case geometry.Triangle:
      return (prim.v0 + prim.v1 + prim.v2) / 3.0
    case geometry.Sphere:
      return prim.center
    }
    return {}
  }
  bounds := geometry.Aabb {
    min = {-5, -5, -5},
    max = {5, 5, 5},
  }
  geometry.octree_init(&octree, bounds, 8, 2) // Low max_items to force subdivision
  for prim in primitives {
    geometry.octree_insert(&octree, prim)
  }
  stats := geometry.octree_get_stats(&octree)
  testing.expect(
    t,
    stats.total_nodes > 1,
    "Octree should subdivide with clustered items",
  )
  testing.expect(t, stats.max_depth > 0, "Octree should have depth > 0")
  // Test ray through cluster
  ray := geometry.Ray {
    origin    = {-1, -1, -1},
    direction = linalg.normalize([3]f32{1, 1, 1}),
  }
  multi_hits: [dynamic]geometry.RayHit(geometry.Primitive)
  geometry.octree_raycast_multi(
    &octree,
    ray,
    10.0,
    geometry.ray_primitive_intersection,
    &multi_hits,
  )
  testing.expect(t, len(multi_hits) > 0, "Should hit some spheres in cluster")
  geometry.octree_destroy(&octree)
  delete(primitives)
  delete(multi_hits)
}

@(test)
test_octree_empty :: proc(t: ^testing.T) {
  empty_octree: geometry.Octree(geometry.Primitive)
  empty_octree.bounds_func = geometry.primitive_bounds
  empty_octree.point_func = proc(p: geometry.Primitive) -> [3]f32 {
    switch prim in p.data {
    case geometry.Triangle:
      return (prim.v0 + prim.v1 + prim.v2) / 3.0
    case geometry.Sphere:
      return prim.center
    }
    return {}
  }
  bounds := geometry.Aabb {
    min = {-10, -10, -10},
    max = {10, 10, 10},
  }
  geometry.octree_init(&empty_octree, bounds, 6, 4)
  ray := geometry.Ray {
    origin    = {0, 0, 0},
    direction = {0, 0, 1},
  }
  oct_hit := geometry.octree_raycast_single(
    &empty_octree,
    ray,
    100.0,
    geometry.ray_primitive_intersection,
  )
  testing.expect(t, !oct_hit.hit, "Empty Octree should return no hit")
  geometry.octree_destroy(&empty_octree)
}

@(test)
test_large_scene_raycasting :: proc(t: ^testing.T) {
  primitives: [dynamic]geometry.Primitive
  // Create a grid of triangles
  grid_size := 10
  for x in 0 ..< grid_size {
    for z in 0 ..< grid_size {
      fx := f32(x)
      fz := f32(z)
      append(
        &primitives,
        geometry.Primitive {
          type = .Triangle,
          data = geometry.Triangle {
            v0 = {fx, 0, fz},
            v1 = {fx + 0.8, 0, fz},
            v2 = {fx, 0, fz + 0.8},
          },
        },
      )
    }
  }
  // Add some spheres
  for i in 0 ..< 20 {
    fi := f32(i)
    append(
      &primitives,
      geometry.Primitive {
        type = .Sphere,
        data = geometry.Sphere{center = {fi * 0.5, 1, fi * 0.5}, radius = 0.3},
      },
    )
  }
  bvh: geometry.BVH(geometry.Primitive)
  bvh.bounds_func = geometry.primitive_bounds
  geometry.bvh_build(&bvh, primitives[:])
  // Test multiple rays
  num_hits := 0
  for i in 0 ..< 10 {
    ray := geometry.Ray {
      origin    = {f32(i), 5, f32(i)},
      direction = {0, -1, 0},
    }
    hit := geometry.bvh_raycast_single(
      &bvh,
      ray,
      100.0,
      geometry.ray_primitive_intersection,
    )
    if hit.hit do num_hits += 1
  }
  testing.expect(t, num_hits > 0, "Should have some hits in large scene")
  // Verify BVH stats
  stats := geometry.bvh_get_stats(&bvh)
  testing.expect(
    t,
    stats.total_primitives == i32(len(primitives)),
    "BVH should contain all primitives",
  )
  testing.expect(
    t,
    stats.internal_nodes > 0,
    "BVH should have internal nodes for large scene",
  )
  geometry.bvh_destroy(&bvh)
  delete(primitives)
}

@(test)
benchmark_bvh_ray_single :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 60 * time.Second)
  setup_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    state := new(BVH_Ray_Single_State)
    // Generate 100k random primitives
    bounds := geometry.Aabb {
      min = {-100, -100, -100},
      max = {100, 100, 100},
    }
    state.primitives = generate_random_primitives(100_000, bounds)
    // Build BVH
    state.bvh.bounds_func = geometry.primitive_bounds
    geometry.bvh_build(&state.bvh, state.primitives)
    // Generate random rays
    state.rays = generate_random_rays(100_000, bounds)
    state.current_ray = 0
    options.input = slice.bytes_from_ptr(state, size_of(BVH_Ray_Single_State))
    options.bytes =
      size_of(geometry.Ray) + size_of(geometry.RayHit(geometry.Primitive))
    return nil
  }
  bench_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    state := cast(^BVH_Ray_Single_State)raw_data(options.input)
    for _ in 0 ..< options.rounds {
      // Get next ray (cycle through)
      ray := state.rays[state.current_ray]
      state.current_ray = (state.current_ray + 1) % len(state.rays)
      hit := geometry.bvh_raycast_single(
        &state.bvh,
        ray,
        1000.0,
        geometry.ray_primitive_intersection,
      )
      if hit.hit {
        state.hit_count += 1
      }
      options.processed += size_of(geometry.Ray)
    }
    return nil
  }
  teardown_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    state := cast(^BVH_Ray_Single_State)raw_data(options.input)
    geometry.bvh_destroy(&state.bvh)
    delete(state.primitives)
    delete(state.rays)
    free(state)
    return nil
  }
  options := &time.Benchmark_Options {
    setup = setup_proc,
    bench = bench_proc,
    teardown = teardown_proc,
    rounds = 1000,
  }
  err := time.benchmark(options)
  state := cast(^BVH_Ray_Single_State)raw_data(options.input)
  hit_rate := f32(state.hit_count) / f32(options.rounds) * 100
  log.infof(
    "BVH ray single: %d queries in %v (%.2f MB/s) | %.2f μs/query | %d hits (%.1f%%)",
    options.rounds,
    options.duration,
    options.megabytes_per_second,
    time.duration_microseconds(options.duration) / f64(options.rounds),
    state.hit_count,
    hit_rate,
  )
}

BVH_Ray_Single_State :: struct {
  bvh:         geometry.BVH(geometry.Primitive),
  primitives:  []geometry.Primitive,
  rays:        []geometry.Ray,
  current_ray: int,
  hit_count:   int,
}

@(test)
benchmark_bvh_ray_multi :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 60 * time.Second)
  setup_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    state := new(BVH_Ray_Multi_State)
    bounds := geometry.Aabb {
      min = {-100, -100, -100},
      max = {100, 100, 100},
    }
    state.primitives = generate_random_primitives(100_000, bounds)
    state.bvh.bounds_func = geometry.primitive_bounds
    geometry.bvh_build(&state.bvh, state.primitives)
    state.rays = generate_random_rays(100_000, bounds)
    state.current_ray = 0
    state.multi_hits = make([dynamic]geometry.RayHit(geometry.Primitive))
    options.input = slice.bytes_from_ptr(state, size_of(BVH_Ray_Multi_State))
    options.bytes =
      size_of(geometry.Ray) +
      size_of([dynamic]geometry.RayHit(geometry.Primitive))
    return nil
  }
  bench_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    state := cast(^BVH_Ray_Multi_State)raw_data(options.input)
    for _ in 0 ..< options.rounds {
      ray := state.rays[state.current_ray]
      state.current_ray = (state.current_ray + 1) % len(state.rays)
      geometry.bvh_raycast_multi(
        &state.bvh,
        ray,
        1000.0,
        geometry.ray_primitive_intersection,
        &state.multi_hits,
      )
      state.total_hits += len(state.multi_hits)
      if len(state.multi_hits) > state.max_hits {
        state.max_hits = len(state.multi_hits)
      }
      clear(&state.multi_hits)
      options.processed +=
        size_of(geometry.Ray) +
        len(state.multi_hits) * size_of(geometry.RayHit(geometry.Primitive))
    }
    return nil
  }
  teardown_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    state := cast(^BVH_Ray_Multi_State)raw_data(options.input)
    geometry.bvh_destroy(&state.bvh)
    delete(state.primitives)
    delete(state.rays)
    delete(state.multi_hits)
    free(state)
    return nil
  }
  options := &time.Benchmark_Options {
    setup = setup_proc,
    bench = bench_proc,
    teardown = teardown_proc,
    rounds = 1000,
  }
  err := time.benchmark(options)
  state := cast(^BVH_Ray_Multi_State)raw_data(options.input)
  avg_hits := f32(state.total_hits) / f32(options.rounds)
  log.infof(
    "BVH ray multi: %d queries in %v (%.2f MB/s) | %.2f μs/query | %.2f avg hits | %d max hits",
    options.rounds,
    options.duration,
    options.megabytes_per_second,
    time.duration_microseconds(options.duration) / f64(options.rounds),
    avg_hits,
    state.max_hits,
  )
}

BVH_Ray_Multi_State :: struct {
  bvh:         geometry.BVH(geometry.Primitive),
  primitives:  []geometry.Primitive,
  rays:        []geometry.Ray,
  current_ray: int,
  multi_hits:  [dynamic]geometry.RayHit(geometry.Primitive),
  total_hits:  int,
  max_hits:    int,
}

@(test)
benchmark_bvh_sphere :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 60 * time.Second)
  setup_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    state := new(BVH_Sphere_State)
    bounds := geometry.Aabb {
      min = {-100, -100, -100},
      max = {100, 100, 100},
    }
    state.primitives = generate_random_primitives(100_000, bounds)
    state.bvh.bounds_func = geometry.primitive_bounds
    geometry.bvh_build(&state.bvh, state.primitives)
    state.spheres = generate_random_spheres(100_000, bounds)
    state.current_sphere = 0
    state.results = make([dynamic]geometry.Primitive)
    options.input = slice.bytes_from_ptr(state, size_of(BVH_Sphere_State))
    options.bytes =
      size_of(geometry.Sphere) + size_of([dynamic]geometry.Primitive)
    return nil
  }
  bench_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    state := cast(^BVH_Sphere_State)raw_data(options.input)
    for _ in 0 ..< options.rounds {
      sphere := state.spheres[state.current_sphere]
      state.current_sphere = (state.current_sphere + 1) % len(state.spheres)
      geometry.bvh_query_sphere_primitives(
        &state.bvh,
        sphere,
        &state.results,
        geometry.sphere_primitive_intersection,
      )
      state.total_hits += len(state.results)
      if len(state.results) > state.max_hits {
        state.max_hits = len(state.results)
      }
      clear(&state.results)
      options.processed +=
        size_of(geometry.Sphere) +
        len(state.results) * size_of(geometry.Primitive)
    }
    return nil
  }
  teardown_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    state := cast(^BVH_Sphere_State)raw_data(options.input)
    geometry.bvh_destroy(&state.bvh)
    delete(state.primitives)
    delete(state.spheres)
    delete(state.results)
    free(state)
    return nil
  }
  options := &time.Benchmark_Options {
    setup = setup_proc,
    bench = bench_proc,
    teardown = teardown_proc,
    rounds = 1000,
  }
  err := time.benchmark(options)
  state := cast(^BVH_Sphere_State)raw_data(options.input)
  avg_hits := f32(state.total_hits) / f32(options.rounds)
  log.infof(
    "BVH sphere: %d queries in %v (%.2f MB/s) | %.2f μs/query | %.2f avg hits | %d max hits",
    options.rounds,
    options.duration,
    options.megabytes_per_second,
    time.duration_microseconds(options.duration) / f64(options.rounds),
    avg_hits,
    state.max_hits,
  )
}

BVH_Sphere_State :: struct {
  bvh:            geometry.BVH(geometry.Primitive),
  primitives:     []geometry.Primitive,
  spheres:        []geometry.Sphere,
  current_sphere: int,
  results:        [dynamic]geometry.Primitive,
  total_hits:     int,
  max_hits:       int,
}

@(test)
benchmark_bvh_aabb :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 60 * time.Second)
  setup_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    state := new(BVH_AABB_State)
    bounds := geometry.Aabb {
      min = {-100, -100, -100},
      max = {100, 100, 100},
    }
    state.primitives = generate_random_primitives(100_000, bounds)
    state.bvh.bounds_func = geometry.primitive_bounds
    geometry.bvh_build(&state.bvh, state.primitives)
    // Generate random AABBs
    state.aabbs = make([]geometry.Aabb, 100_000)
    extent := bounds.max - bounds.min
    for i in 0 ..< 100_000 {
      center :=
        bounds.min +
        [3]f32 {
            rand.float32() * extent.x,
            rand.float32() * extent.y,
            rand.float32() * extent.z,
          }
      size := [3]f32 {
        1 + rand.float32() * 4,
        1 + rand.float32() * 4,
        1 + rand.float32() * 4,
      }
      state.aabbs[i] = geometry.Aabb {
        min = center - size * 0.5,
        max = center + size * 0.5,
      }
    }
    state.current_aabb = 0
    state.results = make([dynamic]geometry.Primitive)
    options.input = slice.bytes_from_ptr(state, size_of(BVH_AABB_State))
    options.bytes =
      size_of(geometry.Aabb) + size_of([dynamic]geometry.Primitive)
    return nil
  }
  bench_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    state := cast(^BVH_AABB_State)raw_data(options.input)
    for _ in 0 ..< options.rounds {
      aabb := state.aabbs[state.current_aabb]
      state.current_aabb = (state.current_aabb + 1) % len(state.aabbs)
      geometry.bvh_query_aabb(&state.bvh, aabb, &state.results)
      state.total_hits += len(state.results)
      if len(state.results) > state.max_hits {
        state.max_hits = len(state.results)
      }
      clear(&state.results)
      options.processed +=
        size_of(geometry.Aabb) +
        len(state.results) * size_of(geometry.Primitive)
    }
    return nil
  }
  teardown_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    state := cast(^BVH_AABB_State)raw_data(options.input)
    geometry.bvh_destroy(&state.bvh)
    delete(state.primitives)
    delete(state.aabbs)
    delete(state.results)
    free(state)
    return nil
  }
  options := &time.Benchmark_Options {
    setup = setup_proc,
    bench = bench_proc,
    teardown = teardown_proc,
    rounds = 1000,
  }
  err := time.benchmark(options)
  state := cast(^BVH_AABB_State)raw_data(options.input)
  avg_hits := f32(state.total_hits) / f32(options.rounds)
  log.infof(
    "BVH AABB: %d queries in %v (%.2f MB/s) | %.2f μs/query | %.2f avg hits | %d max hits",
    options.rounds,
    options.duration,
    options.megabytes_per_second,
    time.duration_microseconds(options.duration) / f64(options.rounds),
    avg_hits,
    state.max_hits,
  )
}

BVH_AABB_State :: struct {
  bvh:          geometry.BVH(geometry.Primitive),
  primitives:   []geometry.Primitive,
  aabbs:        []geometry.Aabb,
  current_aabb: int,
  results:      [dynamic]geometry.Primitive,
  total_hits:   int,
  max_hits:     int,
}

@(test)
benchmark_octree_ray_single :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 60 * time.Second)
  setup_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    state := new(Octree_Ray_Single_State)
    bounds := geometry.Aabb {
      min = {-100, -100, -100},
      max = {100, 100, 100},
    }
    state.primitives = generate_random_primitives(100_000, bounds)
    state.octree.bounds_func = geometry.primitive_bounds
    state.octree.point_func = proc(p: geometry.Primitive) -> [3]f32 {
      switch prim in p.data {
      case geometry.Triangle:
        return (prim.v0 + prim.v1 + prim.v2) / 3.0
      case geometry.Sphere:
        return prim.center
      }
      return {}
    }
    geometry.octree_init(&state.octree, bounds, 10, 16)
    for prim in state.primitives {
      geometry.octree_insert(&state.octree, prim)
    }
    state.rays = generate_random_rays(100_000, bounds)
    state.current_ray = 0
    options.input = slice.bytes_from_ptr(
      state,
      size_of(Octree_Ray_Single_State),
    )
    options.bytes =
      size_of(geometry.Ray) + size_of(geometry.RayHit(geometry.Primitive))
    return nil
  }
  bench_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    state := cast(^Octree_Ray_Single_State)raw_data(options.input)
    for _ in 0 ..< options.rounds {
      ray := state.rays[state.current_ray]
      state.current_ray = (state.current_ray + 1) % len(state.rays)
      hit := geometry.octree_raycast_single(
        &state.octree,
        ray,
        1000.0,
        geometry.ray_primitive_intersection,
      )
      if hit.hit {
        state.hit_count += 1
      }
      options.processed += size_of(geometry.Ray)
    }
    return nil
  }
  teardown_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    state := cast(^Octree_Ray_Single_State)raw_data(options.input)
    geometry.octree_destroy(&state.octree)
    delete(state.primitives)
    delete(state.rays)
    free(state)
    return nil
  }
  options := &time.Benchmark_Options {
    setup = setup_proc,
    bench = bench_proc,
    teardown = teardown_proc,
    rounds = 1000,
  }
  err := time.benchmark(options)
  state := cast(^Octree_Ray_Single_State)raw_data(options.input)
  hit_rate := f32(state.hit_count) / f32(options.rounds) * 100
  log.infof(
    "Octree ray single: %d queries in %v (%.2f MB/s) | %.2f μs/query | %d hits (%.1f%%)",
    options.rounds,
    options.duration,
    options.megabytes_per_second,
    time.duration_microseconds(options.duration) / f64(options.rounds),
    state.hit_count,
    hit_rate,
  )
}

Octree_Ray_Single_State :: struct {
  octree:      geometry.Octree(geometry.Primitive),
  primitives:  []geometry.Primitive,
  rays:        []geometry.Ray,
  current_ray: int,
  hit_count:   int,
}

@(test)
benchmark_octree_ray_multi :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 60 * time.Second)
  setup_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    state := new(Octree_Ray_Multi_State)
    bounds := geometry.Aabb {
      min = {-100, -100, -100},
      max = {100, 100, 100},
    }
    state.primitives = generate_random_primitives(100_000, bounds)
    state.octree.bounds_func = geometry.primitive_bounds
    state.octree.point_func = proc(p: geometry.Primitive) -> [3]f32 {
      switch prim in p.data {
      case geometry.Triangle:
        return (prim.v0 + prim.v1 + prim.v2) / 3.0
      case geometry.Sphere:
        return prim.center
      }
      return {}
    }
    geometry.octree_init(&state.octree, bounds, 10, 16)
    for prim in state.primitives {
      geometry.octree_insert(&state.octree, prim)
    }
    state.rays = generate_random_rays(100_000, bounds)
    state.current_ray = 0
    state.multi_hits = make([dynamic]geometry.RayHit(geometry.Primitive))
    options.input = slice.bytes_from_ptr(
      state,
      size_of(Octree_Ray_Multi_State),
    )
    options.bytes =
      size_of(geometry.Ray) +
      size_of([dynamic]geometry.RayHit(geometry.Primitive))
    return nil
  }
  bench_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    state := cast(^Octree_Ray_Multi_State)raw_data(options.input)
    for _ in 0 ..< options.rounds {
      ray := state.rays[state.current_ray]
      state.current_ray = (state.current_ray + 1) % len(state.rays)
      geometry.octree_raycast_multi(
        &state.octree,
        ray,
        1000.0,
        geometry.ray_primitive_intersection,
        &state.multi_hits,
      )
      state.total_hits += len(state.multi_hits)
      if len(state.multi_hits) > state.max_hits {
        state.max_hits = len(state.multi_hits)
      }
      clear(&state.multi_hits)
      options.processed +=
        size_of(geometry.Ray) +
        len(state.multi_hits) * size_of(geometry.RayHit(geometry.Primitive))
    }
    return nil
  }
  teardown_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    state := cast(^Octree_Ray_Multi_State)raw_data(options.input)
    geometry.octree_destroy(&state.octree)
    delete(state.primitives)
    delete(state.rays)
    delete(state.multi_hits)
    free(state)
    return nil
  }
  options := &time.Benchmark_Options {
    setup = setup_proc,
    bench = bench_proc,
    teardown = teardown_proc,
    rounds = 1000,
  }
  err := time.benchmark(options)
  state := cast(^Octree_Ray_Multi_State)raw_data(options.input)
  avg_hits := f32(state.total_hits) / f32(options.rounds)
  log.infof(
    "Octree ray multi: %d queries in %v (%.2f MB/s) | %.2f μs/query | %.2f avg hits | %d max hits",
    options.rounds,
    options.duration,
    options.megabytes_per_second,
    time.duration_microseconds(options.duration) / f64(options.rounds),
    avg_hits,
    state.max_hits,
  )
}

Octree_Ray_Multi_State :: struct {
  octree:      geometry.Octree(geometry.Primitive),
  primitives:  []geometry.Primitive,
  rays:        []geometry.Ray,
  current_ray: int,
  multi_hits:  [dynamic]geometry.RayHit(geometry.Primitive),
  total_hits:  int,
  max_hits:    int,
}

@(test)
benchmark_octree_sphere :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 60 * time.Second)
  setup_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    state := new(Octree_Sphere_State)
    bounds := geometry.Aabb {
      min = {-100, -100, -100},
      max = {100, 100, 100},
    }
    state.primitives = generate_random_primitives(100_000, bounds)
    state.octree.bounds_func = geometry.primitive_bounds
    state.octree.point_func = proc(p: geometry.Primitive) -> [3]f32 {
      switch prim in p.data {
      case geometry.Triangle:
        return (prim.v0 + prim.v1 + prim.v2) / 3.0
      case geometry.Sphere:
        return prim.center
      }
      return {}
    }
    geometry.octree_init(&state.octree, bounds, 10, 16)
    for prim in state.primitives {
      geometry.octree_insert(&state.octree, prim)
    }
    state.spheres = generate_random_spheres(100_000, bounds)
    state.current_sphere = 0
    state.results = make([dynamic]geometry.Primitive)
    options.input = slice.bytes_from_ptr(state, size_of(Octree_Sphere_State))
    options.bytes =
      size_of(geometry.Sphere) + size_of([dynamic]geometry.Primitive)
    return nil
  }
  bench_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    state := cast(^Octree_Sphere_State)raw_data(options.input)
    for _ in 0 ..< options.rounds {
      sphere := state.spheres[state.current_sphere]
      state.current_sphere = (state.current_sphere + 1) % len(state.spheres)
      geometry.octree_query_sphere_primitives(
        &state.octree,
        sphere,
        &state.results,
        geometry.sphere_primitive_intersection,
      )
      state.total_hits += len(state.results)
      if len(state.results) > state.max_hits {
        state.max_hits = len(state.results)
      }
      clear(&state.results)
      options.processed +=
        size_of(geometry.Sphere) +
        len(state.results) * size_of(geometry.Primitive)
    }
    return nil
  }
  teardown_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    state := cast(^Octree_Sphere_State)raw_data(options.input)
    geometry.octree_destroy(&state.octree)
    delete(state.primitives)
    delete(state.spheres)
    delete(state.results)
    free(state)
    return nil
  }
  options := &time.Benchmark_Options {
    setup = setup_proc,
    bench = bench_proc,
    teardown = teardown_proc,
    rounds = 1000,
  }
  err := time.benchmark(options)
  state := cast(^Octree_Sphere_State)raw_data(options.input)
  avg_hits := f32(state.total_hits) / f32(options.rounds)
  log.infof(
    "Octree sphere: %d queries in %v (%.2f MB/s) | %.2f μs/query | %.2f avg hits | %d max hits",
    options.rounds,
    options.duration,
    options.megabytes_per_second,
    time.duration_microseconds(options.duration) / f64(options.rounds),
    avg_hits,
    state.max_hits,
  )
}

Octree_Sphere_State :: struct {
  octree:         geometry.Octree(geometry.Primitive),
  primitives:     []geometry.Primitive,
  spheres:        []geometry.Sphere,
  current_sphere: int,
  results:        [dynamic]geometry.Primitive,
  total_hits:     int,
  max_hits:       int,
}

@(test)
benchmark_bvh_build :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 60 * time.Second)
  setup_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    state := new(BVH_Build_State)
    bounds := geometry.Aabb {
      min = {-100, -100, -100},
      max = {100, 100, 100},
    }
    state.primitives = generate_random_primitives(100_000, bounds)
    state.bvh.bounds_func = geometry.primitive_bounds
    options.input = slice.bytes_from_ptr(state, size_of(BVH_Build_State))
    options.bytes = 100_000 * size_of(geometry.Primitive)
    return nil
  }
  bench_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    state := cast(^BVH_Build_State)raw_data(options.input)
    for _ in 0 ..< options.rounds {
      geometry.bvh_build(&state.bvh, state.primitives)
      geometry.bvh_destroy(&state.bvh)
      options.processed += len(state.primitives) * size_of(geometry.Primitive)
    }
    return nil
  }
  teardown_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    state := cast(^BVH_Build_State)raw_data(options.input)
    delete(state.primitives)
    free(state)
    return nil
  }
  options := &time.Benchmark_Options {
    setup = setup_proc,
    bench = bench_proc,
    teardown = teardown_proc,
    rounds = 1,
  }
  err := time.benchmark(options)
  ms_per_build :=
    time.duration_milliseconds(options.duration) / f64(options.rounds)
  log.infof(
    "BVH build: %d items built %d times in %v (%.2f MB/s) | %.2f ms/build",
    100_000,
    options.rounds,
    options.duration,
    options.megabytes_per_second,
    ms_per_build,
  )
}

BVH_Build_State :: struct {
  bvh:        geometry.BVH(geometry.Primitive),
  primitives: []geometry.Primitive,
}

@(test)
benchmark_octree_build :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 60 * time.Second)
  setup_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    state := new(Octree_Build_State)
    state.bounds = geometry.Aabb {
      min = {-100, -100, -100},
      max = {100, 100, 100},
    }
    state.primitives = generate_random_primitives(100_000, state.bounds)
    state.octree.bounds_func = geometry.primitive_bounds
    state.octree.point_func = proc(p: geometry.Primitive) -> [3]f32 {
      switch prim in p.data {
      case geometry.Triangle:
        return (prim.v0 + prim.v1 + prim.v2) / 3.0
      case geometry.Sphere:
        return prim.center
      }
      return {}
    }
    options.input = slice.bytes_from_ptr(state, size_of(Octree_Build_State))
    options.bytes = 100_000 * size_of(geometry.Primitive)
    return nil
  }
  bench_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    state := cast(^Octree_Build_State)raw_data(options.input)
    for _ in 0 ..< options.rounds {
      geometry.octree_init(&state.octree, state.bounds, 10, 16)
      for prim in state.primitives {
        geometry.octree_insert(&state.octree, prim)
      }
      geometry.octree_destroy(&state.octree)
      options.processed += len(state.primitives) * size_of(geometry.Primitive)
    }
    return nil
  }
  teardown_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    state := cast(^Octree_Build_State)raw_data(options.input)
    delete(state.primitives)
    free(state)
    return nil
  }
  options := &time.Benchmark_Options {
    setup = setup_proc,
    bench = bench_proc,
    teardown = teardown_proc,
    rounds = 10,
  }
  err := time.benchmark(options)
  ms_per_build :=
    time.duration_milliseconds(options.duration) / f64(options.rounds)
  log.infof(
    "Octree build: %d items built %d times in %v (%.2f MB/s) | %.2f ms/build",
    100_000,
    options.rounds,
    options.duration,
    options.megabytes_per_second,
    ms_per_build,
  )
}

Octree_Build_State :: struct {
  octree:     geometry.Octree(geometry.Primitive),
  primitives: []geometry.Primitive,
  bounds:     geometry.Aabb,
}

generate_random_primitives :: proc(
  count: int,
  bounds: geometry.Aabb,
) -> []geometry.Primitive {
  primitives := make([]geometry.Primitive, count)
  extent := bounds.max - bounds.min
  for i in 0 ..< count {
    // 50/50 mix of triangles and spheres
    if rand.int31() % 2 == 0 {
      // Random triangle
      center :=
        bounds.min +
        [3]f32 {
            rand.float32() * extent.x,
            rand.float32() * extent.y,
            rand.float32() * extent.z,
          }
      // Create triangle with random size (0.1 to 1.0 units)
      size := 0.1 + rand.float32() * 0.9
      primitives[i] = geometry.Primitive {
        type = .Triangle,
        data = geometry.Triangle {
          v0 = center + [3]f32{0, 0, 0},
          v1 = center + [3]f32{size, 0, 0},
          v2 = center + [3]f32{0, size, 0},
        },
      }
    } else {
      // Random sphere
      primitives[i] = geometry.Primitive {
        type = .Sphere,
        data = geometry.Sphere {
          center = bounds.min + [3]f32{rand.float32() * extent.x, rand.float32() * extent.y, rand.float32() * extent.z},
          radius = 0.1 + rand.float32() * 0.4, // 0.1 to 0.5 radius
        },
      }
    }
  }
  return primitives
}

generate_random_rays :: proc(
  count: int,
  bounds: geometry.Aabb,
) -> []geometry.Ray {
  rays := make([]geometry.Ray, count)
  extent := bounds.max - bounds.min
  for i in 0 ..< count {
    // Random origin around the bounds
    origin :=
      bounds.min -
      extent * 0.5 +
      [3]f32 {
          rand.float32() * extent.x * 2,
          rand.float32() * extent.y * 2,
          rand.float32() * extent.z * 2,
        }
    // Random direction (normalized)
    dir := [3]f32 {
      rand.float32() * 2 - 1,
      rand.float32() * 2 - 1,
      rand.float32() * 2 - 1,
    }
    // Ensure non-zero direction
    if math.abs(dir.x) < 0.001 &&
       math.abs(dir.y) < 0.001 &&
       math.abs(dir.z) < 0.001 {
      dir = {0, 0, 1}
    }
    rays[i] = geometry.Ray {
      origin    = origin,
      direction = linalg.normalize(dir),
    }
  }
  return rays
}

generate_random_spheres :: proc(
  count: int,
  bounds: geometry.Aabb,
) -> []geometry.Sphere {
  spheres := make([]geometry.Sphere, count)
  extent := bounds.max - bounds.min
  for i in 0 ..< count {
    spheres[i] = geometry.Sphere {
      center = bounds.min + [3]f32{rand.float32() * extent.x, rand.float32() * extent.y, rand.float32() * extent.z},
      radius = 0.5 + rand.float32() * 2.0, // 0.5 to 2.5 radius for queries
    }
  }
  return spheres
}
