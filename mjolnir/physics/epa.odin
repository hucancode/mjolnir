package physics

import "core:math"
import "core:math/linalg"
import "core:slice"

// EPA Triangle face
EPAFace :: struct {
	a, b, c: int,
	normal:  [3]f32,
	distance: f32,
}

// EPA Edge
EPAEdge :: struct {
	a, b: int,
}

EPA_MAX_VERTICES :: 64
EPA_MAX_FACES :: 128

// EPA (Expanding Polytope Algorithm) - finds penetration depth and normal
// Takes the final simplex from GJK and expands it to find the closest face
epa :: proc(
	simplex: Simplex,
	collider_a: ^Collider,
	pos_a: [3]f32,
	collider_b: ^Collider,
	pos_b: [3]f32,
) -> (
	normal: [3]f32,
	depth: f32,
	ok: bool,
) {
	// Initialize polytope with simplex vertices, removing duplicates
	vertices := make([dynamic][3]f32, context.temp_allocator)
	dedup_epsilon :: 0.0001
	for i in 0 ..< simplex.count {
		point := simplex.points[i]
		// Check if this point is already in vertices (avoid duplicates)
		is_duplicate := false
		for existing in vertices {
			diff := point - existing
			if linalg.length(diff) < dedup_epsilon {
				is_duplicate = true
				break
			}
		}
		if !is_duplicate {
			append(&vertices, point)
		}
	}

	// Initialize faces based on vertex count (after deduplication)
	faces := make([dynamic]EPAFace, context.temp_allocator)
	vertex_count := len(vertices)

	// Create initial tetrahedron faces
	if vertex_count == 4 {
		add_face(&faces, &vertices, 0, 1, 2)
		add_face(&faces, &vertices, 0, 3, 1)
		add_face(&faces, &vertices, 0, 2, 3)
		add_face(&faces, &vertices, 1, 3, 2)
	} else if vertex_count == 3 {
		// If we only have a triangle, we need to create a thin tetrahedron
		// Add a point slightly offset from the triangle
		ab := vertices[1] - vertices[0]
		ac := vertices[2] - vertices[0]
		abc := linalg.vector_cross3(ab, ac)

		// Check if triangle is degenerate (collinear points)
		abc_length := linalg.length(abc)
		normal_dir: [3]f32
		if abc_length < 0.0001 {
			// Points are collinear - find perpendicular direction
			// Use the line direction and create a perpendicular
			line_dir := linalg.normalize(ab)
			// Find a non-parallel axis
			if abs(line_dir.x) < 0.9 {
				normal_dir = linalg.vector_cross3(line_dir, linalg.VECTOR3F32_X_AXIS)
			} else {
				normal_dir = linalg.vector_cross3(line_dir, linalg.VECTOR3F32_Y_AXIS)
			}
			normal_dir = linalg.normalize(normal_dir)
		} else {
			normal_dir = abc / abc_length
		}

		append(&vertices, vertices[0] + normal_dir * 0.001)
		add_face(&faces, &vertices, 0, 1, 2)
		add_face(&faces, &vertices, 0, 3, 1)
		add_face(&faces, &vertices, 0, 2, 3)
		add_face(&faces, &vertices, 1, 3, 2)
	} else if vertex_count == 2 {
		// Only have a line segment - can't do EPA, use distance as approximation
		ab := vertices[1] - vertices[0]
		line_length := linalg.length(ab)
		if line_length < 0.0001 {
			return {}, 0, false
		}
		// The penetration is approximately the distance from origin to the line
		t := -linalg.vector_dot(vertices[0], ab) / linalg.vector_dot(ab, ab)
		t = clamp(t, 0, 1)
		closest_point := vertices[0] + ab * t
		dist := linalg.length(closest_point)
		if dist < 0.0001 {
			return linalg.normalize(ab), 0.001, true
		}
		return linalg.normalize(closest_point), dist, true
	} else {
		// Invalid simplex
		return {}, 0, false
	}

	// Safety check - ensure we have faces
	if len(faces) == 0 {
		return {}, 0, false
	}

	max_iterations := 32
	epsilon :: 0.0001

	for iteration in 0 ..< max_iterations {
		// Check if we still have faces after potential removals
		if len(faces) == 0 {
			return {}, 0, false
		}

		// Find closest face to origin
		closest_face_idx := 0
		min_distance := faces[0].distance
		for i in 1 ..< len(faces) {
			if faces[i].distance < min_distance {
				min_distance = faces[i].distance
				closest_face_idx = i
			}
		}

		closest_face := faces[closest_face_idx]

		// Get support point in direction of closest face normal
		support_point := support(
			collider_a,
			pos_a,
			collider_b,
			pos_b,
			closest_face.normal,
		)

		// Calculate distance from origin to support point along normal
		support_distance := linalg.vector_dot(support_point, closest_face.normal)

		// If support point is not significantly further than closest face,
		// we've found the closest face on the original shapes
		if support_distance - min_distance < epsilon {
			return closest_face.normal, min_distance + epsilon, true
		}

		// Add support point to vertices
		if len(vertices) >= EPA_MAX_VERTICES {
			return closest_face.normal, min_distance + epsilon, true
		}
		append(&vertices, support_point)
		support_idx := len(vertices) - 1

		// Find all faces visible from support point and remove them
		edges := make([dynamic]EPAEdge, context.temp_allocator)
		faces_to_remove := make([dynamic]int, context.temp_allocator)

		for i in 0 ..< len(faces) {
			face := faces[i]
			// Check if face is visible from support point
			to_support := support_point - vertices[face.a]
			if linalg.vector_dot(face.normal, to_support) > 0 {
				// Face is visible, add its edges to the list
				add_if_unique_edge(&edges, face.a, face.b)
				add_if_unique_edge(&edges, face.b, face.c)
				add_if_unique_edge(&edges, face.c, face.a)
				append(&faces_to_remove, i)
			}
		}

		// Remove faces in reverse order to maintain indices
		#reverse for idx in faces_to_remove {
			ordered_remove(&faces, idx)
		}

		// Create new faces from edges to support point
		for edge in edges {
			if len(faces) >= EPA_MAX_FACES {
				break
			}
			add_face(&faces, &vertices, edge.a, edge.b, support_idx)
		}
	}

	// If we hit max iterations, return best result found
	if len(faces) > 0 {
		closest_face := faces[0]
		for face in faces[1:] {
			if face.distance < closest_face.distance {
				closest_face = face
			}
		}
		return closest_face.normal, closest_face.distance + epsilon, true
	}

	return {}, 0, false
}

// Add a face to the polytope with proper normal calculation
add_face :: proc(
	faces: ^[dynamic]EPAFace,
	vertices: ^[dynamic][3]f32,
	a, b, c: int,
) {
	va := vertices[a]
	vb := vertices[b]
	vc := vertices[c]

	// Calculate face normal
	ab := vb - va
	ac := vc - va
	normal := linalg.vector_cross3(ab, ac)

	length := linalg.length(normal)
	if length > 0.0001 {
		normal = normal / length
	} else {
		normal = {0, 1, 0}
	}

	// Calculate distance from origin to face
	distance := linalg.vector_dot(normal, va)

	// Ensure normal points toward origin
	face_a, face_b, face_c := a, b, c
	if distance < 0 {
		normal = -normal
		distance = -distance
		// Swap b and c to maintain winding order
		face_b, face_c = c, b
	}

	face := EPAFace {
		a        = face_a,
		b        = face_b,
		c        = face_c,
		normal   = normal,
		distance = distance,
	}

	append(faces, face)
}

// Add edge to list if not already present (removes if duplicate to maintain silhouette)
add_if_unique_edge :: proc(edges: ^[dynamic]EPAEdge, a, b: int) {
	// Check if reverse edge exists
	for i := 0; i < len(edges); i += 1 {
		if edges[i].a == b && edges[i].b == a {
			// Remove the duplicate edge
			ordered_remove(edges, i)
			return
		}
	}
	// Add the edge
	append(edges, EPAEdge{a = a, b = b})
}
