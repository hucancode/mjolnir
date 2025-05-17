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

make_triangle :: proc(
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
) -> (
  ret: Geometry,
) {
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

// --- Sphere ---
make_sphere :: proc(
  segments: u32 = 16,
  rings: u32 = 16,
  radius: f32 = 1.0,
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
) -> (ret: Geometry) {
  vert_count := (rings + 1) * (segments + 1)
  idx_count := rings * segments * 6
  ret.vertices = make([]Vertex, vert_count)
  ret.indices = make([]u32, idx_count)

  for ring in 0..=rings {
    phi := math.PI * f32(ring) / f32(rings)
    y := math.cos(phi)
    r := math.sin(phi)
    for seg in 0..=segments {
      theta := 2.0 * math.PI * f32(seg) / f32(segments)
      x := r * math.cos(theta)
      z := r * math.sin(theta)
      idx := ring * (segments + 1) + seg
      ret.vertices[idx] = Vertex{
        position = {radius * x, radius * y, radius * z},
        normal = {x, y, z},
        color = color,
        uv = {f32(seg) / f32(segments), f32(ring) / f32(rings)},
      }
    }
  }
  i := 0
  for ring in 0..<rings {
    for seg in 0..<segments {
      a := ring * (segments + 1) + seg
      b := a + segments + 1
      ret.indices[i+0] = a
      ret.indices[i+1] = a + 1
      ret.indices[i+2] = b
      ret.indices[i+3] = b
      ret.indices[i+4] = a + 1
      ret.indices[i+5] = b + 1
      i += 6
    }
  }
  ret.aabb = aabb_from_vertices(ret.vertices)
  return
}

// --- Cone ---
make_cone :: proc(
  segments: u32 = 32,
  height: f32 = 2.0,
  radius: f32 = 1.0,
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
) -> (ret: Geometry) {
  vert_count := segments + 3
  idx_count := segments * 6
  ret.vertices = make([]Vertex, vert_count)
  ret.indices = make([]u32, idx_count)

  // Tip vertex
  ret.vertices[0] = Vertex{
    position = {0, height / 2, 0},
    normal = {0, 1, 0},
    color = color,
    uv = {0.5, 1.0},
  }
  // Base center
  ret.vertices[1] = Vertex{
    position = {0, -height / 2, 0},
    normal = {0, -1, 0},
    color = color,
    uv = {0.5, 0.0},
  }
  // Base circle
  for i in 0..=segments {
    theta := 2.0 * math.PI * f32(i) / f32(segments)
    x := radius * math.cos(theta)
    z := radius * math.sin(theta)
    // Side normal calculation
    side_normal := linalg.normalize(linalg.Vector3f32{x, radius / height, z})
    ret.vertices[2+i] = Vertex{
      position = {x, -height / 2, z},
      normal = side_normal,
      color = color,
      uv = {0.5 + 0.5 * math.cos(theta), 0.5 + 0.5 * math.sin(theta)},
    }
  }
  // Indices (side)
  idx := 0
  for i in 0..<segments {
    next := 2 + ((i+1) % (segments+1))
    ret.indices[idx+0] = 0
    ret.indices[idx+1] = next
    ret.indices[idx+2] = 2 + i
    idx += 3
  }
  // Indices (base)
  for i in 0..<segments {
    next := 2 + ((i+1) % (segments+1))
    ret.indices[idx+0] = 1
    ret.indices[idx+1] = 2 + i
    ret.indices[idx+2] = next
    idx += 3
  }
  ret.aabb = aabb_from_vertices(ret.vertices)
  return
}
// --- Capsule ---
make_capsule :: proc(
  segments: u32 = 16,
  rings: u32 = 8,
  height: f32 = 2.0,
  radius: f32 = 0.5,
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
) -> (ret: Geometry) {
  // Capsule = cylinder + 2 hemispheres
  // Vertices: top hemisphere, bottom hemisphere, cylinder sides

  sphere_rings := rings
  cyl_height := height - 2.0 * radius

  // Vertex counts
  top_hemi_verts := (sphere_rings+1) * (segments+1)
  bottom_hemi_verts := (sphere_rings+1) * (segments+1)
  cylinder_verts := 2 * (segments+1)
  vert_count := top_hemi_verts + bottom_hemi_verts + cylinder_verts

  // Index counts
  top_hemi_quads := sphere_rings * segments
  bottom_hemi_quads := sphere_rings * segments
  cylinder_quads := segments
  idx_count := (top_hemi_quads + bottom_hemi_quads + cylinder_quads) * 6

  ret.vertices = make([]Vertex, vert_count)
  ret.indices = make([]u32, idx_count)

  v := 0

  // --- Top Hemisphere ---
  for ring in 0..=sphere_rings {
    phi := (math.PI/2.0) * f32(ring) / f32(sphere_rings)
    y := math.sin(phi)
    r := math.cos(phi)
    for seg in 0..=segments {
      theta := 2.0 * math.PI * f32(seg) / f32(segments)
      x := r * math.cos(theta)
      z := r * math.sin(theta)
      ret.vertices[v] = Vertex{
        position = {radius * x, cyl_height/2 + radius * y, radius * z},
        normal = linalg.normalize(linalg.Vector3f32{x, y, z}),
        color = color,
        uv = {f32(seg)/f32(segments), 1.0 - f32(ring)/f32(2.0*sphere_rings)},
      }
      v += 1
    }
  }

  // --- Bottom Hemisphere ---
  for ring in 0..=sphere_rings {
    phi := (math.PI/2.0) * f32(ring) / f32(sphere_rings)
    y := -math.sin(phi)
    r := math.cos(phi)
    for seg in 0..=segments {
      theta := 2.0 * math.PI * f32(seg) / f32(segments)
      x := r * math.cos(theta)
      z := r * math.sin(theta)
      ret.vertices[v] = Vertex{
        position = {radius * x, -cyl_height/2 + radius * y, radius * z},
        normal = linalg.normalize(linalg.Vector3f32{x, y, z}),
        color = color,
        uv = {f32(seg)/f32(segments), 0.5 + f32(ring)/f32(2.0*sphere_rings)},
      }
      v += 1
    }
  }

  // --- Cylinder Sides ---
  for seg in 0..=segments {
    theta := 2.0 * math.PI * f32(seg) / f32(segments)
    x := math.cos(theta)
    z := math.sin(theta)
    // Top ring
    ret.vertices[v] = Vertex{
      position = {radius * x, cyl_height/2, radius * z},
      normal = linalg.normalize(linalg.Vector3f32{x, 0, z}),
      color = color,
      uv = {f32(seg)/f32(segments), 0.5},
    }
    v += 1
    // Bottom ring
    ret.vertices[v] = Vertex{
      position = {radius * x, -cyl_height/2, radius * z},
      normal = linalg.normalize(linalg.Vector3f32{x, 0, z}),
      color = color,
      uv = {f32(seg)/f32(segments), 0.5},
    }
    v += 1
  }

  // --- Indices ---
  i := 0
  top_start :u32 = 0
  bottom_start := top_hemi_verts
  cyl_start := top_hemi_verts + bottom_hemi_verts

  // Top hemisphere indices
  for ring in 0..<sphere_rings {
    for seg in 0..<segments {
      a := top_start + ring * (segments+1) + seg
      b := top_start + (ring+1) * (segments+1) + seg
      a1 := top_start + ring * (segments+1) + (seg+1)
      b1 := top_start + (ring+1) * (segments+1) + (seg+1)
      ret.indices[i+0] = a
      ret.indices[i+1] = b
      ret.indices[i+2] = a1
      ret.indices[i+3] = b
      ret.indices[i+4] = b1
      ret.indices[i+5] = a1
      i += 6
    }
  }

  // Bottom hemisphere indices
  for ring in 0..<sphere_rings {
    for seg in 0..<segments {
      a := bottom_start + ring * (segments+1) + seg
      b := bottom_start + (ring+1) * (segments+1) + seg
      a1 := bottom_start + ring * (segments+1) + (seg+1)
      b1 := bottom_start + (ring+1) * (segments+1) + (seg+1)
      ret.indices[i+0] = a
      ret.indices[i+1] = a1
      ret.indices[i+2] = b
      ret.indices[i+3] = b
      ret.indices[i+4] = a1
      ret.indices[i+5] = b1
      i += 6
    }
  }
  // Cylinder indices
  for seg in 0..<segments {
    a := cyl_start + seg * 2
    b := a + 1
    c := cyl_start + (seg+1) * 2
    d := c + 1
    ret.indices[i+0] = a
    ret.indices[i+1] = c
    ret.indices[i+2] = b
    ret.indices[i+3] = b
    ret.indices[i+4] = c
    ret.indices[i+5] = d
    i += 6
  }

  ret.aabb = aabb_from_vertices(ret.vertices)
  return
}
// --- Torus ---
make_torus :: proc(
  segments: u32 = 32,
  sides: u32 = 16,
  major_radius: f32 = 1.0,
  minor_radius: f32 = 0.3,
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
) -> (ret: Geometry) {
  vert_count := (segments+1)*(sides+1)
  idx_count := segments * sides * 6
  ret.vertices = make([]Vertex, vert_count)
  ret.indices = make([]u32, idx_count)

  for seg in 0..=segments {
    theta := 2.0 * math.PI * f32(seg) / f32(segments)
    cos_theta := math.cos(theta)
    sin_theta := math.sin(theta)
    for side in 0..=sides {
      phi := 2.0 * math.PI * f32(side) / f32(sides)
      cos_phi := math.cos(phi)
      sin_phi := math.sin(phi)
      x := (major_radius + minor_radius * cos_phi) * cos_theta
      y := (major_radius + minor_radius * cos_phi) * sin_theta
      z := minor_radius * sin_phi
      idx := seg * (sides+1) + side
      nx := cos_theta * cos_phi
      ny := sin_theta * cos_phi
      nz := sin_phi
      ret.vertices[idx] = Vertex{
        position = {x, y, z},
        normal = {nx, ny, nz},
        color = color,
        uv = {f32(seg)/f32(segments), f32(side)/f32(sides)},
      }
    }
  }
  i := 0
  for seg in 0..<segments {
    for side in 0..<sides {
      a := seg * (sides+1) + side
      b := ((seg+1) % (segments+1)) * (sides+1) + side
      ret.indices[i+0] = a
      ret.indices[i+1] = b
      ret.indices[i+2] = a + 1
      ret.indices[i+3] = b
      ret.indices[i+4] = b + 1
      ret.indices[i+5] = a + 1
      i += 6
    }
  }
  ret.aabb = aabb_from_vertices(ret.vertices)
  return
}

make_cylinder :: proc(
    segments: u32 = 32,
    height: f32 = 2.0,
    radius: f32 = 1.0,
    color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
) -> (ret: Geometry) {
    // Vertices: (segments+1)*2 for body, 1 center+segments+1 for each cap
    body_verts := (segments+1)*2
    cap_verts := (segments+2) * 2 // +1 for center, +segments+1 for rim (duplicate first for UV seam)
    vert_count := body_verts + cap_verts
    idx_count := segments*6 + segments*3*2

    ret.vertices = make([]Vertex, vert_count)
    ret.indices = make([]u32, idx_count)

    half_h := height * 0.5
    v :u32 = 0

    // Body vertices (top and bottom rings)
    for i in 0..=segments {
        theta := 2.0 * math.PI * f32(i) / f32(segments)
        x := math.cos(theta)
        z := math.sin(theta)
        // Top ring
        ret.vertices[v] = Vertex{
            position = {radius * x, half_h, radius * z},
            normal = {x, 0, z},
            color = color,
            uv = {f32(i)/f32(segments), 0.0},
        }
        v += 1
        // Bottom ring
        ret.vertices[v] = Vertex{
            position = {radius * x, -half_h, radius * z},
            normal = {x, 0, z},
            color = color,
            uv = {f32(i)/f32(segments), 1.0},
        }
        v += 1
    }

    // Top cap center
    top_center := v
    ret.vertices[v] = Vertex{
        position = {0, half_h, 0},
        normal = {0, 1, 0},
        color = color,
        uv = {0.5, 0.5},
    }
    v += 1
    // Top cap rim
    for i in 0..=segments {
        theta := 2.0 * math.PI * f32(i) / f32(segments)
        x := math.cos(theta)
        z := math.sin(theta)
        ret.vertices[v] = Vertex{
            position = {radius * x, half_h, radius * z},
            normal = {0, 1, 0},
            color = color,
            uv = {0.5 + 0.5 * x, 0.5 + 0.5 * z},
        }
        v += 1
    }

    // Bottom cap center
    bottom_center := v
    ret.vertices[v] = Vertex{
        position = {0, -half_h, 0},
        normal = {0, -1, 0},
        color = color,
        uv = {0.5, 0.5},
    }
    v += 1
    // Bottom cap rim
    for i in 0..=segments {
        theta := 2.0 * math.PI * f32(i) / f32(segments)
        x := math.cos(theta)
        z := math.sin(theta)
        ret.vertices[v] = Vertex{
            position = {radius * x, -half_h, radius * z},
            normal = {0, -1, 0},
            color = color,
            uv = {0.5 + 0.5 * x, 0.5 + 0.5 * z},
        }
        v += 1
    }

    // Indices
    i := 0
    // Body
    for seg in 0..<segments {
        a := seg * 2
        b := a + 1
        c := (seg+1) * 2
        d := c + 1
        ret.indices[i+0] = a
        ret.indices[i+1] = c
        ret.indices[i+2] = b
        ret.indices[i+3] = b
        ret.indices[i+4] = c
        ret.indices[i+5] = d
        i += 6
    }
    // Top cap (corrected winding: center, next, current)
    top_rim := top_center + 1
    for seg in 0..<segments {
        ret.indices[i+0] = top_center
        ret.indices[i+1] = top_rim + seg + 1
        ret.indices[i+2] = top_rim + seg
        i += 3
    }
    // Bottom cap (corrected winding: center, current, next)
    bottom_rim := bottom_center + 1
    for seg in 0..<segments {
        ret.indices[i+0] = bottom_center
        ret.indices[i+1] = bottom_rim + seg
        ret.indices[i+2] = bottom_rim + seg + 1
        i += 3
    }

    ret.aabb = aabb_from_vertices(ret.vertices)
    return
}
