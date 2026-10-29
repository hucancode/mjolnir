package geometry

import "core:math/linalg"
import "core:slice"

// SkinningData holds the four joint indices and weights that deform one vertex.
SkinningData :: struct {
  joints:  [4]u32,
  weights: [4]f32,
}
#assert(size_of(SkinningData) == 32)

// Vertex is a mesh vertex, as renderers upload it.
Vertex :: struct {
  position: [3]f32,
  normal:   [3]f32,
  color:    [4]f32,
  uv:       [2]f32,
  tangent:  [4]f32, // xyz = tangent, w = handedness (for bitangent reconstruction)
}

// Vertex2D is a vertex of 2D screen-space geometry (a UI, an overlay): a pixel position, a
// texture coordinate and a color.
Vertex2D :: struct {
  pos:   [2]f32,
  uv:    [2]f32,
  color: [4]u8,
}

// Mesh is a CPU triangle mesh; skinnings is empty or parallel to vertices.
Mesh :: struct {
  vertices:  []Vertex,
  skinnings: []SkinningData,
  indices:   []u32,
}

// make_mesh wraps vertices and indices into a Mesh, giving every vertex without a tangent (all
// zero) one aligned with its triangles' UVs.
make_mesh :: proc(vertices: []Vertex, indices: []u32, skinnings: []SkinningData = nil) -> Mesh {
  missing := make([]bool, len(vertices), context.temp_allocator)
  any_missing := false
  for v, i in vertices do if v.tangent == {} {
    missing[i] = true
    any_missing = true
  }
  if !any_missing do return {vertices = vertices, skinnings = skinnings, indices = indices}
  for t := 0; t + 2 < len(indices); t += 3 {
    tri := [3]u32{indices[t], indices[t + 1], indices[t + 2]}
    a, b, c := vertices[tri[0]], vertices[tri[1]], vertices[tri[2]]
    e1, e2 := b.position - a.position, c.position - a.position
    d1, d2 := b.uv - a.uv, c.uv - a.uv
    det := linalg.cross(d1, d2)
    // degenerate UVs contribute no tangent
    if abs(det) < 1e-12 do continue
    tangent := (d2.y * e1 - d1.y * e2) / det
    for k in tri do if missing[k] do vertices[k].tangent.xyz += tangent
  }
  // vertices touching only degenerate triangles (poles, cone tip) get any vector perpendicular
  // to the normal
  for &v, i in vertices do if missing[i] {
    tangent := v.tangent.xyz
    if linalg.length2(tangent) < 1e-12 {
      axis := linalg.VECTOR3F32_X_AXIS if abs(v.normal.x) < 0.9 else linalg.VECTOR3F32_Z_AXIS
      tangent = linalg.cross(v.normal, axis)
      if linalg.length2(tangent) < 1e-12 do tangent = linalg.VECTOR3F32_X_AXIS
    }
    v.tangent = {0, 0, 0, 1}
    v.tangent.xyz = linalg.normalize(tangent)
  }
  return {vertices = vertices, skinnings = skinnings, indices = indices}
}

// mesh_destroy frees the arrays of a Mesh.
mesh_destroy :: proc(mesh: Mesh) {
  delete(mesh.vertices)
  delete(mesh.skinnings)
  delete(mesh.indices)
}

// flat axes are widened so culling never sees a zero-thickness box
@(private)
AABB_MIN_EXTENT :: 0.1

// aabb_from_vertices returns the bounding box of the vertex positions, flat axes widened to AABB_MIN_EXTENT.
aabb_from_vertices :: proc(vertices: []Vertex) -> (ret: Aabb) {
  if len(vertices) == 0 {
    return
  }
  ret = AABB_UNDEFINED
  for vertex in vertices {
    ret.min = linalg.min(ret.min, vertex.position)
    ret.max = linalg.max(ret.max, vertex.position)
  }
  pad := linalg.max(AABB_MIN_EXTENT - (ret.max - ret.min), [3]f32{}) * 0.5
  ret.min -= pad
  ret.max += pad
  return ret
}

// positions returns the vertex positions, allocated with allocator.
positions :: proc(self: Mesh, allocator := context.allocator) -> [][3]f32 {
  out := make([][3]f32, len(self.vertices), allocator)
  for v, i in self.vertices do out[i] = v.position
  return out
}

// make_mesh_from_triangles builds a Mesh from bare triangles: smooth normals, white color and
// planar xz UVs. The input arrays are copied.
make_mesh_from_triangles :: proc(positions: [][3]f32, indices: []u32) -> Mesh {
  n := len(positions)
  vertices := make([]Vertex, n)
  normals := make([][3]f32, n, context.temp_allocator)
  for i := 0; i + 2 < len(indices); i += 3 {
    i0, i1, i2 := indices[i], indices[i + 1], indices[i + 2]
    p0, p1, p2 := positions[i0], positions[i1], positions[i2]
    face := linalg.normalize0(linalg.cross(p1 - p0, p2 - p0))
    normals[i0] += face
    normals[i1] += face
    normals[i2] += face
  }
  for &v, i in vertices {
    v.position = positions[i]
    v.normal = linalg.normalize0(normals[i])
    if v.normal == {} do v.normal = linalg.VECTOR3F32_Y_AXIS
    v.color = {1, 1, 1, 1}
    v.uv = v.position.xz * 0.1
  }
  return make_mesh(vertices, slice.clone(indices))
}

// mesh_transform moves a mesh's vertices by t in place: positions, normals and tangents. A
// mirroring scale (an odd count of negative axes) also flips the triangles' winding.
mesh_transform :: proc(mesh: Mesh, t: Transform) {
  inverse_scale := 1 / t.scale
  for &v in mesh.vertices {
    v.position = transform_point(t, v.position)
    v.normal = linalg.normalize0(qmv(t.rotation, inverse_scale * v.normal))
    v.tangent.xyz = linalg.normalize0(qmv(t.rotation, t.scale * v.tangent.xyz))
  }
  if t.scale.x * t.scale.y * t.scale.z >= 0 do return
  for i := 0; i + 2 < len(mesh.indices); i += 3 do mesh.indices[i + 1], mesh.indices[i + 2] = mesh.indices[i + 2], mesh.indices[i + 1]
}

// mesh_merge returns one mesh holding every part placed by its transform (transforms[i] places
// parts[i]), e.g. the pieces of a procedural prop; the parts are copied, not freed, and their
// skinning is dropped.
mesh_merge :: proc(parts: []Mesh, transforms: []Transform) -> Mesh {
  vertex_count, index_count := 0, 0
  for p in parts do vertex_count, index_count = vertex_count + len(p.vertices), index_count + len(p.indices)
  vertices := make([]Vertex, vertex_count)
  indices := make([]u32, index_count)
  v, i := 0, 0
  for p, k in parts {
    copy(vertices[v:], p.vertices)
    for index, j in p.indices do indices[i + j] = index + u32(v)
    mesh_transform({vertices = vertices[v:][:len(p.vertices)], indices = indices[i:][:len(p.indices)]}, transforms[k])
    v, i = v + len(p.vertices), i + len(p.indices)
  }
  return {vertices = vertices, indices = indices}
}

// destroy frees a mesh, BVH, spline or chain, as its *_destroy does.
destroy :: proc {
  mesh_destroy,
  bvh_destroy,
  spline_destroy,
  chain_destroy,
}
