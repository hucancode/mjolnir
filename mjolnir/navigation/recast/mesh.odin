package recast

import "core:log"
import "core:math/linalg"
import "core:slice"

// Poly_Mesh is the polygon mesh built from contours, in quantized cell coordinates.
Poly_Mesh :: struct {
  verts:          [][3]u16,
  polys:          []u16,
  regs:           []u16,
  flags:          []u16,
  areas:          []u8,
  npolys:         i32,
  maxpolys:       i32,
  nvp:            i32,
  bmin:           [3]f32,
  bmax:           [3]f32,
  cs:             f32,
  ch:             f32,
  border_size:    i32,
  max_edge_error: f32,
}

// create_poly_mesh builds a polygon mesh of at most nvp vertices per polygon from contours, or nil on failure.
create_poly_mesh :: proc(cset: ^Contour_Set, nvp: i32) -> ^Poly_Mesh {
  pmesh := new(Poly_Mesh)
  if !build_poly_mesh(cset, nvp, pmesh) {
    destroy_poly_mesh(pmesh)
    return nil
  }
  return pmesh
}

// destroy_poly_mesh frees the polygon mesh.
destroy_poly_mesh :: proc(pmesh: ^Poly_Mesh) {
  if pmesh == nil do return
  delete(pmesh.verts)
  delete(pmesh.polys)
  delete(pmesh.regs)
  delete(pmesh.flags)
  delete(pmesh.areas)
  free(pmesh)
}

@(private = "file")
uleft :: proc(a, b, c: [3]i16) -> bool {
  // the code above will cause integer overflow, we must use i32 to avoid it
  return(
    (i32(b.x) - i32(a.x)) * (i32(c.z) - i32(a.z)) -
      (i32(c.x) - i32(a.x)) * (i32(b.z) - i32(a.z)) <
    0 \
  )
}

@(private = "file")
get_poly_merge_value :: proc(
  pa, pb: []i32,
  verts: []Mesh_Vertex,
  nvp: i32,
) -> (
  ea, eb, value: i32,
) {
  na := i32(len(pa))
  nb := i32(len(pb))
  if na + nb - 2 > nvp {
    return -1, -1, -1
  }
  ea = -1
  eb = -1
  for i in 0 ..< na {
    va0 := pa[i]
    va1 := pa[(i + 1) % na]
    if va0 > va1 do va0, va1 = va1, va0
    for j in 0 ..< nb {
      vb0 := pb[j]
      vb1 := pb[(j + 1) % nb]
      if vb0 > vb1 do vb0, vb1 = vb1, vb0
      if va0 == vb0 && va1 == vb1 {
        ea = i
        eb = j
        break
      }
    }
    if ea != -1 do break
  }
  if ea == -1 || eb == -1 {
    return -1, -1, -1
  }
  va := pa[(ea + na - 1) % na]
  vb := pa[ea]
  vc := pb[(eb + 2) % nb]
  if va < 0 ||
     vb < 0 ||
     vc < 0 ||
     va >= i32(len(verts)) ||
     vb >= i32(len(verts)) ||
     vc >= i32(len(verts)) {
    return -1, -1, -1
  }
  av1 := [3]i16{i16(verts[va].x), i16(verts[va].y), i16(verts[va].z)}
  bv1 := [3]i16{i16(verts[vb].x), i16(verts[vb].y), i16(verts[vb].z)}
  cv1 := [3]i16{i16(verts[vc].x), i16(verts[vc].y), i16(verts[vc].z)}
  if !uleft(av1, bv1, cv1) {
    return -1, -1, -1
  }
  va = pb[(eb + nb - 1) % nb]
  vb = pb[eb]
  vc = pa[(ea + 2) % na]
  if va < 0 ||
     vb < 0 ||
     vc < 0 ||
     va >= i32(len(verts)) ||
     vb >= i32(len(verts)) ||
     vc >= i32(len(verts)) {
    return -1, -1, -1
  }
  av2 := [3]i16{i16(verts[va].x), i16(verts[va].y), i16(verts[va].z)}
  bv2 := [3]i16{i16(verts[vb].x), i16(verts[vb].y), i16(verts[vb].z)}
  cv2 := [3]i16{i16(verts[vc].x), i16(verts[vc].y), i16(verts[vc].z)}
  if !uleft(av2, bv2, cv2) {
    return -1, -1, -1
  }
  va = pa[ea]
  vb = pa[(ea + 1) % na]
  dx := i32(verts[va].x) - i32(verts[vb].x)
  dz := i32(verts[va].z) - i32(verts[vb].z)
  return ea, eb, dx * dx + dz * dz
}

@(private = "file")
merge_poly_verts :: proc(
  pa, pb: ^Poly_Build,
  ea, eb: i32,
  nvp: i32,
  allocator := context.allocator,
) {
  na := i32(len(pa.verts))
  nb := i32(len(pb.verts))
  tmp := make([]i32, nvp, allocator)
  for i in 0 ..< nvp do tmp[i] = -1
  n := 0
  for i in 0 ..< na - 1 {
    tmp[n] = pa.verts[(ea + 1 + i) % na]
    n += 1
  }
  for i in 0 ..< nb - 1 {
    tmp[n] = pb.verts[(eb + 1 + i) % nb]
    n += 1
  }
  old_verts := pa.verts
  pa.verts = make([]i32, n, allocator)
  copy(pa.verts[:], tmp[:n])
  delete(old_verts, allocator)
  delete(tmp, allocator)
}

@(private)
RC_VERTEX_BUCKET_COUNT :: 1 << 12

@(private)
Mesh_Vertex :: struct {
  x, y, z: u16,
  next:    i32,
}

@(private)
Vertex_Bucket :: struct {
  first: i32,
}

@(private = "file")
Mesh_Edge :: struct {
  vert:      [2]u16,
  poly:      [2]u16,
  poly_edge: [2]u16,
}

@(private = "file")
Poly_Build :: struct {
  verts: []i32,
  area:  u8,
  reg:   u16,
}

@(private)
vertex_hash :: proc "contextless" (x, y, z: u16) -> u32 {
  h1 := u32(x) * 0x8da6b343
  h2 := u32(y) * 0xd8163841
  h3 := u32(z) * 0xcb1ab31f
  return (h1 + h2 + h3) & (RC_VERTEX_BUCKET_COUNT - 1)
}

@(private)
add_vertex :: proc(
  x, y, z: u16,
  verts: ^[dynamic]Mesh_Vertex,
  buckets: []Vertex_Bucket,
) -> i32 {
  bucket := vertex_hash(x, 0, z)
  i := buckets[bucket].first
  max_search := i32(len(verts) + 100)
  search_count := i32(0)
  for i != -1 && search_count < max_search {
    if i < 0 || i >= i32(len(verts)) {
      log.errorf("Invalid vertex index %d in bucket chain", i)
      break
    }
    v := &verts[i]
    // exact x,z match and y within tolerance of 2
    if v.x == x && v.z == z && abs(i32(v.y) - i32(y)) <= 2 {
      return i
    }
    i = v.next
    search_count += 1
  }
  if search_count >= max_search {
    log.errorf(
      "Vertex search exceeded maximum iterations, possible cycle in bucket chain",
    )
  }
  i = i32(len(verts))
  append(verts, Mesh_Vertex{x = x, y = y, z = z, next = buckets[bucket].first})
  buckets[bucket].first = i
  return i
}

@(private = "file")
diagonalie :: proc "contextless" (
  verts: [][4]i32,
  indices: []u32,
  a, c: int,
) -> bool {
  a_idx := indices[a] & 0x0fffffff
  c_idx := indices[c] & 0x0fffffff
  for i in 0 ..< len(indices) {
    i1 := (i + 1) % len(indices)
    if i == a || i1 == a || i == c || i1 == c {
      continue
    }
    b1_idx := indices[i] & 0x0fffffff
    b2_idx := indices[i1] & 0x0fffffff
    va := verts[a_idx]
    vc := verts[c_idx]
    vb1 := verts[b1_idx]
    vb2 := verts[b2_idx]
    if va.xz == vb1.xz ||
       vc.xz == vb1.xz ||
       va.xz == vb2.xz ||
       vc.xz == vb2.xz {
      continue
    }
    if intersect(va.xz, vc.xz, vb1.xz, vb2.xz) {
      return false
    }
  }
  return true
}

@(private = "file")
in_cone_indexed :: proc "contextless" (
  verts: [][4]i32,
  indices: []u32,
  a, b: int,
) -> bool {
  n := len(indices)
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

@(private = "file")
diagonal :: proc "contextless" (
  verts: [][4]i32,
  indices: []u32,
  a, b: int,
) -> bool {
  cone_check := in_cone_indexed(verts, indices, a, b)
  diag_check := diagonalie(verts, indices, a, b)
  return cone_check && diag_check
}

@(private = "file")
diagonalie_loose :: proc "contextless" (
  verts: [][4]i32,
  indices: []u32,
  a, c: int,
) -> bool {
  a_idx := indices[a] & 0x0fffffff
  c_idx := indices[c] & 0x0fffffff
  for i in 0 ..< len(indices) {
    i1 := (i + 1) % len(indices)
    if i == a || i1 == a || i == c || i1 == c {
      continue
    }
    b1_idx := indices[i] & 0x0fffffff
    b2_idx := indices[i1] & 0x0fffffff
    va := verts[a_idx]
    vc := verts[c_idx]
    vb1 := verts[b1_idx]
    vb2 := verts[b2_idx]
    if va.xz == vb1.xz ||
       vc.xz == vb1.xz ||
       va.xz == vb2.xz ||
       vc.xz == vb2.xz {
      continue
    }
    if intersect_prop(va.xz, vc.xz, vb1.xz, vb2.xz) {
      return false
    }
  }
  return true
}

@(private = "file")
in_cone_loose :: proc "contextless" (
  verts: [][4]i32,
  indices: []u32,
  a, b: int,
) -> bool {
  n := len(indices)
  a0_idx := indices[(a + n - 1) % n] & 0x0fffffff
  a1_idx := indices[a] & 0x0fffffff
  a2_idx := indices[(a + 1) % n] & 0x0fffffff
  b_idx := indices[b] & 0x0fffffff
  va0 := verts[a0_idx]
  va1 := verts[a1_idx]
  va2 := verts[a2_idx]
  vb := verts[b_idx]
  if left_on(va0.xz, va1.xz, va2.xz) {
    return(
      left_on(va1.xz, vb.xz, va0.xz) &&
      left_on(vb.xz, va1.xz, va2.xz) \
    )
  } else {
    return(
      !(left_on(va1.xz, vb.xz, va2.xz) &&
        left_on(vb.xz, va1.xz, va0.xz)) \
    )
  }
}

@(private = "file")
diagonal_loose :: proc "contextless" (
  verts: [][4]i32,
  indices: []u32,
  a, b: int,
) -> bool {
  return(
    in_cone_loose(verts, indices, a, b) &&
    diagonalie_loose(verts, indices, a, b) \
  )
}

@(private)
triangulate_polygon :: proc(
  verts: [][4]i32,
  indices: []i32,
  triangles: ^[dynamic]i32,
) -> bool {
  if len(verts) < 3 || len(indices) < 3 do return false
  if len(indices) == 3 {
    append(triangles, indices[0], indices[1], indices[2])
    return true
  }
  MIDDLE_VERTEX_MASK :: 1 << 31
  work_indices := make([]u32, len(indices))
  defer delete(work_indices)
  for i in 0 ..< len(indices) {
    work_indices[i] = u32(indices[i])
  }
  n := len(indices)
  for i in 0 ..< n {
    i1 := (i + 1) % n
    i2 := (i1 + 1) % n
    diag_result := diagonal(verts, work_indices, i, i2)
    if diag_result {
      work_indices[i1] |= MIDDLE_VERTEX_MASK
    }
  }
  ear_count := 0
  for i in 0 ..< n {
    if work_indices[i] & MIDDLE_VERTEX_MASK != 0 {
      ear_count += 1
    }
  }
  log.debugf("Initial ear count: %d out of %d vertices", ear_count, n)
  for n > 3 {
    min_len := -1
    mini := -1
    for i in 0 ..< n {
      i1 := (i + 1) % n
      if work_indices[i1] & MIDDLE_VERTEX_MASK != 0 {
        i2 := (i1 + 1) % n
        p0_idx := i32(work_indices[i] & 0x0fffffff)
        p2_idx := i32(work_indices[i2] & 0x0fffffff)
        p0 := verts[p0_idx]
        p2 := verts[p2_idx]
        length := linalg.length2(p2.xz - p0.xz)
        if min_len < 0 || int(length) < min_len {
          min_len = int(length)
          mini = i
        }
      }
    }
    if mini == -1 {
      // We might get here because the contour has overlapping segments
      min_len = -1
      for i in 0 ..< n {
        i1 := (i + 1) % n
        i2 := (i1 + 1) % n
        if diagonal_loose(verts, work_indices, i, i2) {
          p0_idx := work_indices[i] & 0x0fffffff
          p2_idx := work_indices[(i2 + 1) % n] & 0x0fffffff
          p0 := verts[p0_idx]
          p2 := verts[p2_idx]
          length := linalg.length2(p2.xz - p0.xz)
          if min_len < 0 || int(length) < min_len {
            min_len = int(length)
            mini = i
          }
        }
      }
      if mini == -1 {
        // contour simplification was too aggressive; negative count signals failure
        return false
      }
    }
    i := mini
    i1 := (i + 1) % n
    i2 := (i1 + 1) % n
    append(
      triangles,
      i32(work_indices[i] & 0x0fffffff),
      i32(work_indices[i1] & 0x0fffffff),
      i32(work_indices[i2] & 0x0fffffff),
    )
    n -= 1
    for k in i1 ..< n {
      work_indices[k] = work_indices[k + 1]
    }
    if i1 >= n do i1 = 0
    i = i1 - 1 >= 0 ? i1 - 1 : n - 1
    prev_i := i - 1 >= 0 ? i - 1 : n - 1
    next_i1 := (i1 + 1) % n
    if diagonal(verts, work_indices, prev_i, i1) {
      work_indices[i] |= MIDDLE_VERTEX_MASK
    } else {
      work_indices[i] &= 0x0fffffff
    }
    if diagonal(verts, work_indices, i, next_i1) {
      work_indices[i1] |= MIDDLE_VERTEX_MASK
    } else {
      work_indices[i1] &= 0x0fffffff
    }
  }
  append(
    triangles,
    i32(work_indices[0] & 0x0fffffff),
    i32(work_indices[1] & 0x0fffffff),
    i32(work_indices[2] & 0x0fffffff),
  )
  return true
}

@(private)
validate_poly_mesh :: proc(pmesh: ^Poly_Mesh) -> bool {
  if pmesh == nil do return false
  if len(pmesh.verts) <= 0 || pmesh.npolys <= 0 do return false
  if pmesh.nvp < 3 do return false
  for i in 0 ..< pmesh.npolys {
    pi := int(i) * int(pmesh.nvp) * 2
    if pi + int(pmesh.nvp) * 2 > len(pmesh.polys) do return false
    for j in 0 ..< pmesh.nvp {
      vert_idx := pmesh.polys[pi + int(j)]
      if vert_idx != RC_MESH_NULL_IDX && int(vert_idx) >= len(pmesh.verts) {
        return false
      }
    }
  }
  return true
}

@(private = "file")
copy_poly_mesh :: proc(src: ^Poly_Mesh, dst: ^Poly_Mesh) -> bool {
  if src == nil || dst == nil do return false
  dst.npolys = src.npolys
  dst.maxpolys = src.maxpolys
  dst.nvp = src.nvp
  dst.bmin = src.bmin
  dst.bmax = src.bmax
  dst.cs = src.cs
  dst.ch = src.ch
  dst.border_size = src.border_size
  dst.max_edge_error = src.max_edge_error
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

@(private = "file")
merge_poly_meshes :: proc(meshes: []^Poly_Mesh, mesh: ^Poly_Mesh) -> bool {
  if len(meshes) == 0 do return false
  if len(meshes) == 1 {
    return copy_poly_mesh(meshes[0], mesh)
  }
  max_verts := 0
  max_polys := 0
  max_nvp := 0
  for i in 0 ..< len(meshes) {
    if meshes[i] == nil do continue
    max_verts += len(meshes[i].verts)
    max_polys += int(meshes[i].npolys)
    max_nvp = max(max_nvp, int(meshes[i].nvp))
  }
  if max_verts == 0 || max_polys == 0 do return false
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
  mesh.verts = make([][3]u16, max_verts)
  mesh.polys = make([]u16, max_polys * max_nvp * 2)
  mesh.regs = make([]u16, max_polys)
  mesh.flags = make([]u16, max_polys)
  mesh.areas = make([]u8, max_polys)
  slice.fill(mesh.polys, RC_MESH_NULL_IDX)
  next_vert := 0
  next_poly := 0
  for i in 0 ..< len(meshes) {
    src := meshes[i]
    if src == nil do continue
    vert_offset := next_vert
    for j in 0 ..< len(src.verts) {
      mesh.verts[next_vert] = src.verts[j]
      next_vert += 1
    }
    for j in 0 ..< src.npolys {
      pi_src := int(j) * int(src.nvp) * 2
      pi_dst := next_poly * int(mesh.nvp) * 2
      for k in 0 ..< src.nvp {
        if src.polys[pi_src + int(k)] == RC_MESH_NULL_IDX {
          mesh.polys[pi_dst + int(k)] = RC_MESH_NULL_IDX
        } else {
          mesh.polys[pi_dst + int(k)] =
            src.polys[pi_src + int(k)] + u16(vert_offset)
        }
      }
      for k in 0 ..< src.nvp {
        mesh.polys[pi_dst + int(mesh.nvp) + int(k)] = RC_MESH_NULL_IDX
      }
      mesh.regs[next_poly] = src.regs[j]
      mesh.flags[next_poly] = src.flags[j]
      mesh.areas[next_poly] = src.areas[j]
      next_poly += 1
    }
  }
  mesh.npolys = i32(next_poly)
  return true
}

@(private = "file")
build_mesh_edges :: proc(
  pmesh: ^Poly_Mesh,
  edges: ^[dynamic]Mesh_Edge,
  max_edges: i32,
) -> bool {
  clear(edges)
  for i in 0 ..< pmesh.npolys {
    pi := int(i) * int(pmesh.nvp) * 2
    nverts := 0
    for j in 0 ..< pmesh.nvp {
      if pmesh.polys[pi + int(j)] != RC_MESH_NULL_IDX {
        nverts += 1
      } else {
        break
      }
    }
    if nverts < 3 do continue
    for j in 0 ..< nverts {
      k := (j + 1) % nverts
      va := pmesh.polys[pi + j]
      vb := pmesh.polys[pi + k]
      if va == vb do continue
      if va > vb {
        va, vb = vb, va
      }
      found := false
      for idx in 0 ..< len(edges) {
        if edges[idx].vert[0] == va && edges[idx].vert[1] == vb {
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
        append(
          edges,
          Mesh_Edge {
            vert = {va, vb},
            poly = {u16(i), RC_MESH_NULL_IDX},
            poly_edge = {u16(j), RC_MESH_NULL_IDX},
          },
        )
      }
    }
  }
  return true
}

@(private = "file")
update_polygon_neighbors :: proc(pmesh: ^Poly_Mesh, edges: []Mesh_Edge) {
  for i in 0 ..< pmesh.npolys {
    pi := int(i) * int(pmesh.nvp) * 2
    for j in 0 ..< pmesh.nvp {
      pmesh.polys[pi + int(pmesh.nvp) + int(j)] = RC_MESH_NULL_IDX
    }
  }
  for edge in edges {
    if edge.poly[1] == RC_MESH_NULL_IDX do continue
    pi0 := int(edge.poly[0]) * int(pmesh.nvp) * 2
    edge_idx0 := int(edge.poly_edge[0])
    pmesh.polys[pi0 + int(pmesh.nvp) + edge_idx0] = edge.poly[1]
    pi1 := int(edge.poly[1]) * int(pmesh.nvp) * 2
    edge_idx1 := int(edge.poly_edge[1])
    pmesh.polys[pi1 + int(pmesh.nvp) + edge_idx1] = edge.poly[0]
  }
}

@(private = "file")
merge_triangles_into_polygons :: proc(
  triangles: []i32,
  polys: ^[dynamic]Poly_Build,
  max_verts: i32,
  area: u8,
  reg: u16,
) {
  if len(triangles) % 3 != 0 {
    log.warn("Invalid triangle array length for merging")
    return
  }
  if len(triangles) == 0 do return
  temp_polys := make([dynamic]Poly_Build, 0, len(triangles) / 3)
  defer {
    for poly in temp_polys do delete(poly.verts)
    delete(temp_polys)
  }
  for i := 0; i < len(triangles); i += 3 {
    poly := Poly_Build {
      verts = make([]i32, 3),
      area  = area,
      reg   = reg,
    }
    poly.verts[0] = triangles[i]
    poly.verts[1] = triangles[i + 1]
    poly.verts[2] = triangles[i + 2]
    append(&temp_polys, poly)
  }
  Triangle_Edge :: struct {
    v0, v1:   i32,
    tri_idx:  int,
    edge_idx: int,
  }
  edges := make([dynamic]Triangle_Edge, 0, len(temp_polys) * 3)
  defer delete(edges)
  for tri, tri_idx in temp_polys {
    for edge_idx in 0 ..< 3 {
      v0 := tri.verts[edge_idx]
      v1 := tri.verts[(edge_idx + 1) % 3]
      if v0 > v1 do v0, v1 = v1, v0
      append(&edges, Triangle_Edge{v0, v1, tri_idx, edge_idx})
    }
  }
  slice.sort_by(edges[:], proc(a, b: Triangle_Edge) -> bool {
    if a.v0 != b.v0 do return a.v0 < b.v0
    return a.v1 < b.v1
  })
  merged := make([]bool, len(temp_polys))
  defer delete(merged)
  if max_verts >= 4 {
    for i in 0 ..< len(edges) - 1 {
      edge1 := edges[i]
      edge2 := edges[i + 1]
      if edge1.v0 == edge2.v0 && edge1.v1 == edge2.v1 {
        tri1_idx := edge1.tri_idx
        tri2_idx := edge2.tri_idx
        if merged[tri1_idx] || merged[tri2_idx] do continue
        tri1 := &temp_polys[tri1_idx]
        tri2 := &temp_polys[tri2_idx]
        merged_verts := merge_triangles_to_quad(
          tri1.verts[:],
          tri2.verts[:],
        ) or_continue
        delete(tri1.verts)
        tri1.verts = merged_verts
        merged[tri2_idx] = true
      }
    }
  }
  for poly, idx in temp_polys {
    if !merged[idx] {
      final_poly := Poly_Build {
        verts = make([]i32, len(poly.verts)),
        area  = area,
        reg   = reg,
      }
      copy(final_poly.verts, poly.verts)
      append(polys, final_poly)
    }
  }
}

@(private = "file")
merge_triangles_to_quad :: proc(tri1, tri2: []i32) -> (quad: []i32, ok: bool) {
  shared := make([dynamic]i32, 0, 2)
  defer delete(shared)
  for v1 in tri1 {
    if slice.contains(tri2, v1) {
      append(&shared, v1)
    }
  }
  if len(shared) != 2 {
    return
  }
  unique1: i32 = -1
  unique2: i32 = -1
  for v in tri1 {
    if !slice.contains(shared[:], v) {
      unique1 = v
      break
    }
  }
  for v in tri2 {
    if !slice.contains(shared[:], v) {
      unique2 = v
      break
    }
  }
  if unique1 == -1 || unique2 == -1 {
    return
  }
  shared_idx1, shared_idx2 := i32(-1), i32(-1)
  for i in 0 ..< len(tri1) {
    if tri1[i] == shared[0] do shared_idx1 = i32(i)
    if tri1[i] == shared[1] do shared_idx2 = i32(i)
  }
  quad = make([]i32, 4)
  if (shared_idx1 + 1) % 3 == shared_idx2 {
    quad[0] = unique1
    quad[1] = shared[0]
    quad[2] = shared[1]
    quad[3] = unique2
  } else {
    quad[0] = unique1
    quad[1] = shared[1]
    quad[2] = shared[0]
    quad[3] = unique2
  }
  ok = true
  return
}

@(private = "file")
build_poly_mesh :: proc(
  cset: ^Contour_Set,
  nvp: i32,
  pmesh: ^Poly_Mesh,
) -> bool {
  if cset == nil || pmesh == nil do return false
  if len(cset.conts) == 0 do return false
  if nvp < 3 do return false
  pmesh.npolys = 0
  pmesh.maxpolys = 0
  pmesh.nvp = nvp
  pmesh.bmin = cset.bmin
  pmesh.bmax = cset.bmax
  pmesh.cs = cset.cs
  pmesh.ch = cset.ch
  pmesh.border_size = cset.border_size
  pmesh.max_edge_error = cset.max_error
  max_vertices := 0
  max_polygons := 0
  max_edges := 0
  for i in 0 ..< len(cset.conts) {
    cont := &cset.conts[i]
    if len(cont.verts) < 3 do continue
    max_vertices += len(cont.verts)
    max_polygons += len(cont.verts) - 2
    max_edges += len(cont.verts) * 3
  }
  if max_vertices == 0 do return false
  verts := make([dynamic]Mesh_Vertex, 0, max_vertices)
  defer delete(verts)
  buckets := make([]Vertex_Bucket, RC_VERTEX_BUCKET_COUNT)
  defer delete(buckets)
  for &bucket in buckets {
    bucket.first = -1
  }
  vflags := make([]bool, max_vertices)
  defer delete(vflags)
  polys := make([dynamic]Poly_Build, 0, max_polygons)
  defer delete(polys)
  edges := make([dynamic]Mesh_Edge, 0, max_edges)
  defer delete(edges)
  triangles := make([dynamic]i32, 0, max_polygons * 3)
  defer delete(triangles)
  indices := make([]i32, nvp)
  defer delete(indices)
  for i in 0 ..< len(cset.conts) {
    cont := &cset.conts[i]
    if len(cont.verts) < 3 {
      continue
    }
    indices := make([]i32, len(cont.verts))
    defer delete(indices)
    for j in 0 ..< len(cont.verts) {
      indices[j] = i32(j)
    }
    clear(&triangles)
    if !triangulate_polygon(cont.verts[:], indices, &triangles) {
      log.warnf("Bad triangulation Contour %d. Verts: %d", i, len(cont.verts))
      for j in 0 ..< min(5, len(cont.verts)) {
        v := cont.verts[j]
        log.debugf("  Vert %d: [%d, %d, %d, %d]", j, v.x, v.y, v.z, v.w)
      }
      continue
    }
    verts_before := len(verts)
    for j in 0 ..< len(cont.verts) {
      v := cont.verts[j]
      vert_idx := add_vertex(u16(v.x), u16(v.y), u16(v.z), &verts, buckets)
      indices[j] = vert_idx
      if v.w & RC_BORDER_VERTEX != 0 {
        if int(vert_idx) < len(vflags) {
          vflags[vert_idx] = true
        }
      }
    }
    verts_after := len(verts)
    region_polys: [dynamic]Poly_Build
    defer {
      for &poly in region_polys {
        delete(poly.verts)
      }
      delete(region_polys)
    }
    for tri_idx in 0 ..< len(triangles) / 3 {
      base := tri_idx * 3
      poly := Poly_Build {
        verts = make([]i32, 3),
        area  = cont.area,
        reg   = cont.reg,
      }
      poly.verts[0] = indices[triangles[base + 0]]
      poly.verts[1] = indices[triangles[base + 1]]
      poly.verts[2] = indices[triangles[base + 2]]
      append(&region_polys, poly)
    }
    if nvp > 3 {
      merge_count := 0
      for {
        best_merge_value := i32(0)
        best_pa := -1
        best_pb := -1
        best_ea := i32(-1)
        best_eb := i32(-1)
        for i in 0 ..< len(region_polys) {
          pa := &region_polys[i]
          for j in i + 1 ..< len(region_polys) {
            pb := &region_polys[j]
            ea, eb, merge_value := get_poly_merge_value(
              pa.verts[:],
              pb.verts[:],
              verts[:],
              nvp,
            )
            if merge_value > best_merge_value {
              best_pa = i
              best_pb = j
              best_ea = ea
              best_eb = eb
              best_merge_value = merge_value
            }
          }
        }
        if best_pa == -1 || best_pb == -1 {
          log.debugf(
            "    No more merges possible after %d merges",
            merge_count,
          )
          break
        }
        merge_count += 1
        merge_poly_verts(
          &region_polys[best_pa],
          &region_polys[best_pb],
          best_ea,
          best_eb,
          nvp,
        )
        delete(region_polys[best_pb].verts)
        ordered_remove(&region_polys, best_pb)
      }
    }
    for poly in region_polys {
      final_poly := Poly_Build {
        verts = make([]i32, len(poly.verts)),
        area  = poly.area,
        reg   = poly.reg,
      }
      copy(final_poly.verts[:], poly.verts[:])
      append(&polys, final_poly)
    }
  }
  if len(polys) == 0 {
    return false
  }
  pmesh.npolys = i32(len(polys))
  pmesh.maxpolys = pmesh.npolys
  pmesh.verts = make([][3]u16, len(verts))
  pmesh.polys = make([]u16, pmesh.npolys * nvp * 2)
  pmesh.regs = make([]u16, pmesh.npolys)
  pmesh.flags = make([]u16, pmesh.npolys)
  pmesh.areas = make([]u8, pmesh.npolys)
  slice.fill(pmesh.polys, RC_MESH_NULL_IDX)
  for i := 0; i < len(verts); i += 1 {
    vert := verts[i]
    pmesh.verts[i] = {vert.x, vert.y, vert.z}
  }
  for i := 0; i < len(polys); i += 1 {
    poly := polys[i]
    pi := i * int(nvp) * 2
    for j in 0 ..< len(poly.verts) {
      pmesh.polys[pi + int(j)] = u16(poly.verts[j])
    }
    pmesh.regs[i] = poly.reg
    pmesh.areas[i] = poly.area
    pmesh.flags[i] = 1
    delete(poly.verts)
  }
  for i := 0; i < len(pmesh.verts); {
    should_remove := false
    if i < len(vflags) {
      should_remove = vflags[i]
    }
    if !should_remove {
      i += 1
      continue
    }
    if !can_remove_vertex(pmesh, u16(i)) {
      i += 1
      continue
    }
    log.debugf("Removing border vertex %d", i)
    if !remove_vertex(pmesh, u16(i), pmesh.maxpolys) {
      log.errorf("Failed to remove edge vertex %d", i)
      return false
    }
    // Note: pmesh.nverts is already decremented in remove_vertex
    for j in i ..< len(pmesh.verts) {
      if j + 1 < len(vflags) {
        vflags[j] = vflags[j + 1]
      }
    }
  }
  if build_mesh_edges(pmesh, &edges, i32(max_edges)) {
    update_polygon_neighbors(pmesh, edges[:])
  }
  if !validate_poly_mesh(pmesh) {
    return false
  }
  return true
}

@(private = "file")
can_remove_vertex :: proc(pmesh: ^Poly_Mesh, rem: u16) -> bool {
  if pmesh == nil do return false
  nvp := int(pmesh.nvp)
  numTouchedVerts := 0
  numRemainingEdges := 0
  for i in 0 ..< pmesh.npolys {
    pi := int(i) * nvp * 2
    nv := 0
    for j in 0 ..< nvp {
      if pmesh.polys[pi + j] == RC_MESH_NULL_IDX do break
      nv += 1
    }
    numRemoved := 0
    numVerts := 0
    for j in 0 ..< nv {
      if pmesh.polys[pi + j] == rem {
        numTouchedVerts += 1
        numRemoved += 1
      }
      numVerts += 1
    }
    if numRemoved > 0 {
      numRemainingEdges += numVerts - (numRemoved + 1)
    }
  }
  // a triangle tip marked for removal with no other sharing polys must be kept
  if numRemainingEdges <= 2 {
    return false
  }
  Edge :: struct {
    a, b:   i32,
    shares: i32,
  }
  maxEdges := numTouchedVerts * 2
  edges := make([dynamic]Edge, 0, maxEdges)
  defer delete(edges)
  for i in 0 ..< pmesh.npolys {
    pi := int(i) * nvp * 2
    nv := 0
    for j in 0 ..< nvp {
      if pmesh.polys[pi + j] == RC_MESH_NULL_IDX do break
      nv += 1
    }
    k := nv - 1
    for j in 0 ..< nv {
      if pmesh.polys[pi + j] == rem || pmesh.polys[pi + k] == rem {
        a := i32(pmesh.polys[pi + j])
        b := i32(pmesh.polys[pi + k])
        if b == i32(rem) {
          a, b = b, a
        }
        exists := false
        for &e in edges {
          if e.b == b {
            e.shares += 1
            exists = true
            break
          }
        }
        if !exists {
          append(&edges, Edge{a = a, b = b, shares = 1})
        }
      }
      k = j
    }
  }
  numOpenEdges := 0
  for e in edges {
    if e.shares < 2 {
      numOpenEdges += 1
    }
  }
  if numOpenEdges > 2 {
    return false
  }
  return true
}

@(private = "file")
remove_vertex :: proc(pmesh: ^Poly_Mesh, rem: u16, maxTris: i32) -> bool {
  if pmesh == nil do return false
  nvp := int(pmesh.nvp)
  numRemovedVerts := 0
  for i in 0 ..< pmesh.npolys {
    pi := int(i) * nvp * 2
    nv := 0
    for j in 0 ..< nvp {
      if pmesh.polys[pi + j] == RC_MESH_NULL_IDX do break
      nv += 1
    }
    for j in 0 ..< nv {
      if pmesh.polys[pi + j] == rem {
        numRemovedVerts += 1
        break
      }
    }
  }
  Edge :: struct {
    v0, v1: i32,
    reg:    u16,
    area:   u8,
  }
  edges := make([dynamic]Edge, 0, numRemovedVerts * nvp)
  defer delete(edges)
  for i := 0; i < int(pmesh.npolys); {
    pi := i * nvp * 2
    nv := 0
    for j in 0 ..< nvp {
      if pmesh.polys[pi + j] == RC_MESH_NULL_IDX do break
      nv += 1
    }
    hasRem := false
    for j in 0 ..< nv {
      if pmesh.polys[pi + j] == rem {
        hasRem = true
        break
      }
    }
    if hasRem {
      k := nv - 1
      for j in 0 ..< nv {
        if pmesh.polys[pi + j] != rem && pmesh.polys[pi + k] != rem {
          append(
            &edges,
            Edge {
              v0 = i32(pmesh.polys[pi + k]),
              v1 = i32(pmesh.polys[pi + j]),
              reg = pmesh.regs[i],
              area = pmesh.areas[i],
            },
          )
        }
        k = j
      }
      last_pi := int(pmesh.npolys - 1) * nvp * 2
      if pi != last_pi {
        for j in 0 ..< nvp * 2 {
          pmesh.polys[pi + j] = pmesh.polys[last_pi + j]
        }
      }
      for j in 0 ..< nvp {
        pmesh.polys[last_pi + nvp + j] = RC_MESH_NULL_IDX
      }
      pmesh.regs[i] = pmesh.regs[pmesh.npolys - 1]
      pmesh.areas[i] = pmesh.areas[pmesh.npolys - 1]
      pmesh.npolys -= 1
    } else {
      i += 1
    }
  }
  for i in int(rem) ..< len(pmesh.verts) - 1 {
    pmesh.verts[i] = pmesh.verts[i + 1]
  }
  new_verts := make([][3]u16, len(pmesh.verts) - 1)
  copy(new_verts, pmesh.verts[:len(pmesh.verts) - 1])
  delete(pmesh.verts)
  pmesh.verts = new_verts
  for i in 0 ..< pmesh.npolys {
    pi := int(i) * nvp * 2
    nv := 0
    for j in 0 ..< nvp {
      if pmesh.polys[pi + j] == RC_MESH_NULL_IDX do break
      nv += 1
    }
    for j in 0 ..< nv {
      if pmesh.polys[pi + j] > rem {
        pmesh.polys[pi + j] -= 1
      }
    }
  }
  for i in 0 ..< len(edges) {
    if edges[i].v0 > i32(rem) do edges[i].v0 -= 1
    if edges[i].v1 > i32(rem) do edges[i].v1 -= 1
  }
  if len(edges) == 0 do return true
  hole := make([dynamic]i32, 0, len(edges))
  defer delete(hole)
  hreg := make([dynamic]u16, 0, len(edges))
  defer delete(hreg)
  harea := make([dynamic]u8, 0, len(edges))
  defer delete(harea)
  append(&hole, edges[0].v0)
  append(&hreg, edges[0].reg)
  append(&harea, edges[0].area)
  unordered_remove(&edges, 0)
  for len(edges) > 0 {
    match := false
    for i := 0; i < len(edges); {
      ea := edges[i].v0
      eb := edges[i].v1
      r := edges[i].reg
      a := edges[i].area
      add := false
      if hole[0] == eb {
        inject_at(&hole, 0, ea)
        inject_at(&hreg, 0, r)
        inject_at(&harea, 0, a)
        add = true
      } else if hole[len(hole) - 1] == ea {
        append(&hole, eb)
        append(&hreg, r)
        append(&harea, a)
        add = true
      }
      if add {
        unordered_remove(&edges, i)
        match = true
      } else {
        i += 1
      }
    }
    if !match do break
  }
  tverts := make([][4]i32, len(hole))
  defer delete(tverts)
  tindices := make([]i32, len(hole))
  defer delete(tindices)
  for i in 0 ..< len(hole) {
    vert_idx := hole[i]
    if vert_idx < i32(len(pmesh.verts)) {
      tverts[i] = {
        i32(pmesh.verts[vert_idx][0]),
        i32(pmesh.verts[vert_idx][1]),
        i32(pmesh.verts[vert_idx][2]),
        0,
      }
      tindices[i] = i32(i)
    }
  }
  triangles := make([dynamic]i32, 0, len(hole) * 3)
  defer delete(triangles)
  if !triangulate_polygon(tverts[:], tindices[:], &triangles) {
    log.warnf("removeVertex: triangulate() failed")
    return false
  }
  Temp_Poly :: struct {
    verts: []u16,
    reg:   u16,
    area:  u8,
  }
  temp_polys := make([]Temp_Poly, len(triangles) / 3)
  defer {
    for &p in temp_polys do delete(p.verts)
    delete(temp_polys)
  }
  npolys := 0
  for j := 0; j < len(triangles); j += 3 {
    t := triangles[j:j + 3]
    if t[0] != t[1] && t[0] != t[2] && t[1] != t[2] {
      temp_polys[npolys].verts = make([]u16, 3)
      temp_polys[npolys].verts[0] = u16(hole[t[0]])
      temp_polys[npolys].verts[1] = u16(hole[t[1]])
      temp_polys[npolys].verts[2] = u16(hole[t[2]])
      if t[0] < i32(len(hreg)) {
        temp_polys[npolys].reg = hreg[t[0]]
        temp_polys[npolys].area = harea[t[0]]
      }
      npolys += 1
    }
  }
  if npolys == 0 do return true
  mesh_verts := make([dynamic]Mesh_Vertex, len(pmesh.verts))
  defer delete(mesh_verts)
  for i in 0 ..< len(pmesh.verts) {
    v := pmesh.verts[i]
    mesh_verts[i] = Mesh_Vertex {
      x    = v.x,
      y    = v.y,
      z    = v.z,
      next = -1,
    }
  }
  if nvp > 3 {
    for {
      bestMergeVal := i32(0)
      bestPa := -1
      bestPb := -1
      bestEa := i32(-1)
      bestEb := i32(-1)
      for j in 0 ..< npolys {
        pa := temp_polys[j].verts[:]
        pa_i32 := make([]i32, len(pa))
        defer delete(pa_i32)
        for k in 0 ..< len(pa) do pa_i32[k] = i32(pa[k])
        for k in j + 1 ..< npolys {
          pb := temp_polys[k].verts[:]
          pb_i32 := make([]i32, len(pb))
          defer delete(pb_i32)
          for l in 0 ..< len(pb) do pb_i32[l] = i32(pb[l])
          ea, eb, v := get_poly_merge_value(
            pa_i32[:],
            pb_i32[:],
            mesh_verts[:],
            i32(nvp),
          )
          if v > bestMergeVal {
            bestMergeVal = v
            bestPa = j
            bestPb = k
            bestEa = ea
            bestEb = eb
          }
        }
      }
      if bestMergeVal <= 0 do break
      pa := &temp_polys[bestPa]
      pb := &temp_polys[bestPb]
      na := len(pa.verts)
      nb := len(pb.verts)
      tmp := make([]u16, nvp)
      defer delete(tmp)
      for i in 0 ..< nvp do tmp[i] = RC_MESH_NULL_IDX
      n := 0
      for i in 0 ..< na - 1 {
        tmp[n] = pa.verts[(int(bestEa) + 1 + i) % na]
        n += 1
      }
      for i in 0 ..< nb - 1 {
        tmp[n] = pb.verts[(int(bestEb) + 1 + i) % nb]
        n += 1
      }
      delete(pa.verts)
      pa.verts = make([]u16, n)
      copy(pa.verts, tmp[:n])
      if pa.reg != pb.reg do pa.reg = RC_MULTIPLE_REGS
      delete(pb.verts)
      for i in bestPb ..< npolys - 1 {
        temp_polys[i] = temp_polys[i + 1]
      }
      npolys -= 1
    }
  }
  for i in 0 ..< npolys {
    if pmesh.npolys >= maxTris do break
    pi := int(pmesh.npolys) * nvp * 2
    for j in 0 ..< nvp * 2 {
      pmesh.polys[pi + j] = RC_MESH_NULL_IDX
    }
    for j in 0 ..< min(nvp, len(temp_polys[i].verts)) {
      pmesh.polys[pi + j] = temp_polys[i].verts[j]
    }
    pmesh.regs[pmesh.npolys] = temp_polys[i].reg
    pmesh.areas[pmesh.npolys] = temp_polys[i].area
    pmesh.flags[pmesh.npolys] = 1
    pmesh.npolys += 1
    if pmesh.npolys > maxTris {
      log.errorf(
        "removeVertex: Too many polygons %d (max:%d)",
        pmesh.npolys,
        maxTris,
      )
      return false
    }
  }
  return true
}

@(private = "file")
build_mesh_portal_edges :: proc(pmesh: ^Poly_Mesh) -> bool {
  if pmesh == nil do return false
  nvp := int(pmesh.nvp)
  for i in 0 ..< pmesh.npolys {
    pi := int(i) * nvp * 2
    for j in 0 ..< nvp {
      if pmesh.polys[pi + j] == RC_MESH_NULL_IDX do break
      if pmesh.polys[pi + nvp + j] == RC_MESH_NULL_IDX {
        k := (j + 1) % nvp
        if pmesh.polys[pi + k] == RC_MESH_NULL_IDX do continue
        va := pmesh.polys[pi + j]
        vb := pmesh.polys[pi + k]
        if va < u16(len(pmesh.verts)) && vb < u16(len(pmesh.verts)) {
          ax := pmesh.verts[va].x
          az := pmesh.verts[va].z
          bx := pmesh.verts[vb].x
          bz := pmesh.verts[vb].z
          border := u16(pmesh.border_size * 2)
          is_portal := false
          if (ax == 0 || ax == border) &&
             (bx == 0 || bx == border) &&
             ax == bx {
            is_portal = true
          }
          if (az == 0 || az == border) &&
             (bz == 0 || bz == border) &&
             az == bz {
            is_portal = true
          }
          if is_portal {
            dir := u16(0)
            if ax == 0 {dir = 0} else
            if ax == border {dir = 1} else
            if az == 0 {dir = 2} else
            if az == border {dir = 3}
            pmesh.polys[pi + nvp + j] = 0x8000 | (dir << 13)
          }
        }
      }
    }
  }
  return true
}
