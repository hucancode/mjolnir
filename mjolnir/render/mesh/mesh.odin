package mesh

import "../../geometry"
import "core:math/linalg"
import "core:slice"

// CPU mesh data in the renderer's vertex format: what render.create_mesh
// uploads and the builtin primitives are built from.
Vertex :: struct {
  position: [3]f32,
  normal:   [3]f32,
  color:    [4]f32,
  uv:       [2]f32,
  tangent:  [4]f32, // xyz = tangent, w = handedness (for bitangent reconstruction)
}

SkinningData :: struct {
  joints:  [4]u32,
  weights: [4]f32,
}

Geometry :: struct {
  vertices:  []Vertex,
  skinnings: []SkinningData,
  indices:   []u32,
  aabb:      geometry.Aabb,
}

make_geometry :: proc(
  vertices: []Vertex,
  indices: []u32,
  skinnings: []SkinningData = nil,
) -> Geometry {
  // Calculate tangents if missing (all zeros)
  if len(vertices) > 0 && vertices[0].tangent == {} {
    // Accumulate tangents per triangle
    for i in 0 ..< len(indices) / 3 {
      i0 := indices[i * 3 + 0]
      i1 := indices[i * 3 + 1]
      i2 := indices[i * 3 + 2]
      v0 := vertices[i0]
      v1 := vertices[i1]
      v2 := vertices[i2]
      p0 := v0.position
      p1 := v1.position
      p2 := v2.position
      uv0 := v0.uv
      uv1 := v1.uv
      uv2 := v2.uv
      edge1 := p1 - p0
      edge2 := p2 - p0
      deltaUV1 := uv1 - uv0
      deltaUV2 := uv2 - uv0
      tangent :=
        (deltaUV2.y * edge1 - deltaUV1.y * edge2) /
        linalg.cross(deltaUV1, deltaUV2)
      // Accumulate tangent
      ids := [3]u32{i0, i1, i2}
      for idx in ids {
        vertices[idx].tangent.xyz += tangent
      }
    }
    // Normalize tangents and set handedness to +1
    for &v in vertices {
      tangent_vec := v.tangent.xyz
      if linalg.length2(tangent_vec) > 0.0 {
        v.tangent.xyz = linalg.normalize(tangent_vec)
      }
      v.tangent.w = 1.0
    }
  }
  return {
    vertices = vertices,
    skinnings = skinnings,
    indices = indices,
    aabb = aabb_from_vertices(vertices),
  }
}

delete_geometry :: proc(geometry: Geometry) {
  delete(geometry.vertices)
  delete(geometry.skinnings)
  delete(geometry.indices)
}

aabb_from_vertices :: proc(vertices: []Vertex) -> (ret: geometry.Aabb) {
  if len(vertices) == 0 {
    return
  }
  ret = geometry.AABB_UNDEFINED
  for vertex in vertices {
    ret.min = linalg.min(ret.min, vertex.position)
    ret.max = linalg.max(ret.max, vertex.position)
  }
  return ret
}

// Vertex positions, for consumers that only need positions (physics,
// navigation). Allocated with `allocator`.
positions :: proc(self: Geometry, allocator := context.allocator) -> [][3]f32 {
  out := make([][3]f32, len(self.vertices), allocator)
  for v, i in self.vertices do out[i] = v.position
  return out
}

// Renderable geometry from a bare triangle mesh (an OBJ file, navmesh debug
// triangles): smooth normals averaged from face normals, white color and
// planar xz UVs. The input arrays are copied.
from_triangles :: proc(positions: [][3]f32, indices: []u32) -> Geometry {
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
  return make_geometry(vertices, slice.clone(indices))
}
