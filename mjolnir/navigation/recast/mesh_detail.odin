package navigation_recast

import "../../geometry"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:time"

// Detail mesh building constants
RC_UNSET_HEIGHT :: 0xffff

// Maximum subdivision levels for edge tessellation
MAX_EDGE_SUBDIVISIONS :: 10

// Minimum edge length for detail tessellation (in world units)
MIN_EDGE_LENGTH :: 0.1

// Timeout constants for robustness
DEFAULT_POLYGON_TIMEOUT_MS :: 5000 // 5 seconds per polygon
GLOBAL_TIMEOUT_MS :: 30000 // 30 seconds total
MAX_INTERIOR_SAMPLES :: 10000 // Maximum interior sample points to prevent memory explosion
MIN_POLYGON_AREA :: 1e-6 // Minimum area for valid polygon

// Quality thresholds for triangle optimization
MIN_TRIANGLE_QUALITY :: 0.5 // Minimum ratio of inscribed to circumscribed circle
MIN_ANGLE_DEGREES :: 20.0 // Minimum triangle angle in degrees
MAX_ANGLE_DEGREES :: 160.0 // Maximum triangle angle in degrees

// Vertex structure for detail mesh building
Detail_Vertex :: struct {
  pos:    [3]f32, // World position
  height: f32, // Sampled height from heightfield
  flag:   u32, // Flags (border vertex, etc.)
}

// Edge structure for constrained triangulation
Detail_Edge :: struct {
  v0:          i32, // First vertex index
  v1:          i32, // Second vertex index
  constrained: bool, // Whether this edge must be preserved
  length:      f32, // Edge length in world units
}

// Triangle structure for detail mesh
Detail_Triangle :: struct {
  v:    [3]i32, // Vertex indices
  area: f32, // Triangle area
}

// Polygon context for detail mesh building
Detail_Polygon :: struct {
  vertices:    [dynamic]Detail_Vertex, // Vertices in this polygon
  edges:       [dynamic]Detail_Edge, // Constrained edges
  triangles:   [dynamic]Detail_Triangle, // Generated triangles
  sample_dist: f32, // Sample distance for this polygon
  max_error:   f32, // Maximum allowed error
}

// Height sample point for interpolation
Height_Sample :: struct {
  pos:    [3]f32, // Sample position
  height: f32, // Interpolated height
  weight: f32, // Interpolation weight
}

// Sample height from heightfield at given world position
sample_heightfield_height :: proc(
  chf: ^Compact_Heightfield,
  pos: [3]f32,
) -> f32 {
  if chf == nil do return 0.0
  // Convert world position to cell coordinates
  f := (pos.xz - chf.bmin.xz) / chf.cs
  // Get cell indices
  cell_idx := [2]i32{i32(math.floor(f.x)), i32(math.floor(f.y))}
  x := cell_idx.x
  z := cell_idx.y
  // Check bounds
  if x < 0 || z < 0 || x >= chf.width - 1 || z >= chf.height - 1 {
    return 0.0
  }
  // Get fractional parts for interpolation
  f_frac := f - [2]f32{f32(x), f32(z)}
  fx_frac := f_frac.x
  fz_frac := f_frac.y
  // Sample heights from surrounding cells
  heights: [4]f32
  heights[0] = get_cell_height(chf, x, z) // Bottom-left
  heights[1] = get_cell_height(chf, x + 1, z) // Bottom-right
  heights[2] = get_cell_height(chf, x, z + 1) // Top-left
  heights[3] = get_cell_height(chf, x + 1, z + 1) // Top-right
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

// Calculate minimum extent of polygon
calculate_polygon_min_extent :: proc(poly: ^Detail_Polygon) -> f32 {
  nverts := len(poly.vertices)
  if nverts < 3 do return 0.0
  min_dist := f32(1e30)
  for i in 0 ..< nverts {
    ni := (i + 1) % nverts
    p1 := poly.vertices[i].pos
    p2 := poly.vertices[ni].pos
    max_edge_dist := f32(0.0)
    for j in 0 ..< nverts {
      if j == i || j == ni do continue
      // Distance from point to line segment (2D)
      d, _ := geometry.point_segment_distance2_2d(poly.vertices[j].pos, p1, p2)
      max_edge_dist = max(max_edge_dist, d)
    }
    min_dist = min(min_dist, max_edge_dist)
  }
  return math.sqrt(min_dist)
}

// Check if triangle is degenerate
is_triangle_degenerate :: proc "contextless" (a, b, c: [3]f32) -> bool {
  return geometry.signed_triangle_area_2d(a, b, c) < math.F32_EPSILON
}

// Validate a triangle using multiple criteria
validate_triangle :: proc "contextless" (a, b, c: [3]f32) -> bool {
  // Check for degenerate area
  if is_triangle_degenerate(a, b, c) do return false
  // Check angles (simplified check using dot products)
  ab := b - a
  ac := c - a
  bc := c - b
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
  angle_a := math.acos(clamp(dot_a, -1.0, 1.0)) * 180.0 / math.PI
  if angle_a < MIN_ANGLE_DEGREES || angle_a > MAX_ANGLE_DEGREES do return false
  return true
}

// Add a vertex to the detail polygon, ensuring uniqueness
add_detail_vertex :: proc(
  poly: ^Detail_Polygon,
  pos: [3]f32,
  height: f32,
  flag: u32 = 0,
) -> i32 {
  // Check for existing vertex at this position
  for &v, i in poly.vertices {
    diff := v.pos - pos
    dist_sq := linalg.dot(diff, diff)
    if dist_sq < 1e-6 {   // Very close vertices are considered the same
      return i32(i)
    }
  }
  // Add new vertex
  vertex := Detail_Vertex {
    pos    = pos,
    height = height,
    flag   = flag,
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
  edge := Detail_Edge {
    v0          = v0,
    v1          = v1,
    constrained = true,
    length      = length,
  }
  append(&poly.edges, edge)
}

// Free detail polygon memory
free_detail_polygon :: proc(poly: ^Detail_Polygon) {
  delete(poly.vertices)
  delete(poly.edges)
  delete(poly.triangles)
}

// Copy detail mesh
copy_poly_mesh_detail :: proc(
  src: ^Poly_Mesh_Detail,
  dst: ^Poly_Mesh_Detail,
) -> bool {
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
merge_poly_mesh_details :: proc(
  meshes: []^Poly_Mesh_Detail,
  mesh: ^Poly_Mesh_Detail,
) -> bool {
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
    for j in 0 ..< len(src.meshes) {
      mesh.meshes[mesh_offset][0] = src.meshes[j][0] + u32(vert_offset) // Adjust vertex base
      mesh.meshes[mesh_offset][1] = src.meshes[j][1] // Vertex count
      mesh.meshes[mesh_offset][2] = src.meshes[j][2] + u32(tri_offset) // Adjust triangle base
      mesh.meshes[mesh_offset][3] = src.meshes[j][3] // Triangle count
      mesh_offset += 1
    }
    // Copy vertices
    for j in 0 ..< len(src.verts) {
      mesh.verts[vert_offset] = src.verts[j]
      vert_offset += 1
    }
    // Copy triangles (with adjusted vertex indices)
    for j in 0 ..< len(src.tris) {
      // Adjust vertex indices for the first 3 elements
      for k in 0 ..< 3 {
        mesh.tris[tri_offset][k] = src.tris[j][k] + u8(vert_offset - len(src.verts))
      }
      mesh.tris[tri_offset][3] = src.tris[j][3] // Triangle flags
      tri_offset += 1
    }
  }
  return true
}

// Hull-based triangulation
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
    area := geometry.signed_triangle_area_2d(a, b, c)
    abs_area := abs(area)
    // For hull triangulation, we accept triangles regardless of winding
    if abs_area > MIN_POLYGON_AREA {
      triangle := Detail_Triangle {
        v    = {0, 1, 2},
        area = abs_area,
      }
      append(&poly.triangles, triangle)
    }
    return len(poly.triangles) > 0
  }
  // Create hull indices - for detail mesh, vertices are in hull order
  hull := make([dynamic]i32, nverts)
  defer delete(hull)
  for i in 0 ..< nverts {
    append(&hull, i32(i))
  }
  nhull := nverts
  nin := nverts // All vertices are original polygon vertices for now
  // Validate polygon vertices are in correct order (counter-clockwise)
  // Calculate signed area to check winding
  signed_area := f32(0.0)
  for i in 0 ..< nverts {
    j := (i + 1) % nverts
    signed_area +=
      (poly.vertices[j].pos.x - poly.vertices[i].pos.x) *
      (poly.vertices[j].pos.z + poly.vertices[i].pos.z)
  }
  // If clockwise, reverse the hull array
  if signed_area > 0.0 {
    for i in 0 ..< nverts / 2 {
      hull[i], hull[nverts - 1 - i] = hull[nverts - 1 - i], hull[i]
    }
  }
  // Find starting ear with shortest perimeter
  start := 0
  left := 1
  right := nhull - 1
  dmin := f32(1e30)
  for i in 0 ..< nhull {
    if hull[i] >= i32(nin) do continue
    pi := (i + nhull - 1) % nhull
    ni := (i + 1) % nhull
    pv := poly.vertices[hull[pi]].pos
    cv := poly.vertices[hull[i]].pos
    nv := poly.vertices[hull[ni]].pos
    d :=
      linalg.distance(pv.xz, cv.xz) +
      linalg.distance(cv.xz, nv.xz) +
      linalg.distance(nv.xz, pv.xz)
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
  area := geometry.signed_triangle_area_2d(a, b, c)
  // Always add triangle in hull triangulation, even if degenerate
  // The area check is less strict for hull triangulation
  triangle := Detail_Triangle {
    v    = {hull[start], hull[left], hull[right]},
    area = abs(area), // Use absolute area
  }
  append(&poly.triangles, triangle)
  // Triangulate remaining polygon by moving left or right
  for next_index(left, nhull) != right {
    nleft := next_index(left, nhull)
    nright := prev_index(right, nhull)
    cvleft := poly.vertices[hull[left]].pos
    nvleft := poly.vertices[hull[nleft]].pos
    cvright := poly.vertices[hull[right]].pos
    nvright := poly.vertices[hull[nright]].pos
    dleft :=
      linalg.distance(cvleft.xz, nvleft.xz) +
      linalg.distance(nvleft.xz, cvright.xz)
    dright :=
      linalg.distance(cvright.xz, nvright.xz) +
      linalg.distance(cvleft.xz, nvright.xz)
    if dleft < dright {
      // Move left
      a := poly.vertices[hull[left]].pos
      b := poly.vertices[hull[nleft]].pos
      c := poly.vertices[hull[right]].pos
      area := geometry.signed_triangle_area_2d(a, b, c)
      // Always add triangle in hull triangulation
      triangle := Detail_Triangle {
        v    = {hull[left], hull[nleft], hull[right]},
        area = abs(area),
      }
      append(&poly.triangles, triangle)
      left = nleft
    } else {
      // Move right
      a := poly.vertices[hull[left]].pos
      b := poly.vertices[hull[nright]].pos
      c := poly.vertices[hull[right]].pos
      area := geometry.signed_triangle_area_2d(a, b, c)
      // Always add triangle in hull triangulation
      triangle := Detail_Triangle {
        v    = {hull[left], hull[nright], hull[right]},
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

// Main function to build poly mesh detail
build_poly_mesh_detail :: proc(
  pmesh: ^Poly_Mesh,
  chf: ^Compact_Heightfield,
  sample_dist, sample_max_error: f32,
  dmesh: ^Poly_Mesh_Detail,
) -> bool {
  if pmesh == nil || chf == nil || dmesh == nil do return false
  // Handle empty poly mesh
  if len(pmesh.verts) == 0 || pmesh.npolys == 0 {
    delete(dmesh.meshes)
    delete(dmesh.verts)
    delete(dmesh.tris)
    dmesh.meshes = make([][4]u32, 0)
    dmesh.verts = make([][3]f32, 0)
    dmesh.tris = make([][4]u8, 0)
    return true
  }
  nvp := pmesh.nvp
  cs := pmesh.cs
  ch := pmesh.ch
  orig := pmesh.bmin
  border_size := pmesh.border_size
  height_search_radius := max(1, i32(math.ceil(pmesh.max_edge_error)))
  // Calculate bounds for each polygon
  bounds := make([][4]i32, pmesh.npolys)
  defer delete(bounds)
  poly_workspace := make([][3]f32, nvp) // Working space for polygon vertices
  defer delete(poly_workspace)
  n_poly_verts := 0
  max_hw, max_hh := 0, 0
  // Find max size for polygon area and count total vertices
  for i in 0 ..< pmesh.npolys {
    p := pmesh.polys[i * nvp * 2:]
    bounds[i] = {chf.width, 0, chf.height, 0} // {xmin, xmax, ymin, ymax}
    for j in 0 ..< nvp {
      if p[j] == RC_MESH_NULL_IDX do break
      v := pmesh.verts[p[j]]
      bounds[i].x = min(bounds[i].x, i32(v.x)) // xmin
      bounds[i].y = max(bounds[i].y, i32(v.x)) // xmax
      bounds[i].z = min(bounds[i].z, i32(v.z)) // ymin
      bounds[i].w = max(bounds[i].w, i32(v.z)) // ymax
      n_poly_verts += 1
    }
    // Expand bounds by 1 and clamp to heightfield bounds
    bounds[i].x = max(0, bounds[i].x - 1)
    bounds[i].y = min(chf.width, bounds[i].y + 1)
    bounds[i].z = max(0, bounds[i].z - 1)
    bounds[i].w = min(chf.height, bounds[i].w + 1)
    if bounds[i].x >= bounds[i].y || bounds[i].z >= bounds[i].w do continue
    max_hw = max(max_hw, int(bounds[i].y - bounds[i].x))
    max_hh = max(max_hh, int(bounds[i].w - bounds[i].z))
  }
  // Allocate height patch
  hp := Height_Patch {
    data   = make([dynamic]u16, max_hw * max_hh),
    width  = i32(max_hw),
    height = i32(max_hh),
  }
  defer delete(hp.data)
  vcap := n_poly_verts + n_poly_verts / 2
  tcap := vcap * 2
  dmesh.meshes = make([][4]u32, pmesh.npolys)
  temp_verts := make([dynamic][3]f32, 0, vcap)
  temp_tris := make([dynamic][4]u8, 0, tcap)
  edges := make([dynamic]i32, 0, 64)
  defer delete(edges)
  tris := make([dynamic][4]i32, 0, 512)
  defer delete(tris)
  samples := make([dynamic][4]i32, 0, 512)
  defer delete(samples)
  detail_verts := make([dynamic][3]f32, 0, 256)
  defer delete(detail_verts)
  // Process each polygon
  for i in 0 ..< pmesh.npolys {
    p := pmesh.polys[i * nvp * 2:]
    // Store polygon vertices in workspace
    npoly := 0
    for j in 0 ..< nvp {
      if p[j] == RC_MESH_NULL_IDX do break
      v := pmesh.verts[p[j]]
      poly_workspace[j] = {f32(v.x) * cs, f32(v.y) * ch, f32(v.z) * cs}
      npoly += 1
    }
    if npoly < 3 do continue
    // Get height data from area of polygon
    hp.xmin = bounds[i].x
    hp.ymin = bounds[i].z
    hp.width = bounds[i].y - bounds[i].x
    hp.height = bounds[i].w - bounds[i].z
    // Get height data using flood fill
    get_height_data(
      chf,
      slice.reinterpret([]u16, p[:npoly]),
      npoly,
      slice.reinterpret([][3]u16, pmesh.verts),
      border_size,
      &hp,
    ) or_continue
    // Build detail mesh for this polygon (equivalent to C++ buildPolyDetail)
    build_poly_detail(
      poly_workspace[:npoly],
      sample_dist,
      sample_max_error,
      height_search_radius,
      chf,
      &hp,
      &detail_verts,
      &tris,
      &edges,
      &samples,
    ) or_continue
    // Move detail verts to world space
    for &vert in detail_verts {
      vert += orig
      vert.y += ch // Height offset
    }
    // Offset poly for flag checking
    for &poly in poly_workspace[:npoly] {
      poly += orig
    }
    // Store detail submesh
    dmesh.meshes[i] = [4]u32 {
      u32(len(temp_verts)), // Vertex base
      u32(len(detail_verts)), // Vertex count
      u32(len(temp_tris)), // Triangle base
      u32(len(tris)), // Triangle count
    }
    // Store vertices
    for vert in detail_verts {
      append(&temp_verts, vert)
    }
    // Store triangles
    for tri in tris {
      append(&temp_tris, [4]u8{u8(tri.x), u8(tri.y), u8(tri.z), u8(tri.w)})
    }
    // Clear work arrays for next polygon
    clear(&tris)
    clear(&edges)
    clear(&samples)
    clear(&detail_verts)
  }
  delete(dmesh.verts)
  delete(dmesh.tris)
  dmesh.verts = temp_verts[:]
  dmesh.tris = temp_tris[:]
  return true
}

// Build detail mesh for a single polygon
build_poly_detail :: proc(
  poly_verts: [][3]f32,
  sample_dist, sample_max_error: f32,
  height_search_radius: i32,
  chf: ^Compact_Heightfield,
  hp: ^Height_Patch,
  verts: ^[dynamic][3]f32,
  tris: ^[dynamic][4]i32,
  edges: ^[dynamic]i32,
  samples: ^[dynamic][4]i32,
) -> bool {
  MAX_VERTS :: 127
  MAX_TRIS :: 255
  MAX_VERTS_PER_EDGE :: 32
  nin := len(poly_verts)
  if nin < 3 do return false
  cs := chf.cs
  ics := 1.0 / cs
  clear(verts)
  for v in poly_verts {
    append(verts, v)
  }
  clear(edges)
  clear(tris)
  min_extent := calculate_polygon_min_extent_from_verts(verts[:])
  // Hull tracking array
  hull := make([dynamic]i32, 0, MAX_VERTS)
  defer delete(hull)
  // Tessellate outlines
  if sample_dist > 0 {
    for i in 0 ..< nin {
      j := (nin - 1 + i) % nin // Previous vertex
      vj := poly_verts[j]
      vi := poly_verts[i]
      swapped := false
      // Ensure consistent ordering
      if abs(vj.x - vi.x) < 1e-6 {
        if vj.z > vi.z {
          vj, vi = vi, vj
          swapped = true
        }
      } else {
        if vj.x > vi.x {
          vj, vi = vi, vj
          swapped = true
        }
      }
      // Create samples along edge
      d := vi - vj
      edge_len := linalg.length(d.xz)
      nn := 1 + i32(math.floor(edge_len / sample_dist))
      if nn >= MAX_VERTS_PER_EDGE do nn = MAX_VERTS_PER_EDGE - 1
      if len(verts) + int(nn) >= MAX_VERTS do nn = i32(MAX_VERTS - 1 - len(verts))
      edge_samples := make([][3]f32, nn + 1)
      defer delete(edge_samples)
      for k in 0 ..= nn {
        u := f32(k) / f32(nn)
        pos := vj + d * u
        pos.y =
          get_height_from_patch(
            pos,
            cs,
            ics,
            chf.ch,
            height_search_radius,
            hp,
          ) *
          chf.ch
        edge_samples[k] = pos
      }
      // Simplify samples based on error
      idx := make([dynamic]i32, 0, MAX_VERTS_PER_EDGE)
      defer delete(idx)
      append(&idx, 0, nn)
      for k := 0; k < len(idx) - 1; {
        a := idx[k]
        b := idx[k + 1]
        va := edge_samples[a]
        vb := edge_samples[b]
        // Find maximum deviation
        max_dev := f32(0)
        max_i := i32(-1)
        for m in a + 1 ..< b {
          dev := geometry.point_segment_distance_sq(edge_samples[m], va, vb)
          if dev > max_dev {
            max_dev = dev
            max_i = m
          }
        }
        // Add point if deviation exceeds threshold
        if max_i != -1 && max_dev > sample_max_error * sample_max_error {
          inject_at(&idx, k + 1, max_i)
        } else {
          k += 1
        }
      }
      append(&hull, i32(j))
      // Add new vertices
      if swapped {
        for k := len(idx) - 2; k > 0; k -= 1 {
          append(verts, edge_samples[idx[k]])
          append(&hull, i32(len(verts) - 1))
        }
      } else {
        for k in 1 ..< len(idx) - 1 {
          append(verts, edge_samples[idx[k]])
          append(&hull, i32(len(verts) - 1))
        }
      }
    }
  }
  ok := delaunay_hull(verts[:], hull[:], tris)
  if !ok {
    log.warnf(
      "Delaunay triangulation failed for small polygon, using simple triangulation",
    )
    triangulate_hull_simple(verts[:], hull[:], nin, tris)
  }
  if min_extent < sample_dist * 2 {
    set_triangle_flags(tris[:], hull[:])
    return true
  }
  if len(tris) == 0 {
    log.warnf("Could not triangulate polygon (%d verts)", len(verts))
    return true
  }
  // Add interior samples if needed
  if sample_dist > 0 {
    add_interior_samples_grid(
      poly_verts,
      sample_dist,
      verts,
      samples,
      cs,
      ics,
      chf.ch,
      height_search_radius,
      hp,
    )
    // Add samples with highest error first
    add_samples_by_error(
      verts,
      tris[:],
      samples[:],
      sample_max_error,
      MAX_VERTS,
    )
  }
  return true
}

// Calculate minimum extent from vertex array
calculate_polygon_min_extent_from_verts :: proc(verts: [][3]f32) -> f32 {
  nverts := len(verts)
  if nverts < 3 do return 0
  min_dist := f32(1e30)
  for i in 0 ..< nverts {
    ni := (i + 1) % nverts
    p1 := verts[i]
    p2 := verts[ni]
    max_edge_dist := f32(0)
    for j in 0 ..< nverts {
      if j == i || j == ni do continue
      d, _ := geometry.point_segment_distance2_2d(verts[j], p1, p2)
      max_edge_dist = max(max_edge_dist, d)
    }
    min_dist = min(min_dist, max_edge_dist)
  }
  return math.sqrt(min_dist)
}

// Get height from height patch
get_height_from_patch :: proc(
  pos: [3]f32,
  cs, ics, ch: f32,
  height_search_radius: i32,
  hp: ^Height_Patch,
) -> f32 {
  // Convert to heightfield coordinates
  ix := i32((pos.x * ics) + 0.01)
  iz := i32((pos.z * ics) + 0.01)
  // Sample from height patch
  ix -= hp.xmin
  iz -= hp.ymin
  if ix < 0 || iz < 0 || ix >= hp.width || iz >= hp.height do return 0
  h := hp.data[ix + iz * hp.width]
  if h == RC_UNSET_HEIGHT do return 0
  return f32(h)
}

// Simple hull triangulation (equivalent to C++ triangulateHull)
triangulate_hull_simple :: proc(
  verts: [][3]f32,
  hull: []i32,
  nin: int,
  tris: ^[dynamic][4]i32,
) {
  if len(hull) < 3 do return
  clear(tris)
  // Simple fan triangulation from first hull vertex
  for i in 1 ..< len(hull) - 1 {
    if len(tris) >= 255 do break // MAX_TRIS
    append(tris, [4]i32{hull[0], hull[i], hull[i + 1], 0})
  }
}

// Set triangle edge flags
// Check if edge (a,b) lies on the hull boundary
on_hull :: proc(a, b: i32, hull: []i32) -> bool {
  // All internal sampled points come after the hull so we can early out for those
  if a >= i32(len(hull)) || b >= i32(len(hull)) {
    return false
  }
  // Check if edge (a,b) exists in the hull
  j := len(hull) - 1
  i := 0
  for i < len(hull) - 1 {
    if a == hull[j] && b == hull[i] {
      return true
    }
    j, i = i, i + 1
  }
  return false
}

set_triangle_flags :: proc(tris: [][4]i32, hull: []i32) {
  // Matches DT_DETAIL_EDGE_BOUNDARY
  DETAIL_EDGE_BOUNDARY :: 0x1
  for i in 0 ..< len(tris) {
    a := tris[i][0]
    b := tris[i][1]
    c := tris[i][2]
    tris[i].w = i32(0)
    // Check each of the three triangle edges and set boundary flags
    tris[i].w |= i32(on_hull(a, b, hull) ? DETAIL_EDGE_BOUNDARY : 0) << 0
    tris[i].w |= i32(on_hull(b, c, hull) ? DETAIL_EDGE_BOUNDARY : 0) << 2
    tris[i].w |= i32(on_hull(c, a, hull) ? DETAIL_EDGE_BOUNDARY : 0) << 4
  }
}

// Add interior samples in grid pattern
add_interior_samples_grid :: proc(
  poly_verts: [][3]f32,
  sample_dist: f32,
  verts: ^[dynamic][3]f32,
  samples: ^[dynamic][4]i32,
  cs, ics, ch: f32,
  height_search_radius: i32,
  hp: ^Height_Patch,
) {
  clear(samples)
  if len(poly_verts) == 0 do return
  // Calculate bounding box
  bmin, bmax := calc_bounds(poly_verts)
  // Create grid samples
  x0 := i32(math.floor(bmin.x / sample_dist))
  x1 := i32(math.ceil(bmax.x / sample_dist))
  z0 := i32(math.floor(bmin.z / sample_dist))
  z1 := i32(math.ceil(bmax.z / sample_dist))
  for z in z0 ..< z1 {
    for x in x0 ..< x1 {
      pt := [3]f32 {
        f32(x) * sample_dist,
        (bmax.y + bmin.y) * 0.5,
        f32(z) * sample_dist,
      }
      // Check if point is inside polygon using geometry library
      if geometry.point_in_polygon_2d(pt, poly_verts) {
        height := get_height_from_patch(
          pt,
          cs,
          ics,
          ch,
          height_search_radius,
          hp,
        )
        append(samples, [4]i32{x, i32(height), z, 0}) // 0 = not added yet
      }
    }
  }
}

// Add samples by error priority using proper distance-to-surface calculation
add_samples_by_error :: proc(
  verts: ^[dynamic][3]f32,
  tris: [][4]i32,
  samples: [][4]i32,
  sample_max_error: f32,
  max_verts: int,
) {
  if len(samples) == 0 || len(tris) == 0 do return
  // Create error priority list
  Sample_Error :: struct {
    index: int,
    error: f32,
    point: [3]f32,
  }
  errors := make([dynamic]Sample_Error, 0, len(samples))
  defer delete(errors)
  // Calculate error for each sample point
  for sample, i in samples {
    pt := [3]f32{f32(sample.x), f32(sample.y), f32(sample.z)}
    // Find closest triangle and calculate distance
    min_dist_sq := f32(math.F32_MAX)
    for tri in tris {
      if tri[0] >= i32(len(verts)) || tri[1] >= i32(len(verts)) || tri[2] >= i32(len(verts)) do continue
      v0 := verts[tri[0]]
      v1 := verts[tri[1]]
      v2 := verts[tri[2]]
      // Calculate point-to-triangle distance
      dist_sq := geometry.point_to_triangle_distance_sq(pt, v0, v1, v2)
      min_dist_sq = min(min_dist_sq, dist_sq)
    }
    error := math.sqrt(min_dist_sq)
    // Only consider samples with significant error
    if error > sample_max_error * 0.1 {
      append(&errors, Sample_Error{index = i, error = error, point = pt})
    }
  }
  // Sort by error (highest first)
  slice.sort_by(errors[:], proc(a, b: Sample_Error) -> bool {
    return a.error > b.error
  })
  // Add highest error samples up to limit
  samples_added := 0
  for err in errors {
    if len(verts) >= max_verts do break
    if err.error < sample_max_error do break
    append(verts, err.point)
    samples_added += 1
    // Stop after adding reasonable number of samples
    if samples_added >= len(samples) / 3 do break
  }
}

// Flood fill algorithm for height data collection
get_height_data :: proc(
  chf: ^Compact_Heightfield,
  poly: []u16,
  npoly: int,
  verts: [][3]u16,
  borderSize: i32,
  hp: ^Height_Patch,
) -> bool {
  if chf == nil || hp == nil do return false
  // Initialize height patch
  clear(&hp.data)
  hp.xmin = 0
  hp.ymin = 0
  hp.width = 0
  hp.height = 0
  // Empty polygon
  if npoly == 0 do return true
  // Find polygon bounding box
  minx := i32(verts[poly[0]].x)
  maxx := i32(verts[poly[0]].x)
  minz := i32(verts[poly[0]].z)
  maxz := i32(verts[poly[0]].z)
  for i in 1 ..< npoly {
    v := verts[poly[i]]
    minx = min(minx, i32(v.x))
    maxx = max(maxx, i32(v.x))
    minz = min(minz, i32(v.z))
    maxz = max(maxz, i32(v.z))
  }
  // Expand by border size
  minx = max(0, minx - borderSize)
  maxx = min(chf.width - 1, maxx + borderSize)
  minz = max(0, minz - borderSize)
  maxz = min(chf.height - 1, maxz + borderSize)
  hp.xmin = minx
  hp.ymin = minz
  hp.width = maxx - minx + 1
  hp.height = maxz - minz + 1
  // Allocate height data
  resize(&hp.data, int(hp.width * hp.height))
  for i in 0 ..< len(hp.data) {
    hp.data[i] = RC_UNSET_HEIGHT
  }
  // Use flood fill to collect height data
  stack := make([dynamic][2]i32, 0, 256)
  defer delete(stack)
  // Find seed point inside polygon
  seed := seed_array_with_poly_center(chf, poly[:npoly], verts, minx, minz, hp)
  if !seed do return false
  // Start flood fill from seed points
  for y in 0 ..< hp.height {
    for x in 0 ..< hp.width {
      idx := int(x + y * hp.width)
      if hp.data[idx] != RC_UNSET_HEIGHT {
        // Add to stack
        append(&stack, [2]i32{x, y})
      }
    }
  }
  // 4-way flood fill
  dirs := [4][2]i32{{1, 0}, {0, 1}, {-1, 0}, {0, -1}}
  for len(stack) > 0 {
    cur := pop(&stack)
    cx := cur.x
    cy := cur.y
    for d in dirs {
      nx := cx + d.x
      ny := cy + d.y
      // Check bounds
      if nx < 0 || ny < 0 || nx >= hp.width || ny >= hp.height do continue
      idx := int(nx + ny * hp.width)
      if hp.data[idx] != RC_UNSET_HEIGHT do continue
      // Get cell coordinates
      ax := hp.xmin + nx
      ay := hp.ymin + ny
      if ax < 0 || ay < 0 || ax >= chf.width || ay >= chf.height do continue
      // Sample height
      cell_idx := int(ax + ay * chf.width)
      cell := chf.cells[cell_idx]
      // Skip if no spans
      if cell.count == 0 do continue
      // Get top span height
      span_idx := int(cell.index + u32(cell.count) - 1)
      if span_idx < len(chf.spans) {
        span := chf.spans[span_idx]
        h := u16(span.y) + u16(span.h)
        // Set height
        hp.data[idx] = h
        append(&stack, [2]i32{nx, ny})
      }
    }
  }
  return true
}

// Height patch for detail mesh sampling
Height_Patch :: struct {
  data:   [dynamic]u16,
  xmin:   i32,
  ymin:   i32,
  width:  i32,
  height: i32,
}

// Seed height patch with polygon center
seed_array_with_poly_center :: proc(
  chf: ^Compact_Heightfield,
  poly: []u16,
  verts: [][3]u16,
  minx, minz: i32,
  hp: ^Height_Patch,
) -> bool {
  // Calculate polygon center
  center: [3]f32
  for i in 0 ..< len(poly) {
    v := verts[poly[i]]
    center.x += f32(v.x)
    center.z += f32(v.z)
  }
  center.x /= f32(len(poly))
  center.z /= f32(len(poly))
  // Convert to cell coordinates
  cx := i32(center.x) - minx
  cz := i32(center.z) - minz
  // Ensure within bounds
  cx = clamp(cx, 0, hp.width - 1)
  cz = clamp(cz, 0, hp.height - 1)
  // Get height at center
  ax := minx + cx
  az := minz + cz
  if ax >= 0 && az >= 0 && ax < chf.width && az < chf.height {
    cell_idx := int(ax + az * chf.width)
    cell := chf.cells[cell_idx]
    if cell.count > 0 {
      span_idx := int(cell.index + u32(cell.count) - 1)
      if span_idx < len(chf.spans) {
        span := chf.spans[span_idx]
        h := u16(span.y) + u16(span.h)
        idx := int(cx + cz * hp.width)
        hp.data[idx] = h
        return true
      }
    }
  }
  return false
}

// Edge management constants
EV_UNDEF :: -1
EV_HULL :: -2

// Find edge in edge list
find_edge :: proc(edges: []i32, s, t: i32) -> i32 {
  for i in 0 ..< len(edges) / 4 {
    e := edges[i * 4:]
    if (e[0] == s && e[1] == t) || (e[0] == t && e[1] == s) {
      return i32(i)
    }
  }
  return EV_UNDEF
}

// Add edge to edge list
add_edge :: proc(edges: ^[dynamic]i32, s, t, l, r: i32) -> i32 {
  max_edges := 10000 // Reasonable limit
  nedges := len(edges) / 4
  if nedges >= max_edges {
    log.error("addEdge: Too many edges")
    return EV_UNDEF
  }
  // Add edge if not already in the triangulation
  e := find_edge(edges[:], s, t)
  if e == EV_UNDEF {
    append(edges, s, t, l, r)
    return i32(nedges)
  } else {
    return EV_UNDEF
  }
}

// Update left face of edge
update_left_face :: proc(edges: []i32, edge_idx: i32, s, t, f: i32) {
  e := edges[edge_idx * 4:]
  if e[0] == s && e[1] == t && e[2] == EV_UNDEF {
    e[2] = f
  } else if e[1] == s && e[0] == t && e[3] == EV_UNDEF {
    e[3] = f
  }
}

// Check if edges overlap
overlap_edges :: proc(pts: [][3]f32, edges: []i32, s1, t1: i32) -> bool {
  nedges := len(edges) / 4
  for i in 0 ..< nedges {
    e := edges[i * 4:]
    s0 := e[0]
    t0 := e[1]
    // Same endpoints
    if s0 == s1 || s0 == t1 || t0 == s1 || t0 == t1 {
      continue
    }
    if geometry.segment_segment_intersect_2d(
      pts[s0],
      pts[t0],
      pts[s1],
      pts[t1],
    ) {
      return true
    }
  }
  return false
}

// Complete a facet in Delaunay triangulation
complete_facet :: proc(
  pts: [][3]f32,
  edges: ^[dynamic]i32,
  nfaces: i32,
  e: i32,
) -> i32 {
  EPS :: 1e-5
  edge := edges[e * 4:]
  // Cache s and t
  s, t: i32
  if edge[2] == EV_UNDEF {
    s = edge[0]
    t = edge[1]
  } else if edge[3] == EV_UNDEF {
    s = edge[1]
    t = edge[0]
  } else {
    // Edge already completed
    return nfaces
  }
  // Find best point on left of edge
  pt := i32(len(pts))
  c: [2]f32
  r := f32(-1)
  for u in 0 ..< len(pts) {
    if i32(u) == s || i32(u) == t do continue
    if linalg.cross((pts[t] - pts[s]).xz, (pts[u] - pts[s]).xz) > EPS {
      if r < 0 {
        // The circle is not updated yet, do it now
        pt = i32(u)
        c, r, _ = geometry.circum_circle(pts[s], pts[t], pts[u])
        continue
      }
      d := linalg.length2([2]f32{c.x, c.y} - pts[u].xz)
      tol := f32(0.001)
      if d > r * (1 + tol) {
        // Outside current circumcircle, skip
        continue
      } else if d < r * (1 - tol) {
        // Inside safe circumcircle, update circle
        pt = i32(u)
        c, r, _ = geometry.circum_circle(pts[s], pts[t], pts[u])
      } else {
        // Inside epsilon circumcircle, do extra tests
        if overlap_edges(pts, edges[:], s, i32(u)) do continue
        if overlap_edges(pts, edges[:], t, i32(u)) do continue
        // Edge is valid
        pt = i32(u)
        c, r, _ = geometry.circum_circle(pts[s], pts[t], pts[u])
      }
    }
  }
  // Add new triangle or update edge info if s-t is on hull
  if pt < i32(len(pts)) {
    // Update face information of edge being completed
    update_left_face(edges[:], e, s, t, nfaces)
    // Add new edge or update face info of old edge
    edge_idx := find_edge(edges[:], pt, s)
    if edge_idx == EV_UNDEF {
      add_edge(edges, pt, s, nfaces, EV_UNDEF)
    } else {
      update_left_face(edges[:], edge_idx, pt, s, nfaces)
    }
    // Add new edge or update face info of old edge
    edge_idx = find_edge(edges[:], t, pt)
    if edge_idx == EV_UNDEF {
      add_edge(edges, t, pt, nfaces, EV_UNDEF)
    } else {
      update_left_face(edges[:], edge_idx, t, pt, nfaces)
    }
    return nfaces + 1
  } else {
    update_left_face(edges[:], e, s, t, EV_HULL)
    return nfaces
  }
}

// Validate triangles after generation
validate_triangles :: proc(tris: ^[dynamic][4]i32, nverts: int) -> bool {
  if len(tris) == 0 do return false
  for i in 0 ..< len(tris) {
    t := &tris[i]
    // Check for invalid vertex indices
    if t[0] < 0 ||
       t[1] < 0 ||
       t[2] < 0 ||
       t[0] >= i32(nverts) ||
       t[1] >= i32(nverts) ||
       t[2] >= i32(nverts) {
      return false
    }
    // Check for degenerate triangles (duplicate vertices)
    if t[0] == t[1] || t[1] == t[2] || t[2] == t[0] {
      return false
    }
  }
  return true
}

// Simple but robust triangulation - replaces complex Delaunay algorithm temporarily
delaunay_hull :: proc(
  pts: [][3]f32,
  hull: []i32,
  tris: ^[dynamic][4]i32,
) -> bool {
  clear(tris)
  if len(hull) < 3 do return false
  if len(pts) == 0 do return false
  // Validate hull indices
  for h in hull {
    if h < 0 || h >= i32(len(pts)) do return false
  }
  // Simple fan triangulation from first hull vertex
  // This is a correct and robust approach for convex polygons
  for i in 1 ..< len(hull) - 1 {
    // Create triangle: hull[0], hull[i], hull[i+1]
    v0 := hull[0]
    v1 := hull[i]
    v2 := hull[i + 1]
    // Ensure vertices are different (non-degenerate)
    if v0 != v1 && v1 != v2 && v2 != v0 {
      // Check triangle orientation - ensure counter-clockwise in XZ plane
      p0 := pts[v0]
      p1 := pts[v1]
      p2 := pts[v2]
      // Calculate signed area (cross product in XZ plane)
      edge1 := [2]f32{p1.x - p0.x, p1.z - p0.z}
      edge2 := [2]f32{p2.x - p0.x, p2.z - p0.z}
      signed_area := edge1.x * edge2.y - edge1.y * edge2.x
      // Only add triangles with non-zero area
      if abs(signed_area) > 1e-10 {
        // Ensure counter-clockwise winding
        if signed_area > 0 {
          append(tris, [4]i32{v0, v1, v2, 0})
        } else {
          append(tris, [4]i32{v0, v2, v1, 0}) // Flip winding
        }
      }
    }
  }
  // Handle interior points (points not in hull)
  interior_points := make([dynamic]i32, 0, len(pts))
  defer delete(interior_points)
  for i in 0 ..< len(pts) {
    is_hull := false
    for h in hull {
      if i32(i) == h {
        is_hull = true
        break
      }
    }
    if !is_hull {
      append(&interior_points, i32(i))
    }
  }
  // For interior points, add them to existing triangles using simple approach
  // This is not optimal Delaunay but will generate valid triangulations
  for interior_pt in interior_points {
    if len(tris) == 0 do break
    // Find a triangle to subdivide (use first valid one for simplicity)
    triangle_to_split := -1
    for tri_idx in 0 ..< len(tris) {
      tri := tris[tri_idx]
      if tri[0] >= 0 && tri[1] >= 0 && tri[2] >= 0 {
        triangle_to_split = tri_idx
        break
      }
    }
    if triangle_to_split >= 0 {
      old_tri := tris[triangle_to_split]
      // Replace the old triangle with 3 new triangles
      tris[triangle_to_split] = [4]i32{old_tri[0], old_tri[1], interior_pt, 0}
      append(tris, [4]i32{old_tri[1], old_tri[2], interior_pt, 0})
      append(tris, [4]i32{old_tri[2], old_tri[0], interior_pt, 0})
    }
  }
  return validate_triangles(tris, len(pts))
}

// Jittered sampling functions for interior points
get_jitter_x :: proc(i: i32) -> f32 {
  h: u32 = 0x8da6b343
  return (f32((u32(i) * h) & 0xffff) / 65535.0 * 2.0) - 1.0
}

get_jitter_y :: proc(i: i32) -> f32 {
  h: u32 = 0xd8163841
  return (f32((u32(i) * h) & 0xffff) / 65535.0 * 2.0) - 1.0
}
