#+build !js
#+private
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


@(test)
test_ray_plane_intersection :: proc(t: ^testing.T) {
  down := Ray{origin = {1, 5, 2}, direction = {0, -1, 0}}
  at, hit := ray_plane_intersection(down, {0, 2, 0}, {0, 1, 0})
  dist := linalg.distance(at, down.origin)
  testing.expect(t, hit, "a ray toward the plane hits it")
  testing.expect_value(t, dist, 3.0)
  _, hit = ray_plane_intersection({origin = {0, 5, 0}, direction = {0, 1, 0}}, {0, 2, 0}, {0, 1, 0})
  testing.expect(t, !hit, "a ray away from the plane misses it")
  _, hit = ray_plane_intersection({origin = {0, 5, 0}, direction = {1, 0, 0}}, {0, 2, 0}, {0, 1, 0})
  testing.expect(t, !hit, "a ray parallel to the plane misses it")
  _, hit = ray_plane_intersection(down, {0, 2, 0}, {0, 1, 0}, max_t = 2)
  testing.expect(t, !hit, "a hit beyond max_t is a miss")
}
