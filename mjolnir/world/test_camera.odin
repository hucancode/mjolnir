package world

import "core:math"
import "core:math/linalg"
import "core:testing"

@(test)
test_camera_basis_vectors :: proc(t: ^testing.T) {
	cam: Camera
	camera_init(&cam, 100, 100, {0, 0, 5}, {0, 0, 0})
	fwd := camera_forward(&cam)
	// Looking from (0,0,5) toward origin → forward is -Z
	testing.expectf(t, math.abs(fwd.z + 1.0) < 1e-3, "forward.z expected -1, got %f", fwd.z)
	right := camera_right(&cam)
	testing.expectf(t, math.abs(linalg.length(right) - 1.0) < 1e-4, "right unit length")
	up := camera_up(&cam)
	testing.expectf(t, math.abs(up.y - 1.0) < 1e-3, "up.y expected ~1, got %f", up.y)
	// orthonormal basis
	testing.expect(t, math.abs(linalg.dot(fwd, right)) < 1e-4, "fwd ⟂ right")
	testing.expect(t, math.abs(linalg.dot(fwd, up)) < 1e-4, "fwd ⟂ up")
}

@(test)
test_camera_look_at_singular_up :: proc(t: ^testing.T) {
	// Looking straight down (parallel to default up=Y) → must pick alt up axis
	cam: Camera
	cam.extent = {100, 100}
	cam.projection = PerspectiveProjection{fov = 1.0, aspect_ratio = 1, near = 0.1, far = 100}
	camera_look_at(&cam, {0, 5, 0}, {0, 0, 0})
	fwd := camera_forward(&cam)
	testing.expectf(t, math.abs(fwd.y + 1.0) < 1e-3, "forward should be -Y, got %v", fwd)
}

@(test)
test_camera_resize_updates_aspect :: proc(t: ^testing.T) {
	cam: Camera
	camera_init(&cam, 100, 100, {0, 0, 1}, {0, 0, 0})
	camera_resize(&cam, 1920, 1080)
	persp := cam.projection.(PerspectiveProjection)
	testing.expectf(t, math.abs(persp.aspect_ratio - 1920.0 / 1080.0) < 1e-5, "aspect after resize: %f", persp.aspect_ratio)
	testing.expect(t, cam.extent == [2]u32{1920, 1080}, "extent updated")

	// Resize to identical dims should be no-op
	camera_resize(&cam, 1920, 1080)
	testing.expect(t, cam.extent == [2]u32{1920, 1080}, "no-op resize ok")
}

@(test)
test_camera_viewport_to_world_ray_center :: proc(t: ^testing.T) {
	cam: Camera
	camera_init(&cam, 800, 600, {0, 0, 5}, {0, 0, 0})
	origin, dir := camera_viewport_to_world_ray(&cam, 400, 300)
	testing.expect(t, origin == cam.position, "ray origin = camera position")
	// Center of viewport should produce ray pointing along forward (-Z)
	testing.expectf(t, math.abs(dir.z + 1.0) < 1e-3 && math.abs(dir.x) < 1e-3 && math.abs(dir.y) < 1e-3,
		"center ray should be ~forward, got %v", dir)
}

@(test)
test_camera_viewport_to_world_ray_corners_diverge :: proc(t: ^testing.T) {
	cam: Camera
	camera_init(&cam, 800, 600, {0, 0, 5}, {0, 0, 0})
	_, dir_tl := camera_viewport_to_world_ray(&cam, 0, 0)
	_, dir_br := camera_viewport_to_world_ray(&cam, 800, 600)
	testing.expect(t, dir_tl != dir_br, "corner rays must differ")
	// Top-left should have +x → ... wait, we flipped y in NDC. Verify x flips.
	testing.expect(t, dir_tl.x < 0 && dir_br.x > 0, "x should flip across viewport")
	testing.expect(t, dir_tl.y > 0 && dir_br.y < 0, "y should flip across viewport (NDC inverted)")
}
