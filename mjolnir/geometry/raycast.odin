package geometry

import "core:math"
import "core:slice"

// Acceleration structure type for raycasting
AccelType :: enum {
	BVH,
	OCTREE,
	BRUTE_FORCE,
}

// Raycast configuration
RaycastConfig :: struct {
	max_dist:  f32,
	max_tests: int, // Maximum primitive tests allowed, 0 = infinite (exhaustive)
	accel:     AccelType,
}

// Default raycast configuration with infinite max distance and exhaustive testing
DEFAULT_RAYCAST_CONFIG :: RaycastConfig {
	max_dist  = F32_MAX,
	max_tests = 0,
	accel     = .BVH,
}

// Free-form raycast - finds closest hit
// Returns the closest primitive hit by the ray
raycast :: proc(
	primitives: []$T,
	ray: Ray,
	intersection_func: proc(ray: Ray, primitive: T, max_t: f32) -> (hit: bool, t: f32),
	bounds_func: proc(t: T) -> Aabb,
	config: RaycastConfig = DEFAULT_RAYCAST_CONFIG,
) -> RayHit(T) {
	switch config.accel {
	case .BVH:
		return raycast_bvh(primitives, ray, intersection_func, bounds_func, config)
	case .OCTREE:
		return raycast_octree(primitives, ray, intersection_func, bounds_func, config)
	case .BRUTE_FORCE:
		return raycast_brute(primitives, ray, intersection_func, config)
	}
	return {}
}

// Free-form raycast - finds any hit (early exit)
// Returns as soon as any hit is found
raycast_single :: proc(
	primitives: []$T,
	ray: Ray,
	intersection_func: proc(ray: Ray, primitive: T, max_t: f32) -> (hit: bool, t: f32),
	bounds_func: proc(t: T) -> Aabb,
	config: RaycastConfig = DEFAULT_RAYCAST_CONFIG,
) -> RayHit(T) {
	switch config.accel {
	case .BVH:
		return raycast_single_bvh(primitives, ray, intersection_func, bounds_func, config)
	case .OCTREE:
		return raycast_single_octree(
			primitives,
			ray,
			intersection_func,
			bounds_func,
			config,
		)
	case .BRUTE_FORCE:
		return raycast_single_brute(primitives, ray, intersection_func, config)
	}
	return {}
}

// Free-form raycast - finds all hits
// Returns all primitives hit by the ray, sorted by distance
raycast_multi :: proc(
	primitives: []$T,
	ray: Ray,
	intersection_func: proc(ray: Ray, primitive: T, max_t: f32) -> (hit: bool, t: f32),
	bounds_func: proc(t: T) -> Aabb,
	config: RaycastConfig = DEFAULT_RAYCAST_CONFIG,
	results: ^[dynamic]RayHit(T),
) {
	switch config.accel {
	case .BVH:
		raycast_multi_bvh(primitives, ray, intersection_func, bounds_func, config, results)
	case .OCTREE:
		raycast_multi_octree(
			primitives,
			ray,
			intersection_func,
			bounds_func,
			config,
			results,
		)
	case .BRUTE_FORCE:
		raycast_multi_brute(primitives, ray, intersection_func, config, results)
	}
}

// BVH-accelerated raycast - closest hit
@(private)
raycast_bvh :: proc(
	primitives: []$T,
	ray: Ray,
	intersection_func: proc(ray: Ray, primitive: T, max_t: f32) -> (hit: bool, t: f32),
	bounds_func: proc(t: T) -> Aabb,
	config: RaycastConfig,
) -> RayHit(T) {
	if len(primitives) == 0 do return {}

	bvh: BVH(T)
	bvh.bounds_func = bounds_func
	defer bvh_destroy(&bvh)

	bvh_build(&bvh, primitives)

	// If no max_tests limit, use standard BVH raycast
	if config.max_tests <= 0 {
		return bvh_raycast(&bvh, ray, config.max_dist, intersection_func)
	}

	// Limited version
	return raycast_bvh_limited(&bvh, ray, intersection_func, config)
}

@(private)
raycast_bvh_limited :: proc(
	bvh: ^BVH($T),
	ray: Ray,
	intersection_func: proc(ray: Ray, primitive: T, max_t: f32) -> (hit: bool, t: f32),
	config: RaycastConfig,
) -> RayHit(T) {
	if len(bvh.nodes) == 0 do return {}

	best_hit: RayHit(T)
	best_hit.t = config.max_dist
	tests := 0

	stack := make([dynamic]i32, 0, 64, context.temp_allocator)
	append(&stack, 0)

	for len(stack) > 0 && tests < config.max_tests {
		node_idx := pop(&stack)
		node := &bvh.nodes[node_idx]
  t_near, t_far := ray_aabb_intersection_safe(ray.origin, ray.direction, node.bounds)
		if t_near > best_hit.t || t_far < 0 do continue
  if node.primitive_count > 0 {
			for i in node.primitive_start ..< node.primitive_start + node.primitive_count {
				if tests >= config.max_tests do break
  		prim := bvh.primitives[i]
				hit, t := intersection_func(ray, prim, best_hit.t)
				tests += 1
  		if hit && t < best_hit.t {
					best_hit.primitive = prim
					best_hit.t = t
					best_hit.hit = true
				}
			}
		} else {
			left_node := &bvh.nodes[node.left_child]
			right_node := &bvh.nodes[node.right_child]
  	left_t_near, _ := ray_aabb_intersection_safe(
				ray.origin,
				ray.direction,
				left_node.bounds,
			)
			right_t_near, _ := ray_aabb_intersection_safe(
				ray.origin,
				ray.direction,
				right_node.bounds,
			)
  	if left_t_near < right_t_near {
				append(&stack, node.right_child, node.left_child)
			} else {
				append(&stack, node.left_child, node.right_child)
			}
		}
	}

	return best_hit
}

// BVH-accelerated raycast - single hit (early exit)
@(private)
raycast_single_bvh :: proc(
	primitives: []$T,
	ray: Ray,
	intersection_func: proc(ray: Ray, primitive: T, max_t: f32) -> (hit: bool, t: f32),
	bounds_func: proc(t: T) -> Aabb,
	config: RaycastConfig,
) -> RayHit(T) {
	if len(primitives) == 0 do return {}

	bvh: BVH(T)
	bvh.bounds_func = bounds_func
	defer bvh_destroy(&bvh)

	bvh_build(&bvh, primitives)

	if config.max_tests <= 0 {
		return bvh_raycast_single(&bvh, ray, config.max_dist, intersection_func)
	}

	return raycast_single_bvh_limited(&bvh, ray, intersection_func, config)
}

@(private)
raycast_single_bvh_limited :: proc(
	bvh: ^BVH($T),
	ray: Ray,
	intersection_func: proc(ray: Ray, primitive: T, max_t: f32) -> (hit: bool, t: f32),
	config: RaycastConfig,
) -> RayHit(T) {
	if len(bvh.nodes) == 0 do return {}

	tests := 0
	stack := make([dynamic]i32, 0, 64, context.temp_allocator)
	append(&stack, 0)

	for len(stack) > 0 && tests < config.max_tests {
		node_idx := pop(&stack)
		node := &bvh.nodes[node_idx]
  t_near, t_far := ray_aabb_intersection_safe(ray.origin, ray.direction, node.bounds)
		if t_near > config.max_dist || t_far < 0 do continue
  if node.primitive_count > 0 {
			for i in node.primitive_start ..< node.primitive_start + node.primitive_count {
				if tests >= config.max_tests do break
  		prim := bvh.primitives[i]
				hit, t := intersection_func(ray, prim, config.max_dist)
				tests += 1
  		if hit && t <= config.max_dist {
					return RayHit(T){primitive = prim, t = t, hit = true}
				}
			}
		} else {
			append(&stack, node.left_child, node.right_child)
		}
	}

	return {}
}

// BVH-accelerated raycast - all hits
@(private)
raycast_multi_bvh :: proc(
	primitives: []$T,
	ray: Ray,
	intersection_func: proc(ray: Ray, primitive: T, max_t: f32) -> (hit: bool, t: f32),
	bounds_func: proc(t: T) -> Aabb,
	config: RaycastConfig,
	results: ^[dynamic]RayHit(T),
) {
	clear(results)
	if len(primitives) == 0 do return

	bvh: BVH(T)
	bvh.bounds_func = bounds_func
	defer bvh_destroy(&bvh)

	bvh_build(&bvh, primitives)

	if config.max_tests <= 0 {
		bvh_raycast_multi(&bvh, ray, config.max_dist, intersection_func, results)
		return
	}

	raycast_multi_bvh_limited(&bvh, ray, intersection_func, config, results)
}

@(private)
raycast_multi_bvh_limited :: proc(
	bvh: ^BVH($T),
	ray: Ray,
	intersection_func: proc(ray: Ray, primitive: T, max_t: f32) -> (hit: bool, t: f32),
	config: RaycastConfig,
	results: ^[dynamic]RayHit(T),
) {
	if len(bvh.nodes) == 0 do return

	tests := 0
	stack := make([dynamic]i32, 0, 64, context.temp_allocator)
	append(&stack, 0)

	for len(stack) > 0 && tests < config.max_tests {
		node_idx := pop(&stack)
		node := &bvh.nodes[node_idx]
  t_near, t_far := ray_aabb_intersection_safe(ray.origin, ray.direction, node.bounds)
		if t_near > config.max_dist || t_far < 0 do continue
  if node.primitive_count > 0 {
			for i in node.primitive_start ..< node.primitive_start + node.primitive_count {
				if tests >= config.max_tests do break
  		prim := bvh.primitives[i]
				hit, t := intersection_func(ray, prim, config.max_dist)
				tests += 1
  		if hit && t <= config.max_dist {
					append(results, RayHit(T){primitive = prim, t = t, hit = true})
				}
			}
		} else {
			append(&stack, node.left_child, node.right_child)
		}
	}

	if len(results^) > 1 {
		slice.sort_by(results[:], proc(a, b: RayHit(T)) -> bool {return a.t < b.t})
	}
}

// Octree-accelerated raycast - closest hit
@(private)
raycast_octree :: proc(
	primitives: []$T,
	ray: Ray,
	intersection_func: proc(ray: Ray, primitive: T, max_t: f32) -> (hit: bool, t: f32),
	bounds_func: proc(t: T) -> Aabb,
	config: RaycastConfig,
) -> RayHit(T) {
	if len(primitives) == 0 do return {}

	overall_bounds := AABB_UNDEFINED
	for prim in primitives {
		overall_bounds = aabb_union(overall_bounds, bounds_func(prim))
	}

	octree: Octree(T)
	octree.bounds_func = bounds_func
	octree_init(&octree, overall_bounds)
	defer octree_destroy(&octree)

	for prim in primitives {
		octree_insert(&octree, prim)
	}

	if config.max_tests <= 0 {
		return octree_raycast(&octree, ray, config.max_dist, intersection_func)
	}

	return raycast_octree_limited(&octree, ray, intersection_func, config)
}

@(private)
raycast_octree_limited :: proc(
	octree: ^Octree($T),
	ray: Ray,
	intersection_func: proc(ray: Ray, primitive: T, max_t: f32) -> (hit: bool, t: f32),
	config: RaycastConfig,
) -> RayHit(T) {
	if octree.root == nil do return {}

	best_hit: RayHit(T)
	best_hit.t = config.max_dist
	tests := 0

	inv_dir := [3]f32 {
		1.0 / ray.direction.x,
		1.0 / ray.direction.y,
		1.0 / ray.direction.z,
	}

	t_min, t_max := ray_aabb_intersection(ray.origin, inv_dir, octree.root.bounds)
	if t_min > config.max_dist || t_max < 0 do return best_hit

	octree_node_raycast_limited(
		octree,
		octree.root,
		ray,
		inv_dir,
		max_f32(t_min, 0),
		min_f32(t_max, config.max_dist),
		&best_hit,
		intersection_func,
		&tests,
		config.max_tests,
	)

	return best_hit
}

@(private)
octree_node_raycast_limited :: proc(
	octree: ^Octree($T),
	node: ^OctreeNode(T),
	ray: Ray,
	inv_dir: [3]f32,
	t_min, t_max: f32,
	best_hit: ^RayHit(T),
	intersection_func: proc(ray: Ray, primitive: T, max_t: f32) -> (hit: bool, t: f32),
	tests: ^int,
	max_tests: int,
) {
	if t_min > best_hit.t || tests^ >= max_tests do return

	for item in node.items {
		if tests^ >= max_tests do return
  hit, t := intersection_func(ray, item, best_hit.t)
		tests^ += 1
  if hit && t < best_hit.t {
			best_hit.primitive = item
			best_hit.t = t
			best_hit.hit = true
		}
	}

	if node.children[0] == nil do return

	child_intersections: [8]struct {
		idx:   i32,
		t_min: f32,
	}
	valid_count := 0

	for i in 0 ..< 8 {
		child_t_min, child_t_max := ray_aabb_intersection(
			ray.origin,
			inv_dir,
			node.children[i].bounds,
		)
		if child_t_min <= best_hit.t && child_t_max >= t_min {
			child_intersections[valid_count] = {idx = i32(i), t_min = max_f32(child_t_min, t_min)}
			valid_count += 1
		}
	}

	slice.sort_by(child_intersections[:valid_count], proc(a, b: struct {
			idx:   i32,
			t_min: f32,
		}) -> bool {
		return a.t_min < b.t_min
	})

	for i in 0 ..< valid_count {
		if tests^ >= max_tests do return
  child_idx := child_intersections[i].idx
		child_t_min := child_intersections[i].t_min
		if child_t_min > best_hit.t do break
  child_t_max := min_f32(
			best_hit.t,
			ray_aabb_intersection_far(ray.origin, inv_dir, node.children[child_idx].bounds),
		)
		octree_node_raycast_limited(
			octree,
			node.children[child_idx],
			ray,
			inv_dir,
			child_t_min,
			child_t_max,
			best_hit,
			intersection_func,
			tests,
			max_tests,
		)
	}
}

// Octree-accelerated raycast - single hit (early exit)
@(private)
raycast_single_octree :: proc(
	primitives: []$T,
	ray: Ray,
	intersection_func: proc(ray: Ray, primitive: T, max_t: f32) -> (hit: bool, t: f32),
	bounds_func: proc(t: T) -> Aabb,
	config: RaycastConfig,
) -> RayHit(T) {
	if len(primitives) == 0 do return {}

	overall_bounds := AABB_UNDEFINED
	for prim in primitives {
		overall_bounds = aabb_union(overall_bounds, bounds_func(prim))
	}

	octree: Octree(T)
	octree.bounds_func = bounds_func
	octree_init(&octree, overall_bounds)
	defer octree_destroy(&octree)

	for prim in primitives {
		octree_insert(&octree, prim)
	}

	if config.max_tests <= 0 {
		return octree_raycast_single(&octree, ray, config.max_dist, intersection_func)
	}

	return raycast_single_octree_limited(&octree, ray, intersection_func, config)
}

@(private)
raycast_single_octree_limited :: proc(
	octree: ^Octree($T),
	ray: Ray,
	intersection_func: proc(ray: Ray, primitive: T, max_t: f32) -> (hit: bool, t: f32),
	config: RaycastConfig,
) -> RayHit(T) {
	if octree.root == nil do return {}

	tests := 0
	inv_dir := [3]f32 {
		1.0 / ray.direction.x,
		1.0 / ray.direction.y,
		1.0 / ray.direction.z,
	}

	t_min, t_max := ray_aabb_intersection(ray.origin, inv_dir, octree.root.bounds)
	if t_min > config.max_dist || t_max < 0 do return {}

	return octree_node_raycast_single_limited(
		octree,
		octree.root,
		ray,
		inv_dir,
		max_f32(t_min, 0),
		min_f32(t_max, config.max_dist),
		config.max_dist,
		intersection_func,
		&tests,
		config.max_tests,
	)
}

@(private)
octree_node_raycast_single_limited :: proc(
	octree: ^Octree($T),
	node: ^OctreeNode(T),
	ray: Ray,
	inv_dir: [3]f32,
	t_min, t_max: f32,
	max_dist: f32,
	intersection_func: proc(ray: Ray, primitive: T, max_t: f32) -> (hit: bool, t: f32),
	tests: ^int,
	max_tests: int,
) -> RayHit(T) {
	if tests^ >= max_tests do return {}

	for item in node.items {
		if tests^ >= max_tests do return {}
  hit, t := intersection_func(ray, item, max_dist)
		tests^ += 1
  if hit && t <= max_dist {
			return RayHit(T){primitive = item, t = t, hit = true}
		}
	}

	if node.children[0] == nil do return {}

	child_intersections: [8]struct {
		idx:   i32,
		t_min: f32,
	}
	valid_count := 0

	for i in 0 ..< 8 {
		child_t_min, child_t_max := ray_aabb_intersection(
			ray.origin,
			inv_dir,
			node.children[i].bounds,
		)
		if child_t_min <= max_dist && child_t_max >= t_min {
			child_intersections[valid_count] = {idx = i32(i), t_min = max_f32(child_t_min, t_min)}
			valid_count += 1
		}
	}

	slice.sort_by(child_intersections[:valid_count], proc(a, b: struct {
			idx:   i32,
			t_min: f32,
		}) -> bool {
		return a.t_min < b.t_min
	})

	for i in 0 ..< valid_count {
		if tests^ >= max_tests do return {}
  child_idx := child_intersections[i].idx
		child_t_min := child_intersections[i].t_min
		child_t_max := min_f32(
			max_dist,
			ray_aabb_intersection_far(ray.origin, inv_dir, node.children[child_idx].bounds),
		)
  result := octree_node_raycast_single_limited(
			octree,
			node.children[child_idx],
			ray,
			inv_dir,
			child_t_min,
			child_t_max,
			max_dist,
			intersection_func,
			tests,
			max_tests,
		)
  if result.hit do return result
	}

	return {}
}

// Octree-accelerated raycast - all hits
@(private)
raycast_multi_octree :: proc(
	primitives: []$T,
	ray: Ray,
	intersection_func: proc(ray: Ray, primitive: T, max_t: f32) -> (hit: bool, t: f32),
	bounds_func: proc(t: T) -> Aabb,
	config: RaycastConfig,
	results: ^[dynamic]RayHit(T),
) {
	clear(results)
	if len(primitives) == 0 do return

	overall_bounds := AABB_UNDEFINED
	for prim in primitives {
		overall_bounds = aabb_union(overall_bounds, bounds_func(prim))
	}

	octree: Octree(T)
	octree.bounds_func = bounds_func
	octree_init(&octree, overall_bounds)
	defer octree_destroy(&octree)

	for prim in primitives {
		octree_insert(&octree, prim)
	}

	if config.max_tests <= 0 {
		octree_raycast_multi(&octree, ray, config.max_dist, intersection_func, results)
		return
	}

	raycast_multi_octree_limited(&octree, ray, intersection_func, config, results)
}

@(private)
raycast_multi_octree_limited :: proc(
	octree: ^Octree($T),
	ray: Ray,
	intersection_func: proc(ray: Ray, primitive: T, max_t: f32) -> (hit: bool, t: f32),
	config: RaycastConfig,
	results: ^[dynamic]RayHit(T),
) {
	if octree.root == nil do return

	tests := 0
	inv_dir := [3]f32 {
		1.0 / ray.direction.x,
		1.0 / ray.direction.y,
		1.0 / ray.direction.z,
	}

	t_min, t_max := ray_aabb_intersection(ray.origin, inv_dir, octree.root.bounds)
	if t_min > config.max_dist || t_max < 0 do return

	octree_node_raycast_multi_limited(
		octree,
		octree.root,
		ray,
		inv_dir,
		max_f32(t_min, 0),
		min_f32(t_max, config.max_dist),
		config.max_dist,
		intersection_func,
		results,
		&tests,
		config.max_tests,
	)

	if len(results^) > 1 {
		slice.sort_by(results[:], proc(a, b: RayHit(T)) -> bool {return a.t < b.t})
	}
}

@(private)
octree_node_raycast_multi_limited :: proc(
	octree: ^Octree($T),
	node: ^OctreeNode(T),
	ray: Ray,
	inv_dir: [3]f32,
	t_min, t_max: f32,
	max_dist: f32,
	intersection_func: proc(ray: Ray, primitive: T, max_t: f32) -> (hit: bool, t: f32),
	results: ^[dynamic]RayHit(T),
	tests: ^int,
	max_tests: int,
) {
	if tests^ >= max_tests do return

	for item in node.items {
		if tests^ >= max_tests do return
  hit, t := intersection_func(ray, item, max_dist)
		tests^ += 1
  if hit && t <= max_dist {
			append(results, RayHit(T){primitive = item, t = t, hit = true})
		}
	}

	if node.children[0] == nil do return

	for i in 0 ..< 8 {
		if tests^ >= max_tests do return
  child_t_min, child_t_max := ray_aabb_intersection(
			ray.origin,
			inv_dir,
			node.children[i].bounds,
		)
		if child_t_min <= max_dist && child_t_max >= t_min {
			octree_node_raycast_multi_limited(
				octree,
				node.children[i],
				ray,
				inv_dir,
				max_f32(child_t_min, t_min),
				min_f32(child_t_max, max_dist),
				max_dist,
				intersection_func,
				results,
				tests,
				max_tests,
			)
		}
	}
}

// Brute force raycast - closest hit
@(private)
raycast_brute :: proc(
	primitives: []$T,
	ray: Ray,
	intersection_func: proc(ray: Ray, primitive: T, max_t: f32) -> (hit: bool, t: f32),
	config: RaycastConfig,
) -> RayHit(T) {
	best_hit: RayHit(T)
	best_hit.t = config.max_dist

	max_tests := config.max_tests
	if max_tests <= 0 do max_tests = len(primitives)

	for prim, i in primitives {
		if i >= max_tests do break
  hit, t := intersection_func(ray, prim, best_hit.t)
		if hit && t < best_hit.t {
			best_hit.primitive = prim
			best_hit.t = t
			best_hit.hit = true
		}
	}

	return best_hit
}

// Brute force raycast - single hit (early exit)
@(private)
raycast_single_brute :: proc(
	primitives: []$T,
	ray: Ray,
	intersection_func: proc(ray: Ray, primitive: T, max_t: f32) -> (hit: bool, t: f32),
	config: RaycastConfig,
) -> RayHit(T) {
	max_tests := config.max_tests
	if max_tests <= 0 do max_tests = len(primitives)

	for prim, i in primitives {
		if i >= max_tests do break
  hit, t := intersection_func(ray, prim, config.max_dist)
		if hit && t <= config.max_dist {
			return RayHit(T){primitive = prim, t = t, hit = true}
		}
	}

	return {}
}

// Brute force raycast - all hits
@(private)
raycast_multi_brute :: proc(
	primitives: []$T,
	ray: Ray,
	intersection_func: proc(ray: Ray, primitive: T, max_t: f32) -> (hit: bool, t: f32),
	config: RaycastConfig,
	results: ^[dynamic]RayHit(T),
) {
	clear(results)

	max_tests := config.max_tests
	if max_tests <= 0 do max_tests = len(primitives)

	for prim, i in primitives {
		if i >= max_tests do break
  hit, t := intersection_func(ray, prim, config.max_dist)
		if hit && t <= config.max_dist {
			append(results, RayHit(T){primitive = prim, t = t, hit = true})
		}
	}

	if len(results^) > 1 {
		slice.sort_by(results[:], proc(a, b: RayHit(T)) -> bool {return a.t < b.t})
	}
}
