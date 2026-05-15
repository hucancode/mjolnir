package world

import "../geometry"
import "core:os"
import "core:testing"

OBJ_PATH :: "assets/nav_test.obj"
GLB_PATH :: "assets/cube.glb"

@(test)
test_geometry_load_obj :: proc(t: ^testing.T) {
	if !os.exists(OBJ_PATH) {
		testing.expect(t, true, "skipping: asset missing")
		return
	}
	geom, ok := geometry.load_obj(OBJ_PATH, 1.0)
	testing.expect(t, ok, "load_obj failed")
	defer geometry.delete_geometry(geom)
	testing.expect(t, len(geom.vertices) > 0, "must produce vertices")
	testing.expect(t, len(geom.indices) > 0 && len(geom.indices) % 3 == 0, "must produce triangle indices")
	testing.expect(t, geom.aabb.min != geom.aabb.max, "aabb must span")

	// scale parameter
	geom2, _ := geometry.load_obj(OBJ_PATH, 2.0)
	defer geometry.delete_geometry(geom2)
	span1 := geom.aabb.max - geom.aabb.min
	span2 := geom2.aabb.max - geom2.aabb.min
	testing.expectf(t, span2.x > span1.x * 1.9, "scale=2 should ~double span: %f vs %f", span1.x, span2.x)
}

@(test)
test_geometry_load_obj_missing :: proc(t: ^testing.T) {
	_, ok := geometry.load_obj("assets/this_file_does_not_exist.obj", 1.0)
	testing.expect(t, !ok, "missing file must return ok=false")
}

@(test)
test_world_load_obj_smoke :: proc(t: ^testing.T) {
	if !os.exists(OBJ_PATH) {
		testing.expect(t, true, "skipping: asset missing")
		return
	}
	world: World
	init(&world)
	defer shutdown(&world)

	mat, _ := material_pbr(&world)
	nodes, ok := load_obj(&world, OBJ_PATH, mat)
	testing.expect(t, ok, "world.load_obj failed")
	defer delete(nodes)
	testing.expect(t, len(nodes) > 0, "load_obj must spawn nodes")
}
