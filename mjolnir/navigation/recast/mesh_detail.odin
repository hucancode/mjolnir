package recast

import "../../geometry"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"

// Poly_Mesh_Detail is the height-accurate triangle sub-mesh of each Poly_Mesh polygon.
Poly_Mesh_Detail :: struct {
  meshes: [][4]u32,
  verts:  [][3]f32,
  tris:   [][4]u8,
}

// create_poly_mesh_detail samples the compact heightfield to build detail triangles for pmesh.
create_poly_mesh_detail :: proc(
  pmesh: ^Poly_Mesh,
  chf: ^Compact_Heightfield,
  sample_dist, sample_max_error: f32,
) -> ^Poly_Mesh_Detail {
  dmesh := new(Poly_Mesh_Detail)
  if !build_poly_mesh_detail(
    pmesh,
    chf,
    sample_dist,
    sample_max_error,
    dmesh,
  ) {
    destroy_poly_mesh_detail(dmesh)
    return nil
  }
  return dmesh
}

// destroy_poly_mesh_detail frees the detail mesh.
destroy_poly_mesh_detail :: proc(dmesh: ^Poly_Mesh_Detail) {
  if dmesh == nil do return
  delete(dmesh.meshes)
  delete(dmesh.verts)
  delete(dmesh.tris)
  free(dmesh)
}

@(private = "file")
RC_UNSET_HEIGHT :: 0xffff

@(private = "file")
MAX_EDGE_SUBDIVISIONS :: 10

@(private = "file")
MIN_EDGE_LENGTH :: 0.1

@(private = "file")
DEFAULT_POLYGON_TIMEOUT_MS :: 5000
@(private = "file")
GLOBAL_TIMEOUT_MS :: 30000
@(private = "file")
MAX_INTERIOR_SAMPLES :: 10000
@(private = "file")
MIN_POLYGON_AREA :: 1e-6

@(private = "file")
MIN_TRIANGLE_QUALITY :: 0.5

@(private = "file")
Detail_Vertex :: struct {
  pos:    [3]f32,
  height: f32,
  flag:   u32,
}

@(private = "file")
Detail_Edge :: struct {
  v0:          i32,
  v1:          i32,
  constrained: bool,
  length:      f32,
}

@(private = "file")
Detail_Triangle :: struct {
  v:    [3]i32,
  area: f32,
}

@(private = "file")
Detail_Polygon :: struct {
  vertices:    [dynamic]Detail_Vertex,
  edges:       [dynamic]Detail_Edge,
  triangles:   [dynamic]Detail_Triangle,
  sample_dist: f32,
  max_error:   f32,
}

@(private = "file")
Height_Sample :: struct {
  pos:    [3]f32,
  height: f32,
  weight: f32,
}

@(private = "file")
sample_heightfield_height :: proc(
  chf: ^Compact_Heightfield,
  pos: [3]f32,
) -> f32 {
  if chf == nil do return 0.0
  f := (pos.xz - chf.bmin.xz) / chf.cs
  cell_idx := [2]i32{i32(math.floor(f.x)), i32(math.floor(f.y))}
  x := cell_idx.x
  z := cell_idx.y
  if x < 0 || z < 0 || x >= chf.width - 1 || z >= chf.height - 1 {
    return 0.0
  }
  f_frac := f - [2]f32{f32(x), f32(z)}
  fx_frac := f_frac.x
  fz_frac := f_frac.y
  heights: [4]f32
  heights[0] = get_cell_height(chf, x, z)
  heights[1] = get_cell_height(chf, x + 1, z)
  heights[2] = get_cell_height(chf, x, z + 1)
  heights[3] = get_cell_height(chf, x + 1, z + 1)
  h0 := linalg.mix(heights[0], heights[1], fx_frac)
  h1 := linalg.mix(heights[2], heights[3], fx_frac)
  height := linalg.mix(h0, h1, fz_frac)
  return chf.bmin.y + height * chf.ch
}

@(private = "file")
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
  if index + u32(count) > u32(len(chf.spans)) do return 0.0
  top_span := chf.spans[index + u32(count) - 1]
  return f32(top_span.y) + f32(top_span.h)
}

@(private = "file")
add_detail_vertex :: proc(
  poly: ^Detail_Polygon,
  pos: [3]f32,
  height: f32,
  flag: u32 = 0,
) -> i32 {
  for &v, i in poly.vertices {
    diff := v.pos - pos
    dist_sq := linalg.dot(diff, diff)
    if dist_sq < 1e-6 {
      return i32(i)
    }
  }
  vertex := Detail_Vertex {
    pos    = pos,
    height = height,
    flag   = flag,
  }
  append(&poly.vertices, vertex)
  return i32(len(poly.vertices) - 1)
}

@(private = "file")
add_constrained_edge :: proc(poly: ^Detail_Polygon, v0, v1: i32) {
  if v0 >= i32(len(poly.vertices)) || v1 >= i32(len(poly.vertices)) do return
  if v0 == v1 do return
  for edge in poly.edges {
    if (edge.v0 == v0 && edge.v1 == v1) || (edge.v0 == v1 && edge.v1 == v0) {
      return
    }
  }
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

@(private = "file")
free_detail_polygon :: proc(poly: ^Detail_Polygon) {
  delete(poly.vertices)
  delete(poly.edges)
  delete(poly.triangles)
}

@(private = "file")
copy_poly_mesh_detail :: proc(
  src: ^Poly_Mesh_Detail,
  dst: ^Poly_Mesh_Detail,
) -> bool {
  if src == nil || dst == nil do return false
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

@(private = "file")
merge_poly_mesh_details :: proc(
  meshes: []^Poly_Mesh_Detail,
  mesh: ^Poly_Mesh_Detail,
) -> bool {
  if len(meshes) == 0 do return false
  if len(meshes) == 1 {
    return copy_poly_mesh_detail(meshes[0], mesh)
  }
  total_meshes := 0
  total_verts := 0
  total_tris := 0
  for src in meshes do if src != nil {
    total_meshes += len(src.meshes)
    total_verts += len(src.verts)
    total_tris += len(src.tris)
  }
  if total_meshes == 0 do return false
  mesh.meshes = make([][4]u32, total_meshes)
  mesh.verts = make([][3]f32, total_verts)
  mesh.tris = make([][4]u8, total_tris)
  mesh_offset := 0
  vert_offset := 0
  tri_offset := 0
  for src in meshes do if src != nil {
    for j in 0 ..< len(src.meshes) {
      mesh.meshes[mesh_offset][0] = src.meshes[j][0] + u32(vert_offset)
      mesh.meshes[mesh_offset][1] = src.meshes[j][1]
      mesh.meshes[mesh_offset][2] = src.meshes[j][2] + u32(tri_offset)
      mesh.meshes[mesh_offset][3] = src.meshes[j][3]
      mesh_offset += 1
    }
    for j in 0 ..< len(src.verts) {
      mesh.verts[vert_offset] = src.verts[j]
      vert_offset += 1
    }
    for j in 0 ..< len(src.tris) {
      for k in 0 ..< 3 {
        mesh.tris[tri_offset][k] = src.tris[j][k] + u8(vert_offset - len(src.verts))
      }
      mesh.tris[tri_offset][3] = src.tris[j][3]
      tri_offset += 1
    }
  }
  return true
}

@(private)
build_poly_mesh_detail :: proc(
  pmesh: ^Poly_Mesh,
  chf: ^Compact_Heightfield,
  sample_dist, sample_max_error: f32,
  dmesh: ^Poly_Mesh_Detail,
) -> bool {
  if pmesh == nil || chf == nil || dmesh == nil do return false
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
  bounds := make([][4]i32, pmesh.npolys)
  defer delete(bounds)
  poly_workspace := make([][3]f32, nvp)
  defer delete(poly_workspace)
  n_poly_verts := 0
  max_hw, max_hh := 0, 0
  for i in 0 ..< pmesh.npolys {
    p := pmesh.polys[i * nvp * 2:]
    bounds[i] = {chf.width, 0, chf.height, 0}
    for j in 0 ..< nvp {
      if p[j] == RC_MESH_NULL_IDX do break
      v := pmesh.verts[p[j]]
      bounds[i].x = min(bounds[i].x, i32(v.x))
      bounds[i].y = max(bounds[i].y, i32(v.x))
      bounds[i].z = min(bounds[i].z, i32(v.z))
      bounds[i].w = max(bounds[i].w, i32(v.z))
      n_poly_verts += 1
    }
    bounds[i].x = max(0, bounds[i].x - 1)
    bounds[i].y = min(chf.width, bounds[i].y + 1)
    bounds[i].z = max(0, bounds[i].z - 1)
    bounds[i].w = min(chf.height, bounds[i].w + 1)
    if bounds[i].x >= bounds[i].y || bounds[i].z >= bounds[i].w do continue
    max_hw = max(max_hw, int(bounds[i].y - bounds[i].x))
    max_hh = max(max_hh, int(bounds[i].w - bounds[i].z))
  }
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
  for i in 0 ..< pmesh.npolys {
    p := pmesh.polys[i * nvp * 2:]
    npoly := 0
    for j in 0 ..< nvp {
      if p[j] == RC_MESH_NULL_IDX do break
      v := pmesh.verts[p[j]]
      poly_workspace[j] = {f32(v.x) * cs, f32(v.y) * ch, f32(v.z) * cs}
      npoly += 1
    }
    if npoly < 3 do continue
    hp.xmin = bounds[i].x
    hp.ymin = bounds[i].z
    hp.width = bounds[i].y - bounds[i].x
    hp.height = bounds[i].w - bounds[i].z
    get_height_data(
      chf,
      slice.reinterpret([]u16, p[:npoly]),
      npoly,
      slice.reinterpret([][3]u16, pmesh.verts),
      border_size,
      &hp,
    ) or_continue
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
    for &vert in detail_verts {
      vert += orig
      vert.y += ch
    }
    for &poly in poly_workspace[:npoly] {
      poly += orig
    }
    dmesh.meshes[i] = [4]u32 {
      u32(len(temp_verts)),
      u32(len(detail_verts)),
      u32(len(temp_tris)),
      u32(len(tris)),
    }
    for vert in detail_verts {
      append(&temp_verts, vert)
    }
    for tri in tris {
      append(&temp_tris, [4]u8{u8(tri.x), u8(tri.y), u8(tri.z), u8(tri.w)})
    }
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

@(private = "file")
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
  min_extent := geometry.calculate_polygon_min_extent_2d(verts[:])
  hull := make([dynamic]i32, 0, MAX_VERTS)
  defer delete(hull)
  if sample_dist > 0 {
    for i in 0 ..< nin {
      j := (nin - 1 + i) % nin
      vj := poly_verts[j]
      vi := poly_verts[i]
      swapped := false
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
      idx := make([dynamic]i32, 0, MAX_VERTS_PER_EDGE)
      defer delete(idx)
      append(&idx, 0, nn)
      for k := 0; k < len(idx) - 1; {
        a := idx[k]
        b := idx[k + 1]
        va := edge_samples[a]
        vb := edge_samples[b]
        max_dev := f32(0)
        max_i := i32(-1)
        for m in a + 1 ..< b {
          dev := geometry.point_segment_distance_sq(edge_samples[m], va, vb)
          if dev > max_dev {
            max_dev = dev
            max_i = m
          }
        }
        if max_i != -1 && max_dev > sample_max_error * sample_max_error {
          inject_at(&idx, k + 1, max_i)
        } else {
          k += 1
        }
      }
      append(&hull, i32(j))
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

@(private = "file")
get_height_from_patch :: proc(
  pos: [3]f32,
  cs, ics, ch: f32,
  height_search_radius: i32,
  hp: ^Height_Patch,
) -> f32 {
  ix := i32((pos.x * ics) + 0.01)
  iz := i32((pos.z * ics) + 0.01)
  ix -= hp.xmin
  iz -= hp.ymin
  if ix < 0 || iz < 0 || ix >= hp.width || iz >= hp.height do return 0
  h := hp.data[ix + iz * hp.width]
  if h == RC_UNSET_HEIGHT do return 0
  return f32(h)
}

@(private = "file")
triangulate_hull_simple :: proc(
  verts: [][3]f32,
  hull: []i32,
  nin: int,
  tris: ^[dynamic][4]i32,
) {
  if len(hull) < 3 do return
  clear(tris)
  for i in 1 ..< len(hull) - 1 {
    if len(tris) >= 255 do break
    append(tris, [4]i32{hull[0], hull[i], hull[i + 1], 0})
  }
}

@(private = "file")
on_hull :: proc(a, b: i32, hull: []i32) -> bool {
  if a >= i32(len(hull)) || b >= i32(len(hull)) {
    return false
  }
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

@(private = "file")
set_triangle_flags :: proc(tris: [][4]i32, hull: []i32) {
  // Matches DT_DETAIL_EDGE_BOUNDARY
  DETAIL_EDGE_BOUNDARY :: 0x1
  for i in 0 ..< len(tris) {
    a := tris[i][0]
    b := tris[i][1]
    c := tris[i][2]
    tris[i].w = i32(0)
    tris[i].w |= i32(on_hull(a, b, hull) ? DETAIL_EDGE_BOUNDARY : 0) << 0
    tris[i].w |= i32(on_hull(b, c, hull) ? DETAIL_EDGE_BOUNDARY : 0) << 2
    tris[i].w |= i32(on_hull(c, a, hull) ? DETAIL_EDGE_BOUNDARY : 0) << 4
  }
}

@(private = "file")
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
  bmin, bmax := calc_bounds(poly_verts)
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
      if geometry.point_in_polygon_2d(pt, poly_verts) {
        height := get_height_from_patch(
          pt,
          cs,
          ics,
          ch,
          height_search_radius,
          hp,
        )
        append(samples, [4]i32{x, i32(height), z, 0})
      }
    }
  }
}

@(private = "file")
add_samples_by_error :: proc(
  verts: ^[dynamic][3]f32,
  tris: [][4]i32,
  samples: [][4]i32,
  sample_max_error: f32,
  max_verts: int,
) {
  if len(samples) == 0 || len(tris) == 0 do return
  Sample_Error :: struct {
    index: int,
    error: f32,
    point: [3]f32,
  }
  errors := make([dynamic]Sample_Error, 0, len(samples))
  defer delete(errors)
  for sample, i in samples {
    pt := [3]f32{f32(sample.x), f32(sample.y), f32(sample.z)}
    min_dist_sq := f32(math.F32_MAX)
    for tri in tris {
      if tri[0] >= i32(len(verts)) || tri[1] >= i32(len(verts)) || tri[2] >= i32(len(verts)) do continue
      v0 := verts[tri[0]]
      v1 := verts[tri[1]]
      v2 := verts[tri[2]]
      dist_sq := geometry.point_to_triangle_distance_sq(pt, v0, v1, v2)
      min_dist_sq = min(min_dist_sq, dist_sq)
    }
    error := math.sqrt(min_dist_sq)
    if error > sample_max_error * 0.1 {
      append(&errors, Sample_Error{index = i, error = error, point = pt})
    }
  }
  slice.sort_by(errors[:], proc(a, b: Sample_Error) -> bool {
    return a.error > b.error
  })
  samples_added := 0
  for err in errors {
    if len(verts) >= max_verts do break
    if err.error < sample_max_error do break
    append(verts, err.point)
    samples_added += 1
    if samples_added >= len(samples) / 3 do break
  }
}

@(private = "file")
get_height_data :: proc(
  chf: ^Compact_Heightfield,
  poly: []u16,
  npoly: int,
  verts: [][3]u16,
  borderSize: i32,
  hp: ^Height_Patch,
) -> bool {
  if chf == nil || hp == nil do return false
  clear(&hp.data)
  hp.xmin = 0
  hp.ymin = 0
  hp.width = 0
  hp.height = 0
  if npoly == 0 do return true
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
  minx = max(0, minx - borderSize)
  maxx = min(chf.width - 1, maxx + borderSize)
  minz = max(0, minz - borderSize)
  maxz = min(chf.height - 1, maxz + borderSize)
  hp.xmin = minx
  hp.ymin = minz
  hp.width = maxx - minx + 1
  hp.height = maxz - minz + 1
  resize(&hp.data, int(hp.width * hp.height))
  for i in 0 ..< len(hp.data) {
    hp.data[i] = RC_UNSET_HEIGHT
  }
  stack := make([dynamic][2]i32, 0, 256)
  defer delete(stack)
  seed := seed_array_with_poly_center(chf, poly[:npoly], verts, minx, minz, hp)
  if !seed do return false
  for y in 0 ..< hp.height {
    for x in 0 ..< hp.width {
      idx := int(x + y * hp.width)
      if hp.data[idx] != RC_UNSET_HEIGHT {
        append(&stack, [2]i32{x, y})
      }
    }
  }
  dirs := [4][2]i32{{1, 0}, {0, 1}, {-1, 0}, {0, -1}}
  for len(stack) > 0 {
    cur := pop(&stack)
    cx := cur.x
    cy := cur.y
    for d in dirs {
      nx := cx + d.x
      ny := cy + d.y
      if nx < 0 || ny < 0 || nx >= hp.width || ny >= hp.height do continue
      idx := int(nx + ny * hp.width)
      if hp.data[idx] != RC_UNSET_HEIGHT do continue
      ax := hp.xmin + nx
      ay := hp.ymin + ny
      if ax < 0 || ay < 0 || ax >= chf.width || ay >= chf.height do continue
      cell_idx := int(ax + ay * chf.width)
      cell := chf.cells[cell_idx]
      if cell.count == 0 do continue
      span_idx := int(cell.index + u32(cell.count) - 1)
      if span_idx < len(chf.spans) {
        span := chf.spans[span_idx]
        h := u16(span.y) + u16(span.h)
        hp.data[idx] = h
        append(&stack, [2]i32{nx, ny})
      }
    }
  }
  return true
}

@(private = "file")
Height_Patch :: struct {
  data:   [dynamic]u16,
  xmin:   i32,
  ymin:   i32,
  width:  i32,
  height: i32,
}

@(private = "file")
seed_array_with_poly_center :: proc(
  chf: ^Compact_Heightfield,
  poly: []u16,
  verts: [][3]u16,
  minx, minz: i32,
  hp: ^Height_Patch,
) -> bool {
  center: [3]f32
  for i in 0 ..< len(poly) {
    v := verts[poly[i]]
    center.x += f32(v.x)
    center.z += f32(v.z)
  }
  center.x /= f32(len(poly))
  center.z /= f32(len(poly))
  cx := i32(center.x) - minx
  cz := i32(center.z) - minz
  cx = clamp(cx, 0, hp.width - 1)
  cz = clamp(cz, 0, hp.height - 1)
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

@(private = "file")
EV_UNDEF :: -1
@(private = "file")
EV_HULL :: -2

@(private = "file")
find_edge :: proc(edges: []i32, s, t: i32) -> i32 {
  for i in 0 ..< len(edges) / 4 {
    e := edges[i * 4:]
    if (e[0] == s && e[1] == t) || (e[0] == t && e[1] == s) {
      return i32(i)
    }
  }
  return EV_UNDEF
}

@(private = "file")
add_edge :: proc(edges: ^[dynamic]i32, s, t, l, r: i32) -> i32 {
  max_edges := 10000
  nedges := len(edges) / 4
  if nedges >= max_edges {
    log.error("addEdge: Too many edges")
    return EV_UNDEF
  }
  e := find_edge(edges[:], s, t)
  if e == EV_UNDEF {
    append(edges, s, t, l, r)
    return i32(nedges)
  } else {
    return EV_UNDEF
  }
}

@(private = "file")
validate_triangles :: proc(tris: ^[dynamic][4]i32, nverts: int) -> bool {
  if len(tris) == 0 do return false
  for i in 0 ..< len(tris) {
    t := &tris[i]
    if t[0] < 0 ||
       t[1] < 0 ||
       t[2] < 0 ||
       t[0] >= i32(nverts) ||
       t[1] >= i32(nverts) ||
       t[2] >= i32(nverts) {
      return false
    }
    if t[0] == t[1] || t[1] == t[2] || t[2] == t[0] {
      return false
    }
  }
  return true
}

@(private)
delaunay_hull :: proc(
  pts: [][3]f32,
  hull: []i32,
  tris: ^[dynamic][4]i32,
) -> bool {
  clear(tris)
  if len(hull) < 3 do return false
  if len(pts) == 0 do return false
  for h in hull {
    if h < 0 || h >= i32(len(pts)) do return false
  }
  for i in 1 ..< len(hull) - 1 {
    v0 := hull[0]
    v1 := hull[i]
    v2 := hull[i + 1]
    if v0 != v1 && v1 != v2 && v2 != v0 {
      p0 := pts[v0]
      p1 := pts[v1]
      p2 := pts[v2]
      edge1 := [2]f32{p1.x - p0.x, p1.z - p0.z}
      edge2 := [2]f32{p2.x - p0.x, p2.z - p0.z}
      signed_area := edge1.x * edge2.y - edge1.y * edge2.x
      if abs(signed_area) > 1e-10 {
        if signed_area > 0 {
          append(tris, [4]i32{v0, v1, v2, 0})
        } else {
          append(tris, [4]i32{v0, v2, v1, 0})
        }
      }
    }
  }
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
  for interior_pt in interior_points {
    if len(tris) == 0 do break
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
      tris[triangle_to_split] = [4]i32{old_tri[0], old_tri[1], interior_pt, 0}
      append(tris, [4]i32{old_tri[1], old_tri[2], interior_pt, 0})
      append(tris, [4]i32{old_tri[2], old_tri[0], interior_pt, 0})
    }
  }
  return validate_triangles(tris, len(pts))
}
