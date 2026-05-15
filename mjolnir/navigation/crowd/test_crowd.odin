package crowd

import "../detour"
import "../recast"
import "base:runtime"
import "core:log"
import "core:math"
import "core:testing"
import "core:time"

// ---------------------------------------------------------------
// Pure helpers (no nav mesh) ------------------------------------
// ---------------------------------------------------------------

// Note: proximity_grid wipes bucket heads on every bucket-array growth, so the
// only safe usage pattern is to seed the bounds with the largest item up-front
// (matches crowd_update which clears + readds every frame within stable bounds).
@(test)
test_proximity_grid_add_query :: proc(t: ^testing.T) {
	// Pool needs slack: sentinel covers (0..15)x(0..15)=256 cells, plus items.
	grid, ok := create_proximity_grid(512, 1.0)
	testing.expect(t, ok, "grid create")
	defer destroy_proximity_grid(grid)

	// Seed bounds with a sentinel covering 0..15 in both axes.
	proximity_grid_add_item(grid, 0xfffe, 0, 0, 15, 15)
	// Items kept tight (inside one cell) so each consumes 1 pool slot.
	proximity_grid_add_item(grid, 1, 1.1, 1.1, 1.9, 1.9)
	proximity_grid_add_item(grid, 2, 6.1, 6.1, 6.9, 6.9)
	proximity_grid_add_item(grid, 3, 10.1, 10.1, 10.9, 10.9)

	ids: [32]u16
	n := proximity_grid_query_items(grid, 1, 1, 2, 2, ids[:], 32)
	found1 := false
	for i in 0 ..< n {
		if ids[i] == 1 do found1 = true
	}
	testing.expectf(t, found1, "tight query should find id 1, got n=%d", n)

	n2 := proximity_grid_query_items(grid, 5, 5, 11, 11, ids[:], 32)
	found2 := false
	found3 := false
	for i in 0 ..< n2 {
		if ids[i] == 2 do found2 = true
		if ids[i] == 3 do found3 = true
	}
	testing.expect(t, found2 && found3, "wide query should find id 2 and 3")
}

@(test)
test_proximity_grid_get_item_count_at :: proc(t: ^testing.T) {
	// 8x8 sentinel cells = 64 pool entries, plus item.
	grid, _ := create_proximity_grid(128, 1.0)
	defer destroy_proximity_grid(grid)
	proximity_grid_add_item(grid, 0xfffe, 0, 0, 7, 7)
	proximity_grid_add_item(grid, 5, 3.1, 3.1, 3.9, 3.9)
	c := proximity_grid_get_item_count_at(grid, 3, 3)
	testing.expectf(t, c >= 2, "expected at least 2 entries at (3,3), got %d", c)
	out := proximity_grid_get_item_count_at(grid, 100, 100)
	testing.expect(t, out == 0, "out-of-bounds returns 0")
}

@(test)
test_local_boundary_segment_sorted_by_distance :: proc(t: ^testing.T) {
	b := create_local_boundary()
	defer destroy_local_boundary(b)

	// insert in scrambled order, expect sorted ascending by distance
	dists := [?]f32{4, 1, 8, 2, 0.5, 6, 3, 5}
	for d, i in dists {
		s := [6]f32{f32(i), 0, 0, 0, 0, 0}
		local_boundary_add_segment(b, d, s)
	}
	testing.expectf(t, b.nsegs == MAX_LOCAL_SEGS, "should fill to max=%d, got %d", MAX_LOCAL_SEGS, b.nsegs)
	for i in 1 ..< b.nsegs {
		testing.expectf(t, b.segs[i - 1].d <= b.segs[i].d, "not sorted at %d: %f > %f", i, b.segs[i - 1].d, b.segs[i].d)
	}
}

@(test)
test_local_boundary_get_segment_bounds :: proc(t: ^testing.T) {
	b := create_local_boundary()
	defer destroy_local_boundary(b)
	s := [6]f32{1, 2, 3, 4, 5, 6}
	local_boundary_add_segment(b, 1.0, s)
	got := local_boundary_get_segment(b, 0)
	testing.expect(t, got == s, "should return inserted segment")
	zero := local_boundary_get_segment(b, 99)
	testing.expect(t, zero == [6]f32{}, "out-of-range returns zero")
}

@(test)
test_sweep_circle_circle_geometry :: proc(t: ^testing.T) {
	// stationary obstacle at +x=2, moving sphere at origin heading +x
	hit, tmin, tmax := sweep_circle_circle({0, 0, 0}, 0.5, {1, 0, 0}, {2, 0, 0}, 0.5)
	testing.expect(t, hit, "head-on sweep should hit")
	testing.expectf(t, tmin > 0 && tmin < tmax, "tmin/tmax order broken: %f/%f", tmin, tmax)

	// zero relative velocity -> no hit
	hit2, _, _ := sweep_circle_circle({0, 0, 0}, 0.5, {0, 0, 0}, {2, 0, 0}, 0.5)
	testing.expect(t, !hit2, "no relative motion should miss")

	// motion perpendicular to separation, miss
	hit3, _, _ := sweep_circle_circle({0, 0, 0}, 0.1, {0, 0, 1}, {5, 0, 0}, 0.1)
	testing.expect(t, !hit3, "perpendicular motion should miss")
}

@(test)
test_isect_ray_seg_basic :: proc(t: ^testing.T) {
	// ray from origin along +x, segment crossing at x=2
	hit, tt := isect_ray_seg({0, 0, 0}, {4, 0, 0}, {2, 0, -1}, {2, 0, 1})
	testing.expect(t, hit, "should hit perpendicular wall")
	testing.expectf(t, math.abs(tt - 0.5) < 1e-4, "expected t=0.5, got %f", tt)

	// parallel: no hit
	miss, _ := isect_ray_seg({0, 0, 0}, {4, 0, 0}, {0, 0, 1}, {4, 0, 1})
	testing.expect(t, !miss, "parallel should miss")

	// ray pointing away from segment
	miss2, _ := isect_ray_seg({0, 0, 0}, {-4, 0, 0}, {2, 0, -1}, {2, 0, 1})
	testing.expect(t, !miss2, "ray facing away should miss")
}

@(test)
test_perp_2d_signs :: proc(t: ^testing.T) {
	testing.expect(t, perp_2d({1, 0}, {0, 1}) > 0, "ccw turn positive")
	testing.expect(t, perp_2d({0, 1}, {1, 0}) < 0, "cw turn negative")
	testing.expect(t, perp_2d({1, 1}, {2, 2}) == 0, "colinear is zero")
}

@(test)
test_add_neighbour_inserts_sorted :: proc(t: ^testing.T) {
	neis: [4]Crowd_Neighbour
	n := 0
	n = add_neighbour(0, 5.0, neis[:], n, 4)
	n = add_neighbour(1, 1.0, neis[:], n, 4)
	n = add_neighbour(2, 3.0, neis[:], n, 4)
	n = add_neighbour(3, 0.5, neis[:], n, 4)
	testing.expectf(t, n == 4, "n=%d", n)
	for i in 1 ..< n {
		testing.expectf(t, neis[i - 1].dist <= neis[i].dist, "unsorted at %d", i)
	}
	// over-cap with farthest is dropped
	n = add_neighbour(99, 100.0, neis[:], n, 4)
	testing.expect(t, n == 4, "should not grow beyond max")
}

@(test)
test_merge_corridor_start_moved_truncates_visited :: proc(t: ^testing.T) {
	path := [8]recast.Poly_Ref{1, 2, 3, 4, 0, 0, 0, 0}
	visited := [4]recast.Poly_Ref{10, 11, 2, 0}
	new_n := merge_corridor_start_moved(path[:], 4, 8, visited[:], 3)
	// 'visited' overlaps path at 2 -> must replace prefix with reversed unmatched visited then keep tail from match+1
	testing.expectf(t, new_n >= 3, "expected at least 3 entries, got %d", new_n)
	// Tail polygons after match should still be present
	found_3 := false
	found_4 := false
	for i in 0 ..< new_n {
		if path[i] == 3 do found_3 = true
		if path[i] == 4 do found_4 = true
	}
	testing.expect(t, found_3 && found_4, "tail polys after match must survive")
}

@(test)
test_merge_corridor_start_shortcut_no_overlap_keeps_path :: proc(t: ^testing.T) {
	path := [4]recast.Poly_Ref{1, 2, 3, 4}
	visited := [3]recast.Poly_Ref{99, 98, 97}
	new_n := merge_corridor_start_shortcut(path[:], 4, 4, visited[:], 3)
	testing.expectf(t, new_n == 4, "no overlap should leave path untouched, got n=%d", new_n)
}

@(test)
test_merge_corridor_end_moved_extends_path :: proc(t: ^testing.T) {
	path := [8]recast.Poly_Ref{1, 2, 3, 4, 0, 0, 0, 0}
	visited := [4]recast.Poly_Ref{4, 5, 6, 7}
	new_n := merge_corridor_end_moved(path[:], 4, 8, visited[:], 4)
	testing.expectf(t, new_n == 7, "should extend to 7 entries, got %d", new_n)
	testing.expect(t, path[4] == 5 && path[5] == 6 && path[6] == 7, "extension polys missing")
}

@(test)
test_integrate_velocity_clamped_by_acceleration :: proc(t: ^testing.T) {
	ag: Crowd_Agent
	ag.params.max_acceleration = 4.0
	ag.params.max_speed = 10.0
	ag.vel = {0, 0, 0}
	ag.nvel = {10, 0, 0} // big request
	integrate(&ag, 0.5) // max delta = 4 * 0.5 = 2
	speed := math.sqrt(ag.vel.x * ag.vel.x + ag.vel.z * ag.vel.z)
	testing.expectf(t, math.abs(speed - 2.0) < 1e-4, "expected clamped speed=2, got %f", speed)

	// position must advance
	testing.expect(t, ag.npos.x > 0, "position should move along velocity")
}

@(test)
test_integrate_zero_velocity_resets :: proc(t: ^testing.T) {
	ag: Crowd_Agent
	ag.params.max_acceleration = 100.0
	ag.vel = {0.00001, 0, 0}
	ag.nvel = {0, 0, 0}
	integrate(&ag, 0.016)
	testing.expect(t, ag.vel == [3]f32{0, 0, 0}, "tiny velocity must zero out")
}

@(test)
test_calc_steer_directions_no_corners :: proc(t: ^testing.T) {
	ag: Crowd_Agent
	ag.ncorners = 0
	dir: [3]f32 = {1, 1, 1}
	calc_smooth_steer_direction(&ag, &dir)
	testing.expect(t, dir == [3]f32{0, 0, 0}, "smooth: zero out when no corners")
	dir = {1, 1, 1}
	calc_straight_steer_direction(&ag, &dir)
	testing.expect(t, dir == [3]f32{0, 0, 0}, "straight: zero out when no corners")
}

@(test)
test_get_distance_to_goal_clamps_to_range :: proc(t: ^testing.T) {
	ag: Crowd_Agent
	ag.ncorners = 0
	d := get_distance_to_goal(&ag, 5.0)
	testing.expect(t, d == 5.0, "no corners returns range")

	ag.ncorners = 1
	ag.corner_flags[0] = 0x02 // DT_STRAIGHTPATH_END
	ag.npos = {0, 0, 0}
	ag.corner_verts[0] = {2, 0, 0}
	d2 := get_distance_to_goal(&ag, 5.0)
	testing.expectf(t, math.abs(d2 - 2.0) < 1e-4, "expected 2, got %f", d2)
}

// ---------------------------------------------------------------
// Path queue (no nav mesh round-trip required for slot logic) ---
// ---------------------------------------------------------------

@(test)
test_obstacle_avoidance_query_capacity :: proc(t: ^testing.T) {
	q := create_obstacle_avoidance_query(2, 2)
	defer destroy_obstacle_avoidance_query(q)
	obstacle_avoidance_query_add_circle(q, {1, 0, 0}, 0.5, {0, 0, 0}, {0, 0, 0})
	obstacle_avoidance_query_add_circle(q, {2, 0, 0}, 0.5, {0, 0, 0}, {0, 0, 0})
	obstacle_avoidance_query_add_circle(q, {3, 0, 0}, 0.5, {0, 0, 0}, {0, 0, 0}) // dropped
	testing.expect(t, q.ncircles == 2, "circle cap must hold")
	obstacle_avoidance_query_add_segment(q, {0, 0, 0}, {1, 0, 0})
	obstacle_avoidance_query_add_segment(q, {1, 0, 0}, {2, 0, 0})
	obstacle_avoidance_query_add_segment(q, {2, 0, 0}, {3, 0, 0}) // dropped
	testing.expect(t, q.nsegments == 2, "segment cap must hold")
	obstacle_avoidance_query_reset(q)
	testing.expect(t, q.ncircles == 0 && q.nsegments == 0, "reset zeros counts")
}

// ---------------------------------------------------------------
// Crowd lifecycle + update with real navmesh ---------------------
// ---------------------------------------------------------------

build_test_navmesh :: proc(t: ^testing.T) -> (^detour.Nav_Mesh, bool) {
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
	defer recast.free_poly_mesh(pmesh)
	defer recast.free_poly_mesh_detail(dmesh)

	params := detour.Create_Nav_Mesh_Data_Params {
		poly_mesh        = pmesh,
		poly_mesh_detail = dmesh,
		walkable_height  = f32(cfg.walkable_height) * cfg.ch,
		walkable_radius  = f32(cfg.walkable_radius) * cfg.cs,
		walkable_climb   = f32(cfg.walkable_climb) * cfg.ch,
	}
	nav_mesh, status := detour.create_nav_mesh(&params)
	if !recast.status_succeeded(status) {
		testing.fail_now(t, "create_nav_mesh failed")
	}
	return nav_mesh, true
}

destroy_test_navmesh :: proc(nav: ^detour.Nav_Mesh) {
	detour.nav_mesh_destroy(nav)
	free(nav)
}

default_agent_params :: proc() -> Crowd_Agent_Params {
	return Crowd_Agent_Params {
		radius = 0.4,
		height = 1.8,
		max_acceleration = 8.0,
		max_speed = 3.5,
		collision_query_range = 4.0,
		path_optimization_range = 12.0,
		separation_weight = 2.0,
	}
}

@(test)
test_crowd_lifecycle_add_remove :: proc(t: ^testing.T) {
	nav, ok := build_test_navmesh(t)
	if !ok do return
	defer destroy_test_navmesh(nav)

	c, cok := create_crowd(8, 0.6, nav)
	testing.expect(t, cok, "create_crowd")
	defer destroy_crowd(c)

	params := default_agent_params()
	a0 := crowd_add_agent(c, {0, 0, 0}, &params)
	a1 := crowd_add_agent(c, {1, 0, 0}, &params)
	testing.expectf(t, a0 == 0 && a1 == 1, "expected sequential slots, got %d %d", a0, a1)

	ag := crowd_get_agent(c, a0)
	testing.expect(t, ag != nil && ag.active, "agent must be active after add")

	crowd_remove_agent(c, a0)
	testing.expect(t, !c.agents[a0].active, "agent must be inactive after remove")

	// reuse slot
	a2 := crowd_add_agent(c, {0, 0, 0}, &params)
	testing.expectf(t, a2 == a0, "slot should be recycled, got %d", a2)
}

@(test)
test_crowd_add_agent_off_navmesh_fails :: proc(t: ^testing.T) {
	nav, ok := build_test_navmesh(t)
	if !ok do return
	defer destroy_test_navmesh(nav)
	c, _ := create_crowd(4, 0.6, nav)
	defer destroy_crowd(c)

	params := default_agent_params()
	idx := crowd_add_agent(c, {1000, 0, 1000}, &params)
	testing.expect(t, idx == -1, "off-navmesh add should fail")
}

@(test)
test_crowd_request_move_target_state :: proc(t: ^testing.T) {
	nav, ok := build_test_navmesh(t)
	if !ok do return
	defer destroy_test_navmesh(nav)
	c, _ := create_crowd(4, 0.6, nav)
	defer destroy_crowd(c)
	params := default_agent_params()
	idx := crowd_add_agent(c, {0, 0, 0}, &params)
	testing.expect(t, idx >= 0, "agent add")

	// invalid index
	testing.expect(t, !crowd_request_move_target(c, -1, 1, {0, 0, 0}), "negative idx rejected")
	testing.expect(t, !crowd_request_move_target(c, idx, recast.INVALID_POLY_REF, {0, 0, 0}), "invalid ref rejected")

	// valid request: pick any first poly via nearest poly query
	filter: detour.Query_Filter
	detour.query_filter_init(&filter)
	half := [3]f32{2, 4, 2}
	st, ref, _ := detour.find_nearest_poly(c.nav_query, {3, 0, 3}, half, &filter)
	if recast.status_succeeded(st) && ref != recast.INVALID_POLY_REF {
		ok2 := crowd_request_move_target(c, idx, ref, {3, 0, 3})
		testing.expect(t, ok2, "valid request must succeed")
		testing.expect(t, c.agents[idx].target_state == .Requesting, "state should be Requesting")
	}
}

@(test)
test_crowd_update_advances_agent :: proc(t: ^testing.T) {
	nav, ok := build_test_navmesh(t)
	if !ok do return
	defer destroy_test_navmesh(nav)
	c, _ := create_crowd(4, 0.6, nav)
	defer destroy_crowd(c)

	params := default_agent_params()
	idx := crowd_add_agent(c, {-5, 0, -5}, &params)
	testing.expect(t, idx >= 0, "agent add")

	filter: detour.Query_Filter
	detour.query_filter_init(&filter)
	half := [3]f32{2, 4, 2}
	st, ref, _ := detour.find_nearest_poly(c.nav_query, {5, 0, 5}, half, &filter)
	if !recast.status_succeeded(st) do return
	crowd_request_move_target(c, idx, ref, {5, 0, 5})

	start_pos := c.agents[idx].npos
	// run several update ticks; path planning is sliced and may take several frames
	for _ in 0 ..< 50 {
		crowd_update(c, 0.1)
	}
	end_pos := c.agents[idx].npos
	moved_sq := (end_pos.x - start_pos.x) * (end_pos.x - start_pos.x) +
	            (end_pos.z - start_pos.z) * (end_pos.z - start_pos.z)
	testing.expectf(t, moved_sq > 0.0001, "agent should have moved, dx2+dz2=%f", moved_sq)
}

// ---------------------------------------------------------------
// Benchmarks ----------------------------------------------------
// ---------------------------------------------------------------

bench_proximity_grid_state :: struct {
	grid: ^Proximity_Grid,
	hits: int,
}

@(test)
bench_proximity_grid_query :: proc(t: ^testing.T) {
	state: bench_proximity_grid_state
	opts := time.Benchmark_Options {
		rounds   = 5000,
		setup    = proc(opts: ^time.Benchmark_Options, _: runtime.Allocator) -> time.Benchmark_Error {
			s := cast(^bench_proximity_grid_state)opts.user_data
			s.grid, _ = create_proximity_grid(1024, 1.0)
			proximity_grid_add_item(s.grid, 0xfffe, 0, 0, 31, 31)
			for i in 0 ..< 256 {
				x := f32(i % 16) + 0.5
				y := f32(i / 16) + 0.5
				proximity_grid_add_item(s.grid, u16(i), x - 0.4, y - 0.4, x + 0.4, y + 0.4)
			}
			return .Okay
		},
		bench    = proc(opts: ^time.Benchmark_Options, _: runtime.Allocator) -> time.Benchmark_Error {
			s := cast(^bench_proximity_grid_state)opts.user_data
			ids: [64]u16
			for _ in 0 ..< opts.rounds {
				s.hits += proximity_grid_query_items(s.grid, 0, 0, 8, 8, ids[:], 64)
			}
			opts.count = opts.rounds
			return .Okay
		},
		teardown = proc(opts: ^time.Benchmark_Options, _: runtime.Allocator) -> time.Benchmark_Error {
			s := cast(^bench_proximity_grid_state)opts.user_data
			destroy_proximity_grid(s.grid)
			return .Okay
		},
		user_data = &state,
	}
	err := time.benchmark(&opts)
	testing.expect(t, err == .Okay && state.hits > 0, "bench failed")
	log.infof("proximity_grid_query_items %d rounds in %v, %.0f rounds/sec (hits=%d)",
		opts.rounds, opts.duration, opts.rounds_per_second, state.hits)
}

bench_crowd_state :: struct {
	t:    ^testing.T,
	nav:  ^detour.Nav_Mesh,
	crowd: ^Crowd,
}

@(test)
bench_crowd_update :: proc(t: ^testing.T) {
	state := bench_crowd_state{t = t}
	opts := time.Benchmark_Options {
		rounds   = 200,
		setup    = proc(opts: ^time.Benchmark_Options, _: runtime.Allocator) -> time.Benchmark_Error {
			s := cast(^bench_crowd_state)opts.user_data
			nav, ok := build_test_navmesh(s.t)
			if !ok do return .Allocation_Error
			s.nav = nav
			N :: 32
			c, _ := create_crowd(N, 0.6, nav)
			s.crowd = c
			params := default_agent_params()
			for i in 0 ..< N {
				fi := f32(i)
				x := -8.0 + (fi * 0.5)
				z := -8.0 + (f32(i / 8) * 0.5)
				crowd_add_agent(c, {x, 0, z}, &params)
			}
			filter: detour.Query_Filter
			detour.query_filter_init(&filter)
			half := [3]f32{2, 4, 2}
			st, ref, _ := detour.find_nearest_poly(c.nav_query, {8, 0, 8}, half, &filter)
			if recast.status_succeeded(st) && ref != recast.INVALID_POLY_REF {
				for i in 0 ..< N {
					crowd_request_move_target(c, i, ref, {8, 0, 8})
				}
			}
			return .Okay
		},
		bench    = proc(opts: ^time.Benchmark_Options, _: runtime.Allocator) -> time.Benchmark_Error {
			s := cast(^bench_crowd_state)opts.user_data
			for _ in 0 ..< opts.rounds {
				crowd_update(s.crowd, 0.016)
			}
			opts.count = opts.rounds
			return .Okay
		},
		teardown = proc(opts: ^time.Benchmark_Options, _: runtime.Allocator) -> time.Benchmark_Error {
			s := cast(^bench_crowd_state)opts.user_data
			destroy_crowd(s.crowd)
			destroy_test_navmesh(s.nav)
			return .Okay
		},
		user_data = &state,
	}
	err := time.benchmark(&opts)
	testing.expect(t, err == .Okay, "bench failed")
	log.infof("crowd_update %d ticks in %v, %.0f ticks/sec",
		opts.rounds, opts.duration, opts.rounds_per_second)
}
