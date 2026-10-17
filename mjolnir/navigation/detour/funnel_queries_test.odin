#+build !js
#+private
package detour

import "core:math"
import "core:testing"

@(test)
test_validate_tile_data_too_small :: proc(t: ^testing.T) {
	r := validate_tile_data(make([]u8, 4))
	defer free_all(context.temp_allocator)
	testing.expect(t, !r.valid && r.error_count > 0, "tiny buffer must fail")
}

@(test)
test_validate_tile_data_negative_counts :: proc(t: ^testing.T) {
	buf := make([]u8, size_of(Mesh_Header) + 64)
	defer delete(buf)
	header := cast(^Mesh_Header)raw_data(buf)
	header.poly_count = -1
	header.bmin = {0, 0, 0}
	header.bmax = {1, 1, 1}
	header.walkable_height = 1
	header.walkable_radius = 1
	header.walkable_climb = 0
	r := validate_tile_data(buf)
	testing.expect(t, !r.valid, "negative count flagged")
}

@(test)
test_validate_tile_data_inverted_bounds :: proc(t: ^testing.T) {
	buf := make([]u8, size_of(Mesh_Header) + 64)
	defer delete(buf)
	header := cast(^Mesh_Header)raw_data(buf)
	header.bmin = {5, 5, 5}
	header.bmax = {0, 0, 0}
	header.walkable_height = 1
	header.walkable_radius = 1
	header.walkable_climb = 0
	r := validate_tile_data(buf)
	testing.expect(t, !r.valid, "inverted bounds flagged")
}

@(test)
test_validate_navmesh_header_invalid :: proc(t: ^testing.T) {
	st := validate_navmesh_header(nil)
	testing.expect(t, !status_succeeded(st), "nil header rejected")
	header := Mesh_Header{poly_count = -5, vert_count = 0}
	st2 := validate_navmesh_header(&header)
	testing.expect(t, !status_succeeded(st2), "negative poly_count rejected")
}

@(test)
test_calculate_expected_tile_size_grows_with_counts :: proc(t: ^testing.T) {
	h1 := Mesh_Header{poly_count = 10, vert_count = 30}
	h2 := Mesh_Header{poly_count = 20, vert_count = 60}
	s1 := calculate_expected_tile_size(&h1)
	s2 := calculate_expected_tile_size(&h2)
	testing.expectf(t, s2 > s1, "larger counts must produce larger size: %d vs %d", s1, s2)
}

// ----- spatial_queries: closest/wall/local/around ---------------
