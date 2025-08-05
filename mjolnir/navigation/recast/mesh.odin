package navigation_recast


import "core:slice"
import "core:log"
import "core:mem"
import "core:math"
import "core:math/linalg"
import "core:fmt"

// Check if three vertices form a left turn (counter-clockwise)
// Based on the C++ uleft function from RecastMesh.cpp
uleft :: proc(a, b, c: [3]i16) -> bool {
    // 2D cross product in XZ plane: (b-a) × (c-a)
    return linalg.vector_cross2(b.xz - a.xz, c.xz - a.xz) < 0
}

// Check if three vertices (by index) form a left turn - for i16 vertex arrays
uleft_indexed_i16 :: proc(verts: []i16, ia, ib, ic: i32) -> bool {
    if ia < 0 || ib < 0 || ic < 0 ||
       ia >= i32(len(verts)/3) || ib >= i32(len(verts)/3) || ic >= i32(len(verts)/3) {
        return false
    }

    a := [3]i16{verts[ia*3], verts[ia*3+1], verts[ia*3+2]}
    b := [3]i16{verts[ib*3], verts[ib*3+1], verts[ib*3+2]}
    c := [3]i16{verts[ic*3], verts[ic*3+1], verts[ic*3+2]}

    return uleft(a, b, c)
}

// Check if three vertices (by index) form a left turn - for Mesh_Vertex arrays
uleft_indexed_mesh :: proc(verts: []Mesh_Vertex, ia, ib, ic: i32) -> bool {
    if ia < 0 || ib < 0 || ic < 0 || ia >= i32(len(verts)) || ib >= i32(len(verts)) || ic >= i32(len(verts)) {
        return false
    }

    a := &verts[ia]
    b := &verts[ib]
    c := &verts[ic]

    // Using XZ plane (Y is up)
    // 2D cross product: (b-a) × (c-a)
    return i32(b.x - a.x) * i32(c.z - a.z) - i32(c.x - a.x) * i32(b.z - a.z) < 0
}

// Count vertices in a polygon (excluding null indices)
count_poly_verts :: proc(poly: []i32) -> i32 {
    count := i32(0)
    for v in poly {
        if v == -1 do break
        count += 1
    }
    return count
}

// Get merge value for two polygons
// Returns shared edge indices and merge value (edge length squared)
// Based on C++ getPolyMergeValue from RecastMesh.cpp
get_poly_merge_value :: proc(pa, pb: []i32, verts: []Mesh_Vertex, nvp: i32) -> (ea: i32, eb: i32, value: i32) {
    na := count_poly_verts(pa)
    nb := count_poly_verts(pb)

    // If merged polygon would be too big, cannot merge
    if na + nb - 2 > nvp {
        return -1, -1, -1
    }

    // Check if polygons share an edge
    ea = -1
    eb = -1

    for i in 0..<na {
        va0 := pa[i]
        va1 := pa[(i+1) % na]
        if va0 > va1 do va0, va1 = va1, va0

        for j in 0..<nb {
            vb0 := pb[j]
            vb1 := pb[(j+1) % nb]
            if vb0 > vb1 do vb0, vb1 = vb1, vb0

            if va0 == vb0 && va1 == vb1 {
                ea = i
                eb = j
                break
            }
        }
        if ea != -1 do break
    }

    // No common edge, cannot merge
    if ea == -1 || eb == -1 {
        return -1, -1, -1
    }

    // Check if merged polygon would be convex
    // First check the two connection points
    va := pa[(ea+na-1) % na]
    vb := pa[ea]
    vc := pb[(eb+2) % nb]
    if !uleft_indexed_mesh(verts, va, vb, vc) {
        return -1, -1, -1
    }

    va = pb[(eb+nb-1) % nb]
    vb = pb[eb]
    vc = pa[(ea+2) % na]
    if !uleft_indexed_mesh(verts, va, vb, vc) {
        return -1, -1, -1
    }
    
    // For simple cases (triangles), the connection point check is sufficient
    if na == 3 && nb == 3 {
        // Two triangles merging into a quad - connection point check is enough
        // Skip the full convexity check to avoid performance issues
    } else {
        // For larger polygons, do a full convexity check
        // Create temporary merged polygon to check full convexity
        merged := make([dynamic]i32, 0, na + nb - 2, context.temp_allocator)
        
        // Add vertices from pa (except shared edge)
        for i in 0..<na-1 {
            append(&merged, pa[(ea+1+i) % na])
        }
        
        // Add vertices from pb (except shared edge)  
        for i in 0..<nb-1 {
            append(&merged, pb[(eb+1+i) % nb])
        }
        
        // Check convexity of entire merged polygon
        n := len(merged)
        if n < 3 {
            // Degenerate polygon
            return -1, -1, -1
        }
        
        for i in 0..<n {
            v0 := merged[i]
            v1 := merged[(i+1) % n]
            v2 := merged[(i+2) % n]
            
            // Validate indices
            if v0 < 0 || v1 < 0 || v2 < 0 || v0 >= i32(len(verts)) || v1 >= i32(len(verts)) || v2 >= i32(len(verts)) {
                // Invalid vertex indices
                return -1, -1, -1
            }
            
            if !uleft_indexed_mesh(verts, v0, v1, v2) {
                return -1, -1, -1
            }
        }
    }

    // Calculate merge value (edge length squared)
    va = pa[ea]
    vb = pa[(ea+1) % na]

    dx := i32(verts[va].x) - i32(verts[vb].x)
    dz := i32(verts[va].z) - i32(verts[vb].z)

    return ea, eb, dx*dx + dz*dz
}

// Merge two polygons along shared edge
// Based on C++ mergePolyVerts from RecastMesh.cpp
merge_poly_verts :: proc(pa, pb: ^Poly_Build, ea, eb: i32, nvp: i32) {
    na := count_poly_verts(pa.verts[:])
    nb := count_poly_verts(pb.verts[:])

    // Create temporary merged polygon
    tmp := make([]i32, nvp, context.temp_allocator)
    for i in 0..<nvp do tmp[i] = -1

    n := 0
    // Add vertices from pa (except shared edge)
    for i in 0..<na-1 {
        tmp[n] = pa.verts[(ea+1+i) % na]
        n += 1
    }
    // Add vertices from pb (except shared edge)
    for i in 0..<nb-1 {
        tmp[n] = pb.verts[(eb+1+i) % nb]
        n += 1
    }

    // Update pa with merged polygon
    // Note: pa.verts was allocated with context.temp_allocator, so we don't delete it
    // Instead, we allocate a new slice with the same allocator
    pa.verts = make([]i32, n, context.temp_allocator)
    copy(pa.verts[:], tmp[:n])
}

// Mesh building constants
RC_VERTEX_BUCKET_COUNT :: 1 << 12  // 4096 buckets for vertex hashing

// Vertex structure for mesh building
Mesh_Vertex :: struct {
    x, y, z: u16,           // Vertex coordinates (quantized)
    next:    i32,           // Next vertex in hash bucket
}

// Vertex bucket for efficient vertex lookup during welding
Vertex_Bucket :: struct {
    first: i32,             // Index of first vertex in bucket
}

// Edge structure for polygon mesh building
Mesh_Edge :: struct {
    vert:      [2]u16,      // Vertex indices
    poly:      [2]u16,      // Polygon indices (or RC_MESH_NULL_IDX)
    poly_edge: [2]u16,      // Edge index within each polygon
}

// Temporary structure for building polygons
Poly_Build :: struct {
    verts:     []i32,       // Vertex indices
    area:      u8,          // Area type
    reg:       u16,         // Region ID
}

// Hash function for vertices (simple multiplicative hash)
vertex_hash :: proc "contextless" (x, y, z: u16) -> u32 {
    h1 := u32(x) * 0x8da6b343
    h2 := u32(y) * 0xd8163841
    h3 := u32(z) * 0xcb1ab31f
    return (h1 + h2 + h3) & (RC_VERTEX_BUCKET_COUNT - 1)
}

// Add vertex to hash table, return index (existing or new)
add_vertex :: proc(x, y, z: u16, verts: ^[dynamic]Mesh_Vertex, buckets: []Vertex_Bucket) -> i32 {
    bucket := vertex_hash(x, y, z)

    // Search for existing vertex with cycle protection
    i := buckets[bucket].first
    max_search := i32(len(verts) + 100) // Protection against infinite loops
    search_count := i32(0)
    for i != -1 && search_count < max_search {
        if i < 0 || i >= i32(len(verts)) {
            log.errorf("Invalid vertex index %d in bucket chain", i)
            break
        }
        v := &verts[i]
        if v.x == x && v.y == y && v.z == z {
            return i
        }
        i = v.next
        search_count += 1
    }

    if search_count >= max_search {
        log.errorf("Vertex search exceeded maximum iterations, possible cycle in bucket chain")
    }

    // Add new vertex
    i = i32(len(verts))
    append(verts, Mesh_Vertex{x = x, y = y, z = z, next = buckets[bucket].first})
    buckets[bucket].first = i
    return i
}

// Calculate 2D area of polygon (used for winding order)
calc_poly_area_2d :: proc "contextless" (verts: [][3]u16, indices: []int) -> i32 {
    area: i32 = 0
    j := len(verts) - 1

    for i in 0..<len(verts) {
        vi := verts[indices[i]]
        vj := verts[indices[j]]

        // Get XZ coordinates as 3D vectors and compute 2D cross product (Z component)
        v1 := [3]i32{i32(vi.x), 0, i32(vi.z)}
        v2 := [3]i32{i32(vj.x), 0, i32(vj.z)}
        area += linalg.cross(v1, v2).y

        j = i
    }

    return (area + 1) / 2
}

// Check if vertex is convex (for ear clipping)
is_convex_vertex :: proc "contextless" (verts: [][3]u16, indices: []i32, i: int) -> bool {

    prev := (i + len(verts) - 1) % len(verts)
    next := (i + 1) % len(verts)

    va := verts[indices[prev]]
    vb := verts[indices[i]]
    vc := verts[indices[next]]

    // Get XZ coordinates as 3D vectors
    v1 := [3]i32{i32(va.x), 0, i32(va.z)}
    v2 := [3]i32{i32(vb.x), 0, i32(vb.z)}
    v3 := [3]i32{i32(vc.x), 0, i32(vc.z)}

    // Calculate cross product to determine if angle is convex (Y component gives 2D cross product)
    ab := v2 - v1
    bc := v3 - v2

    return linalg.cross(ab, bc).y >= 0
}

// Check if point is inside triangle (for ear clipping)
point_in_triangle :: proc "contextless" (verts: [][3]u16, a, b, c, p: int) -> bool {
    // Get XZ coordinates as vectors
    va := verts[a].xz
    vb := verts[b].xz
    vc := verts[c].xz
    vp := verts[p].xz

    // Calculate barycentric coordinates
    v0 := vc - va
    v1 := vb - va
    v2 := vp - va

    dot00 := linalg.dot(v0, v0)
    dot01 := linalg.dot(v0, v1)
    dot02 := linalg.dot(v0, v2)
    dot11 := linalg.dot(v1, v1)
    dot12 := linalg.dot(v1, v2)

    inv_denom := 1.0 / f32(dot00 * dot11 - dot01 * dot01)
    u := f32(dot11 * dot02 - dot01 * dot12) * inv_denom
    v := f32(dot00 * dot12 - dot01 * dot02) * inv_denom

    return (u >= 0) && (v >= 0) && (u + v < 1)
}

// Geometric primitive functions for triangulation

// Calculate twice the signed area of triangle formed by three points
area2 :: proc "contextless" (verts: [][4]i32, a, b, c: i32) -> i32 {
    ab := verts[b].xz - verts[a].xz
    ac := verts[c].xz - verts[a].xz
    return linalg.vector_cross2(ab, ac)
}

// Check if point c is to the left of line from a to b
left :: proc "contextless" (verts: [][4]i32, a, b, c: i32) -> bool {
    return area2(verts, a, b, c) < 0
}

// Check if point c is to the left of or on line from a to b
left_on :: proc "contextless" (verts: [][4]i32, a, b, c: i32) -> bool {
    return area2(verts, a, b, c) <= 0
}

// Check if three points are collinear
collinear :: proc "contextless" (verts: [][4]i32, a, b, c: i32) -> bool {
    return area2(verts, a, b, c) == 0
}

// Check if vertices a and b are equal (in XZ plane) - matches C++ vequal behavior
vequal :: proc "contextless" (verts: [][4]i32, a, b: i32) -> bool {
    return verts[a].xz == verts[b].xz
}

// Check if point c is between points a and b on the same line
between :: proc "contextless" (verts: [][4]i32, a, b, c: i32) -> bool {
    if !collinear(verts, a, b, c) do return false

    if verts[a][0] != verts[b][0] {
        return (verts[a][0] <= verts[c][0] && verts[c][0] <= verts[b][0]) ||
               (verts[a][0] >= verts[c][0] && verts[c][0] >= verts[b][0])
    } else {
        return (verts[a][2] <= verts[c][2] && verts[c][2] <= verts[b][2]) ||
               (verts[a][2] >= verts[c][2] && verts[c][2] >= verts[b][2])
    }
}

// Check if segments ab and cd intersect properly (interiors intersect)
intersect_prop :: proc "contextless" (verts: [][4]i32, a, b, c, d: i32) -> bool {
    if collinear(verts, a, b, c) || collinear(verts, a, b, d) ||
       collinear(verts, c, d, a) || collinear(verts, c, d, b) {
        return false
    }

    return (left(verts, a, b, c) != left(verts, a, b, d)) &&
           (left(verts, c, d, a) != left(verts, c, d, b))
}

// Check if segments ab and cd intersect (including endpoints)
intersect :: proc "contextless" (verts: [][4]i32, a, b, c, d: i32) -> bool {
    if intersect_prop(verts, a, b, c, d) {
        return true
    } else if between(verts, a, b, c) || between(verts, a, b, d) ||
              between(verts, c, d, a) || between(verts, c, d, b) {
        return true
    } else {
        return false
    }
}

// Check if diagonal from vertex a to vertex c is internal to polygon
diagonalie :: proc "contextless" (verts: [][4]i32, indices: []u32, n: i32, a, c: i32) -> bool {
    a_idx := i32(indices[a] & 0x0fffffff)
    c_idx := i32(indices[c] & 0x0fffffff)

    for i in i32(0)..<n {
        b1_idx := i32(indices[i] & 0x0fffffff)
        b2_idx := i32(indices[(i + 1) % n] & 0x0fffffff)

        // Skip edges if diagonal endpoints match segment endpoints
        if vequal(verts, a_idx, b1_idx) || vequal(verts, c_idx, b1_idx) ||
           vequal(verts, a_idx, b2_idx) || vequal(verts, c_idx, b2_idx) {
            continue
        }

        if intersect(verts, a_idx, c_idx, b1_idx, b2_idx) {
            return false
        }
    }
    return true
}

// Check if diagonal is in cone of vertex a
in_cone :: proc "contextless" (verts: [][4]i32, indices: []u32, n: i32, a, b: i32) -> bool {
    a0_idx := i32(indices[(a + n - 1) % n] & 0x0fffffff)
    a1_idx := i32(indices[a] & 0x0fffffff)
    a2_idx := i32(indices[(a + 1) % n] & 0x0fffffff)
    b_idx := i32(indices[b] & 0x0fffffff)

    if left_on(verts, a0_idx, a1_idx, a2_idx) {
        return left(verts, a1_idx, b_idx, a0_idx) && left(verts, b_idx, a1_idx, a2_idx)
    } else {
        return !(left_on(verts, a1_idx, b_idx, a2_idx) && left_on(verts, b_idx, a1_idx, a0_idx))
    }
}

// Check if diagonal from a to b is valid
diagonal :: proc "contextless" (verts: [][4]i32, indices: []u32, n: i32, a, b: i32) -> bool {
    cone_check := in_cone(verts, indices, n, a, b)
    diag_check := diagonalie(verts, indices, n, a, b)
    if !cone_check || !diag_check {
        // log.debugf("    diagonal %d->%d failed: in_cone=%v, diagonalie=%v", a, b, cone_check, diag_check)
    }
    return cone_check && diag_check
}


// Loose versions for degenerate cases (more permissive)
diagonalie_loose :: proc "contextless" (verts: [][4]i32, indices: []u32, n: i32, a, c: i32) -> bool {
    a_idx := i32(indices[a] & 0x0fffffff)
    c_idx := i32(indices[c] & 0x0fffffff)

    for i in i32(0)..<n {
        b1_idx := i32(indices[i] & 0x0fffffff)
        b2_idx := i32(indices[(i + 1) % n] & 0x0fffffff)

        if vequal(verts, a_idx, b1_idx) || vequal(verts, c_idx, b1_idx) ||
           vequal(verts, a_idx, b2_idx) || vequal(verts, c_idx, b2_idx) {
            continue
        }

        if intersect_prop(verts, a_idx, c_idx, b1_idx, b2_idx) {
            return false
        }
    }
    return true
}

in_cone_loose :: proc "contextless" (verts: [][4]i32, indices: []u32, n: i32, a, b: i32) -> bool {
    a0_idx := i32(indices[(a + n - 1) % n] & 0x0fffffff)
    a1_idx := i32(indices[a] & 0x0fffffff)
    a2_idx := i32(indices[(a + 1) % n] & 0x0fffffff)
    b_idx := i32(indices[b] & 0x0fffffff)

    if left_on(verts, a0_idx, a1_idx, a2_idx) {
        return left_on(verts, a1_idx, b_idx, a0_idx) && left_on(verts, b_idx, a1_idx, a2_idx)
    } else {
        return !(left(verts, a1_idx, b_idx, a2_idx) && left(verts, b_idx, a1_idx, a0_idx))
    }
}

diagonal_loose :: proc "contextless" (verts: [][4]i32, indices: []u32, n: i32, a, b: i32) -> bool {
    return in_cone_loose(verts, indices, n, a, b) &&
           diagonalie_loose(verts, indices, n, a, b)
}


// Helper functions matching C++ Recast implementation
next :: proc "contextless" (i, n: i32) -> i32 {
    return i + 1 < n ? i + 1 : 0
}

prev :: proc "contextless" (i, n: i32) -> i32 {
    return i - 1 >= 0 ? i - 1 : n - 1
}

// Triangulate polygon using C++ Recast ear clipping algorithm
triangulate_polygon :: proc(verts: [][3]u16, indices: []i32, triangles: ^[dynamic]i32) -> bool {
    if len(verts) < 3 do return false
    if len(verts) == 3 {
        append(triangles, indices[0], indices[1], indices[2])
        return true
    }

    // Copy indices for manipulation and add ear marking bits
    // Use u32 to support the 0x80000000 flag bit
    work_indices := make([]u32, len(indices))
    defer delete(work_indices)
    for i in 0..<len(indices) {
        work_indices[i] = u32(indices[i])
    }
    // Convert vertices to int array for C++ compatibility (4 components per vertex)
    // We need all vertices that might be referenced by indices
    int_verts := make([][4]i32, len(verts))
    defer delete(int_verts)
    for i in 0..<len(verts) {
        v := verts[i]
        int_verts[i] = {i32(v.x), i32(v.y), i32(v.z), 0}  // x, y, z, padding
    }

    n := i32(len(indices))

    // Pre-mark all ears using bit flags
    // The last bit of the index is used to indicate if the vertex can be removed
    for i in 0..<n {
        i1 := next(i, n)
        i2 := next(i1, n)
        if diagonal(int_verts, work_indices, n, i, i2) {
            work_indices[i1] |= 0x80000000  // Mark middle vertex as removable ear
        }
    }

    // Check if we found any ears, fall back to loose diagonal test if needed
    ear_count := 0
    for i in 0..<n {
        if work_indices[i] & 0x80000000 != 0 {
            ear_count += 1
        }
    }
    if ear_count == 0 {
        // Try using loose diagonal test as fallback
        for i in 0..<n {
            i1 := next(i, n)
            i2 := next(i1, n)
            if diagonal_loose(int_verts, work_indices, n, i, i2) {
                work_indices[i1] |= 0x80000000  // Mark middle vertex as removable ear
            }
        }

        // Recount ears after loose test
        ear_count = 0
        for i in 0..<n {
            if work_indices[i] & 0x80000000 != 0 {
                ear_count += 1
            }
        }


    }

    // Remove ears until only triangle remains
    for n > 3 {
        min_len := i32(-1)
        mini := i32(-1)

        // Find ear with shortest diagonal (C++ algorithm)
        for i in 0..<n {
            i1 := next(i, n)
            if work_indices[i1] & 0x80000000 != 0 {
                // This is a marked ear, calculate diagonal length
                i2 := next(i1, n)
                p0_idx := i32(work_indices[i] & 0x0fffffff)
                p2_idx := i32(work_indices[i2] & 0x0fffffff)

                diff := [2]i32{
                    int_verts[p2_idx][0] - int_verts[p0_idx][0],
                    int_verts[p2_idx][2] - int_verts[p0_idx][2],
                }
                length := linalg.length2(diff)

                if min_len < 0 || length < min_len {
                    min_len = length
                    mini = i
                }
            }
        }

        if mini == -1 {
            // We might get here because the contour has overlapping segments
            // Try to recover by loosening up the inCone test
            min_len = -1
            for i in i32(0)..<n {
                i1 := next(i, n)
                i2 := next(i1, n)
                if diagonal_loose(int_verts, work_indices, n, i, i2) {
                    p0_idx := i32(work_indices[i] & 0x0fffffff)
                    p2_idx := i32(work_indices[i2] & 0x0fffffff)

                    dx := int_verts[p2_idx][0] - int_verts[p0_idx][0]
                    dy := int_verts[p2_idx][2] - int_verts[p0_idx][2]
                    length := dx*dx + dy*dy

                    if min_len < 0 || length < min_len {
                        min_len = length
                        mini = i
                    }
                }
            }

            if mini == -1 {
                // Last resort: try to triangulate as a fan from vertex 0
                if n >= 3 {
                    for i in i32(1)..<n-1 {
                        append(triangles, i32(work_indices[0] & 0x0fffffff),
                                        i32(work_indices[i] & 0x0fffffff),
                                        i32(work_indices[i+1] & 0x0fffffff))
                    }
                    return true
                }

                return false
            }
        }

        // Remove the selected ear
        i := mini
        i1 := next(i, n)
        i2 := next(i1, n)

        // Add triangle (unmask indices)
        append(triangles, i32(work_indices[i] & 0x0fffffff), i32(work_indices[i1] & 0x0fffffff), i32(work_indices[i2] & 0x0fffffff))

        // Remove P[i1] by copying P[i+1]...P[n-1] left one index
        n -= 1
        for k in i1..<n {
            work_indices[k] = work_indices[k + 1]
        }

        // Update indices after removal
        if i1 >= n do i1 = 0
        i = prev(i1, n)

        // Update diagonal flags for adjacent vertices
        prev_i := prev(i, n)
        next_i1 := next(i1, n)

        // Try strict diagonal first, then loose
        diag1 := diagonal(int_verts, work_indices, n, prev_i, i1)
        if !diag1 {
            diag1 = diagonal_loose(int_verts, work_indices, n, prev_i, i1)
        }
        if diag1 {
            work_indices[i] |= 0x80000000
        } else {
            work_indices[i] &= 0x0fffffff
        }

        diag2 := diagonal(int_verts, work_indices, n, i, next_i1)
        if !diag2 {
            diag2 = diagonal_loose(int_verts, work_indices, n, i, next_i1)
        }
        if diag2 {
            work_indices[i1] |= 0x80000000
        } else {
            work_indices[i1] &= 0x0fffffff
        }
    }

    // Append the remaining triangle (unmask indices)
    append(triangles, i32(work_indices[0] & 0x0fffffff), i32(work_indices[1] & 0x0fffffff), i32(work_indices[2] & 0x0fffffff))

    return true
}

// Validate polygon mesh data
validate_poly_mesh :: proc(pmesh: ^Poly_Mesh) -> bool {
    if pmesh == nil do return false
    if len(pmesh.verts) <= 0 || pmesh.npolys <= 0 do return false
    if pmesh.nvp < 3 do return false

    // Check vertex bounds
    // verts are now [][3]u16, so no need to check bounds

    // Check polygon data
    for i in 0..<pmesh.npolys {
        pi := int(i) * int(pmesh.nvp) * 2
        if pi + int(pmesh.nvp) * 2 > len(pmesh.polys) do return false

        // Check vertex indices
        for j in 0..<pmesh.nvp {
            vert_idx := pmesh.polys[pi + int(j)]
            if vert_idx != RC_MESH_NULL_IDX && int(vert_idx) >= len(pmesh.verts) {
                return false
            }
        }
    }

    return true
}

// Copy polygon mesh
copy_poly_mesh :: proc(src: ^Poly_Mesh, dst: ^Poly_Mesh) -> bool {
    if src == nil || dst == nil do return false

    // Copy header data
    dst.npolys = src.npolys
    dst.maxpolys = src.maxpolys
    dst.nvp = src.nvp
    dst.bmin = src.bmin
    dst.bmax = src.bmax
    dst.cs = src.cs
    dst.ch = src.ch
    dst.border_size = src.border_size
    dst.max_edge_error = src.max_edge_error

    // Copy arrays
    if len(src.verts) > 0 {
        dst.verts = make([][3]u16, len(src.verts))
        copy(dst.verts, src.verts)
    }

    if src.npolys > 0 {
        poly_size := src.npolys * src.nvp * 2
        dst.polys = make([]u16, poly_size)
        copy(dst.polys, src.polys)

        dst.regs = make([]u16, src.npolys)
        copy(dst.regs, src.regs)

        dst.flags = make([]u16, src.npolys)
        copy(dst.flags, src.flags)

        dst.areas = make([]u8, src.npolys)
        copy(dst.areas, src.areas)
    }

    return true
}

// Merge two polygon meshes
merge_poly_meshes :: proc(meshes: []^Poly_Mesh, mesh: ^Poly_Mesh) -> bool {
    if len(meshes) == 0 do return false
    if len(meshes) == 1 {
        return copy_poly_mesh(meshes[0], mesh)
    }

    // Calculate total sizes
    max_verts := 0
    max_polys := 0
    max_nvp := 0

    for i in 0..<len(meshes) {
        if meshes[i] == nil do continue
        max_verts += len(meshes[i].verts)
        max_polys += int(meshes[i].npolys)
        max_nvp = max(max_nvp, int(meshes[i].nvp))
    }

    if max_verts == 0 || max_polys == 0 do return false

    // Use first mesh as template
    template := meshes[0]
    mesh.npolys = 0
    mesh.maxpolys = i32(max_polys)
    mesh.nvp = i32(max_nvp)
    mesh.bmin = template.bmin
    mesh.bmax = template.bmax
    mesh.cs = template.cs
    mesh.ch = template.ch
    mesh.border_size = template.border_size
    mesh.max_edge_error = template.max_edge_error

    // Allocate arrays
    mesh.verts = make([][3]u16, max_verts)
    mesh.polys = make([]u16, max_polys * max_nvp * 2)
    mesh.regs = make([]u16, max_polys)
    mesh.flags = make([]u16, max_polys)
    mesh.areas = make([]u8, max_polys)

    slice.fill(mesh.polys, RC_MESH_NULL_IDX)

    // Merge meshes
    next_vert := 0
    next_poly := 0

    for i in 0..<len(meshes) {
        src := meshes[i]
        if src == nil do continue

        // Copy vertices
        vert_offset := next_vert
        for j in 0..<len(src.verts) {
            mesh.verts[next_vert] = src.verts[j]
            next_vert += 1
        }

        // Copy polygons
        for j in 0..<src.npolys {
            pi_src := int(j) * int(src.nvp) * 2
            pi_dst := next_poly * int(mesh.nvp) * 2

            // Copy vertex indices (adjust for vertex offset)
            for k in 0..<src.nvp {
                if src.polys[pi_src + int(k)] == RC_MESH_NULL_IDX {
                    mesh.polys[pi_dst + int(k)] = RC_MESH_NULL_IDX
                } else {
                    mesh.polys[pi_dst + int(k)] = src.polys[pi_src + int(k)] + u16(vert_offset)
                }
            }

            // Copy neighbor data (needs adjustment)
            for k in 0..<src.nvp {
                mesh.polys[pi_dst + int(mesh.nvp) + int(k)] = RC_MESH_NULL_IDX  // Reset neighbors
            }

            // Copy polygon attributes
            mesh.regs[next_poly] = src.regs[j]
            mesh.flags[next_poly] = src.flags[j]
            mesh.areas[next_poly] = src.areas[j]
            next_poly += 1
        }
    }

    mesh.npolys = i32(next_poly)

    return true
}

// Build edge list from polygon data (for neighbor finding)
build_mesh_edges :: proc(pmesh: ^Poly_Mesh, edges: ^[dynamic]Mesh_Edge, max_edges: i32) -> bool {
    clear(edges)

    for i in 0..<pmesh.npolys {
        pi := int(i) * int(pmesh.nvp) * 2

        // Find actual number of vertices in this polygon
        nverts := 0
        for j in 0..<pmesh.nvp {
            if pmesh.polys[pi + int(j)] != RC_MESH_NULL_IDX {
                nverts += 1
            } else {
                break
            }
        }

        if nverts < 3 do continue

        // Add edges for this polygon
        for j in 0..<nverts {
            k := (j + 1) % nverts
            va := pmesh.polys[pi + j]
            vb := pmesh.polys[pi + k]

            if va == vb do continue  // Skip degenerate edges

            // Ensure consistent edge ordering (smaller vertex first)
            if va > vb {
                va, vb = vb, va
            }

            // Look for existing edge
            found := false
            for &edge in edges {
                if edge.vert[0] == va && edge.vert[1] == vb {
                    // Found matching edge - this is a shared edge
                    if edge.poly[1] == RC_MESH_NULL_IDX {
                        edge.poly[1] = u16(i)
                        edge.poly_edge[1] = u16(j)
                    }
                    found = true
                    break
                }
            }

            if !found {
                if len(edges) >= int(max_edges) {
                    log.warn("Mesh edge limit reached")
                    return false
                }

                // Add new edge
                append(edges, Mesh_Edge{
                    vert = {va, vb},
                    poly = {u16(i), RC_MESH_NULL_IDX},
                    poly_edge = {u16(j), RC_MESH_NULL_IDX},
                })
            }
        }
    }

    return true
}

// Update polygon neighbor information from edge list
update_polygon_neighbors :: proc(pmesh: ^Poly_Mesh, edges: []Mesh_Edge) {
    // Initialize all neighbors to null
    for i in 0..<pmesh.npolys {
        pi := int(i) * int(pmesh.nvp) * 2
        for j in 0..<pmesh.nvp {
            pmesh.polys[pi + int(pmesh.nvp) + int(j)] = RC_MESH_NULL_IDX
        }
    }

    // Set neighbors from edges
    for edge in edges {
        if edge.poly[1] == RC_MESH_NULL_IDX do continue  // Not a shared edge

        // Set neighbor for first polygon
        pi0 := int(edge.poly[0]) * int(pmesh.nvp) * 2
        edge_idx0 := int(edge.poly_edge[0])
        pmesh.polys[pi0 + int(pmesh.nvp) + edge_idx0] = edge.poly[1]

        // Set neighbor for second polygon
        pi1 := int(edge.poly[1]) * int(pmesh.nvp) * 2
        edge_idx1 := int(edge.poly_edge[1])
        pmesh.polys[pi1 + int(pmesh.nvp) + edge_idx1] = edge.poly[0]
    }
}

// Edge structure for triangle merging
Triangle_Edge :: struct {
    v0, v1: i32,           // Vertex indices (ordered: v0 < v1)
    tri: i32,              // Triangle index that owns this edge
    edge_idx: i32,         // Edge index within triangle (0, 1, or 2)
}

// Check if two triangles share an edge
triangles_share_edge :: proc(tri1, tri2: []i32) -> (shares: bool, shared_edge: [2]i32) {
    if len(tri1) < 3 || len(tri2) < 3 do return false, {}

    // Check all edge combinations
    for i in 0..<3 {
        v1a := tri1[i]
        v1b := tri1[(i + 1) % 3]

        for j in 0..<3 {
            v2a := tri2[j]
            v2b := tri2[(j + 1) % 3]

            // Check if edges match (in either direction)
            if (v1a == v2a && v1b == v2b) || (v1a == v2b && v1b == v2a) {
                return true, {v1a, v1b}
            }
        }
    }

    return false, {}
}

// Get vertices of a polygon formed by merging triangles
get_merged_polygon_vertices :: proc(triangle_indices: []i32, triangles: []i32, verts: ^[dynamic]i32) {
    clear(verts)
    if len(triangle_indices) == 0 do return

    // Start with first triangle
    first_tri := triangle_indices[0] * 3
    append(verts, triangles[first_tri], triangles[first_tri + 1], triangles[first_tri + 2])

    // For each additional triangle, find the shared edge and insert the non-shared vertex
    for i in 1..<len(triangle_indices) {
        tri_idx := triangle_indices[i] * 3
        new_tri := triangles[tri_idx:tri_idx + 3]

        shared_edge: [2]i32
        shared_found := false

        // Find shared edge with existing polygon
        for j in 0..<len(verts) {
            v1 := verts[j]
            v2 := verts[(j + 1) % len(verts)]

            // Check if this edge matches any edge in the new triangle
            for k in 0..<3 {
                tv1 := new_tri[k]
                tv2 := new_tri[(k + 1) % 3]

                if (v1 == tv1 && v2 == tv2) || (v1 == tv2 && v2 == tv1) {
                    shared_edge[0] = v1
                    shared_edge[1] = v2
                    shared_found = true

                    // Find the non-shared vertex in the triangle
                    non_shared_vert := new_tri[(k + 2) % 3]

                    // Insert the non-shared vertex after the shared edge
                    inject_at(verts, (j + 1) % len(verts), non_shared_vert)
                    break
                }
            }
            if shared_found do break
        }

        if !shared_found {
            log.warnf("Could not find shared edge when merging triangle %d", triangle_indices[i])
        }
    }
}

// Check if polygon is convex and valid
is_valid_polygon :: proc(verts: []i32, max_verts: i32) -> bool {
    if len(verts) < 3 || len(verts) > int(max_verts) do return false

    // Check for duplicate vertices
    for i in 0..<len(verts) {
        for j in i + 1..<len(verts) {
            if verts[i] == verts[j] {
                return false
            }
        }
    }

    // Check convexity - navigation meshes require convex polygons
    // Use the "left turn" test for all vertices
    n := len(verts)
    for i in 0..<n {
        v0 := verts[i]
        v1 := verts[(i + 1) % n]
        v2 := verts[(i + 2) % n]

        // NOTE: Cannot check convexity here without access to actual vertex positions
        // This check would require the mesh vertex array, not just indices
    }

    return true
}

// Merge triangles into polygons with maximum vertex count
merge_triangles_into_polygons :: proc(triangles: []i32, polys: ^[dynamic]Poly_Build, max_verts: i32, area: u8, reg: u16) {
    if len(triangles) % 3 != 0 {
        log.warn("Invalid triangle array length for merging")
        return
    }

    num_triangles := len(triangles) / 3
    if num_triangles == 0 do return

    used := make([]bool, num_triangles)
    defer delete(used)

    // Build edge adjacency map
    edges := make([dynamic]Triangle_Edge, 0, num_triangles * 3)
    defer delete(edges)

    for tri_idx in 0..<num_triangles {
        base := tri_idx * 3
        for edge_idx in 0..<3 {
            v0 := triangles[base + edge_idx]
            v1 := triangles[base + (edge_idx + 1) % 3]

            // Ensure consistent edge ordering (smaller vertex first)
            if v0 > v1 {
                v0, v1 = v1, v0
            }

            append(&edges, Triangle_Edge{
                v0 = v0,
                v1 = v1,
                tri = i32(tri_idx),
                edge_idx = i32(edge_idx),
            })
        }
    }

    // Sort edges for adjacency finding
    slice.sort_by(edges[:], proc(a, b: Triangle_Edge) -> bool {
        if a.v0 != b.v0 do return a.v0 < b.v0
        if a.v1 != b.v1 do return a.v1 < b.v1
        return a.tri < b.tri
    })



    merged_polys := 0
    total_triangles_used := 0

    // Greedy merging: start from each unused triangle and try to grow polygons
    for start_tri in 0..<num_triangles {
        if used[start_tri] do continue

        // Start a new polygon with this triangle
        current_group := make([dynamic]i32, 0, max_verts)

        append(&current_group, i32(start_tri))
        used[start_tri] = true

        // Try to merge adjacent triangles
        MAX_MERGE_ITERATIONS :: 20 // Safety limit
        for iter in 0..<MAX_MERGE_ITERATIONS {
            found_merge := false

            // Try to find a triangle that shares an edge with the current group
            for candidate_tri in 0..<num_triangles {
                if used[candidate_tri] do continue

                // Check if this triangle shares an edge with any triangle in current group
                can_merge := false
                for group_tri_idx in current_group {
                    base1 := group_tri_idx * 3
                    base2 := candidate_tri * 3

                    tri1 := triangles[base1:base1 + 3]
                    tri2 := triangles[base2:base2 + 3]

                    if shares, _ := triangles_share_edge(tri1, tri2); shares {
                        can_merge = true
                        break
                    }
                }

                if can_merge {
                    // Try merging and check if resulting polygon is valid
                    test_group := make([dynamic]i32, len(current_group) + 1)
                    defer delete(test_group)
                    copy(test_group[:len(current_group)], current_group[:])
                    test_group[len(current_group)] = i32(candidate_tri)

                    test_verts := make([dynamic]i32, 0, max_verts)
                    defer delete(test_verts)
                    get_merged_polygon_vertices(test_group[:], triangles, &test_verts)

                    if is_valid_polygon(test_verts[:], max_verts) {
                        // Valid merge - add triangle to group
                        append(&current_group, i32(candidate_tri))
                        used[candidate_tri] = true
                        found_merge = true

                        break
                    }
                }
            }

            if !found_merge do break
        }

        // Create polygon from the merged triangles
        final_verts := make([dynamic]i32, 0, max_verts)
        get_merged_polygon_vertices(current_group[:], triangles, &final_verts)

        if len(final_verts) >= 3 && len(final_verts) <= int(max_verts) {
            // Verify polygon is within limits
            assert(len(final_verts) <= int(max_verts),
                   fmt.tprintf("Generated polygon exceeds vertex limit: %d > %d", len(final_verts), max_verts))

            poly := Poly_Build{
                verts = make([]i32, len(final_verts)),
                area = area,
                reg = reg,
            }

            copy(poly.verts, final_verts[:])
            append(polys, poly)
            merged_polys += 1
            total_triangles_used += len(current_group)


        } else {
            // Fallback: create individual triangles
            for tri_idx in current_group {
                base := tri_idx * 3

                // Verify triangle is within limits (should always be true)
                assert(3 <= int(max_verts),
                       fmt.tprintf("Triangle cannot fit in polygon limit: 3 > %d", max_verts))

                poly := Poly_Build{
                    verts = make([]i32, 3),
                    area = area,
                    reg = reg,
                }

                poly.verts[0] = triangles[base + 0]
                poly.verts[1] = triangles[base + 1]
                poly.verts[2] = triangles[base + 2]

                append(polys, poly)
                merged_polys += 1
            }
        }

        delete(final_verts)
        delete(current_group)
    }


}

// Main function to build polygon mesh from contour set
build_poly_mesh :: proc(cset: ^Contour_Set, nvp: i32, pmesh: ^Poly_Mesh) -> bool {
    if cset == nil || pmesh == nil do return false
    if len(cset.conts) == 0 do return false
    if nvp < 3 do return false



    // Initialize mesh
    pmesh.npolys = 0
    pmesh.maxpolys = 0
    pmesh.nvp = nvp
    pmesh.bmin = cset.bmin
    pmesh.bmax = cset.bmax
    pmesh.cs = cset.cs
    pmesh.ch = cset.ch
    pmesh.border_size = cset.border_size
    pmesh.max_edge_error = cset.max_error

    // Estimate sizes
    max_vertices := 0
    max_polygons := 0
    max_edges := 0

    for i in 0..<len(cset.conts) {
        cont := &cset.conts[i]
        if len(cont.verts) < 3 do continue
        max_vertices += len(cont.verts)
        max_polygons += len(cont.verts) - 2  // Triangulation creates n-2 triangles
        max_edges += len(cont.verts) * 3     // Conservative estimate
    }

    if max_vertices == 0 do return false

    // Allocate temporary structures
    verts := make([dynamic]Mesh_Vertex, 0, max_vertices)
    defer delete(verts)

    buckets := make([]Vertex_Bucket, RC_VERTEX_BUCKET_COUNT)
    defer delete(buckets)
    for &bucket in buckets {
        bucket.first = -1
    }

    polys := make([dynamic]Poly_Build, 0, max_polygons)
    defer delete(polys)

    edges := make([dynamic]Mesh_Edge, 0, max_edges)
    defer delete(edges)

    triangles := make([dynamic]i32, 0, max_polygons * 3)
    defer delete(triangles)

    indices := make([]i32, nvp)  // Working buffer for polygon indices
    defer delete(indices)



    // Process each contour
    for i in 0..<len(cset.conts) {
        cont := &cset.conts[i]
        if len(cont.verts) < 3 {
            continue
        }

        // Build arrays for triangulation (matching C++ implementation)
        // First, create vertices array just for this contour
        contour_verts := make([][3]u16, len(cont.verts))
        defer delete(contour_verts)

        // Create sequential indices as expected by triangulate_polygon
        indices := make([]i32, len(cont.verts))
        defer delete(indices)

        // Map from contour vertex index to global vertex index
        vertex_map := make([]i32, len(cont.verts))
        defer delete(vertex_map)

        for j in 0..<len(cont.verts) {
            v := cont.verts[j]
            // Add to global vertex list and store the mapping
            vert_idx := add_vertex(u16(v.x), u16(v.y), u16(v.z), &verts, buckets)
            vertex_map[j] = vert_idx

            // Set up data for triangulation
            contour_verts[j] = {u16(v.x), u16(v.y), u16(v.z)}
            indices[j] = i32(j)  // Sequential indices as expected by triangulate
        }

        // Triangulate the contour
        clear(&triangles)

        if !triangulate_polygon(contour_verts, indices, &triangles) {
            continue
        }

        // Map triangulated indices back to global vertex indices
        // The triangles contain indices into contour_verts, we need to map them to global vertex indices
        for i in 0..<len(triangles) {
            triangles[i] = vertex_map[triangles[i]]
        }

        // Group triangles into convex polygons with max nvp vertices
        // Based on C++ implementation from RecastMesh.cpp

        // Start with triangles as initial polygons
        region_polys := make([dynamic]Poly_Build, context.temp_allocator)
        for tri_idx in 0..<len(triangles)/3 {
            base := tri_idx * 3
            poly := Poly_Build{
                verts = make([]i32, 3, context.temp_allocator),
                area = cont.area,
                reg = cont.reg,
            }
            poly.verts[0] = triangles[base + 0]
            poly.verts[1] = triangles[base + 1]
            poly.verts[2] = triangles[base + 2]
            append(&region_polys, poly)
        }

        // Merge triangles into convex polygons
        if nvp > 3 {
            // Keep merging while possible
            for {
                best_merge_value := i32(0)
                best_pa := -1
                best_pb := -1
                best_ea := i32(-1)
                best_eb := i32(-1)

                // Find best merge candidate
                for i in 0..<len(region_polys) {
                    pa := &region_polys[i]
                    for j in i+1..<len(region_polys) {
                        pb := &region_polys[j]

                        // Check if we can merge these polygons
                        ea, eb, merge_value := get_poly_merge_value(pa.verts[:], pb.verts[:], verts[:], nvp)
                        if merge_value > best_merge_value {
                            best_pa = i
                            best_pb = j
                            best_ea = ea
                            best_eb = eb
                            best_merge_value = merge_value
                        }
                    }
                }

                // No more merges possible
                if best_pa == -1 || best_pb == -1 {
                    break
                }

                // Merge the polygons
                merge_poly_verts(&region_polys[best_pa], &region_polys[best_pb], best_ea, best_eb, nvp)

                // Remove the merged polygon
                ordered_remove(&region_polys, best_pb)
            }
        }

        // Add merged polygons to result
        for poly in region_polys {
            // Create a copy with proper allocation
            final_poly := Poly_Build{
                verts = make([]i32, len(poly.verts)),
                area = poly.area,
                reg = poly.reg,
            }
            copy(final_poly.verts[:], poly.verts[:])
            append(&polys, final_poly)
        }
    }

    if len(polys) == 0 {
        return false
    }

    // Allocate final mesh arrays
    pmesh.npolys = i32(len(polys))
    pmesh.maxpolys = pmesh.npolys

    pmesh.verts = make([][3]u16, len(verts))
    pmesh.polys = make([]u16, pmesh.npolys * nvp * 2)
    pmesh.regs = make([]u16, pmesh.npolys)
    pmesh.flags = make([]u16, pmesh.npolys)
    pmesh.areas = make([]u8, pmesh.npolys)
    slice.fill(pmesh.polys, RC_MESH_NULL_IDX)

    // Copy vertices to final mesh
    for i := 0; i < len(verts); i += 1 {
        vert := verts[i]
        pmesh.verts[i] = {vert.x, vert.y, vert.z}
    }

    // Copy polygons to final mesh
    for i := 0; i < len(polys); i += 1 {
        poly := polys[i]
        pi := i * int(nvp) * 2

        // Copy vertex indices
        for j in 0..<len(poly.verts) {
            pmesh.polys[pi + int(j)] = u16(poly.verts[j])
        }

        // Set polygon attributes
        pmesh.regs[i] = poly.reg
        pmesh.areas[i] = poly.area
        pmesh.flags[i] = 1  // Default walkable flag

        // Clean up poly vertex memory
        delete(poly.verts)
    }

    // Build edge connectivity
    if build_mesh_edges(pmesh, &edges, i32(max_edges)) {
        update_polygon_neighbors(pmesh, edges[:])
    }

    // Validate final mesh
    if !validate_poly_mesh(pmesh) {
        return false
    }

    return true
}

// Weld nearby vertices together to reduce mesh complexity
weld_poly_mesh_vertices :: proc(pmesh: ^Poly_Mesh, weld_tolerance: f32) -> bool {
    if pmesh == nil || len(pmesh.verts) == 0 do return false
    old_vert_count := len(pmesh.verts)
    tolerance_sq := weld_tolerance * weld_tolerance
    // Create vertex remapping table
    remap := make([]i32, len(pmesh.verts))
    defer delete(remap)

    // Initialize remap to identity
    for i in 0..<len(pmesh.verts) {
        remap[i] = i32(i)
    }

    // Find vertices to weld
    for i in 0..<len(pmesh.verts) {
        if remap[i] != i32(i) do continue  // Already remapped
        // Check all subsequent vertices for welding candidates
        for j in i+1..<len(pmesh.verts) {
            if remap[j] != i32(j) do continue  // Already remapped
            delta := [3]f32{
                f32(pmesh.verts[j].x - pmesh.verts[i].x),
                f32(pmesh.verts[j].y - pmesh.verts[i].y),
                f32(pmesh.verts[j].z - pmesh.verts[i].z),
            }
            dist_sq := linalg.length2(delta)
            if dist_sq <= tolerance_sq {
                remap[j] = i32(i)  // Weld vertex j to vertex i
            }
        }
    }

    // Compact vertex array and build final remapping
    new_verts := make([dynamic][3]u16, 0, len(pmesh.verts))
    defer delete(new_verts)

    final_remap := make([]i32, len(pmesh.verts))
    defer delete(final_remap)

    new_vert_count := 0
    for i in 0..<len(pmesh.verts) {
        if remap[i] == i32(i) {
            final_remap[i] = i32(new_vert_count)
            append(&new_verts, pmesh.verts[i])
            new_vert_count += 1
        } else {
            // This vertex is welded to another
            final_remap[i] = final_remap[remap[i]]
        }
    }
    if new_vert_count == len(pmesh.verts) {
        // No vertices were welded
        return true
    }
    // Update vertex array
    delete(pmesh.verts)
    pmesh.verts = make([][3]u16, len(new_verts))
    copy(pmesh.verts, new_verts[:])

    // Update polygon vertex indices
    for i in 0..<pmesh.npolys {
        pi := int(i) * int(pmesh.nvp) * 2

        for j in 0..<pmesh.nvp {
            if pmesh.polys[pi + int(j)] != RC_MESH_NULL_IDX {
                old_idx := int(pmesh.polys[pi + int(j)])
                pmesh.polys[pi + int(j)] = u16(final_remap[old_idx])
            }
        }
    }

    return true
}

// Remove degenerate polygons and unused vertices
remove_degenerate_polys :: proc(pmesh: ^Poly_Mesh) -> bool {
    if pmesh == nil || pmesh.npolys == 0 do return false



    old_poly_count := pmesh.npolys
    kept_polys := 0

    // Process each polygon
    for i in 0..<pmesh.npolys {
        pi := int(i) * int(pmesh.nvp) * 2

        // Count valid vertices
        nverts := 0
        for j in 0..<pmesh.nvp {
            if pmesh.polys[pi + int(j)] != RC_MESH_NULL_IDX {
                nverts += 1
            } else {
                break
            }
        }

        // Check for degenerate cases
        is_degenerate := false

        if nverts < 3 {
            is_degenerate = true
        } else {
            // Check for duplicate vertices
            for j in 0..<nverts {
                for k in j+1..<nverts {
                    if pmesh.polys[pi + j] == pmesh.polys[pi + k] {
                        is_degenerate = true
                        break
                    }
                }
                if is_degenerate do break
            }
        }

        if !is_degenerate {
            // Keep this polygon - move it to the kept position if needed
            if kept_polys != int(i) {
                kept_pi := kept_polys * int(pmesh.nvp) * 2

                // Copy polygon data
                for j in 0..<int(pmesh.nvp) * 2 {
                    pmesh.polys[kept_pi + j] = pmesh.polys[pi + j]
                }

                // Copy attributes
                pmesh.regs[kept_polys] = pmesh.regs[i]
                pmesh.flags[kept_polys] = pmesh.flags[i]
                pmesh.areas[kept_polys] = pmesh.areas[i]
            }
            kept_polys += 1
        }
    }

    pmesh.npolys = i32(kept_polys)


    return true
}

// Remove unused vertices from the mesh
remove_unused_vertices :: proc(pmesh: ^Poly_Mesh) -> bool {
    if pmesh == nil || len(pmesh.verts) == 0 do return false

    // Mark used vertices
    used := make([]bool, len(pmesh.verts))
    defer delete(used)

    for i in 0..<pmesh.npolys {
        pi := int(i) * int(pmesh.nvp) * 2
        for j in 0..<pmesh.nvp {
            if pmesh.polys[pi + int(j)] != RC_MESH_NULL_IDX {
                vert_idx := int(pmesh.polys[pi + int(j)])
                if vert_idx < len(used) {
                    used[vert_idx] = true
                }
            }
        }
    }

    // Build vertex remapping
    remap := make([]i32, len(pmesh.verts))
    defer delete(remap)

    new_vert_count := 0
    for i in 0..<len(pmesh.verts) {
        if used[i] {
            remap[i] = i32(new_vert_count)
            new_vert_count += 1
        } else {
            remap[i] = -1
        }
    }

    if new_vert_count == len(pmesh.verts) {
        // All vertices are used
        return true
    }



    // Compact vertex array
    new_verts := make([][3]u16, new_vert_count)
    defer delete(new_verts)

    for i in 0..<len(pmesh.verts) {
        if used[i] {
            new_verts[remap[i]] = pmesh.verts[i]
        }
    }

    // Update vertex array
    delete(pmesh.verts)
    pmesh.verts = make([][3]u16, len(new_verts))
    copy(pmesh.verts, new_verts)

    // Update polygon vertex indices
    for i in 0..<pmesh.npolys {
        pi := int(i) * int(pmesh.nvp) * 2
        for j in 0..<pmesh.nvp {
            if pmesh.polys[pi + int(j)] != RC_MESH_NULL_IDX {
                old_idx := int(pmesh.polys[pi + int(j)])
                if old_idx < len(remap) && remap[old_idx] != -1 {
                    pmesh.polys[pi + int(j)] = u16(remap[old_idx])
                } else {
                    pmesh.polys[pi + int(j)] = RC_MESH_NULL_IDX
                }
            }
        }
    }

    return true
}

// Comprehensive mesh optimization
optimize_poly_mesh :: proc(pmesh: ^Poly_Mesh, weld_tolerance: f32) -> bool {
    if pmesh == nil do return false



    // Step 1: Remove degenerate polygons
    if !remove_degenerate_polys(pmesh) {
        log.warn("Failed to remove degenerate polygons")
    }

    // Step 2: Weld nearby vertices
    if weld_tolerance > 0.0 {
        if !weld_poly_mesh_vertices(pmesh, weld_tolerance) {
            log.warn("Failed to weld vertices")
        }
    }

    // Step 3: Remove unused vertices
    if !remove_unused_vertices(pmesh) {
        log.warn("Failed to remove unused vertices")
    }

    // Step 4: Rebuild edges for connectivity
    edges := make([dynamic]Mesh_Edge, 0, pmesh.npolys * 3)
    defer delete(edges)

    if build_mesh_edges(pmesh, &edges, pmesh.npolys * 3) {
        update_polygon_neighbors(pmesh, edges[:])
    }

    // Step 5: Final validation
    if !validate_poly_mesh(pmesh) {
        log.error("Mesh optimization resulted in invalid mesh")
        return false
    }


    return true
}
