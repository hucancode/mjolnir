#+build !js
package geometry

import "core:math/linalg"
import "core:testing"

@(test)
test_ray_sphere_intersection :: proc(t: ^testing.T) {
  sphere := Sphere {
    center = {0, 0, 0},
    radius = 1,
  }
  // Basic hit
  ray := Ray {
    origin    = {0, 0, 5},
    direction = {0, 0, -1},
  }
  hit, dist := ray_sphere_intersection(ray, sphere)
  testing.expect(t, hit, "Ray should hit sphere")
  testing.expect_value(t, dist, 4.0)
  // Basic miss
  ray2 := Ray {
    origin    = {2, 0, 5},
    direction = {0, 0, -1},
  }
  hit2, _ := ray_sphere_intersection(ray2, sphere)
  testing.expect(t, !hit2, "Ray should miss sphere")
  // Edge cases
  // Tangent ray
  ray_tangent := Ray {
    origin    = {1, 0, 5},
    direction = {0, 0, -1},
  }
  hit3, dist3 := ray_sphere_intersection(ray_tangent, sphere)
  testing.expect(t, hit3, "Tangent ray should hit sphere")
  testing.expect_value(t, dist3, 5.0)
  // Ray starting inside
  ray_inside := Ray {
    origin    = {0, 0, 0},
    direction = {1, 0, 0},
  }
  hit4, dist4 := ray_sphere_intersection(ray_inside, sphere)
  testing.expect(t, hit4, "Ray from inside should hit")
  testing.expect_value(t, dist4, 1.0)
  // Very small sphere
  tiny_sphere := Sphere {
    center = {0, 0, 0},
    radius = 0.001,
  }
  ray_tiny := Ray {
    origin    = {0, 0, 1},
    direction = {0, 0, -1},
  }
  hit5, _ := ray_sphere_intersection(ray_tiny, tiny_sphere)
  testing.expect(t, hit5, "Should hit tiny sphere")
}


@(private = "file")
sphere_octree :: proc(octree: ^Octree(Sphere), bounds: Aabb, max_depth: i32, max_items: i32) {
  octree.bounds_func = proc(s: Sphere) -> Aabb {
    return {min = s.center - s.radius, max = s.center + s.radius}
  }
  octree.point_func = proc(s: Sphere) -> [3]f32 {return s.center}
  octree_init(octree, bounds, max_depth, max_items)
}

@(private = "file")
ray_sphere :: proc(ray: Ray, s: Sphere, max_t: f32) -> (bool, f32) {
  return ray_sphere_intersection(ray, s, max_t)
}

@(test)
test_octree_basic_raycasting :: proc(t: ^testing.T) {
  octree: Octree(Sphere)
  sphere_octree(&octree, {min = {-10, -10, -10}, max = {10, 10, 10}}, 6, 4)
  defer octree_destroy(&octree)
  octree_insert(&octree, Sphere{center = {0, 0, 0}, radius = 1})
  octree_insert(&octree, Sphere{center = {3, 0, 0}, radius = 1})
  hit := octree_raycast(&octree, Ray{origin = {0, 0, 5}, direction = {0, 0, -1}}, 100.0, ray_sphere)
  testing.expect(t, hit.hit, "Ray should hit first sphere")
  testing.expect_value(t, hit.t, 4.0)
  hit2 := octree_raycast(&octree, Ray{origin = {3, 0, 5}, direction = {0, 0, -1}}, 100.0, ray_sphere)
  testing.expect(t, hit2.hit, "Ray should hit second sphere")
  testing.expect_value(t, hit2.t, 4.0)
  miss := octree_raycast(&octree, Ray{origin = {6, 6, 5}, direction = {0, 0, -1}}, 100.0, ray_sphere)
  testing.expect(t, !miss.hit, "Ray should miss")
}

@(test)
test_octree_single_vs_multi_raycast :: proc(t: ^testing.T) {
  octree: Octree(Sphere)
  sphere_octree(&octree, {min = {-10, -10, -10}, max = {10, 10, 10}}, 6, 4)
  defer octree_destroy(&octree)
  // Three spheres along the ray path
  octree_insert(&octree, Sphere{center = {0, 0, 2}, radius = 0.5})
  octree_insert(&octree, Sphere{center = {0, 0, 4}, radius = 0.5})
  octree_insert(&octree, Sphere{center = {0, 0, 6}, radius = 0.5})
  ray := Ray{origin = {0, 0, 0}, direction = {0, 0, 1}}
  single_hit := octree_raycast_single(&octree, ray, 100.0, ray_sphere)
  testing.expect(t, single_hit.hit, "Single raycast should hit")
  testing.expect_value(t, single_hit.t, 1.5)
  multi_hits: [dynamic]RayHit(Sphere)
  defer delete(multi_hits)
  octree_raycast_multi(&octree, ray, 100.0, ray_sphere, &multi_hits)
  testing.expect_value(t, len(multi_hits), 3)
  testing.expect_value(t, multi_hits[0].t, 1.5)
  testing.expect_value(t, multi_hits[1].t, 3.5)
  testing.expect_value(t, multi_hits[2].t, 5.5)
}

@(test)
test_octree_subdivision_with_raycast :: proc(t: ^testing.T) {
  octree: Octree(Sphere)
  // Low max_items forces subdivision
  sphere_octree(&octree, {min = {-5, -5, -5}, max = {5, 5, 5}}, 8, 2)
  defer octree_destroy(&octree)
  for i in 0 ..< 10 {
    fi := f32(i) * 0.1
    octree_insert(&octree, Sphere{center = {fi, fi, fi}, radius = 0.05})
  }
  stats := octree_get_stats(&octree)
  testing.expect(t, stats.total_nodes > 1, "Octree should subdivide with clustered items")
  testing.expect(t, stats.max_depth > 0, "Octree should have depth > 0")
  ray := Ray{origin = {-1, -1, -1}, direction = linalg.normalize([3]f32{1, 1, 1})}
  multi_hits: [dynamic]RayHit(Sphere)
  defer delete(multi_hits)
  octree_raycast_multi(&octree, ray, 10.0, ray_sphere, &multi_hits)
  testing.expect(t, len(multi_hits) > 0, "Should hit some spheres in cluster")
}
