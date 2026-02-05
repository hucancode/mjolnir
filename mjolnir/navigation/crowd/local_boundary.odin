package crowd

import "core:math"
import "core:math/linalg"
import "core:slice"
import "../recast"
import "../detour"
import "../../geometry"

MAX_LOCAL_SEGS :: 8
MAX_LOCAL_POLYS :: 16

Local_Boundary :: struct {
	center: [3]f32,
	segs:   [MAX_LOCAL_SEGS]Boundary_Segment,
	nsegs:  int,
	polys:  [MAX_LOCAL_POLYS]recast.Poly_Ref,
	npolys: int,
}

Boundary_Segment :: struct {
	s: [6]f32,
	d: f32,
}

create_local_boundary :: proc() -> ^Local_Boundary {
	boundary := new(Local_Boundary)
	local_boundary_reset(boundary)
	return boundary
}

destroy_local_boundary :: proc(boundary: ^Local_Boundary) {
	free(boundary)
}

local_boundary_reset :: proc(boundary: ^Local_Boundary) {
	boundary.center = {math.F32_MAX, math.F32_MAX, math.F32_MAX}
	boundary.npolys = 0
	boundary.nsegs = 0
}

local_boundary_add_segment :: proc(boundary: ^Local_Boundary, dist: f32, s: [6]f32) {
	seg: ^Boundary_Segment

	if boundary.nsegs == 0 {
		seg = &boundary.segs[0]
	} else if dist >= boundary.segs[boundary.nsegs-1].d {
		if boundary.nsegs >= MAX_LOCAL_SEGS do return
		seg = &boundary.segs[boundary.nsegs]
	} else {
		i := 0
		for i < boundary.nsegs {
			if dist <= boundary.segs[i].d do break
			i += 1
		}
		tgt := i + 1
		n := min(boundary.nsegs - i, MAX_LOCAL_SEGS - tgt)
		if n > 0 {
			for j := boundary.nsegs - 1; j >= i; j -= 1 {
				if tgt + (j - i) < MAX_LOCAL_SEGS {
					boundary.segs[tgt + (j - i)] = boundary.segs[j]
				}
			}
		}
		seg = &boundary.segs[i]
	}

	seg.d = dist
	seg.s = s

	if boundary.nsegs < MAX_LOCAL_SEGS {
		boundary.nsegs += 1
	}
}

local_boundary_update :: proc(boundary: ^Local_Boundary, ref: recast.Poly_Ref, pos: [3]f32,
                               collision_query_range: f32, query: ^detour.Nav_Mesh_Query,
                               filter: ^detour.Query_Filter) {
	MAX_SEGS_PER_POLY :: recast.DT_VERTS_PER_POLYGON * 3

	if ref == recast.INVALID_POLY_REF {
		local_boundary_reset(boundary)
		return
	}

	boundary.center = pos

	parent_refs := make([]recast.Poly_Ref, MAX_LOCAL_POLYS)
	defer delete(parent_refs)
	npolys, _ := detour.find_local_neighbourhood(query, ref, pos,
	                                             collision_query_range, filter,
	                                             boundary.polys[:], parent_refs[:], MAX_LOCAL_POLYS)
	boundary.npolys = int(npolys)

	boundary.nsegs = 0
	segs := make([][6]f32, MAX_SEGS_PER_POLY)
	defer delete(segs)

	for j in 0..<boundary.npolys {
		seg_refs := make([]recast.Poly_Ref, MAX_SEGS_PER_POLY)
		defer delete(seg_refs)
		nsegs, _ := detour.get_poly_wall_segments(query, boundary.polys[j],
		                                          filter, segs, seg_refs, MAX_SEGS_PER_POLY)

		for k in 0..<int(nsegs) {
			s := segs[k]
			p0 := [3]f32{s[0], s[1], s[2]}
			p1 := [3]f32{s[3], s[4], s[5]}
			dist_sq, _ := geometry.point_segment_distance2_2d(pos, p0, p1)
			if dist_sq > collision_query_range * collision_query_range do continue
			local_boundary_add_segment(boundary, dist_sq, s)
		}
	}
}

local_boundary_is_valid :: proc(boundary: ^Local_Boundary, query: ^detour.Nav_Mesh_Query,
                                 filter: ^detour.Query_Filter) -> bool {
	if boundary.npolys == 0 do return false

	for i in 0..<boundary.npolys {
		if !detour.is_valid_poly_ref(query.nav_mesh, boundary.polys[i]) {
			return false
		}
	}

	return true
}

local_boundary_get_segment :: proc(boundary: ^Local_Boundary, i: int) -> [6]f32 {
	if i < 0 || i >= boundary.nsegs do return {}
	return boundary.segs[i].s
}
