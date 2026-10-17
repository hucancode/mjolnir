package crowd

import "core:math"
import "core:math/linalg"
import "../detour"

@(private = "file")
DT_CROWDAGENT_MAX_NEIGHBOURS :: 6
// MAX_CORNERS is the number of steering corners cached per agent.
MAX_CORNERS :: 4
@(private = "file")
DT_CROWD_MAX_OBSTAVOIDANCE_PARAMS :: 8
@(private = "file")
DT_CROWD_MAX_QUERY_FILTER_TYPE :: 16

@(private = "file")
MAX_ITERS_PER_UPDATE :: 100
@(private = "file")
MAX_PATHQUEUE_NODES :: 4096

@(private)
Neighbour :: struct {
	idx:  int,
	dist: f32,
}

// AgentState is the agent's navmesh traversal state; INVALID marks a free slot.
AgentState :: enum u8 {
	INVALID,
	WALKING,
	OFFMESH,
}

// AgentParams holds an agent's size, speed limits, query ranges and behavior flags.
AgentParams :: struct {
	radius:                   f32,
	height:                   f32,
	max_acceleration:         f32,
	max_speed:                f32,
	collision_query_range:    f32,
	path_optimization_range:  f32,
	separation_weight:        f32,
	update_flags:             UpdateFlagSet,
	obstacle_avoidance_type:  u8,
	query_filter_type:        u8,
	user_data:                rawptr,
}

// DEFAULT_AGENT_PARAMS is the humanoid-scale default used by agent_create.
DEFAULT_AGENT_PARAMS :: AgentParams {
	radius                  = 0.6,
	height                  = 2.0,
	max_acceleration        = 8.0,
	max_speed               = 3.5,
	collision_query_range   = 0.6 * 12,
	path_optimization_range = 0.6 * 30,
	separation_weight       = 2.0,
	update_flags            = {.ANTICIPATE_TURNS, .OBSTACLE_AVOIDANCE, .SEPARATION, .OPTIMIZE_VIS},
}

// UpdateFlags selects optional per-agent steering behaviors.
UpdateFlags :: enum u8 {
	ANTICIPATE_TURNS    = 0,
	OBSTACLE_AVOIDANCE  = 1,
	SEPARATION          = 2,
	OPTIMIZE_VIS        = 3,
	OPTIMIZE_TOPO       = 4,
}

// UpdateFlagSet is the set of UpdateFlags stored in AgentParams.
UpdateFlagSet :: bit_set[UpdateFlags; u8]

@(private = "file")
Move_Request_State :: enum u8 {
	None = 0,
	Failed,
	Valid,
	Requesting,
	Waiting_For_Queue,
	Waiting_For_Path,
	Velocity,
}

// AgentHandle identifies an agent of a crowd (agent_create).
AgentHandle :: distinct u32

// Agent is one crowd member: its position npos, velocity vel, the next corners of its path
// (corner_verts[:ncorners]) and its goal target_pos.
Agent :: struct {
	state:              AgentState,
	npos:               [3]f32,
	vel:                [3]f32,
	params:             AgentParams,
	corner_verts:       [MAX_CORNERS][3]f32,
	ncorners:           int,
	target_pos:         [3]f32,
	using _: Agent_Internal,
}

@(private)
Agent_Internal :: struct {
	partial:            bool,
	corridor:           ^Path_Corridor,
	boundary:           ^Local_Boundary,
	topology_opt_time:  f32,
	neis:               [DT_CROWDAGENT_MAX_NEIGHBOURS]Neighbour,
	nneis:              int,
	desired_speed:      f32,
	disp:               [3]f32,
	dvel:               [3]f32,
	nvel:               [3]f32,
	corner_flags:       [MAX_CORNERS]u8,
	corner_polys:       [MAX_CORNERS]detour.Poly_Ref,
	target_state:       Move_Request_State,
	target_ref:         detour.Poly_Ref,
	target_pathq_ref:   Path_Queue_Ref,
	target_replan:      bool,
	target_replan_time: f32,
}

// Crowd simulates many agents navigating one shared NavMesh.
Crowd :: struct {
	max_agents:                int,
	using _: Crowd_State,
}

@(private)
Crowd_State :: struct {
	// indexed by agent index; update moves them (agent reads a copy)
	agents:                    []Agent,
	active_agents:             []^Agent,
	path_queue:                ^Path_Queue,
	obstacle_query_params:     [DT_CROWD_MAX_OBSTAVOIDANCE_PARAMS]Obstacle_Avoidance_Params,
	obstacle_query:            ^Obstacle_Avoidance_Query,
	grid:                      ^Proximity_Grid,
	path_result:               []detour.Poly_Ref,
	max_path_result:           int,
	agent_placement_half_extents: [3]f32,
	filters:                   [DT_CROWD_MAX_QUERY_FILTER_TYPE]detour.Query_Filter,
	max_agent_radius:          f32,
	velocity_sample_count:     int,
	nav_query:                 ^detour.Nav_Mesh_Query,
}

// init prepares crowd for up to max_agents agents on nav (a navigation.NavMesh's
// detour_mesh), which must outlive the crowd. Paired with destroy.
init :: proc(self: ^Crowd, max_agents: int, max_agent_radius: f32, nav: ^detour.Nav_Mesh,
             allocator := context.allocator) -> bool {
	context.allocator = allocator
	self^ = {}

	self.max_agents = max_agents
	self.max_agent_radius = max_agent_radius
	self.agent_placement_half_extents = {max_agent_radius*2.0, max_agent_radius*1.5, max_agent_radius*2.0}

	grid, grid_ok := create_proximity_grid(max_agents*4, max_agent_radius*3)
	if !grid_ok {
		return false
	}
	self.grid = grid

	self.obstacle_query = create_obstacle_avoidance_query(6, 8)

	ok: bool
	self.path_queue, ok = create_path_queue(detour.DEFAULT_MAX_PATH, MAX_PATHQUEUE_NODES, nav)
	if !ok {
		destroy_proximity_grid(grid)
		destroy_obstacle_avoidance_query(self.obstacle_query)
		return false
	}

	self.agents = make([]Agent, max_agents)
	for i in 0..<max_agents {
		ag := &self.agents[i]
		ag.corridor, _ = create_path_corridor(detour.DEFAULT_MAX_PATH)
		ag.boundary = create_local_boundary()
	}

	self.active_agents = make([]^Agent, max_agents)

	self.max_path_result = 256
	self.path_result = make([]detour.Poly_Ref, self.max_path_result)

	for i in 0..<DT_CROWD_MAX_QUERY_FILTER_TYPE {
		detour.query_filter_init(&self.filters[i])
	}

	params := Obstacle_Avoidance_Params{
		vel_bias = 0.4,
		weight_des_vel = 2.0,
		weight_cur_vel = 0.75,
		weight_side = 0.75,
		weight_toi = 2.5,
		horiz_time = 2.5,
		grid_size = 33,
		adaptive_divs = 7,
		adaptive_rings = 2,
		adaptive_depth = 5,
	}
	for i in 0..<DT_CROWD_MAX_OBSTAVOIDANCE_PARAMS {
		self.obstacle_query_params[i] = params
	}

	self.nav_query = new(detour.Nav_Mesh_Query)
	status := detour.nav_mesh_query_init(self.nav_query, nav, MAX_PATHQUEUE_NODES)
	if detour.status_failed(status) {
		shutdown(self)
		return false
	}

	return true
}

// shutdown frees all agent state.
shutdown :: proc(self: ^Crowd) {
	for i in 0..<self.max_agents {
		ag := &self.agents[i]
		destroy_path_corridor(ag.corridor)
		destroy_local_boundary(ag.boundary)
	}

	delete(self.agents)
	delete(self.active_agents)
	delete(self.path_result)

	destroy_proximity_grid(self.grid)
	destroy_obstacle_avoidance_query(self.obstacle_query)
	destroy_path_queue(self.path_queue)
	detour.nav_mesh_query_destroy(self.nav_query)
	free(self.nav_query)
	self^ = {}
}

// agent_create places a new agent at the mesh point nearest pos and returns its handle; false when
// the crowd is full or pos is off the mesh.
agent_create :: proc(self: ^Crowd, pos: [3]f32, params := DEFAULT_AGENT_PARAMS) -> (agent: AgentHandle, ok: bool) {
	idx := -1
	for i in 0..<self.max_agents {
		if self.agents[i].state == .INVALID {
			idx = i
			break
		}
	}

	if idx == -1 do return 0, false

	ag := &self.agents[idx]
	ag.state = .WALKING
	ag.params = params

	nearest_status, nearest_ref, nearest_pt := detour.find_nearest_poly(self.nav_query, pos,
	                                                                      self.agent_placement_half_extents,
	                                                                      &self.filters[ag.params.query_filter_type])
	if detour.status_failed(nearest_status) || nearest_ref == detour.INVALID_POLY_REF {
		ag.state = .INVALID
		return 0, false
	}

	path_corridor_reset(ag.corridor, nearest_ref, nearest_pt)
	ag.boundary.center = {math.F32_MAX, math.F32_MAX, math.F32_MAX}
	ag.boundary.nsegs = 0

	ag.topology_opt_time = 0
	ag.target_state = .None

	ag.npos = nearest_pt
	ag.desired_speed = 0
	ag.nvel = {0, 0, 0}
	ag.vel = {0, 0, 0}

	return AgentHandle(idx), true
}

// agent_destroy deactivates the agent, freeing its slot.
agent_destroy :: proc(self: ^Crowd, handle: AgentHandle) {
	idx := int(handle)
	if idx >= self.max_agents do return
	self.agents[idx].state = .INVALID
}

@(private)
request_move_target :: proc(self: ^Crowd, idx: int, ref: detour.Poly_Ref, pos: [3]f32) -> bool {
	if idx < 0 || idx >= self.max_agents do return false
	if ref == detour.INVALID_POLY_REF do return false

	ag := &self.agents[idx]
	if ag.state == .INVALID do return false

	ag.target_ref = ref
	ag.target_pos = pos
	ag.target_pathq_ref = PATHQ_INVALID
	ag.target_state = .Requesting
	ag.target_replan = false

	return true
}

// move_to snaps pos to the mesh within extents and sets it as the agent's goal.
move_to :: proc(self: ^Crowd, handle: AgentHandle, pos: [3]f32, extents: [3]f32 = {2, 4, 2}) -> bool {
	idx := int(handle)
	if idx >= self.max_agents do return false
	filter := &self.filters[self.agents[idx].params.query_filter_type]
	status, ref, snapped := detour.find_nearest_poly(self.nav_query, pos, extents, filter)
	if detour.status_failed(status) do return false
	return request_move_target(self, idx, ref, snapped)
}

// update advances every active agent by dt seconds.
update :: proc(self: ^Crowd, dt: f32) {
	self.velocity_sample_count = 0

	nactive := 0
	for i in 0..<self.max_agents {
		ag := &self.agents[i]
		if ag.state == .INVALID do continue
		self.active_agents[nactive] = ag
		nactive += 1
	}

	update_move_request(self, dt)
	update_topology_optimization(self, self.active_agents[:nactive], dt)

	proximity_grid_clear(self.grid)
	for i in 0..<nactive {
		ag := self.active_agents[i]
		p := ag.npos
		r := ag.params.radius
		proximity_grid_add_item(self.grid, u16(i), p.x-r, p.z-r, p.x+r, p.z+r)
	}

	for i in 0..<nactive {
		ag := self.active_agents[i]

		if ag.state != .WALKING do continue

		ag.disp = {0, 0, 0}
		ag.dvel = {0, 0, 0}

		ag.ncorners = path_corridor_find_corners(ag.corridor, ag.corner_verts[:], ag.corner_flags[:],
		                                          ag.corner_polys[:], MAX_CORNERS,
		                                          self.nav_query,
		                                          &self.filters[ag.params.query_filter_type])

		ag.nneis = get_neighbours(ag.npos, ag.params.height, ag.params.collision_query_range,
		                          ag, ag.neis[:], DT_CROWDAGENT_MAX_NEIGHBOURS,
		                          self.active_agents[:nactive], self.grid)

		if .ANTICIPATE_TURNS in ag.params.update_flags {
			calc_smooth_steer_direction(ag, &ag.dvel)
		} else {
			calc_straight_steer_direction(ag, &ag.dvel)
		}

		distance_to_goal := get_distance_to_goal(ag, ag.params.collision_query_range)
		ag.desired_speed = ag.params.max_speed

		if distance_to_goal < ag.params.collision_query_range {
			ag.desired_speed *= distance_to_goal / ag.params.collision_query_range
		}

		if linalg.length2(ag.dvel.xz) > 0.0001 {
			ag.dvel = linalg.normalize(ag.dvel) * ag.desired_speed
		}
	}

	for i in 0..<nactive {
		ag := self.active_agents[i]

		if ag.state != .WALKING do continue

		if .SEPARATION in ag.params.update_flags {
			separation_distance := ag.params.collision_query_range
			inv_separation_distance := 1.0 / separation_distance

			sep_vector := [3]f32{0, 0, 0}
			n_sep := 0

			for j in 0..<ag.nneis {
				nei := &self.agents[ag.neis[j].idx]
				diff := ag.npos - nei.npos
				diff.y = 0

				dist_sq := linalg.length2(diff)
				if dist_sq < 0.00001 do continue
				if dist_sq > separation_distance * separation_distance do continue

				dist := math.sqrt(dist_sq)
				weight := ag.params.separation_weight * (1.0 - (dist * inv_separation_distance))
				sep_vector += diff / dist * weight
				n_sep += 1
			}

			if n_sep > 0 {
				sep_vector /= f32(n_sep)
				ag.dvel += sep_vector
			}
		}
	}

	for i in 0..<nactive {
		ag := self.active_agents[i]

		if ag.state != .WALKING do continue

		ag.nvel = ag.dvel

		if .OBSTACLE_AVOIDANCE in ag.params.update_flags {
			obstacle_avoidance_query_reset(self.obstacle_query)

			for j in 0..<ag.nneis {
				nei := &self.agents[ag.neis[j].idx]
				obstacle_avoidance_query_add_circle(self.obstacle_query, nei.npos,
				                                    nei.params.radius, nei.vel, nei.dvel)
			}

			for j in 0..<ag.boundary.nsegs {
				s := local_boundary_get_segment(ag.boundary, j)
				p0 := [3]f32{s[0], s[1], s[2]}
				p1 := [3]f32{s[3], s[4], s[5]}
				range_sq := ag.params.collision_query_range * ag.params.collision_query_range
				if linalg.length2(p0.xz - ag.npos.xz) < range_sq {
					obstacle_avoidance_query_add_segment(self.obstacle_query, p0, p1)
				}
			}

			avo_params := &self.obstacle_query_params[ag.params.obstacle_avoidance_type]
			self.velocity_sample_count += obstacle_avoidance_sample_velocity_adaptive(
				self.obstacle_query, ag.npos, ag.params.radius, ag.desired_speed,
				ag.vel, ag.dvel, &ag.nvel, avo_params, nil)
		}
	}

	for i in 0..<nactive {
		ag := self.active_agents[i]

		if ag.state != .WALKING do continue

		integrate(ag, dt)

		filter := &self.filters[ag.params.query_filter_type]
		path_corridor_move_position(ag.corridor, ag.npos, self.nav_query, filter)

		ag.ncorners = path_corridor_find_corners(ag.corridor, ag.corner_verts[:], ag.corner_flags[:],
		                                          ag.corner_polys[:], MAX_CORNERS,
		                                          self.nav_query, filter)

		if .OPTIMIZE_VIS in ag.params.update_flags && ag.ncorners > 0 {
			target := ag.corner_verts[min(1, ag.ncorners-1)]
			path_corridor_optimize_path_visibility(ag.corridor, target,
			                                        ag.params.path_optimization_range,
			                                        self.nav_query, filter)
		}

		local_boundary_update(ag.boundary, path_corridor_get_first_poly(ag.corridor),
		                      ag.npos, ag.params.collision_query_range,
		                      self.nav_query, filter)
	}

	path_queue_update(self.path_queue, MAX_ITERS_PER_UPDATE)
}

@(private = "file")
update_move_request :: proc(self: ^Crowd, dt: f32) {
	PATH_MAX_AGENTS :: 8
	queue: [PATH_MAX_AGENTS]^Agent
	nqueue := 0

	for i in 0..<self.max_agents {
		ag := &self.agents[i]
		if ag.state == .INVALID do continue
		if ag.target_state == .None || ag.target_state == .Velocity do continue

		if ag.target_state == .Requesting {
			filter := &self.filters[ag.params.query_filter_type]
			ag.target_pathq_ref = path_queue_request(self.path_queue,
			                                         path_corridor_get_last_poly(ag.corridor),
			                                         ag.target_ref,
			                                         path_corridor_get_target(ag.corridor),
			                                         ag.target_pos, filter)

			if ag.target_pathq_ref != PATHQ_INVALID {
				ag.target_state = .Waiting_For_Queue
			}
		}

		if ag.target_state == .Waiting_For_Queue {
			status := path_queue_get_request_status(self.path_queue, ag.target_pathq_ref)
			if detour.status_failed(status) {
				ag.target_pathq_ref = PATHQ_INVALID
				ag.target_state = .Failed
				continue
			} else if detour.status_succeeded(status) {
				ag.target_state = .Waiting_For_Path
				continue
			}
		}

		if ag.target_state == .Waiting_For_Path {
			npath, status := path_queue_get_path_result(self.path_queue, ag.target_pathq_ref,
			                                            self.path_result)
			ag.target_pathq_ref = PATHQ_INVALID

			if detour.status_failed(status) || npath <= 0 {
				ag.target_state = .Failed
				continue
			}

			path_corridor_set_corridor(ag.corridor, ag.target_pos, self.path_result[:npath])
			ag.target_state = .Valid
			ag.target_replan = false
			ag.target_replan_time = 0
		}
	}
}

@(private = "file")
update_topology_optimization :: proc(self: ^Crowd, agents: []^Agent, dt: f32) {
	MAX_NEIS :: 32
	queue: [MAX_NEIS]^Agent
	nqueue := 0

	for i in 0..<len(agents) {
		ag := agents[i]
		if ag.state != .WALKING do continue
		if ag.target_state != .Valid do continue
		if .OPTIMIZE_TOPO not_in ag.params.update_flags do continue

		ag.topology_opt_time += dt
		if ag.topology_opt_time >= 0.5 && nqueue < MAX_NEIS {
			queue[nqueue] = ag
			nqueue += 1
		}
	}

	for i in 0..<min(nqueue, 10) {
		ag := queue[i]
		ag.topology_opt_time = 0

		filter := &self.filters[ag.params.query_filter_type]
		path_corridor_optimize_path_topology(ag.corridor, self.nav_query, filter)
	}
}

@(private)
integrate :: proc(ag: ^Agent, dt: f32) {
	max_delta := ag.params.max_acceleration * dt
	dv := ag.nvel - ag.vel
	ds := linalg.length(dv)
	if ds > max_delta {
		dv = dv * (max_delta / ds)
	}
	ag.vel += dv

	if linalg.length(ag.vel) > 0.0001 {
		ag.npos += ag.vel * dt
	} else {
		ag.vel = {0, 0, 0}
	}
}

@(private)
calc_smooth_steer_direction :: proc(ag: ^Agent, dir: ^[3]f32) {
	if ag.ncorners == 0 {
		dir^ = {0, 0, 0}
		return
	}

	ip0 := 0
	ip1 := min(1, ag.ncorners - 1)
	p0 := ag.corner_verts[ip0]
	p1 := ag.corner_verts[ip1]

	dir0 := p0 - ag.npos
	dir1 := p1 - ag.npos
	dir0.y = 0
	dir1.y = 0

	len0 := linalg.length(dir0)
	len1 := linalg.length(dir1)
	if len1 > 0.001 {
		dir1 = linalg.normalize(dir1)
	}

	dir^ = dir0 - dir1 * len0 * 0.5
	dir.y = 0
	dir^ = linalg.normalize(dir^)
}

@(private)
calc_straight_steer_direction :: proc(ag: ^Agent, dir: ^[3]f32) {
	if ag.ncorners == 0 {
		dir^ = {0, 0, 0}
		return
	}
	dir^ = ag.corner_verts[0] - ag.npos
	dir.y = 0
	dir^ = linalg.normalize(dir^)
}

@(private)
get_distance_to_goal :: proc(ag: ^Agent, range: f32) -> f32 {
	if ag.ncorners == 0 do return range

	DT_STRAIGHTPATH_END :: 0x02
	end_of_path := (ag.corner_flags[ag.ncorners-1] & DT_STRAIGHTPATH_END) != 0
	if end_of_path {
		dist_sq := linalg.length2(ag.corner_verts[ag.ncorners-1].xz - ag.npos.xz)
		range_sq := range * range
		if dist_sq < range_sq {
			return math.sqrt(dist_sq)
		}
		return range
	}

	return range
}

@(private = "file")
get_neighbours :: proc(pos: [3]f32, height: f32, range: f32, skip: ^Agent,
                       result: []Neighbour, max_result: int,
                       agents: []^Agent, grid: ^Proximity_Grid) -> int {
	MAX_NEIS :: 32
	ids: [MAX_NEIS]u16

	nids := proximity_grid_query_items(grid, pos.x-range, pos.z-range, pos.x+range, pos.z+range,
	                                   ids[:], MAX_NEIS)

	n := 0
	for i in 0..<nids {
		ag := agents[ids[i]]

		if ag == skip do continue

		diff := pos - ag.npos
		if math.abs(diff.y) >= (height + ag.params.height) / 2.0 do continue

		diff.y = 0
		dist_sq := linalg.length2(diff)
		if dist_sq > range * range do continue

		n = add_neighbour(int(ids[i]), dist_sq, result, n, max_result)
	}

	return n
}

@(private)
add_neighbour :: proc(idx: int, dist: f32, neis: []Neighbour, nneis: int, max_neis: int) -> int {
	if nneis == 0 {
		neis[0] = {idx, dist}
		return 1
	}

	if dist >= neis[nneis-1].dist {
		if nneis >= max_neis do return nneis
		neis[nneis] = {idx, dist}
		return nneis + 1
	}
	insert_idx := 0
	for i in 0..<nneis {
		if dist <= neis[i].dist {
			insert_idx = i
			break
		}
	}
	n := min(nneis - insert_idx, max_neis - insert_idx - 1)
	if n > 0 {
		for j := nneis - 1; j >= insert_idx; j -= 1 {
			if insert_idx + (j - insert_idx) + 1 < max_neis {
				neis[insert_idx + (j - insert_idx) + 1] = neis[j]
			}
		}
	}
	neis[insert_idx] = {idx, dist}
	return min(nneis + 1, max_neis)
}

// agent returns a copy of the agent; false when the handle is out of range or destroyed.
// update moves it; give it a goal with move_to and tune it through agent_params.
agent :: proc(self: ^Crowd, handle: AgentHandle) -> (ag: Agent, ok: bool) #optional_ok {
	if int(handle) >= self.max_agents || self.agents[handle].state == .INVALID do return
	return self.agents[handle], true
}

// agent_params returns the agent's parameters, to edit in place; update only reads them.
agent_params :: proc(self: ^Crowd, handle: AgentHandle) -> (params: ^AgentParams, ok: bool) #optional_ok {
	if int(handle) >= self.max_agents || self.agents[handle].state == .INVALID do return
	return &self.agents[handle].params, true
}

// filter returns the query filter agents use for query_filter_type i; false if out of range.
filter :: proc(self: ^Crowd, i: int) -> (^detour.Query_Filter, bool) #optional_ok {
	if i < 0 || i >= DT_CROWD_MAX_QUERY_FILTER_TYPE do return nil, false
	return &self.filters[i], true
}

// destroy frees an agent, as agent_destroy does.
destroy :: proc {
	agent_destroy,
}
