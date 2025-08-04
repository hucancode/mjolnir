package navigation_recast


import "core:slice"
import "core:log"
import "core:mem"
import "core:math"
import "core:math/linalg"
import "core:time"

// Detail mesh building constants
RC_UNSET_HEIGHT :: 0xffff

// Maximum subdivision levels for edge tessellation
MAX_EDGE_SUBDIVISIONS :: 10

// Minimum edge length for detail tessellation (in world units)
MIN_EDGE_LENGTH :: 0.1

// Timeout constants for robustness
DEFAULT_POLYGON_TIMEOUT_MS :: 5000     // 5 seconds per polygon
GLOBAL_TIMEOUT_MS :: 30000             // 30 seconds total
MAX_INTERIOR_SAMPLES :: 10000          // Maximum interior sample points to prevent memory explosion
MIN_POLYGON_AREA :: 1e-6               // Minimum area for valid polygon

// Quality thresholds for triangle optimization
MIN_TRIANGLE_QUALITY :: 0.5    // Minimum ratio of inscribed to circumscribed circle
MIN_ANGLE_DEGREES :: 20.0      // Minimum triangle angle in degrees
MAX_ANGLE_DEGREES :: 160.0     // Maximum triangle angle in degrees

// Vertex structure for detail mesh building
Detail_Vertex :: struct {
    pos:    [3]f32,     // World position
    height: f32,        // Sampled height from heightfield
    flag:   u32,        // Flags (border vertex, etc.)
}

// Edge structure for constrained triangulation
Detail_Edge :: struct {
    v0:         i32,    // First vertex index
    v1:         i32,    // Second vertex index
    constrained: bool,  // Whether this edge must be preserved
    length:     f32,    // Edge length in world units
}

// Triangle structure for detail mesh
Detail_Triangle :: struct {
    v: [3]i32,          // Vertex indices
    quality: f32,       // Triangle quality metric (0-1, higher is better)
    area:   f32,        // Triangle area
}

// Polygon context for detail mesh building
Detail_Polygon :: struct {
    vertices:    [dynamic]Detail_Vertex,    // Vertices in this polygon
    edges:       [dynamic]Detail_Edge,      // Constrained edges
    triangles:   [dynamic]Detail_Triangle,  // Generated triangles
    sample_dist: f32,                       // Sample distance for this polygon
    max_error:   f32,                       // Maximum allowed error
}

// Height sample point for interpolation
Height_Sample :: struct {
    pos:    [3]f32,     // Sample position
    height: f32,        // Interpolated height
    weight: f32,        // Interpolation weight
}

// Barycentric coordinates for triangle interpolation
Barycentric :: struct {
    u, v, w: f32,       // Barycentric coordinates (u + v + w = 1)
}

// Timeout context for detail mesh building
Timeout_Context :: struct {
    start_time:        time.Time,    // When processing started
    global_timeout:    time.Duration, // Global timeout limit
    polygon_timeout:   time.Duration, // Per-polygon timeout limit
    last_progress:     time.Time,    // Last progress update
    polygons_processed: i32,         // Number of polygons completed
    current_polygon:   i32,          // Currently processing polygon
}

// Calculate barycentric coordinates for point p in triangle (a, b, c)
calculate_barycentric :: proc "contextless" (p, a, b, c: [3]f32) -> Barycentric {
    v0 := c - a
    v1 := b - a
    v2 := p - a

    dot00 := linalg.dot(v0.xz, v0.xz)
    dot01 := linalg.dot(v0.xz, v1.xz)
    dot02 := linalg.dot(v0.xz, v2.xz)
    dot11 := linalg.dot(v1.xz, v1.xz)
    dot12 := linalg.dot(v1.xz, v2.xz)

    inv_denom := 1.0 / (dot00 * dot11 - dot01 * dot01)
    u := (dot11 * dot02 - dot01 * dot12) * inv_denom
    v := (dot00 * dot12 - dot01 * dot02) * inv_denom
    w := 1.0 - u - v

    return Barycentric{u, v, w}
}

// Check if point is inside triangle using barycentric coordinates
point_in_triangle_bary :: proc "contextless" (bary: Barycentric) -> bool {
    return bary.u >= 0.0 && bary.v >= 0.0 && bary.w >= 0.0
}

// Sample height from heightfield at given world position
sample_heightfield_height :: proc(chf: ^Compact_Heightfield, pos: [3]f32) -> f32 {
    if chf == nil do return 0.0

    // Convert world position to cell coordinates
    f := (pos.xz - chf.bmin.xz) / chf.cs
    // Get cell indices
    cell_idx := [2]i32{i32(math.floor(f.x)), i32(math.floor(f.y))}
    x := cell_idx.x
    z := cell_idx.y

    // Check bounds
    if x < 0 || z < 0 || x >= chf.width-1 || z >= chf.height-1 {
        return 0.0
    }

    // Get fractional parts for interpolation
    f_frac := f - [2]f32{f32(x), f32(z)}
    fx_frac := f_frac.x
    fz_frac := f_frac.y

    // Sample heights from surrounding cells
    heights: [4]f32
    heights[0] = get_cell_height(chf, x,   z)     // Bottom-left
    heights[1] = get_cell_height(chf, x+1, z)     // Bottom-right
    heights[2] = get_cell_height(chf, x,   z+1)   // Top-left
    heights[3] = get_cell_height(chf, x+1, z+1)   // Top-right

    // Bilinear interpolation
    h0 := linalg.mix(heights[0], heights[1], fx_frac)
    h1 := linalg.mix(heights[2], heights[3], fx_frac)
    height := linalg.mix(h0, h1, fz_frac)

    return chf.bmin.y + height * chf.ch
}

// Get height of cell from compact heightfield
get_cell_height :: proc(chf: ^Compact_Heightfield, x, z: i32) -> f32 {
    if x < 0 || z < 0 || x >= chf.width || z >= chf.height {
        return 0.0
    }

    cell_idx := z * chf.width + x
    if cell_idx >= i32(len(chf.cells)) do return 0.0

    cell := chf.cells[cell_idx]
    index := cell.index
    count := cell.count

    if count == 0 do return 0.0

    // Return height of the topmost span
    if index + u32(count) > u32(len(chf.spans)) do return 0.0
    top_span := chf.spans[index + u32(count) - 1]

    return f32(top_span.y) + f32(top_span.h)
}

// Calculate triangle quality (ratio of inscribed to circumscribed circle radii)
calculate_triangle_quality :: proc "contextless" (a, b, c: [3]f32) -> f32 {
    // Calculate edge lengths
    lab := linalg.distance(a.xz, b.xz)
    lbc := linalg.distance(b.xz, c.xz)
    lca := linalg.distance(c.xz, a.xz)

    if lab <= 0.0 || lbc <= 0.0 || lca <= 0.0 do return 0.0

    // Calculate area using cross product
    ab := b - a
    ac := c - a
    cross := linalg.cross(ab, ac)
    area := linalg.length(cross) * 0.5

    if area <= 0.0 do return 0.0

    // Calculate circumradius and inradius
    perimeter := lab + lbc + lca
    circumradius := (lab * lbc * lca) / (4.0 * area)
    inradius := area / (perimeter * 0.5)

    if circumradius <= 0.0 do return 0.0

    // Quality metric: 2 * inradius / circumradius
    // For equilateral triangle this equals 1.0
    return 2.0 * inradius / circumradius
}

// Calculate minimum extent of polygon (C++ polyMinExtent)
calculate_polygon_min_extent :: proc(poly: ^Detail_Polygon) -> f32 {
    nverts := len(poly.vertices)
    if nverts < 3 do return 0.0
    
    min_dist := f32(1e30)
    
    for i in 0..<nverts {
        ni := (i + 1) % nverts
        p1 := poly.vertices[i].pos
        p2 := poly.vertices[ni].pos
        
        max_edge_dist := f32(0.0)
        for j in 0..<nverts {
            if j == i || j == ni do continue
            
            // Distance from point to line segment (2D)
            d := distance_to_edge(poly.vertices[j].pos, p1, p2)
            max_edge_dist = max(max_edge_dist, d)
        }
        min_dist = min(min_dist, max_edge_dist)
    }
    
    return math.sqrt(min_dist)
}



// Check if triangle is degenerate
is_triangle_degenerate :: proc "contextless" (a, b, c: [3]f32, min_area: f32) -> bool {
    area := triangle_area_2d_detail(a, b, c)
    return area < min_area
}

// Validate a triangle using multiple criteria
validate_triangle :: proc "contextless" (a, b, c: [3]f32) -> bool {
    // Check for degenerate area
    if is_triangle_degenerate(a, b, c, 1e-6) do return false

    // Check quality
    quality := calculate_triangle_quality(a, b, c)
    if quality < MIN_TRIANGLE_QUALITY do return false

    // Check angles (simplified check using dot products)
    ab := [3]f32{b.x - a.x, 0, b.z - a.z}
    ac := [3]f32{c.x - a.x, 0, c.z - a.z}
    bc := [3]f32{c.x - b.x, 0, c.z - b.z}

    // Normalize vectors
    ab_len := linalg.length(ab.xz)
    ac_len := linalg.length(ac.xz)
    bc_len := linalg.length(bc.xz)

    if ab_len <= 0 || ac_len <= 0 || bc_len <= 0 do return false

    ab.xz = linalg.normalize(ab.xz)
    ac.xz = linalg.normalize(ac.xz)
    bc.xz = linalg.normalize(bc.xz)

    // Check angle at vertex A
    dot_a := linalg.dot(ab.xz, ac.xz)
    angle_a := math.acos(math.clamp(dot_a, -1.0, 1.0)) * 180.0 / RC_PI

    if angle_a < MIN_ANGLE_DEGREES || angle_a > MAX_ANGLE_DEGREES do return false

    return true
}

// Find the closest point on an edge to a given point
closest_point_on_edge :: proc "contextless" (p, a, b: [3]f32) -> [3]f32 {
    ab := b - a
    ap := p - a

    ab_len_sq := linalg.dot(ab, ab)
    if ab_len_sq <= 0.0 do return a

    t := linalg.dot(ap, ab) / ab_len_sq
    t = math.clamp(t, 0.0, 1.0)

    return linalg.mix(a, b, t)
}

// Calculate distance from point to edge
distance_to_edge :: proc "contextless" (p, a, b: [3]f32) -> f32 {
    closest := closest_point_on_edge(p, a, b)
    return linalg.distance(p, closest)
}

// Add a vertex to the detail polygon, ensuring uniqueness
add_detail_vertex :: proc(poly: ^Detail_Polygon, pos: [3]f32, height: f32, flag: u32 = 0) -> i32 {
    // Check for existing vertex at this position
    for &v, i in poly.vertices {
        diff := v.pos - pos
        dist_sq := linalg.dot(diff, diff)
        if dist_sq < 1e-6 {  // Very close vertices are considered the same
            return i32(i)
        }
    }

    // Add new vertex
    vertex := Detail_Vertex{
        pos = pos,
        height = height,
        flag = flag,
    }
    append(&poly.vertices, vertex)
    return i32(len(poly.vertices) - 1)
}

// Add a constrained edge between two vertices
add_constrained_edge :: proc(poly: ^Detail_Polygon, v0, v1: i32) {
    if v0 >= i32(len(poly.vertices)) || v1 >= i32(len(poly.vertices)) do return
    if v0 == v1 do return

    // Check if edge already exists
    for edge in poly.edges {
        if (edge.v0 == v0 && edge.v1 == v1) || (edge.v0 == v1 && edge.v1 == v0) {
            return
        }
    }

    // Calculate edge length
    p0 := poly.vertices[v0].pos
    p1 := poly.vertices[v1].pos
    diff := p1 - p0
    length := linalg.length(diff)

    edge := Detail_Edge{
        v0 = v0,
        v1 = v1,
        constrained = true,
        length = length,
    }
    append(&poly.edges, edge)
}

// Initialize detail polygon from polygon mesh polygon
init_detail_polygon :: proc(poly: ^Detail_Polygon, pmesh: ^Poly_Mesh, chf: ^Compact_Heightfield,
                          poly_idx: i32, sample_dist, max_error: f32) -> bool {

    clear(&poly.vertices)
    clear(&poly.edges)
    clear(&poly.triangles)

    poly.sample_dist = sample_dist
    poly.max_error = max_error

    if pmesh == nil || chf == nil do return false
    if poly_idx < 0 || poly_idx >= pmesh.npolys do return false

    // Get polygon data
    pi := int(poly_idx) * int(pmesh.nvp) * 2

    // Find actual number of vertices in this polygon
    nverts := 0
    for j in 0..<pmesh.nvp {
        if pmesh.polys[pi + int(j)] != RC_MESH_NULL_IDX {
            nverts += 1
        } else {
            break
        }
    }

    if nverts < 3 do return false

    // Add polygon vertices
    for i in 0..<nverts {
        vert_idx := int(pmesh.polys[pi + i])
        if vert_idx >= len(pmesh.verts) do return false

        v := pmesh.verts[vert_idx]
        pos := [3]f32{
            pmesh.bmin.x + f32(v[0]) * pmesh.cs,
            pmesh.bmin.y + f32(v[1]) * pmesh.ch,
            pmesh.bmin.z + f32(v[2]) * pmesh.cs,
        }

        // Sample height from heightfield
        height := sample_heightfield_height(chf, pos)
        pos.y = height  // Use sampled height

        // Mark border vertices
        flag := u32(0)
        if is_border_vertex(pmesh, vert_idx) {
            flag |= RC_BORDER_VERTEX
        }

        add_detail_vertex(poly, pos, height, flag)
    }

    // Add constrained edges between consecutive vertices
    for i in 0..<nverts {
        v0 := i32(i)
        v1 := i32((i + 1) % nverts)
        add_constrained_edge(poly, v0, v1)
    }

    return true
}

// Check if a vertex is on the border of the mesh
is_border_vertex :: proc(pmesh: ^Poly_Mesh, vert_idx: int) -> bool {
    // A vertex is on the border if it's used by a polygon edge that has no neighbor
    for i in 0..<pmesh.npolys {
        pi := int(i) * int(pmesh.nvp) * 2

        // Check each edge of this polygon
        nverts := 0
        for j in 0..<pmesh.nvp {
            if pmesh.polys[pi + int(j)] != RC_MESH_NULL_IDX {
                nverts += 1
            } else {
                break
            }
        }

        for j in 0..<nverts {
            k := (j + 1) % nverts
            v0 := int(pmesh.polys[pi + j])
            v1 := int(pmesh.polys[pi + k])

            if v0 == vert_idx || v1 == vert_idx {
                // Check if this edge has a neighbor
                neighbor := pmesh.polys[pi + int(pmesh.nvp) + j]
                if neighbor == RC_MESH_NULL_IDX {
                    return true  // No neighbor means border edge
                }
            }
        }
    }
    return false
}

// Free detail polygon memory
free_detail_polygon :: proc(poly: ^Detail_Polygon) {
    delete(poly.vertices)
    delete(poly.edges)
    delete(poly.triangles)
}

// Validate detail mesh data
validate_poly_mesh_detail :: proc(dmesh: ^Poly_Mesh_Detail) -> bool {
    if dmesh == nil do return false
    if len(dmesh.meshes) <= 0 || len(dmesh.verts) <= 0 || len(dmesh.tris) <= 0 do return false

    // Check mesh data bounds
    for i in 0..<len(dmesh.meshes) {

        // Each mesh entry: [vertex_base, vertex_count, triangle_base, triangle_count]
        mesh_info := dmesh.meshes[i]
        vert_base := mesh_info[0]
        vert_count := mesh_info[1]
        tri_base := mesh_info[2]
        tri_count := mesh_info[3]

        // Validate bounds
        if vert_base + vert_count > u32(len(dmesh.verts)) do return false
        if tri_base + tri_count > u32(len(dmesh.tris)) do return false
    }

    // Check triangle data
    for tri in dmesh.tris {
        // Check vertex indices
        for j in 0..<3 {
            vert_idx := tri[j]
            if int(vert_idx) >= len(dmesh.verts) do return false
        }
    }
    return true
}

// Copy detail mesh
copy_poly_mesh_detail :: proc(src: ^Poly_Mesh_Detail, dst: ^Poly_Mesh_Detail) -> bool {
    if src == nil || dst == nil do return false

    // Copy arrays
    if len(src.meshes) > 0 {
        dst.meshes = make([][4]u32, len(src.meshes))
        copy(dst.meshes, src.meshes)
    }

    if len(src.verts) > 0 {
        dst.verts = make([][3]f32, len(src.verts))
        copy(dst.verts, src.verts)
    }

    if len(src.tris) > 0 {
        dst.tris = make([][4]u8, len(src.tris))
        copy(dst.tris, src.tris)
    }

    return true
}

// Merge multiple detail meshes
merge_poly_mesh_details :: proc(meshes: []^Poly_Mesh_Detail,
                                  mesh: ^Poly_Mesh_Detail) -> bool {
    if len(meshes) == 0 do return false
    if len(meshes) == 1 {
        return copy_poly_mesh_detail(meshes[0], mesh)
    }

    // Calculate total sizes
    total_meshes := 0
    total_verts := 0
    total_tris := 0

    for mesh in meshes do if mesh != nil {
        total_meshes += len(mesh.meshes)
        total_verts += len(mesh.verts)
        total_tris += len(mesh.tris)
    }

    if total_meshes == 0 do return false

    // Allocate arrays
    mesh.meshes = make([][4]u32, total_meshes)
    mesh.verts = make([][3]f32, total_verts)
    mesh.tris = make([][4]u8, total_tris)

    // Merge data
    mesh_offset := 0
    vert_offset := 0
    tri_offset := 0

    for src in meshes do if src != nil {
        // Copy mesh headers (with adjusted offsets)
        for j in 0..<len(src.meshes) {
            mesh.meshes[mesh_offset][0] = src.meshes[j][0] + u32(vert_offset)  // Adjust vertex base
            mesh.meshes[mesh_offset][1] = src.meshes[j][1]                     // Vertex count
            mesh.meshes[mesh_offset][2] = src.meshes[j][2] + u32(tri_offset)   // Adjust triangle base
            mesh.meshes[mesh_offset][3] = src.meshes[j][3]                     // Triangle count
            mesh_offset += 1
        }

        // Copy vertices
        for j in 0..<len(src.verts) {
            mesh.verts[vert_offset] = src.verts[j]
            vert_offset += 1
        }

        // Copy triangles (with adjusted vertex indices)
        for j in 0..<len(src.tris) {
            // Adjust vertex indices for the first 3 elements
            for k in 0..<3 {
                mesh.tris[tri_offset][k] = src.tris[j][k] + u8(vert_offset - len(src.verts))
            }
            mesh.tris[tri_offset][3] = src.tris[j][3]  // Triangle flags
            tri_offset += 1
        }
    }

    return true
}

// Subdivide edge with limits to prevent excessive subdivision
subdivide_edge_with_limits :: proc(poly: ^Detail_Polygon, chf: ^Compact_Heightfield,
                                  v0, v1: i32, sample_dist: f32) -> [dynamic]i32 {
    result := make([dynamic]i32, 0, 8)

    if v0 >= i32(len(poly.vertices)) || v1 >= i32(len(poly.vertices)) {
        append(&result, v0, v1)
        return result
    }

    p0 := poly.vertices[v0].pos
    p1 := poly.vertices[v1].pos

    // Calculate edge vector and length
    edge := p1 - p0
    length := linalg.length(edge)

    if length <= sample_dist {
        // Edge is short enough, no subdivision needed
        append(&result, v0, v1)
        return result
    }

    // Calculate number of subdivisions with strict limits
    nsubdivs := i32(math.ceil(length / sample_dist))
    if nsubdivs > MAX_EDGE_SUBDIVISIONS do nsubdivs = MAX_EDGE_SUBDIVISIONS

    // Additional safety: don't subdivide very short edges excessively
    if length < MIN_EDGE_LENGTH * 2.0 && nsubdivs > 2 {
        nsubdivs = 2
    }

    append(&result, v0)

    // Add intermediate points
    for i in 1..<nsubdivs {
        t := f32(i) / f32(nsubdivs)
        pos := linalg.mix(p0, p1, t)

        // Sample height from heightfield (this can be slow, so we limit subdivisions)
        height := sample_heightfield_height(chf, pos)
        pos.y = height

        vert_idx := add_detail_vertex(poly, pos, height)
        append(&result, vert_idx)
    }

    append(&result, v1)
    return result
}

// Subdivide edge by adding sample points along its length (original version)
subdivide_edge :: proc(poly: ^Detail_Polygon, chf: ^Compact_Heightfield,
                      v0, v1: i32, sample_dist: f32) -> [dynamic]i32 {

    result := make([dynamic]i32, 0, 8)
    defer if len(result) == 0 do delete(result)

    if v0 >= i32(len(poly.vertices)) || v1 >= i32(len(poly.vertices)) {
        append(&result, v0, v1)
        return result
    }

    p0 := poly.vertices[v0].pos
    p1 := poly.vertices[v1].pos

    // Calculate edge vector and length
    edge := p1 - p0
    length := linalg.length(edge)

    if length <= sample_dist {
        // Edge is short enough, no subdivision needed
        append(&result, v0, v1)
        return result
    }

    // Calculate number of subdivisions
    nsubdivs := i32(math.ceil(length / sample_dist))
    if nsubdivs > MAX_EDGE_SUBDIVISIONS do nsubdivs = MAX_EDGE_SUBDIVISIONS

    append(&result, v0)

    // Add intermediate points
    for i in 1..<nsubdivs {
        t := f32(i) / f32(nsubdivs)
        pos := linalg.mix(p0, p1, t)

        // Sample height from heightfield
        height := sample_heightfield_height(chf, pos)
        pos.y = height

        vert_idx := add_detail_vertex(poly, pos, height)
        append(&result, vert_idx)
    }

    append(&result, v1)
    return result
}

// Triangulate polygon using C++ Recast approach
// This matches the exact logic from buildPolyDetail in C++ Recast
triangulate_delaunay :: proc(poly: ^Detail_Polygon) -> bool {
    if len(poly.vertices) < 3 do return false

    clear(&poly.triangles)

    nverts := len(poly.vertices)
    if nverts == 3 {
        // Simple triangle case
        a := poly.vertices[0].pos
        b := poly.vertices[1].pos
        c := poly.vertices[2].pos
        
        // Check triangle orientation - must be counter-clockwise
        area := triangle_area_2d_detail(a, b, c)
        if area > MIN_POLYGON_AREA {
            triangle := Detail_Triangle{
                v = {0, 1, 2},
                quality = calculate_triangle_quality(a, b, c),
                area = area,
            }
            append(&poly.triangles, triangle)
        }
        return len(poly.triangles) > 0
    }

    // C++ logic: check if polygon is small enough to skip interior sampling
    min_extent := calculate_polygon_min_extent(poly)
    sample_threshold := poly.sample_dist * 2.0
    
    // For small polygons, use simple hull triangulation only (C++ path)
    if min_extent < sample_threshold {
        success := triangulate_hull_based(poly)
        if success && len(poly.triangles) > 0 {
            return true
        }
        // Fallback for small polygons that hull fails on
        return triangulate_simple_fan(poly)
    }

    // For larger polygons, try hull triangulation first
    // C++ always calls triangulateHull before interior sampling
    success := triangulate_hull_based(poly)
    
    // If hull triangulation succeeds and produces reasonable results, use it
    expected_triangles := nverts - 2
    if success && len(poly.triangles) >= expected_triangles {
        return true
    }

    // Hull triangulation failed or incomplete, try ear clipping
    clear(&poly.triangles) // Clear partial results
    success = triangulate_ear_clipping_robust(poly)
    
    if success && len(poly.triangles) >= expected_triangles {
        return true
    }

    // Ear clipping failed, use simple fan as last resort
    clear(&poly.triangles) // Clear partial results
    return triangulate_simple_fan(poly)
}

// Hull-based triangulation that matches C++ triangulateHull exactly
// This is more robust than ear clipping for simple polygons
triangulate_hull_based :: proc(poly: ^Detail_Polygon) -> bool {
    nverts := len(poly.vertices)
    if nverts < 3 {
        log.warnf("triangulate_hull_based: Too few vertices (%d)", nverts)
        return false
    }

    clear(&poly.triangles)

    // For triangles, handle directly
    if nverts == 3 {
        a := poly.vertices[0].pos
        b := poly.vertices[1].pos
        c := poly.vertices[2].pos
        
        // Check triangle orientation and area
        area := triangle_area_2d_detail(a, b, c)
        abs_area := abs(area)
        
        // For hull triangulation, we accept triangles regardless of winding
        // The C++ version uses absolute area for hull triangulation
        if abs_area > MIN_POLYGON_AREA {
            triangle := Detail_Triangle{
                v = {0, 1, 2},
                quality = calculate_triangle_quality(a, b, c),
                area = abs_area,
            }
            append(&poly.triangles, triangle)
        }
        return len(poly.triangles) > 0
    }

    // Create hull indices - for detail mesh, vertices are in hull order
    hull := make([dynamic]i32, nverts)
    defer delete(hull)
    
    for i in 0..<nverts {
        append(&hull, i32(i))
    }
    
    nhull := nverts
    nin := nverts  // All vertices are original polygon vertices for now
    
    // Validate polygon vertices are in correct order (counter-clockwise)
    // Calculate signed area to check winding
    signed_area := f32(0.0)
    for i in 0..<nverts {
        j := (i + 1) % nverts
        signed_area += (poly.vertices[j].pos.x - poly.vertices[i].pos.x) * (poly.vertices[j].pos.z + poly.vertices[i].pos.z)
    }

    // If clockwise, reverse the hull array
    if signed_area > 0.0 {
        for i in 0..<nverts/2 {
            hull[i], hull[nverts-1-i] = hull[nverts-1-i], hull[i]
        }
    }
    
    // Find starting ear with shortest perimeter (C++ logic)
    start := 0
    left := 1
    right := nhull - 1
    dmin := f32(1e30)

    for i in 0..<nhull {
        // C++ logic: prefer original vertices for ears (skip non-original in C++)
        if hull[i] >= i32(nin) do continue
        
        pi := (i + nhull - 1) % nhull
        ni := (i + 1) % nhull
        
        pv := poly.vertices[hull[pi]].pos
        cv := poly.vertices[hull[i]].pos
        nv := poly.vertices[hull[ni]].pos
        
        d := linalg.distance(pv.xz, cv.xz) + linalg.distance(cv.xz, nv.xz) + linalg.distance(nv.xz, pv.xz)
        if d < dmin {
            start = i
            left = ni
            right = pi
            dmin = d
        }
    }

    // Add first triangle
    a := poly.vertices[hull[start]].pos
    b := poly.vertices[hull[left]].pos
    c := poly.vertices[hull[right]].pos

    // Ensure triangle has positive area (counter-clockwise)
    area := triangle_area_2d_detail(a, b, c)
    
    // C++ behavior: Always add triangle in hull triangulation, even if degenerate
    // The area check is less strict for hull triangulation
    triangle := Detail_Triangle{
        v = {hull[start], hull[left], hull[right]},
        quality = abs(area) > MIN_POLYGON_AREA ? calculate_triangle_quality(a, b, c) : 0.1,
        area = abs(area), // Use absolute area
    }
    append(&poly.triangles, triangle)

    // Triangulate remaining polygon by moving left or right (C++ logic)
    for next_index(left, nhull) != right {
        nleft := next_index(left, nhull)
        nright := prev_index(right, nhull)
        
        cvleft := poly.vertices[hull[left]].pos
        nvleft := poly.vertices[hull[nleft]].pos
        cvright := poly.vertices[hull[right]].pos
        nvright := poly.vertices[hull[nright]].pos
        
        dleft := linalg.distance(cvleft.xz, nvleft.xz) + linalg.distance(nvleft.xz, cvright.xz)
        dright := linalg.distance(cvright.xz, nvright.xz) + linalg.distance(cvleft.xz, nvright.xz)
        
        if dleft < dright {
            // Move left
            a := poly.vertices[hull[left]].pos
            b := poly.vertices[hull[nleft]].pos
            c := poly.vertices[hull[right]].pos
            
            area := triangle_area_2d_detail(a, b, c)
            // C++ behavior: Always add triangle in hull triangulation
            triangle := Detail_Triangle{
                v = {hull[left], hull[nleft], hull[right]},
                quality = abs(area) > MIN_POLYGON_AREA ? calculate_triangle_quality(a, b, c) : 0.1,
                area = abs(area),
            }
            append(&poly.triangles, triangle)
            left = nleft
        } else {
            // Move right
            a := poly.vertices[hull[left]].pos
            b := poly.vertices[hull[nright]].pos
            c := poly.vertices[hull[right]].pos
            
            area := triangle_area_2d_detail(a, b, c)
            // C++ behavior: Always add triangle in hull triangulation
            triangle := Detail_Triangle{
                v = {hull[left], hull[nright], hull[right]},
                quality = abs(area) > MIN_POLYGON_AREA ? calculate_triangle_quality(a, b, c) : 0.1,
                area = abs(area),
            }
            append(&poly.triangles, triangle)
            right = nright
        }
    }

    return len(poly.triangles) > 0
}

// Helper functions for hull triangulation
next_index :: proc "contextless" (i, n: int) -> int {
    return (i + 1) % n
}

prev_index :: proc "contextless" (i, n: int) -> int {
    return (i + n - 1) % n
}

// Simple triangulation for convex polygons (triangles and quads)
triangulate_simple_convex :: proc(poly: ^Detail_Polygon) -> bool {
    nverts := len(poly.vertices)
    if nverts < 3 do return false

    if nverts == 3 {
        a := poly.vertices[0].pos
        b := poly.vertices[1].pos
        c := poly.vertices[2].pos
        
        if !is_triangle_degenerate(a, b, c, MIN_POLYGON_AREA) {
            triangle := Detail_Triangle{
                v = {0, 1, 2},
                quality = calculate_triangle_quality(a, b, c),
                area = triangle_area_2d_detail(a, b, c),
            }
            append(&poly.triangles, triangle)
        }
    } else if nverts == 4 {
        // For quads, choose better diagonal
        // Test both possible triangulations and pick the one with better quality
        a := poly.vertices[0].pos
        b := poly.vertices[1].pos
        c := poly.vertices[2].pos
        d := poly.vertices[3].pos
        
        // Option 1: triangles (0,1,2) and (0,2,3)
        q1a := calculate_triangle_quality(a, b, c)
        q1b := calculate_triangle_quality(a, c, d)
        quality1 := min(q1a, q1b)
        
        // Option 2: triangles (0,1,3) and (1,2,3)
        q2a := calculate_triangle_quality(a, b, d)
        q2b := calculate_triangle_quality(b, c, d)
        quality2 := min(q2a, q2b)
        
        if quality1 >= quality2 {
            // Use diagonal 0-2
            if !is_triangle_degenerate(a, b, c, MIN_POLYGON_AREA) {
                triangle1 := Detail_Triangle{
                    v = {0, 1, 2},
                    quality = q1a,
                    area = triangle_area_2d_detail(a, b, c),
                }
                append(&poly.triangles, triangle1)
            }
            if !is_triangle_degenerate(a, c, d, MIN_POLYGON_AREA) {
                triangle2 := Detail_Triangle{
                    v = {0, 2, 3},
                    quality = q1b,
                    area = triangle_area_2d_detail(a, c, d),
                }
                append(&poly.triangles, triangle2)
            }
        } else {
            // Use diagonal 1-3
            if !is_triangle_degenerate(a, b, d, MIN_POLYGON_AREA) {
                triangle1 := Detail_Triangle{
                    v = {0, 1, 3},
                    quality = q2a,
                    area = triangle_area_2d_detail(a, b, d),
                }
                append(&poly.triangles, triangle1)
            }
            if !is_triangle_degenerate(b, c, d, MIN_POLYGON_AREA) {
                triangle2 := Detail_Triangle{
                    v = {1, 2, 3},
                    quality = q2b,
                    area = triangle_area_2d_detail(b, c, d),
                }
                append(&poly.triangles, triangle2)
            }
        }
    }

    return len(poly.triangles) > 0
}

// Robust ear clipping with improved ear detection  
// Returns true if triangulation completed successfully
triangulate_ear_clipping_robust :: proc(poly: ^Detail_Polygon) -> bool {
    nverts := len(poly.vertices)
    if nverts < 3 do return false

    // Create working list of vertex indices
    indices := make([dynamic]i32, nverts)
    defer delete(indices)

    for i in 0..<nverts {
        append(&indices, i32(i))
    }

    remaining := nverts
    iterations := 0

    // Ear clipping should complete in exactly (n-2) ears for n vertices
    // We track progress to detect degenerate cases
    last_remaining := remaining
    stalled_iterations := 0

    for remaining > 3 {
        iterations += 1
        found_ear := false
        best_ear := -1
        best_quality := f32(0.0)

        // Check for progress stalling (indicates degenerate polygon)
        if remaining == last_remaining {
            stalled_iterations += 1
            // Much more lenient stalling detection - allow more attempts
            if stalled_iterations > 3 || iterations > remaining * 6 {

                // Use fallback triangulation
                return triangulate_remaining_as_fan(poly, indices[:remaining])
            }
        } else {
            stalled_iterations = 0
            last_remaining = remaining
        }

        // Additional safety check: prevent runaway iterations (more lenient)
        if iterations > remaining * 10 {
            return triangulate_remaining_as_fan(poly, indices[:remaining])
        }

        // Find the best quality ear
        for i in 0..<remaining {
            curr := i
            prev := (i + remaining - 1) % remaining
            next := (i + 1) % remaining
            if !is_ear(poly, indices[:remaining], prev, curr, next) do continue
            // Calculate triangle quality
            a := poly.vertices[indices[prev]].pos
            b := poly.vertices[indices[curr]].pos
            c := poly.vertices[indices[next]].pos

            if !validate_triangle(a, b, c) do continue

            quality := calculate_triangle_quality(a, b, c)
            if quality > best_quality {
                best_quality = quality
                best_ear = curr
                found_ear = true
            }
        }

        if !found_ear {
            // Fallback: try relaxed ear test for difficult cases
            for i in 0..<remaining {
                curr := i
                prev := (i + remaining - 1) % remaining
                next := (i + 1) % remaining

                if is_ear_relaxed(poly, indices[:remaining], prev, curr, next) {
                    best_ear = curr
                    found_ear = true
                    best_quality = 0.3  // Lower quality but still valid
                    break
                }
            }
        }

        if !found_ear {
            // Try one more time with even more relaxed constraints
            for i in 0..<remaining {
                curr := i
                prev := (i + remaining - 1) % remaining
                next := (i + 1) % remaining

                a := poly.vertices[indices[prev]].pos
                b := poly.vertices[indices[curr]].pos
                c := poly.vertices[indices[next]].pos

                // Very basic convexity test - just check signed area is positive
                area := triangle_area_2d_detail(a, b, c)
                if area > 1e-12 {
                    best_ear = curr
                    found_ear = true
                    best_quality = 0.1  // Very low quality but still valid
                    break
                }
            }
        }
        
        if !found_ear {
            // Only warn if this happens early - for complex polygons it's more normal
            if iterations <= 2 {
  
            }
            // This indicates a degenerate polygon that cannot be properly triangulated
            return triangulate_remaining_as_fan(poly, indices[:remaining])
        }

        // Create triangle from the best ear
        curr := best_ear
        prev := (best_ear + remaining - 1) % remaining
        next := (best_ear + 1) % remaining

        a := poly.vertices[indices[prev]].pos
        b := poly.vertices[indices[curr]].pos
        c := poly.vertices[indices[next]].pos

        triangle := Detail_Triangle{
            v = {indices[prev], indices[curr], indices[next]},
            quality = calculate_triangle_quality(a, b, c),
            area = triangle_area_2d_detail(a, b, c),
        }
        append(&poly.triangles, triangle)

        // Remove the ear vertex
        for j in best_ear..<remaining-1 {
            indices[j] = indices[j+1]
        }
        remaining -= 1
    }

    // Final triangle case
    if remaining == 3 {
        // Create the final triangle
        a := poly.vertices[indices[0]].pos
        b := poly.vertices[indices[1]].pos
        c := poly.vertices[indices[2]].pos

        if !is_triangle_degenerate(a, b, c, MIN_POLYGON_AREA) {
            triangle := Detail_Triangle{
                v = {indices[0], indices[1], indices[2]},
                quality = calculate_triangle_quality(a, b, c),
                area = triangle_area_2d_detail(a, b, c),
            }
            append(&poly.triangles, triangle)
        }
    } else if remaining > 3 {
        // Shouldn't happen, but handle as fallback
        log.warnf("Triangulation ended with %d vertices remaining, using fan triangulation", remaining)
        return triangulate_remaining_as_fan(poly, indices[:remaining])
    }

    // Verify we created the expected number of triangles
    expected_triangles := nverts - 2
    if len(poly.triangles) != expected_triangles {
        log.warnf("Triangulation created %d triangles, expected %d", len(poly.triangles), expected_triangles)
    }

    return len(poly.triangles) > 0
}

// Simple fan triangulation as fallback
triangulate_simple_fan :: proc(poly: ^Detail_Polygon) -> bool {
    nverts := len(poly.vertices)
    if nverts < 3 do return false

    clear(&poly.triangles)

    // Create fan from first vertex
    for i in 1..<nverts-1 {
        a := poly.vertices[0].pos
        b := poly.vertices[i].pos
        c := poly.vertices[i+1].pos

        if !is_triangle_degenerate(a, b, c, MIN_POLYGON_AREA) {
            triangle := Detail_Triangle{
                v = {0, i32(i), i32(i+1)},
                quality = 0.3, // Lower quality but guaranteed to work
                area = triangle_area_2d_detail(a, b, c),
            }
            append(&poly.triangles, triangle)
        }
    }

    return len(poly.triangles) > 0
}

// Triangulate remaining vertices as a fan
triangulate_remaining_as_fan :: proc(poly: ^Detail_Polygon, indices: []i32) -> bool {
    remaining := len(indices)
    if remaining < 3 do return len(poly.triangles) > 0

    // Create fan from first vertex with more lenient area check
    for i in 1..<remaining-1 {
        a := poly.vertices[indices[0]].pos
        b := poly.vertices[indices[i]].pos
        c := poly.vertices[indices[i+1]].pos

        // Use much more lenient area threshold for fallback triangulation
        area := triangle_area_2d_detail(a, b, c)

        if area > 1e-12 {  // Very small but not zero
            triangle := Detail_Triangle{
                v = {indices[0], indices[i], indices[i+1]},
                quality = 0.3, // Lower quality but guaranteed to work
                area = area,
            }
            append(&poly.triangles, triangle)
        }
    }

    return len(poly.triangles) > 0
}


// Relaxed ear test for fallback cases
is_ear_relaxed :: proc(poly: ^Detail_Polygon, indices: []i32, prev, curr, next: int) -> bool {
    if prev < 0 || curr < 0 || next < 0 do return false
    if prev >= len(indices) || curr >= len(indices) || next >= len(indices) do return false

    v_prev := indices[prev]
    v_curr := indices[curr]
    v_next := indices[next]

    if v_prev >= i32(len(poly.vertices)) || v_curr >= i32(len(poly.vertices)) || v_next >= i32(len(poly.vertices)) {
        return false
    }
    if v_prev < 0 || v_curr < 0 || v_next < 0 do return false

    a := poly.vertices[v_prev].pos
    b := poly.vertices[v_curr].pos
    c := poly.vertices[v_next].pos

    // Very lenient degeneracy check
    if is_triangle_degenerate(a, b, c, MIN_POLYGON_AREA * 0.01) do return false

    // Relaxed convexity check - just ensure we have some positive area
    if linalg.vector_cross2(b.xz - a.xz, c.xz - b.xz) <= 0 do return false  // Still need convexity

    // Skip the expensive point-in-triangle test for relaxed mode
    return true
}

// Check if a vertex forms a valid ear (improved algorithm)
is_ear :: proc(poly: ^Detail_Polygon, indices: []i32, prev, curr, next: int) -> bool {
    if prev < 0 || curr < 0 || next < 0 do return false
    if prev >= len(indices) || curr >= len(indices) || next >= len(indices) do return false

    v_prev := indices[prev]
    v_curr := indices[curr]
    v_next := indices[next]

    if v_prev >= i32(len(poly.vertices)) || v_curr >= i32(len(poly.vertices)) || v_next >= i32(len(poly.vertices)) {
        return false
    }
    if v_prev < 0 || v_curr < 0 || v_next < 0 do return false

    a := poly.vertices[v_prev].pos
    b := poly.vertices[v_curr].pos
    c := poly.vertices[v_next].pos

    // Check if triangle is degenerate using signed area
    area := triangle_area_2d_detail(a, b, c)
    if area <= 1e-9 do return false  // Must be counter-clockwise (positive area)

    // Check that no other vertices lie inside this triangle
    for i in 0..<len(indices) {
        if i == prev || i == curr || i == next do continue

        test_v := indices[i]
        if test_v >= i32(len(poly.vertices)) || test_v < 0 do continue

        p := poly.vertices[test_v].pos

        // Use improved point-in-triangle test
        if point_in_triangle_2d_robust(p, a, b, c) {
            return false  // Point inside triangle, not a valid ear
        }
    }

    return true
}

// Simple point in triangle test using cross products
point_in_triangle_2d :: proc "contextless" (p, a, b, c: [3]f32) -> bool {
    // Use edge testing method - point is inside if it's on the same side of all edges

    // Vector from a to b
    cross1 := linalg.cross(b.xz - a.xz, p.xz - a.xz)

    // Vector from b to c
    cross2 := linalg.cross(c.xz - b.xz, p.xz - b.xz)

    // Vector from c to a
    cross3 := linalg.cross(a.xz - c.xz, p.xz - c.xz)

    // Point is inside if all crosses have the same sign (all positive or all negative)
    return (cross1 >= 0 && cross2 >= 0 && cross3 >= 0) || (cross1 <= 0 && cross2 <= 0 && cross3 <= 0)
}

// Robust point-in-triangle test using edge method with proper epsilon handling
point_in_triangle_2d_robust :: proc "contextless" (p, a, b, c: [3]f32) -> bool {
    // Use edge testing method with consistent winding
    // For counter-clockwise triangles, point is inside if all edge tests are positive
    
    EPSILON :: 1e-9
    
    // Edge AB
    cross1 := linalg.cross(b.xz - a.xz, p.xz - a.xz)
    
    // Edge BC  
    cross2 := linalg.cross(c.xz - b.xz, p.xz - b.xz)
    
    // Edge CA
    cross3 := linalg.cross(a.xz - c.xz, p.xz - c.xz)

    // Point is strictly inside if all crosses have the same sign as the triangle orientation
    // For counter-clockwise triangles, all should be positive  
    // Use epsilon to avoid boundary cases being considered "inside"
    return cross1 > EPSILON && cross2 > EPSILON && cross3 > EPSILON
}

// Calculate 2D triangle area (signed)
triangle_area_2d_detail :: proc "contextless" (a, b, c: [3]f32) -> f32 {
    return 0.5 * linalg.cross(b.xz - a.xz, c.xz - a.xz)
}

// Add interior samples with limits to prevent excessive point generation
add_interior_samples_with_limits :: proc(poly: ^Detail_Polygon, chf: ^Compact_Heightfield, sample_dist: f32) {
    if len(poly.vertices) < 3 do return

    // Calculate polygon bounds
    min_pos := poly.vertices[0].pos
    max_pos := poly.vertices[0].pos

    for v in poly.vertices[1:] {
        min_pos.x = min(min_pos.x, v.pos.x)
        min_pos.z = min(min_pos.z, v.pos.z)
        max_pos.x = max(max_pos.x, v.pos.x)
        max_pos.z = max(max_pos.z, v.pos.z)
    }

    // Calculate potential sample count and limit it
    nx := i32(math.ceil((max_pos.x - min_pos.x) / sample_dist))
    nz := i32(math.ceil((max_pos.z - min_pos.z) / sample_dist))

    total_samples := nx * nz
    adjusted_dist := sample_dist
    if total_samples > MAX_INTERIOR_SAMPLES {
        // Adjust sample distance to stay within limits
        scale_factor := math.sqrt(f32(total_samples) / f32(MAX_INTERIOR_SAMPLES))
        adjusted_dist *= scale_factor
        nx = i32(math.ceil((max_pos.x - min_pos.x) / adjusted_dist))
        nz = i32(math.ceil((max_pos.z - min_pos.z) / adjusted_dist))


    }

    samples_added := 0
    for i in 1..<nx {
        for j in 1..<nz {
            x := min_pos.x + f32(i) * adjusted_dist
            z := min_pos.z + f32(j) * adjusted_dist

            pos := [3]f32{x, 0, z}

            // Check if point is inside polygon (2D test)
            inside := point_in_polygon_detail(pos, poly)
            if !inside do continue

            // Sample height from heightfield
            height := sample_heightfield_height(chf, pos)
            pos.y = height

            add_detail_vertex(poly, pos, height)
            samples_added += 1

            // Safety limit on samples added
            if samples_added >= MAX_INTERIOR_SAMPLES / 2 {

                return
            }
        }
    }


}

// Add sample points inside polygon for better triangulation (original version)
add_interior_samples :: proc(poly: ^Detail_Polygon, chf: ^Compact_Heightfield, sample_dist: f32) {
    if len(poly.vertices) < 3 do return

    // Calculate polygon bounds
    min_pos := poly.vertices[0].pos
    max_pos := poly.vertices[0].pos

    for v in poly.vertices[1:] {
        min_pos.x = min(min_pos.x, v.pos.x)
        min_pos.z = min(min_pos.z, v.pos.z)
        max_pos.x = max(max_pos.x, v.pos.x)
        max_pos.z = max(max_pos.z, v.pos.z)
    }

    // Sample points in grid pattern
    nx := i32(math.ceil((max_pos.x - min_pos.x) / sample_dist))
    nz := i32(math.ceil((max_pos.z - min_pos.z) / sample_dist))

    for i in 1..<nx {
        for j in 1..<nz {
            x := min_pos.x + f32(i) * sample_dist
            z := min_pos.z + f32(j) * sample_dist

            pos := [3]f32{x, 0, z}

            // Check if point is inside polygon (2D test)
            inside := point_in_polygon_detail(pos, poly)
            if !inside do continue

            // Sample height from heightfield
            height := sample_heightfield_height(chf, pos)
            pos.y = height

            add_detail_vertex(poly, pos, height)
        }
    }
}

// Point in polygon test for detail vertices
point_in_polygon_detail :: proc(pt: [3]f32, poly: ^Detail_Polygon) -> bool {
    if len(poly.vertices) < 3 do return false

    inside := false
    j := len(poly.vertices) - 1

    for i in 0..<len(poly.vertices) {
        vi := poly.vertices[i].pos
        vj := poly.vertices[j].pos

        if ((vi.z > pt.z) != (vj.z >= pt.z)) &&
           (pt.x < (vj.x - vi.x) * (pt.z - vi.z) / (vj.z - vi.z) + vi.x) {
            inside = !inside
        }
        j = i
    }

    return inside
}

// Timeout-protected version of polygon detail mesh building
build_polygon_detail_mesh_with_timeout :: proc(poly: ^Detail_Polygon, chf: ^Compact_Heightfield,
                                              timeout_ctx: ^Timeout_Context) -> bool {
    start_time := time.now()

    // Quick timeout check
    if check_timeout(timeout_ctx, "polygon mesh building") {
        return false
    }

    if len(poly.vertices) < 3 do return false

    // Step 1: Subdivide constraint edges with timeout protection
    new_edges := make([dynamic]Detail_Edge, 0, len(poly.edges) * 4)
    defer delete(new_edges)

    edge_count := 0
    for edge in poly.edges {
        edge_count += 1

        // Check timeout every 10 edges
        if edge_count % 10 == 0 && check_timeout(timeout_ctx, "edge subdivision") {
            log.warnf("Timeout during edge subdivision at edge %d", edge_count)
            return false
        }

        if !edge.constrained do continue

        subdivided := subdivide_edge_with_limits(poly, chf, edge.v0, edge.v1, poly.sample_dist)

        // Create new constraint edges between subdivided points
        for i in 0..<len(subdivided)-1 {
            new_edge := Detail_Edge{
                v0 = subdivided[i],
                v1 = subdivided[i+1],
                constrained = true,
                length = 0, // Will be calculated later if needed
            }
            append(&new_edges, new_edge)
        }

        delete(subdivided)
    }

    // Replace old edges with subdivided ones
    clear(&poly.edges)
    for edge in new_edges {
        append(&poly.edges, edge)
    }

    // Step 2: Check if polygon is too small for interior sampling (matches C++ line 805)
    // Calculate minimum extent of polygon
    min_extent := f32(math.F32_MAX)
    for i in 0..<len(poly.vertices) {
        j := (i + 1) % len(poly.vertices)
        edge_vec := poly.vertices[j].pos.xz - poly.vertices[i].pos.xz
        edge_len := linalg.length(edge_vec)
        min_extent = min(min_extent, edge_len)
    }
    
    // If polygon is too small for sampling, use simple hull triangulation (C++ behavior)
    if min_extent < poly.sample_dist * 2.0 {
        return triangulate_hull_based(poly)
    }

    // Add interior sample points with limits
    initial_vert_count := len(poly.vertices)
    add_interior_samples_with_limits(poly, chf, poly.sample_dist)



    // Step 3: Triangulate with timeout check
    if check_timeout(timeout_ctx, "triangulation") {
        log.warn("Timeout before triangulation, using simple fallback")
        return triangulate_simple_fan(poly)
    }

    if !triangulate_delaunay(poly) {
        log.warn("Failed to triangulate detail polygon, using fallback")
        return triangulate_simple_fan(poly)
    }



    return true
}

// Main function to build detailed mesh for a single polygon (legacy version)
build_polygon_detail_mesh :: proc(poly: ^Detail_Polygon, chf: ^Compact_Heightfield) -> bool {
    if len(poly.vertices) < 3 do return false

    // Step 1: Subdivide constraint edges
    new_edges := make([dynamic]Detail_Edge, 0, len(poly.edges) * 4)
    defer delete(new_edges)

    for edge in poly.edges {
        if !edge.constrained do continue

        subdivided := subdivide_edge(poly, chf, edge.v0, edge.v1, poly.sample_dist)

        // Create new constraint edges between subdivided points
        for i in 0..<len(subdivided)-1 {
            new_edge := Detail_Edge{
                v0 = subdivided[i],
                v1 = subdivided[i+1],
                constrained = true,
                length = 0, // Will be calculated later if needed
            }
            append(&new_edges, new_edge)
        }

        delete(subdivided)
    }

    // Replace old edges with subdivided ones
    clear(&poly.edges)
    for edge in new_edges {
        append(&poly.edges, edge)
    }

    // Step 2: Add interior sample points
    add_interior_samples(poly, chf, poly.sample_dist)

    // Step 3: Triangulate
    if !triangulate_delaunay(poly) {
        log.warn("Failed to triangulate detail polygon")
        return false
    }


    return true
}

// Check if timeout has been exceeded
check_timeout :: proc(ctx: ^Timeout_Context, operation: string) -> bool {
    now := time.now()

    // Check global timeout
    if time.duration_milliseconds(time.diff(ctx.start_time, now)) > time.duration_milliseconds(ctx.global_timeout) {
        return true
    }

    // Check polygon timeout
    if time.duration_milliseconds(time.diff(ctx.last_progress, now)) > time.duration_milliseconds(ctx.polygon_timeout) {
        log.warnf("Polygon timeout exceeded during %s on polygon %d (%.2fs)", operation,
                 ctx.current_polygon, f64(time.duration_milliseconds(time.diff(ctx.last_progress, now))) / 1000.0)
        return true
    }

    return false
}

// Update progress tracking
update_progress :: proc(ctx: ^Timeout_Context, polygon_idx: i32) {
    ctx.last_progress = time.now()
    ctx.current_polygon = polygon_idx


}

// Main function to build poly mesh detail with timeout protection
build_poly_mesh_detail :: proc(pmesh: ^Poly_Mesh, chf: ^Compact_Heightfield,
                                 sample_dist, sample_max_error: f32, dmesh: ^Poly_Mesh_Detail) -> bool {

    if pmesh == nil || chf == nil || dmesh == nil do return false
    if pmesh.npolys <= 0 do return false

    // Initialize timeout context
    timeout_ctx := Timeout_Context{
        start_time = time.now(),
        global_timeout = time.Millisecond * GLOBAL_TIMEOUT_MS,
        polygon_timeout = time.Millisecond * DEFAULT_POLYGON_TIMEOUT_MS,
        last_progress = time.now(),
        polygons_processed = pmesh.npolys,
        current_polygon = 0,
    }



    // Initialize detail mesh

    // Process each polygon
    detail_polygons := make([dynamic]Detail_Polygon, pmesh.npolys)
    defer {
        for &poly in detail_polygons {
            free_detail_polygon(&poly)
        }
        delete(detail_polygons)
    }

    total_verts := 0
    total_tris := 0
    
    processed_count := 0
    failed_init_count := 0
    degenerate_count := 0
    triangulation_fail_count := 0
    zero_triangle_count := 0

    for i in 0..<pmesh.npolys {
        // Check for timeout before processing each polygon
        if check_timeout(&timeout_ctx, "polygon processing") {
            log.warnf("Timeout exceeded, stopping at polygon %d/%d", i, pmesh.npolys)
            break
        }

        update_progress(&timeout_ctx, i)
        poly := &detail_polygons[i]

        // Initialize polygon from mesh data
        if !init_detail_polygon(poly, pmesh, chf, i, sample_dist, sample_max_error) {
            log.warnf("Failed to initialize detail polygon %d", i)
            failed_init_count += 1
            continue
        }

        // Quick validation: skip polygons that are too small or have too few vertices
        if len(poly.vertices) < 3 {

            degenerate_count += 1
            continue
        }

        // Calculate polygon area and skip if degenerate
        if len(poly.vertices) >= 3 {
            area := triangle_area_2d_detail(poly.vertices[0].pos, poly.vertices[1].pos, poly.vertices[2].pos)
            abs_area := abs(area)  // Use absolute value to handle both winding directions
            if abs_area < MIN_POLYGON_AREA {

                degenerate_count += 1
                continue
            }
        }

        // Build detailed mesh for this polygon with timeout protection
        if !build_polygon_detail_mesh_with_timeout(poly, chf, &timeout_ctx) {
            log.warnf("Failed to build detail mesh for polygon %d", i)
            triangulation_fail_count += 1
            continue
        }
        
        processed_count += 1
        
        // Debug logging for successful triangulation
        if len(poly.triangles) == 0 {
            log.warnf("Polygon %d has %d vertices but generated 0 triangles", i, len(poly.vertices))
            zero_triangle_count += 1
        }

        total_verts += len(poly.vertices)
        total_tris += len(poly.triangles)
    }
    



    if total_verts == 0 || total_tris == 0 {
        log.warn("No valid detail mesh data generated")
        return false
    }

    // Allocate final detail mesh arrays
    dmesh.meshes = make([][4]u32, pmesh.npolys)
    dmesh.verts = make([][3]f32, total_verts)
    dmesh.tris = make([][4]u8, total_tris)

    // Copy data to final arrays
    mesh_idx := 0
    vert_offset := 0
    tri_offset := 0

    for i in 0..<pmesh.npolys {
        poly := &detail_polygons[i]

        if len(poly.vertices) == 0 || len(poly.triangles) == 0 do continue

        // Set mesh header
        dmesh.meshes[mesh_idx] = [4]u32{
            u32(vert_offset),          // Vertex base
            u32(len(poly.vertices)),   // Vertex count
            u32(tri_offset),           // Triangle base
            u32(len(poly.triangles)),  // Triangle count
        }

        // Copy vertices
        for &vertex in poly.vertices {
            dmesh.verts[vert_offset] = [3]f32{vertex.pos.x, vertex.pos.y, vertex.pos.z}
            vert_offset += 1
        }

        // Copy triangles
        for &triangle in poly.triangles {

            // Store triangle with vertex indices relative to mesh base
            dmesh.tris[tri_offset] = [4]u8{
                u8(triangle.v[0]),
                u8(triangle.v[1]),
                u8(triangle.v[2]),
                0,  // Triangle flags (reserved)
            }

            tri_offset += 1
        }

        mesh_idx += 1
    }

    // Update actual counts (in case some polygons failed)
    // Arrays are already properly sized, no need to update counts

    // Validate final mesh
    if !validate_poly_mesh_detail(dmesh) {
        log.error("Generated invalid detail mesh")
        return false
    }



    return true
}
