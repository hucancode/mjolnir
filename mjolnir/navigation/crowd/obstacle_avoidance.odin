package navigation_crowd

import "core:math"
import "core:math/linalg"
import "../recast"
import "../../geometry"

DT_PI :: math.PI
DT_MAX_PATTERN_DIVS :: 32
DT_MAX_PATTERN_RINGS :: 4

Obstacle_Circle :: struct {
	p:    [3]f32,
	vel:  [3]f32,
	dvel: [3]f32,
	rad:  f32,
	dp:   [3]f32,
	np:   [3]f32,
}

Obstacle_Segment :: struct {
	p:     [3]f32,
	q:     [3]f32,
	touch: bool,
}

Obstacle_Avoidance_Params :: struct {
	vel_bias:       f32,
	weight_des_vel: f32,
	weight_cur_vel: f32,
	weight_side:    f32,
	weight_toi:     f32,
	horiz_time:     f32,
	grid_size:      u8,
	adaptive_divs:  u8,
	adaptive_rings: u8,
	adaptive_depth: u8,
}

Obstacle_Avoidance_Debug_Data :: struct {
	nsamples:    int,
	max_samples: int,
	vel:         [][3]f32,
	ssize:       []f32,
	pen:         []f32,
	vpen:        []f32,
	vcpen:       []f32,
	spen:        []f32,
	tpen:        []f32,
}

Obstacle_Avoidance_Query :: struct {
	params:        Obstacle_Avoidance_Params,
	inv_horiz_time: f32,
	vmax:          f32,
	inv_vmax:      f32,
	max_circles:   int,
	circles:       []Obstacle_Circle,
	ncircles:      int,
	max_segments:  int,
	segments:      []Obstacle_Segment,
	nsegments:     int,
}

create_obstacle_avoidance_debug_data :: proc(max_samples: int, allocator := context.allocator) -> ^Obstacle_Avoidance_Debug_Data {
	context.allocator = allocator
	data := new(Obstacle_Avoidance_Debug_Data)
	data.max_samples = max_samples
	data.vel = make([][3]f32, max_samples)
	data.ssize = make([]f32, max_samples)
	data.pen = make([]f32, max_samples)
	data.vpen = make([]f32, max_samples)
	data.vcpen = make([]f32, max_samples)
	data.spen = make([]f32, max_samples)
	data.tpen = make([]f32, max_samples)
	return data
}

destroy_obstacle_avoidance_debug_data :: proc(data: ^Obstacle_Avoidance_Debug_Data) {
	if data == nil do return
	delete(data.vel)
	delete(data.ssize)
	delete(data.pen)
	delete(data.vpen)
	delete(data.vcpen)
	delete(data.spen)
	delete(data.tpen)
	free(data)
}

create_obstacle_avoidance_query :: proc(max_circles: int, max_segments: int, allocator := context.allocator) -> ^Obstacle_Avoidance_Query {
	context.allocator = allocator
	query := new(Obstacle_Avoidance_Query)
	query.max_circles = max_circles
	query.circles = make([]Obstacle_Circle, max_circles)
	query.max_segments = max_segments
	query.segments = make([]Obstacle_Segment, max_segments)
	return query
}

destroy_obstacle_avoidance_query :: proc(query: ^Obstacle_Avoidance_Query) {
	if query == nil do return
	delete(query.circles)
	delete(query.segments)
	free(query)
}

obstacle_avoidance_query_reset :: proc(query: ^Obstacle_Avoidance_Query) {
	query.ncircles = 0
	query.nsegments = 0
}

obstacle_avoidance_query_add_circle :: proc(query: ^Obstacle_Avoidance_Query, pos: [3]f32, rad: f32, vel: [3]f32, dvel: [3]f32) {
	if query.ncircles >= query.max_circles do return
	cir := &query.circles[query.ncircles]
	query.ncircles += 1
	cir.p = pos
	cir.rad = rad
	cir.vel = vel
	cir.dvel = dvel
}

obstacle_avoidance_query_add_segment :: proc(query: ^Obstacle_Avoidance_Query, p: [3]f32, q: [3]f32) {
	if query.nsegments >= query.max_segments do return
	seg := &query.segments[query.nsegments]
	query.nsegments += 1
	seg.p = p
	seg.q = q
}

sweep_circle_circle :: proc(c0: [3]f32, r0: f32, v: [3]f32, c1: [3]f32, r1: f32) -> (hit: bool, tmin: f32, tmax: f32) {
	EPS :: 0.0001
	s := c1 - c0
	r := r0 + r1
	c := linalg.dot(s.xz, s.xz) - r*r
	a := linalg.dot(v.xz, v.xz)
	if a < EPS do return false, 0, 0

	b := linalg.dot(v.xz, s.xz)
	d := b*b - a*c
	if d < 0.0 do return false, 0, 0
	a = 1.0 / a
	rd := math.sqrt(d)
	tmin = (b - rd) * a
	tmax = (b + rd) * a
	return true, tmin, tmax
}

perp_2d :: proc "contextless" (a: [2]f32, b: [2]f32) -> f32 {
	return a.x * b.y - a.y * b.x
}

isect_ray_seg :: proc(ap: [3]f32, u: [3]f32, bp: [3]f32, bq: [3]f32) -> (hit: bool, t: f32) {
	v := bq - bp
	w := ap - bp
	d := perp_2d(u.xz, v.xz)
	if math.abs(d) < 1e-6 do return false, 0
	d = 1.0 / d
	t = perp_2d(v.xz, w.xz) * d
	if t < 0 || t > 1 do return false, 0
	s := perp_2d(u.xz, w.xz) * d
	if s < 0 || s > 1 do return false, 0
	return true, t
}

obstacle_avoidance_query_prepare :: proc(query: ^Obstacle_Avoidance_Query, pos: [3]f32, dvel: [3]f32) {
	for i in 0..<query.ncircles {
		cir := &query.circles[i]

		pa := pos
		pb := cir.p

		orig := [3]f32{0, 0, 0}
		cir.dp = linalg.normalize(pb - pa)
		dv := cir.dvel - dvel

		a := geometry.signed_triangle_area_2d(orig, cir.dp, dv)
		if a < 0.01 {
			cir.np = {-cir.dp.z, 0, cir.dp.x}
		} else {
			cir.np = {cir.dp.z, 0, -cir.dp.x}
		}
	}

	for i in 0..<query.nsegments {
		seg := &query.segments[i]
		r := f32(0.01)
		dist_sq, _ := geometry.point_segment_distance2_2d(pos, seg.p, seg.q)
		seg.touch = dist_sq < r*r
	}
}

obstacle_avoidance_query_process_sample :: proc(query: ^Obstacle_Avoidance_Query, vcand: [3]f32, cs: f32,
                                                 pos: [3]f32, rad: f32, vel: [3]f32, dvel: [3]f32,
                                                 min_penalty: f32, debug: ^Obstacle_Avoidance_Debug_Data) -> f32 {
	vpen := query.params.weight_des_vel * (linalg.distance(vcand.xz, dvel.xz) * query.inv_vmax)
	vcpen := query.params.weight_cur_vel * (linalg.distance(vcand.xz, vel.xz) * query.inv_vmax)

	min_pen := min_penalty - vpen - vcpen
	t_threshold := (query.params.weight_toi / min_pen - 0.1) * query.params.horiz_time
	if t_threshold - query.params.horiz_time > -math.F32_EPSILON {
		return min_penalty
	}

	tmin := query.params.horiz_time
	side := f32(0)
	nside := 0

	for i in 0..<query.ncircles {
		cir := &query.circles[i]

		vab := vcand * 2 - vel - cir.vel

		side += clamp(min(linalg.dot(cir.dp.xz, vab.xz)*0.5+0.5, linalg.dot(cir.np.xz, vab.xz)*2), 0.0, 1.0)
		nside += 1

		hit, htmin, htmax := sweep_circle_circle(pos, rad, vab, cir.p, cir.rad)
		if !hit do continue

		if htmin < 0.0 && htmax > 0.0 {
			htmin = -htmin * 0.5
		}

		if htmin >= 0.0 {
			if htmin < tmin {
				tmin = htmin
				if tmin < t_threshold {
					return min_penalty
				}
			}
		}
	}

	for i in 0..<query.nsegments {
		seg := &query.segments[i]
		htmin := f32(0)

		if seg.touch {
			sdir := seg.q - seg.p
			snorm := [3]f32{-sdir.z, 0, sdir.x}
			if linalg.dot(snorm.xz, vcand.xz) < 0.0 do continue
			htmin = 0.0
		} else {
			hit, t := isect_ray_seg(pos, vcand, seg.p, seg.q)
			if !hit do continue
			htmin = t
		}

		htmin *= 2.0

		if htmin < tmin {
			tmin = htmin
			if tmin < t_threshold {
				return min_penalty
			}
		}
	}

	if nside > 0 {
		side /= f32(nside)
	}

	spen := query.params.weight_side * side
	tpen := query.params.weight_toi * (1.0 / (0.1 + tmin * query.inv_horiz_time))

	penalty := vpen + vcpen + spen + tpen

	if debug != nil && debug.nsamples < debug.max_samples {
		debug.vel[debug.nsamples] = vcand
		debug.ssize[debug.nsamples] = cs
		debug.pen[debug.nsamples] = penalty
		debug.vpen[debug.nsamples] = vpen
		debug.vcpen[debug.nsamples] = vcpen
		debug.spen[debug.nsamples] = spen
		debug.tpen[debug.nsamples] = tpen
		debug.nsamples += 1
	}

	return penalty
}

obstacle_avoidance_sample_velocity_grid :: proc(query: ^Obstacle_Avoidance_Query, pos: [3]f32, rad: f32, vmax: f32,
                                                 vel: [3]f32, dvel: [3]f32, nvel: ^[3]f32,
                                                 params: ^Obstacle_Avoidance_Params,
                                                 debug: ^Obstacle_Avoidance_Debug_Data) -> int {
	obstacle_avoidance_query_prepare(query, pos, dvel)

	query.params = params^
	query.inv_horiz_time = 1.0 / query.params.horiz_time
	query.vmax = vmax
	query.inv_vmax = vmax > 0 ? 1.0 / vmax : math.F32_MAX

	nvel^ = {0, 0, 0}

	if debug != nil {
		debug.nsamples = 0
	}

	cvx := dvel.x * query.params.vel_bias
	cvz := dvel.z * query.params.vel_bias
	cs := vmax * 2 * (1 - query.params.vel_bias) / f32(query.params.grid_size - 1)
	half := f32(query.params.grid_size - 1) * cs * 0.5

	min_penalty := f32(math.F32_MAX)
	ns := 0

	for y in 0..<int(query.params.grid_size) {
		for x in 0..<int(query.params.grid_size) {
			vcand := [3]f32{
				cvx + f32(x)*cs - half,
				0,
				cvz + f32(y)*cs - half,
			}

			if vcand.x*vcand.x + vcand.z*vcand.z > (vmax+cs/2)*(vmax+cs/2) do continue

			penalty := obstacle_avoidance_query_process_sample(query, vcand, cs, pos, rad, vel, dvel, min_penalty, debug)
			ns += 1
			if penalty < min_penalty {
				min_penalty = penalty
				nvel^ = vcand
			}
		}
	}

	return ns
}

normalize_2d :: proc(v: ^[3]f32) {
	d := math.sqrt(v.x*v.x + v.z*v.z)
	if d == 0 do return
	d = 1.0 / d
	v.x *= d
	v.z *= d
}

rotate_2d :: proc(dest: ^[3]f32, v: [3]f32, ang: f32) {
	c := math.cos(ang)
	s := math.sin(ang)
	dest.x = v.x*c - v.z*s
	dest.z = v.x*s + v.z*c
	dest.y = v.y
}

obstacle_avoidance_sample_velocity_adaptive :: proc(query: ^Obstacle_Avoidance_Query, pos: [3]f32, rad: f32, vmax: f32,
                                                     vel: [3]f32, dvel: [3]f32, nvel: ^[3]f32,
                                                     params: ^Obstacle_Avoidance_Params,
                                                     debug: ^Obstacle_Avoidance_Debug_Data) -> int {
	obstacle_avoidance_query_prepare(query, pos, dvel)

	query.params = params^
	query.inv_horiz_time = 1.0 / query.params.horiz_time
	query.vmax = vmax
	query.inv_vmax = vmax > 0 ? 1.0 / vmax : math.F32_MAX

	nvel^ = {0, 0, 0}

	if debug != nil {
		debug.nsamples = 0
	}

	pat: [(DT_MAX_PATTERN_DIVS*DT_MAX_PATTERN_RINGS+1)*2]f32
	npat := 0

	ndivs := int(query.params.adaptive_divs)
	nrings := int(query.params.adaptive_rings)
	depth := int(query.params.adaptive_depth)

	nd := clamp(ndivs, 1, DT_MAX_PATTERN_DIVS)
	nr := clamp(nrings, 1, DT_MAX_PATTERN_RINGS)
	da := (1.0 / f32(nd)) * DT_PI * 2
	ca := math.cos(da)
	sa := math.sin(da)

	ddir: [6]f32
	ddir[0] = dvel.x
	ddir[1] = dvel.y
	ddir[2] = dvel.z
	temp_dir := [3]f32{ddir[0], ddir[1], ddir[2]}
	normalize_2d(&temp_dir)
	ddir[0] = temp_dir.x
	ddir[1] = temp_dir.y
	ddir[2] = temp_dir.z
	temp_dir2: [3]f32
	rotate_2d(&temp_dir2, temp_dir, da*0.5)
	ddir[3] = temp_dir2.x
	ddir[4] = temp_dir2.y
	ddir[5] = temp_dir2.z

	pat[npat*2+0] = 0
	pat[npat*2+1] = 0
	npat += 1

	for j in 0..<nr {
		r := f32(nr - j) / f32(nr)
		idx := (j % 2) * 3
		pat[npat*2+0] = ddir[idx] * r
		pat[npat*2+1] = ddir[idx+2] * r
		last1 := npat * 2
		last2 := last1
		npat += 1

		for i := 1; i < nd-1; i += 2 {
			pat[npat*2+0] = pat[last1+0]*ca + pat[last1+1]*sa
			pat[npat*2+1] = -pat[last1+0]*sa + pat[last1+1]*ca
			pat[npat*2+2] = pat[last2+0]*ca - pat[last2+1]*sa
			pat[npat*2+3] = pat[last2+0]*sa + pat[last2+1]*ca

			last1 = npat * 2
			last2 = last1 + 2
			npat += 2
		}

		if (nd & 1) == 0 {
			pat[npat*2+2] = pat[last2+0]*ca - pat[last2+1]*sa
			pat[npat*2+3] = pat[last2+0]*sa + pat[last2+1]*ca
			npat += 1
		}
	}

	cr := vmax * (1.0 - query.params.vel_bias)
	res := [3]f32{dvel.x * query.params.vel_bias, 0, dvel.z * query.params.vel_bias}
	ns := 0

	for k in 0..<depth {
		min_penalty := f32(math.F32_MAX)
		bvel := [3]f32{0, 0, 0}

		for i in 0..<npat {
			vcand := [3]f32{
				res.x + pat[i*2+0]*cr,
				0,
				res.z + pat[i*2+1]*cr,
			}

			if vcand.x*vcand.x + vcand.z*vcand.z > (vmax+0.001)*(vmax+0.001) do continue

			penalty := obstacle_avoidance_query_process_sample(query, vcand, cr/10, pos, rad, vel, dvel, min_penalty, debug)
			ns += 1
			if penalty < min_penalty {
				min_penalty = penalty
				bvel = vcand
			}
		}

		res = bvel
		cr *= 0.5
	}

	nvel^ = res

	return ns
}
