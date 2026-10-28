#+build !js
#+private
package navigation

import "detour"
import "base:runtime"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:testing"
import "core:time"

// ---------------------------------------------------------------
// Pure helpers (no nav mesh) ------------------------------------
// ---------------------------------------------------------------

// Note: proximity_grid wipes bucket heads on every bucket-array growth, so the
// only safe usage pattern is to seed the bounds with the largest item up-front
// (matches update which clears + readds every frame within stable bounds).
@(test)
test_proximity_grid_add_query :: proc(t: ^testing.T) {
	// Pool needs slack: sentinel covers (0..15)x(0..15)=256 cells, plus items.
	grid := &Proximity_Grid{}
	ok := proximity_grid_init(grid, 512, 1.0)
	testing.expect(t, ok, "grid create")
	defer proximity_grid_destroy(grid)

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
	grid := &Proximity_Grid{}
	proximity_grid_init(grid, 128, 1.0)
	defer proximity_grid_destroy(grid)
	proximity_grid_add_item(grid, 0xfffe, 0, 0, 7, 7)
	proximity_grid_add_item(grid, 5, 3.1, 3.1, 3.9, 3.9)
	c := proximity_grid_get_item_count_at(grid, 3, 3)
	testing.expectf(t, c >= 2, "expected at least 2 entries at (3,3), got %d", c)
	out := proximity_grid_get_item_count_at(grid, 100, 100)
	testing.expect(t, out == 0, "out-of-bounds returns 0")
}

@(test)
test_local_boundary_segment_sorted_by_distance :: proc(t: ^testing.T) {
	b := &Local_Boundary{}
	local_boundary_init(b)

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
	b := &Local_Boundary{}
	local_boundary_init(b)
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
test_add_neighbour_inserts_sorted :: proc(t: ^testing.T) {
	neis: [4]Neighbour
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
	path := [8]detour.Poly_Ref{1, 2, 3, 4, 0, 0, 0, 0}
	visited := [4]detour.Poly_Ref{10, 11, 2, 0}
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
	path := [4]detour.Poly_Ref{1, 2, 3, 4}
	visited := [3]detour.Poly_Ref{99, 98, 97}
	new_n := merge_corridor_start_shortcut(path[:], 4, 4, visited[:], 3)
	testing.expectf(t, new_n == 4, "no overlap should leave path untouched, got n=%d", new_n)
}

@(test)
test_merge_corridor_end_moved_extends_path :: proc(t: ^testing.T) {
	path := [8]detour.Poly_Ref{1, 2, 3, 4, 0, 0, 0, 0}
	visited := [4]detour.Poly_Ref{4, 5, 6, 7}
	new_n := merge_corridor_end_moved(path[:], 4, 8, visited[:], 4)
	testing.expectf(t, new_n == 7, "should extend to 7 entries, got %d", new_n)
	testing.expect(t, path[4] == 5 && path[5] == 6 && path[6] == 7, "extension polys missing")
}

@(test)
test_integrate_velocity_clamped_by_acceleration :: proc(t: ^testing.T) {
	ag: Agent
	ag.params.max_acceleration = 4.0
	ag.params.max_speed = 10.0
	ag.velocity = {0, 0, 0}
	ag.nvel = {10, 0, 0} // big request
	integrate(&ag, 0.5) // max delta = 4 * 0.5 = 2
	speed := math.sqrt(ag.velocity.x * ag.velocity.x + ag.velocity.z * ag.velocity.z)
	testing.expectf(t, math.abs(speed - 2.0) < 1e-4, "expected clamped speed=2, got %f", speed)

	// position must advance
	testing.expect(t, ag.position.x > 0, "position should move along velocity")
}

@(test)
test_integrate_zero_velocity_resets :: proc(t: ^testing.T) {
	ag: Agent
	ag.params.max_acceleration = 100.0
	ag.velocity = {0.00001, 0, 0}
	ag.nvel = {0, 0, 0}
	integrate(&ag, 0.016)
	testing.expect(t, ag.velocity == [3]f32{0, 0, 0}, "tiny velocity must zero out")
}

@(test)
test_calc_steer_directions_no_corners :: proc(t: ^testing.T) {
	ag: Agent
	ag.corner_count = 0
	dir: [3]f32 = {1, 1, 1}
	calc_smooth_steer_direction(&ag, &dir)
	testing.expect(t, dir == [3]f32{0, 0, 0}, "smooth: zero out when no corners")
	dir = {1, 1, 1}
	calc_straight_steer_direction(&ag, &dir)
	testing.expect(t, dir == [3]f32{0, 0, 0}, "straight: zero out when no corners")
}

@(test)
test_get_distance_to_goal_clamps_to_range :: proc(t: ^testing.T) {
	ag: Agent
	ag.corner_count = 0
	d := get_distance_to_goal(&ag, 5.0)
	testing.expect(t, d == 5.0, "no corners returns range")

	ag.corner_count = 1
	ag.corner_flags[0] = 0x02 // DT_STRAIGHTPATH_END
	ag.position = {0, 0, 0}
	ag.corners[0] = {2, 0, 0}
	d2 := get_distance_to_goal(&ag, 5.0)
	testing.expectf(t, math.abs(d2 - 2.0) < 1e-4, "expected 2, got %f", d2)
}

// ---------------------------------------------------------------
// Path queue (no nav mesh round-trip required for slot logic) ---
// ---------------------------------------------------------------

@(test)
test_obstacle_avoidance_query_capacity :: proc(t: ^testing.T) {
	q := &Obstacle_Avoidance_Query{}
	obstacle_avoidance_query_init(q, 2, 2)
	defer obstacle_avoidance_query_destroy(q)
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

// test_plane.navmesh is a 20x20 walkable plane centered at the origin, baked by navigation/bake
build_test_navmesh :: proc(t: ^testing.T) -> (^NavMesh, bool) {
	nav := new(NavMesh)
	if !navmesh_init(nav, #load("test_plane.navmesh")) do testing.fail_now(t, "loading the plane fixture failed")
	return nav, true
}

destroy_test_navmesh :: proc(nav: ^NavMesh) {
	destroy(nav)
	free(nav)
}

default_agent_params :: proc() -> AgentParams {
	return AgentParams {
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

	cv: Crowd
	c := &cv
	testing.expect(t, crowd_init(c, 8, 0.6, nav), "init")
	defer crowd_destroy(c)

	params := default_agent_params()
	a0, _ := agent_create(c, {0, 0, 0}, params)
	a1, _ := agent_create(c, {1, 0, 0}, params)
	testing.expectf(t, a0.index == 0 && a1.index == 1, "expected sequential slots, got %v %v", a0, a1)

	ag, ag_ok := agent(c, a0)
	testing.expect(t, ag_ok && ag.state != .INVALID, "agent must be active after add")

	agent_destroy(c, a0)
	testing.expect(t, c.agents[a0.index].state == .INVALID, "agent must be inactive after remove")

	// reuse slot
	a2, _ := agent_create(c, {0, 0, 0}, params)
	testing.expectf(t, a2.index == a0.index, "slot should be recycled, got %v", a2)
	_, stale := agent(c, a0)
	testing.expect(t, !stale, "the old handle must not reach the recycled slot")
}

@(test)
test_crowd_add_agent_off_navmesh_fails :: proc(t: ^testing.T) {
	nav, ok := build_test_navmesh(t)
	if !ok do return
	defer destroy_test_navmesh(nav)
	cv: Crowd
	c := &cv
	crowd_init(c, 4, 0.6, nav)
	defer crowd_destroy(c)

	params := default_agent_params()
	_, added := agent_create(c, {1000, 0, 1000}, params)
	testing.expect(t, !added, "off-navmesh add should fail")
}

@(test)
test_crowd_request_move_target_state :: proc(t: ^testing.T) {
	nav, ok := build_test_navmesh(t)
	if !ok do return
	defer destroy_test_navmesh(nav)
	cv: Crowd
	c := &cv
	crowd_init(c, 4, 0.6, nav)
	defer crowd_destroy(c)
	params := default_agent_params()
	idx, _ := agent_create(c, {0, 0, 0}, params)
	testing.expect(t, idx != {}, "agent add")

	// invalid index
	testing.expect(t, !request_move_target(c, -1, 1, {0, 0, 0}), "negative idx rejected")
	testing.expect(t, !request_move_target(c, int(idx.index), detour.INVALID_POLY_REF, {0, 0, 0}), "invalid ref rejected")

	// valid request: pick any first poly via nearest poly query
	filter: detour.Query_Filter
	detour.query_filter_init(&filter)
	half := [3]f32{2, 4, 2}
	st, ref, _ := detour.find_nearest_poly(&c.nav_query, {3, 0, 3}, half, &filter)
	if detour.status_succeeded(st) && ref != detour.INVALID_POLY_REF {
		ok2 := request_move_target(c, int(idx.index), ref, {3, 0, 3})
		testing.expect(t, ok2, "valid request must succeed")
		testing.expect(t, c.agents[idx.index].target_state == .Requesting, "state should be Requesting")
	}
}

@(test)
test_crowd_update_advances_agent :: proc(t: ^testing.T) {
	nav, ok := build_test_navmesh(t)
	if !ok do return
	defer destroy_test_navmesh(nav)
	cv: Crowd
	c := &cv
	crowd_init(c, 4, 0.6, nav)
	defer crowd_destroy(c)

	params := default_agent_params()
	idx, _ := agent_create(c, {-5, 0, -5}, params)
	testing.expect(t, idx != {}, "agent add")

	filter: detour.Query_Filter
	detour.query_filter_init(&filter)
	half := [3]f32{2, 4, 2}
	st, ref, _ := detour.find_nearest_poly(&c.nav_query, {5, 0, 5}, half, &filter)
	if !detour.status_succeeded(st) do return
	request_move_target(c, int(idx.index), ref, {5, 0, 5})

	start_pos := c.agents[idx.index].position
	// run several update ticks; path planning is sliced and may take several frames
	for _ in 0 ..< 50 {
		crowd_update(c, 0.1)
	}
	end_pos := c.agents[idx.index].position
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
			s.grid = new(Proximity_Grid)
			proximity_grid_init(s.grid, 1024, 1.0)
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
			proximity_grid_destroy(s.grid)
			free(s.grid)
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
	nav:  ^NavMesh,
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
			c := new(Crowd)
			crowd_init(c, N, 0.6, nav)
			s.crowd = c
			params := default_agent_params()
			for i in 0 ..< N {
				fi := f32(i)
				x := -8.0 + (fi * 0.5)
				z := -8.0 + (f32(i / 8) * 0.5)
				agent_create(c, {x, 0, z}, params)
			}
			filter: detour.Query_Filter
			detour.query_filter_init(&filter)
			half := [3]f32{2, 4, 2}
			st, ref, _ := detour.find_nearest_poly(&c.nav_query, {8, 0, 8}, half, &filter)
			if detour.status_succeeded(st) && ref != detour.INVALID_POLY_REF {
				for i in 0 ..< N {
					request_move_target(c, i, ref, {8, 0, 8})
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
			crowd_destroy(s.crowd)
			free(s.crowd)
			destroy_test_navmesh(s.nav)
			return .Okay
		},
		user_data = &state,
	}
	err := time.benchmark(&opts)
	testing.expect(t, err == .Okay, "bench failed")
	log.infof("update %d ticks in %v, %.0f ticks/sec",
		opts.rounds, opts.duration, opts.rounds_per_second)
}

@(test)
test_crowd_move_to_reaches_goal :: proc(t: ^testing.T) {
	nav, ok := build_test_navmesh(t)
	if !ok do return
	defer destroy_test_navmesh(nav)
	cv: Crowd
	c := &cv
	crowd_init(c, 4, 0.6, nav)
	defer crowd_destroy(c)
	params := default_agent_params()
	idx, _ := agent_create(c, {0, 0, 0}, params)
	testing.expect(t, move_to(c, idx, {5, 0, 5}), "move_to on the mesh must succeed")
	for _ in 0 ..< 100 do crowd_update(c, 0.1)
	d := c.agents[idx.index].position - {5, 0, 5}
	testing.expectf(t, d.x * d.x + d.z * d.z < 1.0, "agent should reach the goal, at %v", c.agents[idx.index].position)
}

@(test)
test_crowd_stop_halts_agent :: proc(t: ^testing.T) {
	nav, ok := build_test_navmesh(t)
	if !ok do return
	defer destroy_test_navmesh(nav)
	cv: Crowd
	c := &cv
	crowd_init(c, 4, 0.6, nav)
	defer crowd_destroy(c)
	idx, _ := agent_create(c, {-5, 0, 0}, default_agent_params())
	move_to(c, idx, {5, 0, 0})
	for _ in 0 ..< 10 do crowd_update(c, 0.1)
	stop(c, idx)
	for _ in 0 ..< 30 do crowd_update(c, 0.1)
	halted := c.agents[idx.index].position
	for _ in 0 ..< 10 do crowd_update(c, 0.1)
	d := c.agents[idx.index].position - halted
	testing.expectf(t, d.x * d.x + d.z * d.z < 0.01, "a stopped agent should stay put, moved %v", d)
	testing.expectf(t, halted.x < 4, "a stopped agent should not reach its old goal, at %v", halted)
}

@(test)
test_crowd_agent_poses_links_users :: proc(t: ^testing.T) {
	nav, ok := build_test_navmesh(t)
	if !ok do return
	defer destroy_test_navmesh(nav)
	cv: Crowd
	c := &cv
	crowd_init(c, 4, 0.6, nav)
	defer crowd_destroy(c)
	linked, _ := agent_create(c, {0, 0, 0}, default_agent_params(), user = {index = 7, generation = 1})
	unlinked, _ := agent_create(c, {3, 0, 3}, default_agent_params())
	move_to(c, linked, {0, 0, 5})
	for _ in 0 ..< 10 do crowd_update(c, 0.1)
	poses := agent_poses(c)
	testing.expect_value(t, len(poses), 2)
	testing.expect_value(t, poses[0].user, Handle{index = 7, generation = 1})
	testing.expect(t, poses[0].agent == linked && poses[1].agent == unlinked, "every agent has a pose, by handle")
	testing.expect_value(t, poses[0].position, c.agents[linked.index].position)
	forward := linalg.quaternion_mul_vector3(poses[0].rotation, [3]f32{0, 0, 1})
	testing.expectf(t, forward.z > 0.9, "heading should turn +Z towards +Z travel, got %v", forward)
}

// Neighbours are active-list entries: once a destroyed agent leaves a hole in the slots, the
// survivors must still separate from each other, not from the dead slot.
@(test)
test_crowd_separation_after_destroy :: proc(t: ^testing.T) {
	nav, ok := build_test_navmesh(t)
	if !ok do return
	defer destroy_test_navmesh(nav)
	cv: Crowd
	c := &cv
	testing.expect(t, crowd_init(c, 4, 0.6, nav), "init")
	defer crowd_destroy(c)
	params := default_agent_params()
	params.update_flags = {.SEPARATION}
	dead, _ := agent_create(c, {-8, 0, 0}, params)
	a, _ := agent_create(c, {2, 0, 0}, params)
	b, _ := agent_create(c, {2.3, 0, 0}, params)
	agent_destroy(c, dead)
	for _ in 0 ..< 30 do crowd_update(c, 1.0 / 30)
	pa, _ := agent(c, a)
	pb, _ := agent(c, b)
	testing.expectf(t, pb.position.x - pa.position.x > 0.4, "the two live agents must push apart, got %v and %v", pa.position, pb.position)
}

@(test)
test_crowd_place_and_steer :: proc(t: ^testing.T) {
	nav, ok := build_test_navmesh(t)
	if !ok do return
	defer destroy_test_navmesh(nav)
	cv: Crowd
	c := &cv
	crowd_init(c, 4, 0.6, nav)
	defer crowd_destroy(c)
	a, _ := agent_create(c, {0, 0, 0}, default_agent_params())
	testing.expect(t, agent_place(c, a, {5, 0, 5}), "teleport on the mesh")
	testing.expect(t, linalg.distance(agent(c, a).position.xz, [2]f32{5, 5}) < 0.1, "placed where asked")
	testing.expect(t, agent_steer(c, a, {0, 0, -2}), "steer")
	for _ in 0 ..< 10 do crowd_update(c, 0.1)
	testing.expectf(t, agent(c, a).position.z < 4, "a steered agent moves along its velocity, at %v", agent(c, a).position)
}

// Area costs live on the NavMesh: a filter that blocks every area finds no path.
@(test)
test_navmesh_filters_decide_paths :: proc(t: ^testing.T) {
	nav, ok := build_test_navmesh(t)
	if !ok do return
	defer destroy_test_navmesh(nav)
	path := find_path(nav, {-8, 0, -8}, {8, 0, 8}, allocator = context.temp_allocator)
	testing.expect(t, len(path) > 0, "filter 0 walks the plane")
	nav.filters[1].include_flags = 0
	blocked := find_path(nav, {-8, 0, -8}, {8, 0, 8}, filter = 1, allocator = context.temp_allocator)
	testing.expect(t, len(blocked) == 0, "a filter excluding every polygon finds nothing")
}
