package navigation

import "core:math"
import "core:math/linalg"
import "../containers"
import "detour"

@(private = "file")
DT_CROWDAGENT_MAX_NEIGHBOURS :: 6
// MAX_CORNERS is the number of steering corners cached per agent.
MAX_CORNERS :: 4
@(private = "file")
DT_CROWD_MAX_OBSTAVOIDANCE_PARAMS :: 8

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
	// the NavMesh.filters entry its paths and queries use
	query_filter_type:        u8,
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

// AgentHandle identifies an agent of a crowd (agent_create); stale after agent_destroy.
AgentHandle :: distinct containers.Handle

// Handle is the caller link an agent carries (Agent.user), e.g. the scene node it moves.
Handle :: containers.Handle

// Agent is one crowd member: where it is, how fast it moves, the next corners of its path
// (corners[:corner_count]), its goal and its caller link.
Agent :: struct {
	state:              AgentState,
	position:           [3]f32,
	velocity:           [3]f32,
	params:             AgentParams,
	corners:            [MAX_CORNERS][3]f32,
	corner_count:       int,
	target:             [3]f32,
	user:               Handle,
	using _: Agent_Internal,
}

// AgentPose is an agent's position on the mesh and its heading, turning +Z towards where it
// last moved, together with its handle and user link.
AgentPose :: struct {
	agent:    AgentHandle,
	user:     Handle,
	position: [3]f32,
	rotation: quaternion128,
}

@(private)
Agent_Internal :: struct {
	partial:            bool,
	corridor:           Path_Corridor,
	boundary:           Local_Boundary,
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
	// yaw of the last velocity fast enough to face (agent_poses)
	heading:            f32,
}

// Crowd simulates many agents navigating one shared NavMesh.
Crowd :: struct {
	using _: Crowd_State,
}

@(private)
Crowd_State :: struct {
	// which agent indices are live; index 0 is never handed out
	slots:                     containers.Slots,
	// indexed by agent index; crowd_update moves them (agent reads a copy)
	agents:                    []Agent,
	// every agent's corridor path, DEFAULT_MAX_PATH each
	corridor_paths:            []detour.Poly_Ref,
	path_queue:                Path_Queue,
	obstacle_query_params:     [DT_CROWD_MAX_OBSTAVOIDANCE_PARAMS]Obstacle_Avoidance_Params,
	obstacle_query:            Obstacle_Avoidance_Query,
	grid:                      Proximity_Grid,
	path_result:               []detour.Poly_Ref,
	agent_placement_half_extents: [3]f32,
	// the mesh the crowd walks, which outlives it: its filters
	navmesh:                   ^NavMesh,
	max_agent_radius:          f32,
	velocity_sample_count:     int,
	nav_query:                 detour.Nav_Mesh_Query,
	// agent_poses' result
	poses:                     [dynamic]AgentPose,
}

// crowd_init prepares the crowd for up to max_agents agents on navmesh, which must outlive the
// crowd. The crowd must not move after crowd_init; free it with crowd_destroy.
crowd_init :: proc(self: ^Crowd, max_agents: int, max_agent_radius: f32, navmesh: ^NavMesh,
             allocator := context.allocator) -> bool {
	context.allocator = allocator
	nav := &navmesh.detour_mesh
	self^ = {}
	self.navmesh = navmesh

	containers.slots_init(&self.slots, u32(max_agents) + 1)
	self.max_agent_radius = max_agent_radius
	self.agent_placement_half_extents = {max_agent_radius*2.0, max_agent_radius*1.5, max_agent_radius*2.0}

	obstacle_avoidance_query_init(&self.obstacle_query, 6, 8)
	if !proximity_grid_init(&self.grid, max_agents*4, max_agent_radius*3) ||
	   !path_queue_init(&self.path_queue, detour.DEFAULT_MAX_PATH, MAX_PATHQUEUE_NODES, nav) {
		crowd_destroy(self)
		return false
	}

	self.agents = make([]Agent, max_agents + 1)
	self.corridor_paths = make([]detour.Poly_Ref, len(self.agents) * detour.DEFAULT_MAX_PATH)
	for &ag, i in self.agents {
		path_corridor_init(&ag.corridor, self.corridor_paths[i * detour.DEFAULT_MAX_PATH:][:detour.DEFAULT_MAX_PATH])
		local_boundary_init(&ag.boundary)
	}

	self.path_result = make([]detour.Poly_Ref, 256)

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

	status := detour.nav_mesh_query_init(&self.nav_query, nav, MAX_PATHQUEUE_NODES)
	if detour.status_failed(status) {
		crowd_destroy(self)
		return false
	}

	return true
}

// crowd_destroy frees all agent state.
crowd_destroy :: proc(self: ^Crowd) {
	containers.slots_destroy(&self.slots)
	delete(self.agents)
	delete(self.corridor_paths)
	delete(self.path_result)
	proximity_grid_destroy(&self.grid)
	obstacle_avoidance_query_destroy(&self.obstacle_query)
	path_queue_destroy(&self.path_queue)
	detour.nav_mesh_query_destroy(&self.nav_query)
	delete(self.poses)
	self^ = {}
}

// agent_create places a new agent at the mesh point nearest pos and returns its handle; false when
// the crowd is full or pos is off the mesh. `user` is its caller link (agent_poses).
agent_create :: proc(self: ^Crowd, pos: [3]f32, params := DEFAULT_AGENT_PARAMS, user: Handle = {}) -> (agent: AgentHandle, ok: bool) #optional_ok {
	idx := containers.slots_alloc(&self.slots) or_return
	ag := &self.agents[idx]
	ag.params = params
	ag.user = user
	ag.heading = 0
	ag.topology_opt_time = 0
	if !snap(self, ag, pos) {
		containers.slots_free(&self.slots, idx)
		return {}, false
	}
	ag.state = .WALKING
	return AgentHandle(containers.slots_handle(&self.slots, idx)), true
}

// Puts the agent at the mesh point nearest pos, at rest and without a goal; false when pos is
// off the mesh.
@(private = "file")
snap :: proc(self: ^Crowd, ag: ^Agent, pos: [3]f32) -> bool {
	status, ref, point := detour.find_nearest_poly(&self.nav_query, pos, self.agent_placement_half_extents, agent_filter(self, ag))
	if detour.status_failed(status) || ref == detour.INVALID_POLY_REF do return false
	path_corridor_reset(&ag.corridor, ref, point)
	ag.boundary.center = {math.F32_MAX, math.F32_MAX, math.F32_MAX}
	ag.boundary.nsegs = 0
	ag.target_state = .None
	ag.position = point
	ag.desired_speed = 0
	ag.nvel = {0, 0, 0}
	ag.velocity = {0, 0, 0}
	return true
}

// agent_place teleports the agent to the mesh point nearest pos, at rest and without a goal;
// false when the handle is stale or pos is off the mesh.
agent_place :: proc(self: ^Crowd, handle: AgentHandle, pos: [3]f32) -> bool {
	idx := agent_index(self, handle) or_return
	return snap(self, &self.agents[idx], pos)
}

// agent_steer drives the agent at `velocity` instead of along a path, still kept on the mesh,
// away from walls and from the others, until the next move_to or stop.
agent_steer :: proc(self: ^Crowd, handle: AgentHandle, velocity: [3]f32) -> bool {
	idx := agent_index(self, handle) or_return
	ag := &self.agents[idx]
	ag.target = velocity
	ag.target_pathq_ref = PATHQ_INVALID
	ag.target_state = .Velocity
	ag.target_replan = false
	return true
}

@(private = "file")
agent_filter :: #force_inline proc(self: ^Crowd, ag: ^Agent) -> ^detour.Query_Filter {
	return &self.navmesh.filters[ag.params.query_filter_type % MAX_FILTERS]
}

// The live agent behind handle; false when the handle is stale.
@(private)
agent_index :: proc(self: ^Crowd, handle: AgentHandle) -> (idx: int, ok: bool) {
	return int(handle.index), containers.slots_valid(&self.slots, handle)
}

// agent_destroy deactivates the agent, freeing its slot; a stale handle is ignored.
agent_destroy :: proc(self: ^Crowd, handle: AgentHandle) {
	idx, ok := agent_index(self, handle)
	if !ok do return
	self.agents[idx].state = .INVALID
	containers.slots_free(&self.slots, u32(idx))
}

@(private)
request_move_target :: proc(self: ^Crowd, idx: int, ref: detour.Poly_Ref, pos: [3]f32) -> bool {
	if idx < 0 || idx >= len(self.agents) do return false
	if ref == detour.INVALID_POLY_REF do return false

	ag := &self.agents[idx]
	if ag.state == .INVALID do return false

	ag.target_ref = ref
	ag.target = pos
	ag.target_pathq_ref = PATHQ_INVALID
	ag.target_state = .Requesting
	ag.target_replan = false

	return true
}

// move_to snaps pos to the mesh within extents and sets it as the agent's goal.
move_to :: proc(self: ^Crowd, handle: AgentHandle, pos: [3]f32, extents: [3]f32 = {2, 4, 2}) -> bool {
	idx := agent_index(self, handle) or_return
	filter := agent_filter(self, &self.agents[idx])
	status, ref, snapped := detour.find_nearest_poly(&self.nav_query, pos, extents, filter)
	if detour.status_failed(status) do return false
	return request_move_target(self, idx, ref, snapped)
}

// stop drops the agent's goal: it slows to a halt where it is, until the next move_to.
stop :: proc(self: ^Crowd, handle: AgentHandle) {
	idx, ok := agent_index(self, handle)
	if !ok do return
	ag := &self.agents[idx]
	path_corridor_reset(&ag.corridor, path_corridor_get_first_poly(&ag.corridor), ag.position)
	ag.target = ag.position
	ag.target_state = .None
	ag.target_replan = false
}

// crowd_update advances every active agent by dt seconds.
crowd_update :: proc(self: ^Crowd, dt: f32) {
	self.velocity_sample_count = 0

	active_agents := make([]^Agent, len(self.agents), context.temp_allocator)
	nactive := 0
	for i in 0..<len(self.agents) {
		ag := &self.agents[i]
		if ag.state == .INVALID do continue
		active_agents[nactive] = ag
		nactive += 1
	}

	check_path_validity(self, active_agents[:nactive])
	update_move_request(self, dt)
	update_topology_optimization(self, active_agents[:nactive], dt)

	proximity_grid_clear(&self.grid)
	for i in 0..<nactive {
		ag := active_agents[i]
		p := ag.position
		r := ag.params.radius
		proximity_grid_add_item(&self.grid, u16(i), p.x-r, p.z-r, p.x+r, p.z+r)
	}

	for i in 0..<nactive {
		ag := active_agents[i]

		if ag.state != .WALKING do continue

		ag.disp = {0, 0, 0}
		ag.dvel = {0, 0, 0}

		ag.nneis = get_neighbours(ag.position, ag.params.height, ag.params.collision_query_range,
		                          ag, ag.neis[:], DT_CROWDAGENT_MAX_NEIGHBOURS,
		                          active_agents[:nactive], &self.grid)

		// without a goal (stop) it only brakes
		if ag.target_state == .None {
			ag.corner_count = 0
			ag.desired_speed = 0
			continue
		}
		// steered (agent_steer): the velocity is the goal
		if ag.target_state == .Velocity {
			ag.corner_count = 0
			ag.dvel = ag.target
			ag.desired_speed = linalg.length(ag.target)
			continue
		}

		ag.corner_count = path_corridor_find_corners(&ag.corridor, ag.corners[:], ag.corner_flags[:],
		                                          ag.corner_polys[:], MAX_CORNERS,
		                                          &self.nav_query,
		                                          agent_filter(self, ag))

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
		ag := active_agents[i]

		if ag.state != .WALKING do continue

		if .SEPARATION in ag.params.update_flags {
			separation_distance := ag.params.collision_query_range
			inv_separation_distance := 1.0 / separation_distance

			sep_vector := [3]f32{0, 0, 0}
			n_sep := 0

			for j in 0..<ag.nneis {
				nei := active_agents[ag.neis[j].idx]
				diff := ag.position - nei.position
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
		ag := active_agents[i]

		if ag.state != .WALKING do continue

		ag.nvel = ag.dvel

		if .OBSTACLE_AVOIDANCE in ag.params.update_flags {
			obstacle_avoidance_query_reset(&self.obstacle_query)

			for j in 0..<ag.nneis {
				nei := active_agents[ag.neis[j].idx]
				obstacle_avoidance_query_add_circle(&self.obstacle_query, nei.position,
				                                    nei.params.radius, nei.velocity, nei.dvel)
			}

			for j in 0..<ag.boundary.nsegs {
				s := local_boundary_get_segment(&ag.boundary, j)
				p0 := [3]f32{s[0], s[1], s[2]}
				p1 := [3]f32{s[3], s[4], s[5]}
				range_sq := ag.params.collision_query_range * ag.params.collision_query_range
				if linalg.length2(p0.xz - ag.position.xz) < range_sq {
					obstacle_avoidance_query_add_segment(&self.obstacle_query, p0, p1)
				}
			}

			avo_params := &self.obstacle_query_params[ag.params.obstacle_avoidance_type]
			self.velocity_sample_count += obstacle_avoidance_sample_velocity_adaptive(
				&self.obstacle_query, ag.position, ag.params.radius, ag.desired_speed,
				ag.velocity, ag.dvel, &ag.nvel, avo_params, nil)
		}
	}

	for i in 0..<nactive {
		ag := active_agents[i]

		if ag.state != .WALKING do continue

		integrate(ag, dt)
		if linalg.length2(ag.velocity.xz) > 0.01 do ag.heading = math.atan2(ag.velocity.x, ag.velocity.z)

		filter := agent_filter(self, ag)
		path_corridor_move_position(&ag.corridor, ag.position, &self.nav_query, filter)

		ag.corner_count = path_corridor_find_corners(&ag.corridor, ag.corners[:], ag.corner_flags[:],
		                                          ag.corner_polys[:], MAX_CORNERS,
		                                          &self.nav_query, filter)

		if .OPTIMIZE_VIS in ag.params.update_flags && ag.corner_count > 0 {
			target := ag.corners[min(1, ag.corner_count-1)]
			path_corridor_optimize_path_visibility(&ag.corridor, target,
			                                        ag.params.path_optimization_range,
			                                        &self.nav_query, filter)
		}

		local_boundary_update(&ag.boundary, path_corridor_get_first_poly(&ag.corridor),
		                      ag.position, ag.params.collision_query_range,
		                      &self.nav_query, filter)
	}

	path_queue_update(&self.path_queue, MAX_ITERS_PER_UPDATE)
}

// After the mesh changed under the crowd (navmesh_init again), agents off the new polygons snap
// back onto it and paths through stale polygons are planned again.
@(private = "file")
check_path_validity :: proc(self: ^Crowd, agents: []^Agent) {
	CHECK_LOOKAHEAD :: 10
	for ag in agents {
		target, state := ag.target, ag.target_state
		snapped := !detour.is_valid_poly_ref(self.nav_query.nav_mesh, path_corridor_get_first_poly(&ag.corridor))
		if snapped {
			if !snap(self, ag, ag.position) do continue
			ag.target, ag.target_state = target, state
		}
		if state == .None || state == .Velocity || state == .Failed do continue
		if !snapped && path_corridor_is_valid(&ag.corridor, CHECK_LOOKAHEAD, &self.nav_query, agent_filter(self, ag)) do continue
		status, ref, goal := detour.find_nearest_poly(&self.nav_query, ag.target, self.agent_placement_half_extents, agent_filter(self, ag))
		if detour.status_failed(status) || ref == detour.INVALID_POLY_REF {
			ag.target_state = .Failed
			continue
		}
		path_corridor_reset(&ag.corridor, path_corridor_get_first_poly(&ag.corridor), ag.position)
		ag.target_ref, ag.target = ref, goal
		ag.target_pathq_ref = PATHQ_INVALID
		ag.target_state = .Requesting
	}
}

@(private = "file")
update_move_request :: proc(self: ^Crowd, dt: f32) {
	PATH_MAX_AGENTS :: 8
	queue: [PATH_MAX_AGENTS]^Agent
	nqueue := 0

	for i in 0..<len(self.agents) {
		ag := &self.agents[i]
		if ag.state == .INVALID do continue
		if ag.target_state == .None || ag.target_state == .Velocity do continue

		if ag.target_state == .Requesting {
			filter := agent_filter(self, ag)
			ag.target_pathq_ref = path_queue_request(&self.path_queue,
			                                         path_corridor_get_last_poly(&ag.corridor),
			                                         ag.target_ref,
			                                         path_corridor_get_target(&ag.corridor),
			                                         ag.target, filter)

			if ag.target_pathq_ref != PATHQ_INVALID {
				ag.target_state = .Waiting_For_Queue
			}
		}

		if ag.target_state == .Waiting_For_Queue {
			status := path_queue_get_request_status(&self.path_queue, ag.target_pathq_ref)
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
			npath, status := path_queue_get_path_result(&self.path_queue, ag.target_pathq_ref,
			                                            self.path_result)
			ag.target_pathq_ref = PATHQ_INVALID

			if detour.status_failed(status) || npath <= 0 {
				ag.target_state = .Failed
				continue
			}

			path_corridor_set_corridor(&ag.corridor, ag.target, self.path_result[:npath])
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

		filter := agent_filter(self, ag)
		path_corridor_optimize_path_topology(&ag.corridor, &self.nav_query, filter)
	}
}

@(private)
integrate :: proc(ag: ^Agent, dt: f32) {
	max_delta := ag.params.max_acceleration * dt
	dv := ag.nvel - ag.velocity
	ds := linalg.length(dv)
	if ds > max_delta {
		dv = dv * (max_delta / ds)
	}
	ag.velocity += dv

	if linalg.length(ag.velocity) > 0.0001 {
		ag.position += ag.velocity * dt
	} else {
		ag.velocity = {0, 0, 0}
	}
}

@(private)
calc_smooth_steer_direction :: proc(ag: ^Agent, dir: ^[3]f32) {
	if ag.corner_count == 0 {
		dir^ = {0, 0, 0}
		return
	}

	ip0 := 0
	ip1 := min(1, ag.corner_count - 1)
	p0 := ag.corners[ip0]
	p1 := ag.corners[ip1]

	dir0 := p0 - ag.position
	dir1 := p1 - ag.position
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
	if ag.corner_count == 0 {
		dir^ = {0, 0, 0}
		return
	}
	dir^ = ag.corners[0] - ag.position
	dir.y = 0
	dir^ = linalg.normalize(dir^)
}

@(private)
get_distance_to_goal :: proc(ag: ^Agent, range: f32) -> f32 {
	if ag.corner_count == 0 do return range

	DT_STRAIGHTPATH_END :: 0x02
	end_of_path := (ag.corner_flags[ag.corner_count-1] & DT_STRAIGHTPATH_END) != 0
	if end_of_path {
		dist_sq := linalg.length2(ag.corners[ag.corner_count-1].xz - ag.position.xz)
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

		diff := pos - ag.position
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
// crowd_update moves it; give it a goal with move_to and tune it through agent_params.
agent :: proc(self: ^Crowd, handle: AgentHandle) -> (ag: Agent, ok: bool) #optional_ok {
	idx := agent_index(self, handle) or_return
	return self.agents[idx], true
}

// agent_poses returns the pose of every active agent, for copying onto what it moves; valid
// until the next call.
agent_poses :: proc(self: ^Crowd) -> []AgentPose {
	clear(&self.poses)
	for ag, i in self.agents {
		if ag.state == .INVALID do continue
		pose := AgentPose{AgentHandle(containers.slots_handle(&self.slots, u32(i))), ag.user, ag.position, linalg.quaternion_angle_axis_f32(ag.heading, {0, 1, 0})}
		append(&self.poses, pose)
	}
	return self.poses[:]
}

// agent_params returns the agent's parameters, to edit in place; crowd_update only reads them.
agent_params :: proc(self: ^Crowd, handle: AgentHandle) -> (params: ^AgentParams, ok: bool) #optional_ok {
	idx := agent_index(self, handle) or_return
	return &self.agents[idx].params, true
}


// destroy frees an agent, as agent_destroy does.

