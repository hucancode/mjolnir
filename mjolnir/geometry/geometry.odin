package geometry

import "base:runtime"
import "core:math"
import linalg "core:math/linalg"
import vk "vendor:vulkan"

// --- Vertex Structs and Descriptions ---

Vertex :: struct {
  position: [3]f32,
  normal:   [3]f32,
  color:    [4]f32,
  uv:       [2]f32,
}

// Vertex input binding description for static vertices
VERTEX_BINDING_DESCRIPTION := [?]vk.VertexInputBindingDescription {
  {binding = 0, stride = size_of(Vertex), inputRate = .VERTEX},
}

// Vertex attribute description for static vertices
VERTEX_ATTRIBUTE_DESCRIPTIONS := [?]vk.VertexInputAttributeDescription {
  // Position
  {
    binding = 0,
    location = 0,
    format = .R32G32B32_SFLOAT,
    offset = u32(offset_of(Vertex, position)),
  },
  // Normal
  {
    binding = 0,
    location = 1,
    format = .R32G32B32_SFLOAT,
    offset = u32(offset_of(Vertex, normal)),
  },
  // Color
  {
    binding = 0,
    location = 2,
    format = .R32G32B32A32_SFLOAT,
    offset = u32(offset_of(Vertex, color)),
  },
  // UV
  {
    binding = 0,
    location = 3,
    format = .R32G32_SFLOAT,
    offset = u32(offset_of(Vertex, uv)),
  },
}

SkinnedVertex :: struct {
  position: [3]f32,
  normal:   [3]f32,
  color:    [4]f32,
  uv:       [2]f32,
  joints:   [4]u32,
  weights:  [4]f32,
}

// Vertex input binding description for skinned vertices
SKINNED_VERTEX_BINDING_DESCRIPTION := [?]vk.VertexInputBindingDescription {
  {binding = 0, stride = size_of(SkinnedVertex), inputRate = .VERTEX},
}

// Vertex attribute descriptions for skinned vertices
SKINNED_VERTEX_ATTRIBUTE_DESCRIPTIONS :=
  [?]vk.VertexInputAttributeDescription {
    // Position
    {
      binding = 0,
      location = 0,
      format = .R32G32B32_SFLOAT,
      offset = u32(offset_of(SkinnedVertex, position)),
    },
    // Normal
    {
      binding = 0,
      location = 1,
      format = .R32G32B32_SFLOAT,
      offset = u32(offset_of(SkinnedVertex, normal)),
    },
    // Color
    {
      binding = 0,
      location = 2,
      format = .R32G32B32A32_SFLOAT,
      offset = u32(offset_of(SkinnedVertex, color)),
    },
    // UV
    {
      binding = 0,
      location = 3,
      format = .R32G32_SFLOAT,
      offset = u32(offset_of(SkinnedVertex, uv)),
    },
    // Joints
    {
      binding = 0,
      location = 4,
      format = .R32G32B32A32_UINT,
      offset = u32(offset_of(SkinnedVertex, joints)),
    },
    // Weights
    {
      binding = 0,
      location = 5,
      format = .R32G32B32A32_SFLOAT,
      offset = u32(offset_of(SkinnedVertex, weights)),
    },
  }

// --- Constant Vectors ---
VEC_FORWARD :: [3]f32{0.0, 0.0, 1.0}
VEC_BACKWARD :: [3]f32{0.0, 0.0, -1.0}
VEC_UP :: [3]f32{0.0, 1.0, 0.0}
VEC_DOWN :: [3]f32{0.0, -1.0, 0.0}
VEC_LEFT :: [3]f32{-1.0, 0.0, 0.0}
VEC_RIGHT :: [3]f32{1.0, 0.0, 0.0}
F32_MIN :: -3.40282347E+38
F32_MAX :: 3.40282347E+38

// --- AABB (Axis-Aligned Bounding Box) ---
Aabb :: struct {
  min: linalg.Vector4f32,
  max: linalg.Vector4f32,
}

aabb_from_vertices :: proc(vertices: []Vertex) -> Aabb {
  bounds := Aabb {
      min = {F32_MAX, F32_MAX, F32_MAX, F32_MAX},
      max = {F32_MIN, F32_MIN, F32_MIN, F32_MIN},
    }
  if len(vertices) == 0 {
    bounds.min = {0, 0, 0, 1}
    bounds.max = {0, 0, 0, 1}
    return bounds
  }

  for vertex in vertices {
    v_pos4 := linalg.Vector4f32 {
      vertex.position[0],
      vertex.position[1],
      vertex.position[2],
      1.0,
    }
    bounds.min = linalg.min(bounds.min, v_pos4)
    bounds.max = linalg.max(bounds.max, v_pos4)
  }
  return bounds
}

aabb_from_skinned_vertices :: proc(vertices: []SkinnedVertex) -> Aabb {
  bounds := Aabb {
    min = {F32_MAX, F32_MAX, F32_MAX, F32_MAX},
    max = {F32_MIN, F32_MIN, F32_MIN, F32_MIN},
  }
  if len(vertices) == 0 {
    bounds.min = {0, 0, 0, 1}
    bounds.max = {0, 0, 0, 1}
    return bounds
  }

  for vertex in vertices {
    v_pos4 := linalg.Vector4f32 {
      vertex.position[0],
      vertex.position[1],
      vertex.position[2],
      1.0,
    }
    bounds.min = linalg.min(bounds.min, v_pos4)
    bounds.max = linalg.max(bounds.max, v_pos4)
  }
  return bounds
}

// --- Geometry Structs ---
Geometry :: struct {
  vertices: []Vertex,
  indices:  []u32,
  aabb:     Aabb,
}

extract_positions_geometry :: proc(geom: ^Geometry) -> []linalg.Vector4f32 {
  positions := make([]linalg.Vector4f32, len(geom.vertices))
  for &v, i in geom.vertices {
    positions[i] = {v.position[0], v.position[1], v.position[2], 1.0}
  }
  return positions
}

make_geometry :: proc(vertices: []Vertex, indices: []u32) -> Geometry {
  return {
    vertices = vertices,
    indices = indices,
    aabb = aabb_from_vertices(vertices),
  }
}

SkinnedGeometry :: struct {
  vertices: []SkinnedVertex, // Slice, lifetime managed by caller
  indices:  []u32, // Slice, lifetime managed by caller
  aabb:     Aabb,
}

extract_positions_skinned_geometry :: proc(
  geom: ^SkinnedGeometry,
) -> []linalg.Vector4f32 {
  positions := make([]linalg.Vector4f32, len(geom.vertices))
  for &v, i in geom.vertices {
    positions[i] = {v.position[0], v.position[1], v.position[2], 1.0}
  }
  return positions
}

make_skinned_geometry :: proc(
  vertices: []SkinnedVertex,
  indices: []u32,
) -> SkinnedGeometry {
  return SkinnedGeometry {
    vertices = vertices,
    indices = indices,
    aabb = aabb_from_skinned_vertices(vertices),
  }
}

// --- Primitive Geometries ---
// For primitives, vertices and indices are defined as global constants.
// The procedures then return Geometry structs that slice these constants.

// make_cube creates a cube geometry. If color is nil, uses default white.
make_cube :: proc(color: [4]f32 = {1.0, 1.0, 1.0, 1.0}) -> (ret: Geometry) {
  ret.vertices = make([]Vertex, 24)
  ret.indices = make([]u32, 36)
  vertices := [?]Vertex {
    // Front face
    {{-1, -1, 1}, VEC_FORWARD, color, {0, 1}},
    {{1, -1, 1}, VEC_FORWARD, color, {1, 1}},
    {{1, 1, 1}, VEC_FORWARD, color, {1, 0}},
    {{-1, 1, 1}, VEC_FORWARD, color, {0, 0}},
    // Back face
    {{-1, 1, -1}, VEC_BACKWARD, color, {1, 1}},
    {{1, 1, -1}, VEC_BACKWARD, color, {0, 1}},
    {{1, -1, -1}, VEC_BACKWARD, color, {0, 0}},
    {{-1, -1, -1}, VEC_BACKWARD, color, {1, 0}},
    // Top face
    {{1, 1, -1}, VEC_UP, color, {0, 1}},
    {{-1, 1, -1}, VEC_UP, color, {1, 1}},
    {{-1, 1, 1}, VEC_UP, color, {1, 0}},
    {{1, 1, 1}, VEC_UP, color, {0, 0}},
    // Bottom face
    {{1, -1, 1}, VEC_DOWN, color, {0, 1}},
    {{-1, -1, 1}, VEC_DOWN, color, {1, 1}},
    {{-1, -1, -1}, VEC_DOWN, color, {1, 0}},
    {{1, -1, -1}, VEC_DOWN, color, {0, 0}},
    // Right face
    {{1, -1, -1}, VEC_RIGHT, color, {0, 1}},
    {{1, 1, -1}, VEC_RIGHT, color, {1, 1}},
    {{1, 1, 1}, VEC_RIGHT, color, {1, 0}},
    {{1, -1, 1}, VEC_RIGHT, color, {0, 0}},
    // Left face
    {{-1, -1, 1}, VEC_LEFT, color, {0, 1}},
    {{-1, 1, 1}, VEC_LEFT, color, {1, 1}},
    {{-1, 1, -1}, VEC_LEFT, color, {1, 0}},
    {{-1, -1, -1}, VEC_LEFT, color, {0, 0}},
  }
  copy_slice(ret.vertices, vertices[:])
  indices := [?]u32 {
    // Front
    0,
    1,
    2,
    2,
    3,
    0,
    // Back
    4,
    5,
    6,
    6,
    7,
    4,
    // Top
    8,
    9,
    10,
    10,
    11,
    8,
    // Bottom
    12,
    13,
    14,
    14,
    15,
    12,
    // Right
    16,
    17,
    18,
    18,
    19,
    16,
    // Left
    20,
    21,
    22,
    22,
    23,
    20,
  }
  copy_slice(ret.indices, indices[:])
  ret.aabb = {
    min = {-1, -1, -1, 1},
    max = {1, 1, 1, 1},
  }
  return
}

// Triangle

make_triangle :: proc(color: [4]f32 = {1.0, 1.0, 1.0, 1.0}) -> (ret: Geometry) {
  ret.vertices = make([]Vertex, 3)
  ret.indices = make([]u32, 3)

  local_vertices := [?]Vertex {
    {{0.0, 0.0, 0.0}, VEC_FORWARD, color, {0.0, 0.0}},
    {{1.0, 0.0, 0.0}, VEC_FORWARD, color, {1.0, 0.0}},
    {{0.5, 1.0, 0.0}, VEC_FORWARD, color, {0.5, 1.0}},
  }
  copy_slice(ret.vertices, local_vertices[:])

  local_indices := [?]u32{0, 1, 2}
  copy_slice(ret.indices, local_indices[:])

  ret.aabb = aabb_from_vertices(ret.vertices)
  return
}

// Quad (on XZ plane, facing Y up)
make_quad :: proc(color: [4]f32 = {1.0, 1.0, 1.0, 1.0}) -> (ret: Geometry) {
  ret.vertices = make([]Vertex, 4)
  ret.indices = make([]u32, 6)

  local_vertices := [?]Vertex {
    {{0, 0, 0}, VEC_UP, color, {0, 0}},
    {{0, 0, 1}, VEC_UP, color, {0, 1}},
    {{1, 0, 1}, VEC_UP, color, {1, 1}},
    {{1, 0, 0}, VEC_UP, color, {1, 0}},
  }
  copy_slice(ret.vertices, local_vertices[:])

  local_indices := [?]u32{0, 1, 2, 2, 3, 0}
  copy_slice(ret.indices, local_indices[:])

  ret.aabb = Aabb {
    min = {0, -0.0001, 0, 1},
    max = {1, 0.0001, 1, 1},
  }
  return
}

// Sphere (Placeholder - requires dynamic generation)
// make_sphere would need to allocate vertices and indices.
make_sphere :: proc(segments, rings: u32) -> (Geometry, bool) {
  // TODO: Implement sphere generation
  // This would involve calculating vertex positions, normals, UVs, and indices,
  return Geometry{}, false // Return empty geometry and false for not implemented
}
