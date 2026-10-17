#+build !js
#+private
package bake

import "../detour"
import "../recast"
import "core:math"
import "core:testing"

// Build a 20x20 walkable plane (centered at origin) for query tests.
build_plane_navmesh :: proc(t: ^testing.T) -> ^detour.Nav_Mesh {
	verts := [][3]f32{{-10, 0, -10}, {10, 0, -10}, {10, 0, 10}, {-10, 0, 10}}
	indices := []i32{0, 2, 1, 0, 3, 2}
	areas := []u8{recast.RC_WALKABLE_AREA, recast.RC_WALKABLE_AREA}
	cfg := recast.Config {
		cs                       = 0.3,
		ch                       = 0.2,
		walkable_slope           = math.PI * 0.25,
		walkable_height          = 10,
		walkable_climb           = 4,
		walkable_radius          = 2,
		max_edge_len             = 12,
		max_simplification_error = 1.3,
		min_region_area          = 8,
		merge_region_area        = 20,
		max_verts_per_poly       = 6,
		detail_sample_dist       = 6,
		detail_sample_max_error  = 1,
	}
	pmesh, dmesh, ok := recast.build_navmesh(verts, indices, areas, cfg)
	if !ok {
		testing.fail_now(t, "build_navmesh failed")
	}
	defer recast.destroy_poly_mesh(pmesh)
	defer recast.destroy_poly_mesh_detail(dmesh)
	params := Create_Nav_Mesh_Data_Params {
		poly_mesh        = pmesh,
		poly_mesh_detail = dmesh,
		walkable_height  = f32(cfg.walkable_height) * cfg.ch,
		walkable_radius  = f32(cfg.walkable_radius) * cfg.cs,
		walkable_climb   = f32(cfg.walkable_climb) * cfg.ch,
	}
	nav_mesh, st := create_nav_mesh(&params)
	if !detour.status_succeeded(st) {
		testing.fail_now(t, "create_nav_mesh failed")
	}
	return nav_mesh
}

destroy_plane_navmesh :: proc(nav: ^detour.Nav_Mesh) {
	detour.nav_mesh_destroy(nav)
	free(nav)
}

// ----- data_validation -----------------------------------------

@(test)
test_closest_point_on_polygon_inside_outside :: proc(t: ^testing.T) {
	nav := build_plane_navmesh(t)
	defer destroy_plane_navmesh(nav)
	query: detour.Nav_Mesh_Query
	defer detour.nav_mesh_query_destroy(&query)
	detour.nav_mesh_query_init(&query, nav, 256)

	filter: detour.Query_Filter
	detour.query_filter_init(&filter)
	half := [3]f32{2, 4, 2}
	st, ref, _ := detour.find_nearest_poly(&query, {0, 0, 0}, half, &filter)
	if !detour.status_succeeded(st) do return

	tile, poly, _ := detour.get_tile_and_poly_by_ref(nav, ref)

	// Inside polygon → returned point must have same X/Z as input
	pt_in, inside := detour.closest_point_on_polygon(tile, poly, {0, 0, 0})
	testing.expect(t, inside, "origin should be inside")
	testing.expectf(t, math.abs(pt_in.x) < 1e-3 && math.abs(pt_in.z) < 1e-3,
		"inside should preserve XZ, got %v", pt_in)

	// Outside polygon → returned point on boundary, closer to input
	pt_out, _ := detour.closest_point_on_polygon(tile, poly, {100, 0, 0})
	testing.expect(t, pt_out.x < 100, "outside projects toward boundary")
}

@(test)
test_find_distance_to_wall :: proc(t: ^testing.T) {
	nav := build_plane_navmesh(t)
	defer destroy_plane_navmesh(nav)
	query: detour.Nav_Mesh_Query
	defer detour.nav_mesh_query_destroy(&query)
	detour.nav_mesh_query_init(&query, nav, 256)

	filter: detour.Query_Filter
	detour.query_filter_init(&filter)
	half := [3]f32{2, 4, 2}
	st, ref, _ := detour.find_nearest_poly(&query, {0, 0, 0}, half, &filter)
	if !detour.status_succeeded(st) do return

	dist, _, _, st2 := detour.find_distance_to_wall(&query, ref, {0, 0, 0}, 50.0, &filter)
	testing.expect(t, detour.status_succeeded(st2), "query should succeed")
	testing.expectf(t, dist > 0 && dist < 50.0, "wall distance must be bounded, got %f", dist)
}

@(test)
test_find_local_neighbourhood :: proc(t: ^testing.T) {
	nav := build_plane_navmesh(t)
	defer destroy_plane_navmesh(nav)
	query: detour.Nav_Mesh_Query
	defer detour.nav_mesh_query_destroy(&query)
	detour.nav_mesh_query_init(&query, nav, 256)

	filter: detour.Query_Filter
	detour.query_filter_init(&filter)
	half := [3]f32{2, 4, 2}
	st, ref, _ := detour.find_nearest_poly(&query, {0, 0, 0}, half, &filter)
	if !detour.status_succeeded(st) do return

	refs := make([]detour.Poly_Ref, 32)
	defer delete(refs)
	parents := make([]detour.Poly_Ref, 32)
	defer delete(parents)
	count, st2 := detour.find_local_neighbourhood(&query, ref, {0, 0, 0}, 5.0, &filter, refs, parents, 32)
	testing.expect(t, detour.status_succeeded(st2) && count >= 1, "must find at least starting poly")
	testing.expect(t, refs[0] == ref, "first result is start ref")
}

@(test)
test_find_polys_around_circle :: proc(t: ^testing.T) {
	nav := build_plane_navmesh(t)
	defer destroy_plane_navmesh(nav)
	query: detour.Nav_Mesh_Query
	defer detour.nav_mesh_query_destroy(&query)
	detour.nav_mesh_query_init(&query, nav, 256)

	filter: detour.Query_Filter
	detour.query_filter_init(&filter)
	half := [3]f32{2, 4, 2}
	st, ref, _ := detour.find_nearest_poly(&query, {0, 0, 0}, half, &filter)
	if !detour.status_succeeded(st) do return

	refs := make([]detour.Poly_Ref, 32)
	defer delete(refs)
	parents := make([]detour.Poly_Ref, 32)
	defer delete(parents)
	costs := make([]f32, 32)
	defer delete(costs)
	count, st2 := detour.find_polys_around_circle(&query, ref, {0, 0, 0}, 8.0, &filter, refs, parents, costs, 32)
	testing.expect(t, detour.status_succeeded(st2) && count >= 1, "must find at least starting poly")
	testing.expect(t, costs[0] == 0, "starting poly cost = 0")
}

// ----- raycast --------------------------------------------------

@(test)
test_raycast_hits_boundary :: proc(t: ^testing.T) {
	nav := build_plane_navmesh(t)
	defer destroy_plane_navmesh(nav)
	query: detour.Nav_Mesh_Query
	defer detour.nav_mesh_query_destroy(&query)
	detour.nav_mesh_query_init(&query, nav, 256)

	filter: detour.Query_Filter
	detour.query_filter_init(&filter)
	half := [3]f32{2, 4, 2}
	st, ref, _ := detour.find_nearest_poly(&query, {0, 0, 0}, half, &filter)
	if !detour.status_succeeded(st) do return

	path := make([]detour.Poly_Ref, 16)
	defer delete(path)
	// Cast to far outside plane -> should hit edge with t < ∞
	st2, hit, _ := detour.raycast(&query, ref, {0, 0, 0}, {100, 0, 0}, &filter, 0, path, 16)
	testing.expect(t, detour.status_succeeded(st2), "raycast call must succeed")
	testing.expectf(t, hit.t < 1.0, "ray to outside must report hit before end, got t=%f", hit.t)
}

@(test)
test_raycast_zero_length :: proc(t: ^testing.T) {
	nav := build_plane_navmesh(t)
	defer destroy_plane_navmesh(nav)
	query: detour.Nav_Mesh_Query
	defer detour.nav_mesh_query_destroy(&query)
	detour.nav_mesh_query_init(&query, nav, 256)

	filter: detour.Query_Filter
	detour.query_filter_init(&filter)
	half := [3]f32{2, 4, 2}
	st, ref, _ := detour.find_nearest_poly(&query, {0, 0, 0}, half, &filter)
	if !detour.status_succeeded(st) do return

	path := make([]detour.Poly_Ref, 4)
	defer delete(path)
	st2, hit, _ := detour.raycast(&query, ref, {0, 0, 0}, {0, 0, 0}, &filter, 0, path, 4)
	testing.expect(t, detour.status_succeeded(st2) && hit.t == 0, "zero-length ray returns t=0")
}

// ----- funnel: closest_point_on_poly + point_in_polygon ---------

@(test)
test_closest_point_on_poly_inside :: proc(t: ^testing.T) {
	nav := build_plane_navmesh(t)
	defer destroy_plane_navmesh(nav)
	query: detour.Nav_Mesh_Query
	defer detour.nav_mesh_query_destroy(&query)
	detour.nav_mesh_query_init(&query, nav, 256)
	filter: detour.Query_Filter
	detour.query_filter_init(&filter)
	half := [3]f32{2, 4, 2}
	_, ref, _ := detour.find_nearest_poly(&query, {0, 0, 0}, half, &filter)
	pt := detour.closest_point_on_poly(&query, ref, {0, 0, 0})
	testing.expectf(t, math.abs(pt.x) < 1e-3 && math.abs(pt.z) < 1e-3,
		"interior point preserves XZ, got %v", pt)
}

@(test)
test_point_in_polygon_funnel :: proc(t: ^testing.T) {
	nav := build_plane_navmesh(t)
	defer destroy_plane_navmesh(nav)
	query: detour.Nav_Mesh_Query
	defer detour.nav_mesh_query_destroy(&query)
	detour.nav_mesh_query_init(&query, nav, 256)
	filter: detour.Query_Filter
	detour.query_filter_init(&filter)
	half := [3]f32{2, 4, 2}
	_, ref, _ := detour.find_nearest_poly(&query, {0, 0, 0}, half, &filter)
	testing.expect(t, detour.point_in_polygon(&query, ref, {0, 0, 0}), "origin inside polygon")
	testing.expect(t, !detour.point_in_polygon(&query, ref, {500, 0, 500}), "far point outside")
}
