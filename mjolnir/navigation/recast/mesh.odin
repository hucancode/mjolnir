package navigation_recast


import "core:slice"
import "core:log"
import "core:mem"
import "core:math"
import "core:math/linalg"
import "core:fmt"

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
    nverts:    i32,         // Number of vertices
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
calc_poly_area_2d :: proc "contextless" (verts: []u16, indices: []i32, nverts: i32) -> i32 {
    area: i32 = 0
    j := nverts - 1

    for i in 0..<nverts {
        vi := indices[i] * 3
        vj := indices[j] * 3

        // Get XZ coordinates as 3D vectors and compute 2D cross product (Z component)
        v1 := [3]i32{i32(verts[vi+0]), 0, i32(verts[vi+2])}
        v2 := [3]i32{i32(verts[vj+0]), 0, i32(verts[vj+2])}
        area += linalg.cross(v1, v2).y

        j = i
    }

    return (area + 1) / 2
}

// Check if vertex is convex (for ear clipping)
is_convex_vertex :: proc "contextless" (verts: []u16, indices: []i32, nverts: i32, i: i32) -> bool {
    prev := (i + nverts - 1) % nverts
    next := (i + 1) % nverts

    a := indices[prev] * 3
    b := indices[i] * 3
    c := indices[next] * 3

    // Get XZ coordinates as 3D vectors
    va := [3]i32{i32(verts[a+0]), 0, i32(verts[a+2])}
    vb := [3]i32{i32(verts[b+0]), 0, i32(verts[b+2])}
    vc := [3]i32{i32(verts[c+0]), 0, i32(verts[c+2])}

    // Calculate cross product to determine if angle is convex (Y component gives 2D cross product)
    ab := vb - va
    bc := vc - vb

    return linalg.cross(ab, bc).y >= 0
}

// Check if point is inside triangle (for ear clipping)
point_in_triangle :: proc "contextless" (verts: []u16, a, b, c, p: i32) -> bool {
    // Get XZ coordinates as vectors
    va := [2]i32{i32(verts[a*3+0]), i32(verts[a*3+2])}
    vb := [2]i32{i32(verts[b*3+0]), i32(verts[b*3+2])}
    vc := [2]i32{i32(verts[c*3+0]), i32(verts[c*3+2])}
    vp := [2]i32{i32(verts[p*3+0]), i32(verts[p*3+2])}

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
area2 :: proc "contextless" (verts: []i32, a, b, c: i32) -> i32 {
    return (verts[b*4+0] - verts[a*4+0]) * (verts[c*4+2] - verts[a*4+2]) -
           (verts[c*4+0] - verts[a*4+0]) * (verts[b*4+2] - verts[a*4+2])
}

// Check if point c is to the left of line from a to b
left :: proc "contextless" (verts: []i32, a, b, c: i32) -> bool {
    return area2(verts, a, b, c) < 0
}

// Check if point c is to the left of or on line from a to b
left_on :: proc "contextless" (verts: []i32, a, b, c: i32) -> bool {
    return area2(verts, a, b, c) <= 0
}

// Check if three points are collinear
collinear :: proc "contextless" (verts: []i32, a, b, c: i32) -> bool {
    return area2(verts, a, b, c) == 0
}

// Check if vertices a and b are equal (in XZ plane) - matches C++ vequal behavior
vequal :: proc "contextless" (verts: []i32, a, b: i32) -> bool {
    return verts[a*4+0] == verts[b*4+0] && verts[a*4+2] == verts[b*4+2]
}

// Check if point c is between points a and b on the same line
between :: proc "contextless" (verts: []i32, a, b, c: i32) -> bool {
    if !collinear(verts, a, b, c) do return false

    if verts[a*4+0] != verts[b*4+0] {
        return (verts[a*4+0] <= verts[c*4+0] && verts[c*4+0] <= verts[b*4+0]) ||
               (verts[a*4+0] >= verts[c*4+0] && verts[c*4+0] >= verts[b*4+0])
    } else {
        return (verts[a*4+2] <= verts[c*4+2] && verts[c*4+2] <= verts[b*4+2]) ||
               (verts[a*4+2] >= verts[c*4+2] && verts[c*4+2] >= verts[b*4+2])
    }
}

// Check if segments ab and cd intersect properly (interiors intersect)
intersect_prop :: proc "contextless" (verts: []i32, a, b, c, d: i32) -> bool {
    if collinear(verts, a, b, c) || collinear(verts, a, b, d) ||
       collinear(verts, c, d, a) || collinear(verts, c, d, b) {
        return false
    }

    return (left(verts, a, b, c) != left(verts, a, b, d)) &&
           (left(verts, c, d, a) != left(verts, c, d, b))
}

// Check if segments ab and cd intersect (including endpoints)
intersect :: proc "contextless" (verts: []i32, a, b, c, d: i32) -> bool {
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
diagonalie :: proc "contextless" (verts: []i32, indices: []u32, n: i32, a, c: i32) -> bool {
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
in_cone :: proc "contextless" (verts: []i32, indices: []u32, n: i32, a, b: i32) -> bool {
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
diagonal :: proc "contextless" (verts: []i32, indices: []u32, n: i32, a, b: i32) -> bool {
    cone_check := in_cone(verts, indices, n, a, b)
    diag_check := diagonalie(verts, indices, n, a, b)
    if !cone_check || !diag_check {
        // log.debugf("    diagonal %d->%d failed: in_cone=%v, diagonalie=%v", a, b, cone_check, diag_check)
    }
    return cone_check && diag_check
}


// Loose versions for degenerate cases (more permissive)
diagonalie_loose :: proc "contextless" (verts: []i32, indices: []u32, n: i32, a, c: i32) -> bool {
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

in_cone_loose :: proc "contextless" (verts: []i32, indices: []u32, n: i32, a, b: i32) -> bool {
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

diagonal_loose :: proc "contextless" (verts: []i32, indices: []u32, n: i32, a, b: i32) -> bool {
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
triangulate_polygon :: proc(verts: []u16, indices: []i32, nverts: i32, triangles: ^[dynamic]i32) -> bool {
    if nverts < 3 do return false
    if nverts == 3 {
        append(triangles, indices[0], indices[1], indices[2])
        return true
    }


    // Copy indices for manipulation and add ear marking bits
    work_indices := make([]u32, nverts)
    defer delete(work_indices)
    for i in 0..<nverts {
        work_indices[i] = u32(indices[i])
    }

    // Convert vertices to int array for C++ compatibility (4 components per vertex)
    int_verts := make([]i32, (len(verts) / 3) * 4)
    defer delete(int_verts)
    for i in 0..<len(verts)/3 {
        int_verts[i*4 + 0] = i32(verts[i*3 + 0])  // x
        int_verts[i*4 + 1] = i32(verts[i*3 + 1])  // y
        int_verts[i*4 + 2] = i32(verts[i*3 + 2])  // z
        int_verts[i*4 + 3] = 0                    // padding (C++ uses 4-component vertices)
    }

    n := nverts

    // Pre-mark all ears using bit flags
    // The last bit of the index is used to indicate if the vertex can be removed
    for i in i32(0)..<n {
        i1 := next(i, n)
        i2 := next(i1, n)
        if diagonal(int_verts, work_indices, n, i, i2) {
            work_indices[i1] |= 0x80000000  // Mark middle vertex as removable ear
        }
    }

    // Check if we found any ears, fall back to loose diagonal test if needed
    ear_count := 0
    for i in i32(0)..<n {
        if work_indices[i] & 0x80000000 != 0 {
            ear_count += 1
        }
    }
    if ear_count == 0 {
        // Try using loose diagonal test as fallback
        for i in i32(0)..<n {
            i1 := next(i, n)
            i2 := next(i1, n)
            if diagonal_loose(int_verts, work_indices, n, i, i2) {
                work_indices[i1] |= 0x80000000  // Mark middle vertex as removable ear
            }
        }

        // Recount ears after loose test
        ear_count = 0
        for i in i32(0)..<n {
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
        for i in i32(0)..<n {
            i1 := next(i, n)
            if work_indices[i1] & 0x80000000 != 0 {
                // This is a marked ear, calculate diagonal length
                i2 := next(i1, n)
                p0_idx := i32(work_indices[i] & 0x0fffffff)
                p2_idx := i32(work_indices[i2] & 0x0fffffff)

                diff := [2]i32{
                    int_verts[p2_idx*4 + 0] - int_verts[p0_idx*4 + 0],
                    int_verts[p2_idx*4 + 2] - int_verts[p0_idx*4 + 2],
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

                    dx := int_verts[p2_idx*4 + 0] - int_verts[p0_idx*4 + 0]
                    dy := int_verts[p2_idx*4 + 2] - int_verts[p0_idx*4 + 2]
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
validate_poly_mesh :: proc(pmesh: ^Rc_Poly_Mesh) -> bool {
    if pmesh == nil do return false
    if pmesh.nverts <= 0 || pmesh.npolys <= 0 do return false
    if pmesh.nvp < 3 do return false

    // Check vertex bounds
    for i in 0..<pmesh.nverts {
        vi := int(i) * 3
        if vi+2 >= len(pmesh.verts) do return false
    }

    // Check polygon data
    for i in 0..<pmesh.npolys {
        pi := int(i) * int(pmesh.nvp) * 2
        if pi + int(pmesh.nvp) * 2 > len(pmesh.polys) do return false

        // Check vertex indices
        for j in 0..<pmesh.nvp {
            vert_idx := pmesh.polys[pi + int(j)]
            if vert_idx != RC_MESH_NULL_IDX && int(vert_idx) >= int(pmesh.nverts) {
                return false
            }
        }
    }

    return true
}

// Copy polygon mesh
rc_copy_poly_mesh :: proc(src: ^Rc_Poly_Mesh, dst: ^Rc_Poly_Mesh) -> bool {
    if src == nil || dst == nil do return false

    // Copy header data
    dst.nverts = src.nverts
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
    if src.nverts > 0 {
        dst.verts = make([]u16, src.nverts * 3)
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
rc_merge_poly_meshes :: proc(meshes: []^Rc_Poly_Mesh, nmeshes: i32, mesh: ^Rc_Poly_Mesh) -> bool {
    if nmeshes == 0 do return false
    if nmeshes == 1 {
        return rc_copy_poly_mesh(meshes[0], mesh)
    }

    // Calculate total sizes
    max_verts := 0
    max_polys := 0
    max_nvp := 0

    for i in 0..<nmeshes {
        if meshes[i] == nil do continue
        max_verts += int(meshes[i].nverts)
        max_polys += int(meshes[i].npolys)
        max_nvp = max(max_nvp, int(meshes[i].nvp))
    }

    if max_verts == 0 || max_polys == 0 do return false

    // Use first mesh as template
    template := meshes[0]
    mesh.nverts = 0
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
    mesh.verts = make([]u16, max_verts * 3)
    mesh.polys = make([]u16, max_polys * max_nvp * 2)
    mesh.regs = make([]u16, max_polys)
    mesh.flags = make([]u16, max_polys)
    mesh.areas = make([]u8, max_polys)

    slice.fill(mesh.polys, RC_MESH_NULL_IDX)

    // Merge meshes
    next_vert := 0
    next_poly := 0

    for i in 0..<nmeshes {
        src := meshes[i]
        if src == nil do continue

        // Copy vertices
        vert_offset := next_vert
        for j in 0..<src.nverts {
            vi_src := j * 3
            vi_dst := next_vert * 3
            mesh.verts[vi_dst+0] = src.verts[vi_src+0]
            mesh.verts[vi_dst+1] = src.verts[vi_src+1]
            mesh.verts[vi_dst+2] = src.verts[vi_src+2]
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

    mesh.nverts = i32(next_vert)
    mesh.npolys = i32(next_poly)

    return true
}

// Build edge list from polygon data (for neighbor finding)
build_mesh_edges :: proc(pmesh: ^Rc_Poly_Mesh, edges: ^[dynamic]Mesh_Edge, max_edges: i32) -> bool {
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
update_polygon_neighbors :: proc(pmesh: ^Rc_Poly_Mesh, edges: []Mesh_Edge) {
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
triangles_share_edge :: proc(tri1, tri2: []i32, shared_edge: ^[2]i32) -> bool {
    if len(tri1) < 3 || len(tri2) < 3 do return false

    // Check all edge combinations
    for i in 0..<3 {
        v1a := tri1[i]
        v1b := tri1[(i + 1) % 3]

        for j in 0..<3 {
            v2a := tri2[j]
            v2b := tri2[(j + 1) % 3]

            // Check if edges match (in either direction)
            if (v1a == v2a && v1b == v2b) || (v1a == v2b && v1b == v2a) {
                shared_edge[0] = v1a
                shared_edge[1] = v1b
                return true
            }
        }
    }

    return false
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

    // For navigation meshes, we typically want convex polygons
    // However, for now we'll accept any valid polygon
    // TODO: Add convexity check if needed

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

                    shared_edge: [2]i32
                    if triangles_share_edge(tri1, tri2, &shared_edge) {
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
                nverts = i32(len(final_verts)),
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
                    nverts = 3,
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
rc_build_poly_mesh :: proc(cset: ^Rc_Contour_Set, nvp: i32, pmesh: ^Rc_Poly_Mesh) -> bool {
    if cset == nil || pmesh == nil do return false
    if cset.nconts == 0 do return false
    if nvp < 3 do return false



    // Initialize mesh
    pmesh.nverts = 0
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

    for i in 0..<cset.nconts {
        cont := &cset.conts[i]
        if cont.nverts < 3 do continue
        max_vertices += int(cont.nverts)
        max_polygons += int(cont.nverts) - 2  // Triangulation creates n-2 triangles
        max_edges += int(cont.nverts) * 3     // Conservative estimate
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
    for i in 0..<cset.nconts {
        cont := &cset.conts[i]
        if cont.nverts < 3 {
            continue
        }

        // Convert contour vertices to mesh vertices and build vertex indices
        contour_indices := make([]i32, cont.nverts)
        defer delete(contour_indices)

        for j in 0..<cont.nverts {
            vi := j * 4
            x := u16(cont.verts[vi+0])
            y := u16(cont.verts[vi+1])
            z := u16(cont.verts[vi+2])

            vert_idx := add_vertex(x, y, z, &verts, buckets)
            contour_indices[j] = vert_idx
        }

        // Build vertex coordinate array for triangulation
        vert_coords := make([]u16, len(verts) * 3)
        defer delete(vert_coords)

        for v_idx in 0..<len(verts) {
            coord_idx := v_idx * 3
            vert_coords[coord_idx+0] = verts[v_idx].x
            vert_coords[coord_idx+1] = verts[v_idx].y
            vert_coords[coord_idx+2] = verts[v_idx].z
        }

        // Triangulate the contour
        clear(&triangles)

        if !triangulate_polygon(vert_coords, contour_indices, cont.nverts, &triangles) {
            continue
        }

        // Group triangles into polygons with max nvp vertices
        // Create polygons from triangles
        // For now, we'll keep triangles separate to ensure convex polygons
        // TODO: Implement proper convex polygon merging
        for tri_idx in 0..<len(triangles)/3 {
            base := tri_idx * 3
            poly := Poly_Build{
                verts = make([]i32, 3),
                nverts = 3,
                area = cont.area,
                reg = cont.reg,
            }
            poly.verts[0] = triangles[base + 0]
            poly.verts[1] = triangles[base + 1]
            poly.verts[2] = triangles[base + 2]
            append(&polys, poly)
        }
    }

    if len(polys) == 0 {
        return false
    }

    // Allocate final mesh arrays
    pmesh.nverts = i32(len(verts))
    pmesh.npolys = i32(len(polys))
    pmesh.maxpolys = pmesh.npolys

    pmesh.verts = make([]u16, pmesh.nverts * 3)
    pmesh.polys = make([]u16, pmesh.npolys * nvp * 2)
    pmesh.regs = make([]u16, pmesh.npolys)
    pmesh.flags = make([]u16, pmesh.npolys)
    pmesh.areas = make([]u8, pmesh.npolys)
    slice.fill(pmesh.polys, RC_MESH_NULL_IDX)

    // Copy vertices to final mesh
    for i := 0; i < len(verts); i += 1 {
        vert := verts[i]
        vi := i * 3
        pmesh.verts[vi+0] = vert.x
        pmesh.verts[vi+1] = vert.y
        pmesh.verts[vi+2] = vert.z
    }

    // Copy polygons to final mesh
    for i := 0; i < len(polys); i += 1 {
        poly := polys[i]
        pi := i * int(nvp) * 2

        // Copy vertex indices
        for j in 0..<poly.nverts {
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
rc_weld_poly_mesh_vertices :: proc(pmesh: ^Rc_Poly_Mesh, weld_tolerance: f32) -> bool {
    if pmesh == nil || pmesh.nverts == 0 do return false



    old_vert_count := pmesh.nverts
    tolerance_sq := weld_tolerance * weld_tolerance

    // Create vertex remapping table
    remap := make([]i32, pmesh.nverts)
    defer delete(remap)

    // Initialize remap to identity
    for i in 0..<pmesh.nverts {
        remap[i] = i
    }

    // Find vertices to weld
    for i in 0..<pmesh.nverts {
        if remap[i] != i do continue  // Already remapped

        vi := i * 3
        v1 := [3]f32{f32(pmesh.verts[vi+0]), f32(pmesh.verts[vi+1]), f32(pmesh.verts[vi+2])}

        // Check all subsequent vertices for welding candidates
        for j in i+1..<pmesh.nverts {
            if remap[j] != j do continue  // Already remapped

            vj := j * 3
            v2 := [3]f32{f32(pmesh.verts[vj+0]), f32(pmesh.verts[vj+1]), f32(pmesh.verts[vj+2])}

            // Calculate distance squared using vector operations
            dist_sq := linalg.length2(v2 - v1)

            if dist_sq <= tolerance_sq {
                remap[j] = i  // Weld vertex j to vertex i
            }
        }
    }

    // Compact vertex array and build final remapping
    new_verts := make([dynamic]u16, 0, pmesh.nverts * 3)
    defer delete(new_verts)

    final_remap := make([]i32, pmesh.nverts)
    defer delete(final_remap)

    new_vert_count := 0
    for i in 0..<pmesh.nverts {
        if remap[i] == i {
            // This vertex is kept
            final_remap[i] = i32(new_vert_count)

            vi := i * 3
            vertex := [3]u16{pmesh.verts[vi+0], pmesh.verts[vi+1], pmesh.verts[vi+2]}
            append(&new_verts, ..vertex[:])
            new_vert_count += 1
        } else {
            // This vertex is welded to another
            final_remap[i] = final_remap[remap[i]]
        }
    }



    if new_vert_count == int(pmesh.nverts) {
        // No vertices were welded
        return true
    }

    // Update vertex array
    delete(pmesh.verts)
    pmesh.verts = make([]u16, len(new_verts))
    copy(pmesh.verts, new_verts[:])
    pmesh.nverts = i32(new_vert_count)

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
rc_remove_degenerate_polys :: proc(pmesh: ^Rc_Poly_Mesh) -> bool {
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
rc_remove_unused_vertices :: proc(pmesh: ^Rc_Poly_Mesh) -> bool {
    if pmesh == nil || pmesh.nverts == 0 do return false



    // Mark used vertices
    used := make([]bool, pmesh.nverts)
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
    remap := make([]i32, pmesh.nverts)
    defer delete(remap)

    new_vert_count := 0
    for i in 0..<pmesh.nverts {
        if used[i] {
            remap[i] = i32(new_vert_count)
            new_vert_count += 1
        } else {
            remap[i] = -1
        }
    }

    if new_vert_count == int(pmesh.nverts) {
        // All vertices are used
        return true
    }



    // Compact vertex array
    new_verts := make([]u16, new_vert_count * 3)
    defer delete(new_verts)

    for i in 0..<pmesh.nverts {
        if used[i] {
            old_vi := i * 3
            new_vi := int(remap[i]) * 3
            new_verts[new_vi+0] = pmesh.verts[old_vi+0]
            new_verts[new_vi+1] = pmesh.verts[old_vi+1]
            new_verts[new_vi+2] = pmesh.verts[old_vi+2]
        }
    }

    // Update vertex array
    delete(pmesh.verts)
    pmesh.verts = make([]u16, len(new_verts))
    copy(pmesh.verts, new_verts)
    pmesh.nverts = i32(new_vert_count)

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
rc_optimize_poly_mesh :: proc(pmesh: ^Rc_Poly_Mesh, weld_tolerance: f32) -> bool {
    if pmesh == nil do return false



    // Step 1: Remove degenerate polygons
    if !rc_remove_degenerate_polys(pmesh) {
        log.warn("Failed to remove degenerate polygons")
    }

    // Step 2: Weld nearby vertices
    if weld_tolerance > 0.0 {
        if !rc_weld_poly_mesh_vertices(pmesh, weld_tolerance) {
            log.warn("Failed to weld vertices")
        }
    }

    // Step 3: Remove unused vertices
    if !rc_remove_unused_vertices(pmesh) {
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
