package navigation_crowd

import "core:math"
import "core:math/linalg"
import "core:slice"
import "../recast"
import "../detour"

Path_Corridor :: struct {
	pos:      [3]f32,
	target:   [3]f32,
	path:     []recast.Poly_Ref,
	npath:    int,
	max_path: int,
}

create_path_corridor :: proc(max_path: int, allocator := context.allocator) -> (corridor: ^Path_Corridor, ok: bool) {
	if max_path <= 0 {
		return nil, false
	}
	context.allocator = allocator
	corridor = new(Path_Corridor)
	corridor.path = make([]recast.Poly_Ref, max_path)
	corridor.npath = 0
	corridor.max_path = max_path
	return corridor, true
}

destroy_path_corridor :: proc(corridor: ^Path_Corridor) {
	if corridor == nil do return
	delete(corridor.path)
	free(corridor)
}

path_corridor_reset :: proc(corridor: ^Path_Corridor, ref: recast.Poly_Ref, pos: [3]f32) {
	corridor.pos = pos
	corridor.target = pos
	corridor.path[0] = ref
	corridor.npath = 1
}

path_corridor_find_corners :: proc(corridor: ^Path_Corridor, corner_verts: [][3]f32,
                                    corner_flags: []u8, corner_polys: []recast.Poly_Ref,
                                    max_corners: int, query: ^detour.Nav_Mesh_Query,
                                    filter: ^detour.Query_Filter) -> int {
	MIN_TARGET_DIST :: 0.01

	if corridor.npath == 0 do return 0

	straight_path := make([]detour.Straight_Path_Point, max_corners)
	defer delete(straight_path)
	flags := make([]u8, max_corners)
	defer delete(flags)
	refs := make([]recast.Poly_Ref, max_corners)
	defer delete(refs)

	_, ncorners := detour.find_straight_path(query, corridor.pos, corridor.target,
	                                         corridor.path[:corridor.npath], i32(corridor.npath),
	                                         straight_path, flags, refs, i32(max_corners), 0)

	for i in 0..<ncorners {
		corner_verts[i] = straight_path[i].pos
		corner_flags[i] = flags[i]
		corner_polys[i] = refs[i]
	}

	ncorners_result := int(ncorners)

	DT_STRAIGHTPATH_OFFMESH_CONNECTION :: 0x04
	MIN_TARGET_DIST_SQ :: MIN_TARGET_DIST * MIN_TARGET_DIST
	for ncorners_result > 0 {
		is_offmesh := (corner_flags[0] & DT_STRAIGHTPATH_OFFMESH_CONNECTION) != 0
		dist_sq := linalg.length2(corner_verts[0].xz - corridor.pos.xz)
		if is_offmesh || dist_sq > MIN_TARGET_DIST_SQ {
			break
		}
		ncorners_result -= 1
		if ncorners_result > 0 {
			for i in 0..<ncorners_result {
				corner_flags[i] = corner_flags[i+1]
				corner_polys[i] = corner_polys[i+1]
				corner_verts[i] = corner_verts[i+1]
			}
		}
	}

	for i in 0..<ncorners_result {
		is_offmesh := (corner_flags[i] & DT_STRAIGHTPATH_OFFMESH_CONNECTION) != 0
		if is_offmesh {
			ncorners_result = i + 1
			break
		}
	}

	return ncorners_result
}

path_corridor_optimize_path_visibility :: proc(corridor: ^Path_Corridor, next: [3]f32,
                                                path_optimization_range: f32,
                                                query: ^detour.Nav_Mesh_Query,
                                                filter: ^detour.Query_Filter) {
	goal := next
	dist_sq := linalg.length2(goal.xz - corridor.pos.xz)

	if dist_sq < 0.01 * 0.01 do return

	dist := math.sqrt(dist_sq)
	dist = min(dist + 0.01, path_optimization_range)

	delta := goal - corridor.pos
	goal = corridor.pos + delta * (path_optimization_range / linalg.length(delta))

	MAX_RES :: 32
	res := make([]recast.Poly_Ref, MAX_RES)
	defer delete(res)

	status, hit, nres := detour.raycast(query, corridor.path[0], corridor.pos, goal, filter, 0, res, MAX_RES)

	if recast.status_succeeded(status) && nres > 1 && hit.t > 0.99 {
		corridor.npath = merge_corridor_start_shortcut(corridor.path, corridor.npath,
		                                                corridor.max_path, res[:nres],
		                                                int(nres))
	}
}

path_corridor_optimize_path_topology :: proc(corridor: ^Path_Corridor, query: ^detour.Nav_Mesh_Query,
                                              filter: ^detour.Query_Filter) -> bool {
	if corridor.npath < 3 do return false

	MAX_ITER :: 32
	MAX_RES :: 32
	res := make([]recast.Poly_Ref, MAX_RES)
	defer delete(res)

	status := detour.init_sliced_find_path(query, corridor.path[0], corridor.path[corridor.npath-1],
	                                       corridor.pos, corridor.target, filter, 0)
	if recast.status_failed(status) do return false

	_, status = detour.update_sliced_find_path(query, MAX_ITER)
	if recast.status_failed(status) do return false

	nres: i32
	status, nres = detour.finalize_sliced_find_path_partial(query, corridor.path[:corridor.npath],
	                                                         res, MAX_RES)

	if recast.status_succeeded(status) && nres > 0 {
		corridor.npath = merge_corridor_start_shortcut(corridor.path, corridor.npath,
		                                                corridor.max_path, res[:nres], int(nres))
		return true
	}

	return false
}

path_corridor_move_position :: proc(corridor: ^Path_Corridor, npos: [3]f32,
                                     query: ^detour.Nav_Mesh_Query,
                                     filter: ^detour.Query_Filter) -> bool {
	MAX_VISITED :: 16
	visited := make([]recast.Poly_Ref, MAX_VISITED)
	defer delete(visited)

	result, nvisited, status := detour.move_along_surface(query, corridor.path[0], corridor.pos,
	                                                       npos, filter, visited, MAX_VISITED)

	if recast.status_succeeded(status) {
		corridor.npath = merge_corridor_start_moved(corridor.path, corridor.npath,
		                                             corridor.max_path, visited[:nvisited],
		                                             int(nvisited))

		h := corridor.pos.y
		poly_h, poly_height_status := detour.get_poly_height(query, corridor.path[0], result)
		if recast.status_succeeded(poly_height_status) {
			h = poly_h
		}
		result.y = h
		corridor.pos = result
		return true
	}
	return false
}

path_corridor_move_target_position :: proc(corridor: ^Path_Corridor, npos: [3]f32,
                                            query: ^detour.Nav_Mesh_Query,
                                            filter: ^detour.Query_Filter) -> bool {
	MAX_VISITED :: 16
	visited := make([]recast.Poly_Ref, MAX_VISITED)
	defer delete(visited)

	result, nvisited, status := detour.move_along_surface(query, corridor.path[corridor.npath-1],
	                                                       corridor.target, npos, filter,
	                                                       visited, MAX_VISITED)

	if recast.status_succeeded(status) {
		corridor.npath = merge_corridor_end_moved(corridor.path, corridor.npath,
		                                           corridor.max_path, visited[:nvisited],
		                                           int(nvisited))
		corridor.target = result
		return true
	}
	return false
}

path_corridor_set_corridor :: proc(corridor: ^Path_Corridor, target: [3]f32,
                                    path: []recast.Poly_Ref) {
	corridor.target = target
	n := min(len(path), corridor.max_path)
	copy(corridor.path[:n], path[:n])
	corridor.npath = n
}

path_corridor_is_valid :: proc(corridor: ^Path_Corridor, max_look_ahead: int,
                                query: ^detour.Nav_Mesh_Query,
                                filter: ^detour.Query_Filter) -> bool {
	n := min(corridor.npath, max_look_ahead)
	for i in 0..<n {
		if !detour.is_valid_poly_ref(query.nav_mesh, corridor.path[i]) {
			return false
		}
	}
	return true
}

path_corridor_get_pos :: proc(corridor: ^Path_Corridor) -> [3]f32 {
	return corridor.pos
}

path_corridor_get_target :: proc(corridor: ^Path_Corridor) -> [3]f32 {
	return corridor.target
}

path_corridor_get_first_poly :: proc(corridor: ^Path_Corridor) -> recast.Poly_Ref {
	if corridor.npath > 0 do return corridor.path[0]
	return recast.INVALID_POLY_REF
}

path_corridor_get_last_poly :: proc(corridor: ^Path_Corridor) -> recast.Poly_Ref {
	if corridor.npath > 0 do return corridor.path[corridor.npath-1]
	return recast.INVALID_POLY_REF
}

path_corridor_get_path :: proc(corridor: ^Path_Corridor) -> []recast.Poly_Ref {
	return corridor.path[:corridor.npath]
}

merge_corridor_start_moved :: proc(path: []recast.Poly_Ref, npath: int, max_path: int,
                                    visited: []recast.Poly_Ref, nvisited: int) -> int {
	furthest_path := -1
	furthest_visited := -1

	for i := npath-1; i >= 0; i -= 1 {
		for j := nvisited-1; j >= 0; j -= 1 {
			if path[i] == visited[j] {
				furthest_path = i
				furthest_visited = j
				break
			}
		}
		if furthest_path != -1 do break
	}

	if furthest_path == -1 || furthest_visited == -1 do return npath

	req := nvisited - furthest_visited
	orig := min(furthest_path + 1, npath)
	size := max(0, npath - orig)
	if req + size > max_path {
		size = max_path - req
	}
	if size > 0 {
		copy(path[req:req+size], path[orig:orig+size])
	}

	for i in 0..<min(req, max_path) {
		path[i] = visited[(nvisited-1) - i]
	}

	return req + size
}

merge_corridor_end_moved :: proc(path: []recast.Poly_Ref, npath: int, max_path: int,
                                  visited: []recast.Poly_Ref, nvisited: int) -> int {
	furthest_path := -1
	furthest_visited := -1

	for i in 0..<npath {
		for j := nvisited-1; j >= 0; j -= 1 {
			if path[i] == visited[j] {
				furthest_path = i
				furthest_visited = j
				break
			}
		}
		if furthest_path != -1 do break
	}

	if furthest_path == -1 || furthest_visited == -1 do return npath

	ppos := furthest_path + 1
	vpos := furthest_visited + 1
	count := min(nvisited - vpos, max_path - ppos)
	if count > 0 {
		copy(path[ppos:ppos+count], visited[vpos:vpos+count])
	}

	return ppos + count
}

merge_corridor_start_shortcut :: proc(path: []recast.Poly_Ref, npath: int, max_path: int,
                                       visited: []recast.Poly_Ref, nvisited: int) -> int {
	furthest_path := -1
	furthest_visited := -1

	for i := npath-1; i >= 0; i -= 1 {
		for j := nvisited-1; j >= 0; j -= 1 {
			if path[i] == visited[j] {
				furthest_path = i
				furthest_visited = j
				break
			}
		}
		if furthest_path != -1 do break
	}

	if furthest_path == -1 || furthest_visited == -1 do return npath

	req := furthest_visited
	if req <= 0 do return npath

	orig := furthest_path
	size := max(0, npath - orig)
	if req + size > max_path {
		size = max_path - req
	}
	if size > 0 {
		copy(path[req:req+size], path[orig:orig+size])
	}

	copy(path[:req], visited[:req])

	return req + size
}
