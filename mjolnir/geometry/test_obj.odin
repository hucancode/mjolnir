package geometry

import "core:os"
import "core:testing"

OBJ_PATH :: "assets/nav_test.obj"

@(test)
test_load_obj :: proc(t: ^testing.T) {
	if !os.exists(OBJ_PATH) {
		testing.expect(t, true, "skipping: asset missing")
		return
	}
	obj, ok := load_obj(OBJ_PATH, 1.0)
	testing.expect(t, ok, "load_obj failed")
	defer obj_mesh_destroy(&obj)
	testing.expect(t, len(obj.positions) > 0, "must produce positions")
	testing.expect(t, len(obj.indices) > 0 && len(obj.indices) % 3 == 0, "must produce triangle indices")
	for i in obj.indices do testing.expect(t, int(i) < len(obj.positions), "index in range")

	// scale parameter
	obj2, _ := load_obj(OBJ_PATH, 2.0)
	defer obj_mesh_destroy(&obj2)
	testing.expect(t, len(obj2.positions) == len(obj.positions), "same vertex count")
	testing.expectf(t, obj2.positions[0] == obj.positions[0] * 2, "scale=2 doubles positions: %v vs %v", obj.positions[0], obj2.positions[0])
}

@(test)
test_load_obj_missing :: proc(t: ^testing.T) {
	_, ok := load_obj("assets/this_file_does_not_exist.obj", 1.0)
	testing.expect(t, !ok, "missing file must return ok=false")
}
