package navigation_recast


import "core:slice"
import "core:log"
import geometry "../../geometry"

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

// These indexed versions were removed to eliminate indirection.
// Callers should extract vertices and call uleft directly.

// Count vertices in a polygon (excluding null indices)
count_poly_verts :: proc(poly: []i32) -> i32 {
    // This function is used on temporary i32 arrays during merging,
    // which don't use RC_MESH_NULL_IDX but just have a specific length
    return i32(len(poly))
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
    // Extract vertices and check directly
    if va < 0 || vb < 0 || vc < 0 || va >= i32(len(verts)) || vb >= i32(len(verts)) || vc >= i32(len(verts)) {
        return -1, -1, -1
    }
    av1 := [3]i16{i16(verts[va].x), i16(verts[va].y), i16(verts[va].z)}
    bv1 := [3]i16{i16(verts[vb].x), i16(verts[vb].y), i16(verts[vb].z)}
    cv1 := [3]i16{i16(verts[vc].x), i16(verts[vc].y), i16(verts[vc].z)}
    if !uleft(av1, bv1, cv1) {
        return -1, -1, -1
    }

    va = pb[(eb+nb-1) % nb]
    vb = pb[eb]
    vc = pa[(ea+2) % na]
    // Extract vertices and check directly
    if va < 0 || vb < 0 || vc < 0 || va >= i32(len(verts)) || vb >= i32(len(verts)) || vc >= i32(len(verts)) {
        return -1, -1, -1
    }
    av2 := [3]i16{i16(verts[va].x), i16(verts[va].y), i16(verts[va].z)}
    bv2 := [3]i16{i16(verts[vb].x), i16(verts[vb].y), i16(verts[vb].z)}
    cv2 := [3]i16{i16(verts[vc].x), i16(verts[vc].y), i16(verts[vc].z)}
    if !uleft(av2, bv2, cv2) {
        return -1, -1, -1
    }

    // C++ only checks connection points, not full convexity
    // This matches the original Recast behavior

    // Calculate merge value (edge length squared)
    va = pa[ea]
    vb = pa[(ea+1) % na]

    dx := i32(verts[va].x) - i32(verts[vb].x)
    dz := i32(verts[va].z) - i32(verts[vb].z)

    return ea, eb, dx*dx + dz*dz
}

// Merge two polygons along shared edge
// Based on C++ mergePolyVerts from RecastMesh.cpp
merge_poly_verts :: proc(pa, pb: ^Poly_Build, ea, eb: i32, nvp: i32, allocator := context.allocator) {
    na := count_poly_verts(pa.verts[:])
    nb := count_poly_verts(pb.verts[:])

    // Create temporary merged polygon
    tmp := make([]i32, nvp)
    defer delete(tmp)
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
    // Create new slice with the same allocator that was used for the original
    old_verts := pa.verts
    pa.verts = make([]i32, n, allocator)
    copy(pa.verts[:], tmp[:n])

    // Note: old_verts will be cleaned up by the allocator that created it
    // (either temp_allocator automatically or regular allocator later)
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
    bucket := vertex_hash(x, 0, z)  // Hash only uses x and z (matching C++)

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
        // Match C++ behavior: exact x,z match and y within tolerance of 2
        if v.x == x && v.z == z && abs(i32(v.y) - i32(y)) <= 2 {
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


// Geometric primitive functions for triangulation



// Check if diagonal from vertex a to vertex c is internal to polygon
diagonalie :: proc "contextless" (verts: [][4]i32, indices: []u32, n: i32, a, c: i32) -> bool {
    a_idx := i32(indices[a] & 0x0fffffff)
    c_idx := i32(indices[c] & 0x0fffffff)
    
    // log.infof("diagonalie: checking diagonal from %d to %d", a, c)

    for i in i32(0)..<n {
        i1 := (i + 1) % n
        
        // Skip edges incident to a or c (matching C++ logic)
        if i == a || i1 == a || i == c || i1 == c {
            // log.infof("  Skipping edge %d-%d (incident to diagonal)", i, i1)
            continue
        }
        
        b1_idx := i32(indices[i] & 0x0fffffff)
        b2_idx := i32(indices[i1] & 0x0fffffff)

        // Also skip if vertices are equal (additional check from C++)
        va := verts[a_idx]
        vc := verts[c_idx]
        vb1 := verts[b1_idx]
        vb2 := verts[b2_idx]

        if va.xz == vb1.xz || vc.xz == vb1.xz ||
           va.xz == vb2.xz || vc.xz == vb2.xz {
            continue
        }

        if geometry.intersect(va.xz, vc.xz, vb1.xz, vb2.xz) {
            return false
        }
    }
    return true
}

// Check if diagonal is in cone of vertex a
in_cone_indexed :: proc "contextless" (verts: [][4]i32, indices: []u32, n: i32, a, b: i32) -> bool {
    a0_idx := i32(indices[(a + n - 1) % n] & 0x0fffffff)
    a1_idx := i32(indices[a] & 0x0fffffff)
    a2_idx := i32(indices[(a + 1) % n] & 0x0fffffff)
    b_idx := i32(indices[b] & 0x0fffffff)

    va0 := verts[a0_idx]
    va1 := verts[a1_idx]
    va2 := verts[a2_idx]
    vb := verts[b_idx]

    return in_cone(va0.xz, va1.xz, va2.xz, vb.xz)
}

// Check if diagonal from a to b is valid
diagonal :: proc "contextless" (verts: [][4]i32, indices: []u32, n: i32, a, b: i32) -> bool {
    cone_check := in_cone_indexed(verts, indices, n, a, b)
    diag_check := diagonalie(verts, indices, n, a, b)
    return cone_check && diag_check
}


// Loose versions for degenerate cases (more permissive)
diagonalie_loose :: proc "contextless" (verts: [][4]i32, indices: []u32, n: i32, a, c: i32) -> bool {
    a_idx := i32(indices[a] & 0x0fffffff)
    c_idx := i32(indices[c] & 0x0fffffff)

    for i in i32(0)..<n {
        i1 := (i + 1) % n
        
        // Skip edges incident to a or c (matching C++ logic)
        if i == a || i1 == a || i == c || i1 == c {
            continue
        }
        
        b1_idx := i32(indices[i] & 0x0fffffff)
        b2_idx := i32(indices[i1] & 0x0fffffff)

        va := verts[a_idx]
        vc := verts[c_idx]
        vb1 := verts[b1_idx]
        vb2 := verts[b2_idx]

        if va.xz == vb1.xz || vc.xz == vb1.xz || va.xz == vb2.xz || vc.xz == vb2.xz {
            continue
        }

        if geometry.intersect_prop(va.xz, vc.xz, vb1.xz, vb2.xz) {
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

    va0 := verts[a0_idx]
    va1 := verts[a1_idx]
    va2 := verts[a2_idx]
    vb := verts[b_idx]

    if geometry.left_on(va0.xz, va1.xz, va2.xz) {
        return geometry.left_on(va1.xz, vb.xz, va0.xz) && geometry.left_on(vb.xz, va1.xz, va2.xz)
    } else {
        return !(geometry.left_on(va1.xz, vb.xz, va2.xz) && geometry.left_on(vb.xz, va1.xz, va0.xz))
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

// Internal triangulation using u16 vertices  
triangulate_polygon_u16 :: proc(verts: [][3]u16, indices: []i32, triangles: ^[dynamic]i32) -> bool {
    // Convert to [4]i32 format for triangulation
    int_verts := make([][4]i32, len(verts))
    defer delete(int_verts)
    for i in 0..<len(verts) {
        v := verts[i]
        int_verts[i] = {i32(v.x), i32(v.y), i32(v.z), 0}
    }
    return triangulate_polygon(int_verts, indices, triangles)
}

// Triangulate polygon using C++ Recast ear clipping algorithm
// Matches C++ triangulate(int n, const int* verts, int* indices, int* tris)
triangulate_polygon :: proc(verts: [][4]i32, indices: []i32, triangles: ^[dynamic]i32) -> bool {
    if len(verts) < 3 {
        log.debugf("triangulate_polygon: Too few verts: %d", len(verts))
        return false
    }
    if len(verts) == 3 {
        append(triangles, indices[0], indices[1], indices[2])
        return true
    }
    if len(indices) < 3 {
        log.debugf("triangulate_polygon: Too few indices: %d", len(indices))
        return false
    }

    // Copy indices for manipulation and add ear marking bits
    // Use u32 to support the 0x80000000 flag bit
    work_indices := make([]u32, len(indices))
    defer delete(work_indices)
    for i in 0..<len(indices) {
        work_indices[i] = u32(indices[i])
    }
    // Verts already in C++ format: [4]i32 with x, y, z, flags
    // No conversion needed - use directly

    n := i32(len(indices))

    // Pre-mark all ears using bit flags
    // The last bit of the index is used to indicate if the vertex can be removed
    for i in 0..<n {
        i1 := next(i, n)
        i2 := next(i1, n)
        
        diag_result := diagonal(verts, work_indices, n, i, i2)
        if diag_result {
            work_indices[i1] |= 0x80000000  // Mark middle vertex as removable ear
        }
    }

    // Check if we found any ears for debugging purposes
    ear_count := 0
    for i in 0..<n {
        if work_indices[i] & 0x80000000 != 0 {
            ear_count += 1
        }
    }
    log.debugf("Initial ear count: %d out of %d vertices", ear_count, n)

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

                // Calculate squared distance in XZ plane
                p0 := verts[p0_idx]
                p2 := verts[p2_idx]
                length := linalg.length2(p2.xz - p0.xz)

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
                if diagonal_loose(verts, work_indices, n, i, i2) {
                    p0_idx := i32(work_indices[i] & 0x0fffffff)
                    p2_idx := i32(work_indices[next(i2, n)] & 0x0fffffff)  // Match C++ exactly

                    // Calculate squared distance in XZ plane
                    p0 := verts[p0_idx]
                    p2 := verts[p2_idx]
                    length := linalg.length2(p2.xz - p0.xz)

                    if min_len < 0 || length < min_len {
                        min_len = length
                        mini = i
                    }
                }
            }

            if mini == -1 {
                // The contour is messed up. This sometimes happens
                // if the contour simplification is too aggressive.
                // Return negative triangle count to signal error (matching C++)
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

        // Update diagonal flags for adjacent vertices (matching C++)
        prev_i := prev(i, n)
        next_i1 := next(i1, n)

        // Only check strict diagonal (not loose) for flag updates
        if diagonal(verts, work_indices, n, prev_i, i1) {
            work_indices[i] |= 0x80000000
        } else {
            work_indices[i] &= 0x0fffffff
        }

        if diagonal(verts, work_indices, n, i, next_i1) {
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
        dst.verts = slice.clone(src.verts)
    }

    if src.npolys > 0 {
        poly_size := src.npolys * src.nvp * 2
        dst.polys = slice.clone(src.polys[:poly_size])

        dst.regs = slice.clone(src.regs[:src.npolys])

        dst.flags = slice.clone(src.flags[:src.npolys])

        dst.areas = slice.clone(src.areas[:src.npolys])
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
            for idx in 0..<len(edges) {
                if edges[idx].vert[0] == va && edges[idx].vert[1] == vb {
                    // Found matching edge - this is a shared edge
                    if edges[idx].poly[1] == RC_MESH_NULL_IDX {
                        edges[idx].poly[1] = u16(i)
                        edges[idx].poly_edge[1] = u16(j)
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
    log.infof("build_poly_mesh: Processing %d contours", len(cset.conts))
    for i in 0..<len(cset.conts) {
        cont := &cset.conts[i]
        log.infof("  Contour %d: nverts=%d, area=%d, reg=%d", i, len(cont.verts), cont.area, cont.reg)
        if len(cont.verts) < 3 {
            continue
        }

        // Build arrays for triangulation (matching C++ implementation)
        // Create indices array for triangulation (0, 1, 2, ...)
        indices := make([]i32, len(cont.verts))
        defer delete(indices)
        
        for j in 0..<len(cont.verts) {
            indices[j] = i32(j)
        }

        // Triangulate the contour FIRST (matching C++ approach)
        // Pass cont.verts directly - they're already [4]i32 with x, y, z, flags
        clear(&triangles)
        
        if !triangulate_polygon(cont.verts[:], indices, &triangles) {
            // Bad triangulation, should not happen.
            log.warnf("build_poly_mesh: Bad triangulation Contour %d. Verts: %d", i, len(cont.verts))
            // Debug: print vertices
            for j in 0..<min(5, len(cont.verts)) {
                v := cont.verts[j]
                log.debugf("  Vert %d: [%d, %d, %d, %d]", j, v.x, v.y, v.z, v.w)
            }
            continue
        }
        
        log.infof("  Contour %d triangulated: %d triangles from %d verts", i, len(triangles)/3, len(cont.verts))

        // NOW add vertices and merge duplicates AFTER triangulation
        // Reuse indices array to store global vertex indices
        verts_before := len(verts)
        for j in 0..<len(cont.verts) {
            v := cont.verts[j]
            indices[j] = add_vertex(u16(v.x), u16(v.y), u16(v.z), &verts, buckets)
        }
        verts_after := len(verts)
        new_verts := verts_after - verts_before
        log.infof("    Contour %d: added %d vertices (%d new unique)", i, len(cont.verts), new_verts)

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
            // Use triangles as lookup into indices array (matching C++ approach)
            poly.verts[0] = indices[triangles[base + 0]]
            poly.verts[1] = indices[triangles[base + 1]]
            poly.verts[2] = indices[triangles[base + 2]]
            append(&region_polys, poly)
        }

        // Merge triangles into convex polygons
        if nvp > 3 {
            merge_count := 0
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
                    log.debugf("    No more merges possible after %d merges", merge_count)
                    break
                }
                merge_count += 1

                // Merge the polygons
                merge_poly_verts(&region_polys[best_pa], &region_polys[best_pb], best_ea, best_eb, nvp, context.temp_allocator)

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
        log.infof("  Contour %d: %d triangles merged into %d polygons", i, len(triangles)/3, len(region_polys))
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
optimize_poly_mesh :: proc(pmesh: ^Poly_Mesh) -> bool {
    if pmesh == nil do return false

    // Step 1: Remove degenerate polygons
    if !remove_degenerate_polys(pmesh) {
        log.warn("Failed to remove degenerate polygons")
    }

    // Step 2: Remove unused vertices
    if !remove_unused_vertices(pmesh) {
        log.warn("Failed to remove unused vertices")
    }

    // Step 3: Rebuild edges for connectivity
    edges := make([dynamic]Mesh_Edge, 0, pmesh.npolys * 3)
    defer delete(edges)

    if build_mesh_edges(pmesh, &edges, pmesh.npolys * 3) {
        update_polygon_neighbors(pmesh, edges[:])
    }

    // Step 4: Final validation
    if !validate_poly_mesh(pmesh) {
        log.error("Mesh optimization resulted in invalid mesh")
        return false
    }

    return true
}

// Check if a vertex can be removed from the mesh
// Based on C++ canRemoveVertex from RecastMesh.cpp
can_remove_vertex :: proc(pmesh: ^Poly_Mesh, rem: u16) -> bool {
    if pmesh == nil do return false

    // Count number of polygon edges that use this vertex
    nvp := int(pmesh.nvp)
    numRemovedVerts := 0
    numTouchedVerts := 0
    numRemainingEdges := 0

    // Find polygons that use this vertex
    for i in 0..<pmesh.npolys {
        pi := int(i) * nvp * 2

        nv := 0
        for j in 0..<nvp {
            if pmesh.polys[pi + j] == RC_MESH_NULL_IDX do break
            nv += 1
        }

        hasRem := false
        for j in 0..<nv {
            if pmesh.polys[pi + j] == rem {
                hasRem = true
            }
        }

        if hasRem {
            // Polygon uses the vertex
            numTouchedVerts += nv
            numRemovedVerts += 1

            // Count edges after removal
            edges := nv
            if nv > 3 {
                edges -= 1
            }
            numRemainingEdges += edges
        }
    }

    // There must be enough edges remaining to fill the hole
    if numRemainingEdges <= numRemovedVerts * 2 {
        return false
    }

    // Check if vertex is on mesh boundary
    edge_count := 0
    for i in 0..<pmesh.npolys {
        pi := int(i) * nvp * 2

        nv := 0
        for j in 0..<nvp {
            if pmesh.polys[pi + j] == RC_MESH_NULL_IDX do break
            nv += 1
        }

        for j in 0..<nv {
            if pmesh.polys[pi + j] == rem {
                // Check if edge j has a neighbor
                if pmesh.polys[pi + nvp + j] == RC_MESH_NULL_IDX {
                    edge_count += 1
                }
                // Check previous edge
                k := (j + nv - 1) % nv
                if pmesh.polys[pi + k] != RC_MESH_NULL_IDX {
                    if pmesh.polys[pi + nvp + k] == RC_MESH_NULL_IDX {
                        edge_count += 1
                    }
                }
            }
        }
    }

    // Can't remove vertex on open edges
    if edge_count > 0 {
        return false
    }

    return true
}

// Remove a vertex from the polygon mesh and re-triangulate the hole
// Based on C++ removeVertex from RecastMesh.cpp
remove_vertex :: proc(pmesh: ^Poly_Mesh, rem: u16, maxTris: i32) -> bool {
    if pmesh == nil do return false

    nvp := int(pmesh.nvp)

    // Collect polygons that use the vertex
    polys_to_remove := make([dynamic]i32, 0, 16)
    defer delete(polys_to_remove)

    nv_total := 0
    for i in 0..<pmesh.npolys {
        pi := int(i) * nvp * 2

        nv := 0
        for j in 0..<nvp {
            if pmesh.polys[pi + j] == RC_MESH_NULL_IDX do break
            nv += 1
        }

        hasRem := false
        for j in 0..<nv {
            if pmesh.polys[pi + j] == rem {
                hasRem = true
                break
            }
        }

        if hasRem {
            append(&polys_to_remove, i)
            nv_total += nv
        }
    }

    if len(polys_to_remove) == 0 do return true

    // Create hole polygon by collecting all edges that don't include rem vertex
    hole := make([dynamic]u16, 0, nv_total)
    defer delete(hole)

    nhole := 0
    navail := 0

    for poly_idx in polys_to_remove {
        pi := int(poly_idx) * nvp * 2

        nv := 0
        for j in 0..<nvp {
            if pmesh.polys[pi + j] == RC_MESH_NULL_IDX do break
            nv += 1
        }

        // Find vertex to remove
        rem_idx := -1
        for j in 0..<nv {
            if pmesh.polys[pi + j] == rem {
                rem_idx = j
                break
            }
        }

        if rem_idx != -1 {
            // Add vertices except rem to hole
            for j in 0..<nv {
                if j != rem_idx {
                    append(&hole, pmesh.polys[pi + j])
                    nhole += 1
                    navail += 1
                }
            }
        }
    }

    // Generate triangle indices for hole triangulation
    triangles := make([dynamic]i32, 0, maxTris * 3)
    defer delete(triangles)

    // Create vertex array for triangulation
    tverts := make([][3]u16, len(hole))
    defer delete(tverts)

    tindices := make([]i32, len(hole))
    defer delete(tindices)

    for i in 0..<len(hole) {
        vert_idx := int(hole[i])
        if vert_idx < len(pmesh.verts) {
            tverts[i] = pmesh.verts[vert_idx]
            tindices[i] = i32(i)
        }
    }

    // Triangulate the hole
    if !triangulate_polygon_u16(tverts[:], tindices[:], &triangles) {
        return false
    }

    // Remap triangle indices back to mesh vertex indices
    for i in 0..<len(triangles) {
        triangles[i] = i32(hole[triangles[i]])
    }

    // Remove old polygons
    next_free := 0
    for i in 0..<pmesh.npolys {
        is_removed := false
        for rem_idx in polys_to_remove {
            if i == rem_idx {
                is_removed = true
                break
            }
        }

        if !is_removed {
            // Keep this polygon - copy to next free slot if needed
            if next_free != int(i) {
                src_pi := int(i) * nvp * 2
                dst_pi := next_free * nvp * 2

                // Copy polygon data
                for j in 0..<nvp*2 {
                    pmesh.polys[dst_pi + j] = pmesh.polys[src_pi + j]
                }

                // Copy attributes
                pmesh.regs[next_free] = pmesh.regs[i]
                pmesh.flags[next_free] = pmesh.flags[i]
                pmesh.areas[next_free] = pmesh.areas[i]
            }
            next_free += 1
        }
    }

    // Store first removed polygon area/region for new polygons
    first_removed := polys_to_remove[0]
    poly_area := pmesh.areas[first_removed]
    poly_reg := pmesh.regs[first_removed]

    // Convert triangles to polygons and add to mesh
    polys := make([dynamic]Poly_Build, 0, len(triangles) / 3)
    defer {
        for &p in polys {
            delete(p.verts)
        }
        delete(polys)
    }

    // Note: We need to convert mesh vertices back for merging
    mesh_verts := make([dynamic]Mesh_Vertex, len(pmesh.verts))
    defer delete(mesh_verts)

    for i in 0..<len(pmesh.verts) {
        v := pmesh.verts[i]
        mesh_verts[i] = Mesh_Vertex{x = v.x, y = v.y, z = v.z, next = -1}
    }

    merge_triangles_into_polygons(triangles[:], &polys, i32(nvp), poly_area, poly_reg)

    // Add new polygons to mesh
    for poly in polys {
        if next_free >= int(pmesh.maxpolys) do break

        pi := next_free * nvp * 2

        // Clear polygon
        for j in 0..<nvp*2 {
            pmesh.polys[pi + j] = RC_MESH_NULL_IDX
        }

        // Copy vertices
        for j in 0..<len(poly.verts) {
            if j < nvp {
                pmesh.polys[pi + j] = u16(poly.verts[j])
            }
        }

        // Set attributes
        pmesh.regs[next_free] = poly.reg
        pmesh.flags[next_free] = 1
        pmesh.areas[next_free] = poly.area

        next_free += 1
    }

    pmesh.npolys = i32(next_free)

    // Remove unused vertices (optional but recommended)
    if !remove_unused_vertices(pmesh) {
        log.warn("Failed to remove unused vertices after vertex removal")
    }

    // Rebuild adjacency
    edges := make([dynamic]Mesh_Edge, 0, pmesh.npolys * 3)
    defer delete(edges)

    if build_mesh_edges(pmesh, &edges, pmesh.npolys * 3) {
        update_polygon_neighbors(pmesh, edges[:])
    }

    return true
}

// Build portal edges between tile boundaries
// Based on C++ implementation from RecastMesh.cpp
build_mesh_portal_edges :: proc(pmesh: ^Poly_Mesh) -> bool {
    if pmesh == nil do return false

    nvp := int(pmesh.nvp)

    // Mark portal edges (edges on tile boundaries)
    for i in 0..<pmesh.npolys {
        pi := int(i) * nvp * 2

        for j in 0..<nvp {
            if pmesh.polys[pi + j] == RC_MESH_NULL_IDX do break

            // Check if edge has no neighbor (boundary edge)
            if pmesh.polys[pi + nvp + j] == RC_MESH_NULL_IDX {
                k := (j + 1) % nvp
                if pmesh.polys[pi + k] == RC_MESH_NULL_IDX do continue

                va := pmesh.polys[pi + j]
                vb := pmesh.polys[pi + k]

                // Check if edge is on tile boundary by comparing vertex positions
                if va < u16(len(pmesh.verts)) && vb < u16(len(pmesh.verts)) {
                    ax := pmesh.verts[va].x
                    az := pmesh.verts[va].z
                    bx := pmesh.verts[vb].x
                    bz := pmesh.verts[vb].z

                    // Check if edge aligns with tile boundary
                    // Vertices on boundary have x or z == 0 or borderSize*2
                    border := u16(pmesh.border_size * 2)

                    is_portal := false

                    // Check X boundaries
                    if (ax == 0 || ax == border) && (bx == 0 || bx == border) && ax == bx {
                        is_portal = true
                    }
                    // Check Z boundaries
                    if (az == 0 || az == border) && (bz == 0 || bz == border) && az == bz {
                        is_portal = true
                    }

                    if is_portal {
                        // Mark as portal edge using upper bits of neighbor value
                        // Set portal direction based on which boundary
                        dir := u16(0)
                        if ax == 0 { dir = 0 }    // -X
                        else if ax == border { dir = 1 }  // +X
                        else if az == 0 { dir = 2 }      // -Z
                        else if az == border { dir = 3 }  // +Z

                        // Store portal info in upper bits
                        pmesh.polys[pi + nvp + j] = 0x8000 | (dir << 13)
                    }
                }
            }
        }
    }

    return true
}
