package geometry

import "core:math"
import "core:math/linalg"
import vk "vendor:vulkan"

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

VERTEX_BINDING_DESCRIPTION := [?]vk.VertexInputBindingDescription {
  {binding = 0, stride = size_of(Vertex), inputRate = .VERTEX},
}

VERTEX_ATTRIBUTE_DESCRIPTIONS := [?]vk.VertexInputAttributeDescription {
  {
    binding = 0,
    location = 0,
    format = .R32G32B32_SFLOAT,
    offset = u32(offset_of(Vertex, position)),
  },
  {
    binding = 0,
    location = 1,
    format = .R32G32B32_SFLOAT,
    offset = u32(offset_of(Vertex, normal)),
  },
  {
    binding = 0,
    location = 2,
    format = .R32G32B32A32_SFLOAT,
    offset = u32(offset_of(Vertex, color)),
  },
  {
    binding = 0,
    location = 3,
    format = .R32G32_SFLOAT,
    offset = u32(offset_of(Vertex, uv)),
  },
  {
    binding = 0,
    location = 4,
    format = .R32G32B32A32_SFLOAT,
    offset = u32(offset_of(Vertex, tangent)),
  },
}

VEC_FORWARD :: [3]f32{0.0, 0.0, 1.0}
VEC_BACKWARD :: [3]f32{0.0, 0.0, -1.0}
VEC_UP :: [3]f32{0.0, 1.0, 0.0}
VEC_DOWN :: [3]f32{0.0, -1.0, 0.0}
VEC_LEFT :: [3]f32{-1.0, 0.0, 0.0}
VEC_RIGHT :: [3]f32{1.0, 0.0, 0.0}
F32_MIN :: -3.40282347E+38
F32_MAX :: 3.40282347E+38

Geometry :: struct {
  vertices:  []Vertex,
  skinnings: []SkinningData,
  indices:   []u32,
  aabb:      Aabb,
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
      tangent := (deltaUV2.y * edge1 - deltaUV1.y * edge2) / linalg.cross(deltaUV1, deltaUV2)
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

make_cube :: proc(color: [4]f32 = {1.0, 1.0, 1.0, 1.0}) -> (ret: Geometry) {
  ret.vertices = make([]Vertex, 24)
  ret.indices = make([]u32, 36)
  // Front face
  ret.vertices[0] = {{-1, -1, 1}, VEC_FORWARD, color, {0, 1}, {1, 0, 0, 1}}
  ret.vertices[1] = {{1, -1, 1}, VEC_FORWARD, color, {1, 1}, {1, 0, 0, 1}}
  ret.vertices[2] = {{1, 1, 1}, VEC_FORWARD, color, {1, 0}, {1, 0, 0, 1}}
  ret.vertices[3] = {{-1, 1, 1}, VEC_FORWARD, color, {0, 0}, {1, 0, 0, 1}}
  // Back face
  ret.vertices[4] = {{-1, 1, -1}, VEC_BACKWARD, color, {1, 1}, {-1, 0, 0, 1}}
  ret.vertices[5] = {{1, 1, -1}, VEC_BACKWARD, color, {0, 1}, {-1, 0, 0, 1}}
  ret.vertices[6] = {{1, -1, -1}, VEC_BACKWARD, color, {0, 0}, {-1, 0, 0, 1}}
  ret.vertices[7] = {{-1, -1, -1}, VEC_BACKWARD, color, {1, 0}, {-1, 0, 0, 1}}
  // Top face
  ret.vertices[8] = {{1, 1, -1}, VEC_UP, color, {0, 1}, {0, 1, 0, 1}}
  ret.vertices[9] = {{-1, 1, -1}, VEC_UP, color, {1, 1}, {0, 1, 0, 1}}
  ret.vertices[10] = {{-1, 1, 1}, VEC_UP, color, {1, 0}, {0, 1, 0, 1}}
  ret.vertices[11] = {{1, 1, 1}, VEC_UP, color, {0, 0}, {0, 1, 0, 1}}
  // Bottom face
  ret.vertices[12] = {{1, -1, 1}, VEC_DOWN, color, {0, 1}, {0, 1, 0, 1}}
  ret.vertices[13] = {{-1, -1, 1}, VEC_DOWN, color, {1, 1}, {0, 1, 0, 1}}
  ret.vertices[14] = {{-1, -1, -1}, VEC_DOWN, color, {1, 0}, {0, 1, 0, 1}}
  ret.vertices[15] = {{1, -1, -1}, VEC_DOWN, color, {0, 0}, {0, 1, 0, 1}}
  // Right face
  ret.vertices[16] = {{1, -1, -1}, VEC_RIGHT, color, {0, 1}, {0, 1, 0, 1}}
  ret.vertices[17] = {{1, 1, -1}, VEC_RIGHT, color, {1, 1}, {0, 1, 0, 1}}
  ret.vertices[18] = {{1, 1, 1}, VEC_RIGHT, color, {1, 0}, {0, 1, 0, 1}}
  ret.vertices[19] = {{1, -1, 1}, VEC_RIGHT, color, {0, 0}, {0, 1, 0, 1}}
  // Left face
  ret.vertices[20] = {{-1, -1, 1}, VEC_LEFT, color, {0, 1}, {0, 1, 0, 1}}
  ret.vertices[21] = {{-1, 1, 1}, VEC_LEFT, color, {1, 1}, {0, 1, 0, 1}}
  ret.vertices[22] = {{-1, 1, -1}, VEC_LEFT, color, {1, 0}, {0, 1, 0, 1}}
  ret.vertices[23] = {{-1, -1, -1}, VEC_LEFT, color, {0, 0}, {0, 1, 0, 1}}
  for face in 0 ..< 6 {
    i := u32(face * 4)
    p := ret.indices[face * 6:]
    p[0], p[1], p[2], p[3], p[4], p[5] = i, i + 1, i + 2, i + 2, i + 3, i
  }
  ret.aabb = {
    min = {-1, -1, -1},
    max = {1, 1, 1},
  }
  return
}

make_triangle :: proc(
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
) -> (
  ret: Geometry,
) {
  ret.vertices = make([]Vertex, 3)
  ret.indices = make([]u32, 3)
  ret.vertices[0] = {
    {0.0, 0.0, 0.0},
    VEC_FORWARD,
    color,
    {0.0, 0.0},
    {0, 1, 0, 1},
  }
  ret.vertices[1] = {
    {1.0, 0.0, 0.0},
    VEC_FORWARD,
    color,
    {1.0, 0.0},
    {0, 1, 0, 1},
  }
  ret.vertices[2] = {
    {0.5, 1.0, 0.0},
    VEC_FORWARD,
    color,
    {0.5, 1.0},
    {0, 1, 0, 1},
  }
  ret.indices[0], ret.indices[1], ret.indices[2] = 0, 1, 2
  ret.aabb = Aabb {
    min = {0, 0, 0},
    max = {1, 1, 0.1}, // add some thickness
  }
  return
}

// Quad (on XZ plane, facing Y up)
make_quad :: proc(color: [4]f32 = {1.0, 1.0, 1.0, 1.0}) -> (ret: Geometry) {
  ret.vertices = make([]Vertex, 4)
  ret.indices = make([]u32, 6)
  ret.vertices[0] = {{-1, 0, -1}, VEC_UP, color, {0, 0}, {0, 1, 0, 1}}
  ret.vertices[1] = {{-1, 0, 1}, VEC_UP, color, {0, 1}, {0, 1, 0, 1}}
  ret.vertices[2] = {{1, 0, 1}, VEC_UP, color, {1, 1}, {0, 1, 0, 1}}
  ret.vertices[3] = {{1, 0, -1}, VEC_UP, color, {1, 0}, {0, 1, 0, 1}}
  ret.indices[0], ret.indices[1], ret.indices[2] = 0, 1, 2
  ret.indices[3], ret.indices[4], ret.indices[5] = 2, 3, 0
  ret.aabb = Aabb {
    min = {-1, 0, -1},
    max = {1, 0.1, 1}, // add some thickness
  }
  return
}

make_sphere :: proc(
  segments: u32 = 16,
  rings: u32 = 16,
  radius: f32 = 1.0,
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
) -> (
  ret: Geometry,
) {
  vert_count := (rings + 1) * (segments + 1)
  idx_count := rings * segments * 6
  ret.vertices = make([]Vertex, vert_count)
  ret.indices = make([]u32, idx_count)
  for ring in 0 ..= rings {
    phi := math.PI * f32(ring) / f32(rings)
    y := math.cos(phi)
    r := math.sin(phi)
    for seg in 0 ..= segments {
      theta := 2.0 * math.PI * f32(seg) / f32(segments)
      x := r * math.cos(theta)
      z := r * math.sin(theta)
      idx := ring * (segments + 1) + seg
      ret.vertices[idx] = Vertex {
        position = {radius * x, radius * y, radius * z},
        normal   = {x, y, z},
        color    = color,
        uv       = {f32(seg) / f32(segments), f32(ring) / f32(rings)},
      }
    }
  }
  i := 0
  for ring in 0 ..< rings {
    for seg in 0 ..< segments {
      a := ring * (segments + 1) + seg
      b := a + segments + 1
      p := ret.indices[i:]
      p[0], p[1], p[2], p[3], p[4], p[5] = a, a + 1, b, b, a + 1, b + 1
      i += 6
    }
  }
  ret.aabb = aabb_from_vertices(ret.vertices)
  return
}

make_cone :: proc(
  segments: u32 = 32,
  height: f32 = 2.0,
  radius: f32 = 1.0,
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
) -> (
  ret: Geometry,
) {
  vert_count := segments + 3
  idx_count := segments * 6
  ret.vertices = make([]Vertex, vert_count)
  ret.indices = make([]u32, idx_count)
  // Tip vertex
  ret.vertices[0] = Vertex {
    position = {0, height / 2, 0},
    normal   = {0, 1, 0},
    color    = color,
    uv       = {0.5, 1.0},
  }
  // Base center
  ret.vertices[1] = Vertex {
    position = {0, -height / 2, 0},
    normal   = {0, -1, 0},
    color    = color,
    uv       = {0.5, 0.0},
  }
  // Base circle
  for i in 0 ..= segments {
    theta := 2.0 * math.PI * f32(i) / f32(segments)
    x := radius * math.cos(theta)
    z := radius * math.sin(theta)
    // Side normal calculation
    side_normal := linalg.normalize([3]f32{x, radius / height, z})
    ret.vertices[2 + i] = Vertex {
      position = {x, -height / 2, z},
      normal   = side_normal,
      color    = color,
      uv       = {0.5 + 0.5 * math.cos(theta), 0.5 + 0.5 * math.sin(theta)},
    }
  }
  // Indices (side)
  idx := 0
  for i in 0 ..< segments {
    next := 2 + ((i + 1) % (segments + 1))
    p := ret.indices[idx:]
    p[0], p[1], p[2] = 0, next, 2 + i
    idx += 3
  }
  // Indices (base)
  for i in 0 ..< segments {
    next := 2 + ((i + 1) % (segments + 1))
    p := ret.indices[idx:]
    p[0], p[1], p[2] = 1, 2 + i, next
    idx += 3
  }
  ret.aabb = aabb_from_vertices(ret.vertices)
  return
}

// Generate a full-screen triangle for directional lights
// Uses special coordinates that cover the entire screen when transformed
make_fullscreen_triangle :: proc(
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
) -> (
  ret: Geometry,
) {
  ret.vertices = make([]Vertex, 3)
  ret.indices = make([]u32, 3)
  // Full-screen triangle vertices in NDC space (clip coordinates)
  // These coordinates cover the entire screen when used directly
  ret.vertices[0] = Vertex {
    position = {-1.0, -1.0, 0.0}, // Bottom-left
    normal   = {0.0, 0.0, 1.0},
    color    = color,
    uv       = {0.0, 0.0},
  }
  ret.vertices[1] = Vertex {
    position = {3.0, -1.0, 0.0}, // Bottom-right (extends beyond screen)
    normal   = {0.0, 0.0, 1.0},
    color    = color,
    uv       = {2.0, 0.0},
  }
  ret.vertices[2] = Vertex {
    position = {-1.0, 3.0, 0.0}, // Top-left (extends beyond screen)
    normal   = {0.0, 0.0, 1.0},
    color    = color,
    uv       = {0.0, 2.0},
  }
  // Clockwise winding
  ret.indices[0] = 0
  ret.indices[1] = 2
  ret.indices[2] = 1
  ret.aabb = aabb_from_vertices(ret.vertices)
  return
}

make_capsule :: proc(
  segments: u32 = 16,
  rings: u32 = 8,
  height: f32 = 2.0,
  radius: f32 = 0.5,
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
) -> (
  ret: Geometry,
) {
  // Capsule = cylinder + 2 hemispheres
  // Vertices: top hemisphere, bottom hemisphere, cylinder sides
  sphere_rings := rings
  cyl_height := height - 2.0 * radius
  // Vertex counts
  top_hemi_verts := (sphere_rings + 1) * (segments + 1)
  bottom_hemi_verts := (sphere_rings + 1) * (segments + 1)
  cylinder_verts := 2 * (segments + 1)
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
  for ring in 0 ..= sphere_rings {
    phi := (math.PI / 2.0) * f32(ring) / f32(sphere_rings)
    y := math.sin(phi)
    r := math.cos(phi)
    for seg in 0 ..= segments {
      theta := 2.0 * math.PI * f32(seg) / f32(segments)
      x := r * math.cos(theta)
      z := r * math.sin(theta)
      ret.vertices[v] = Vertex {
        position = {radius * x, cyl_height / 2 + radius * y, radius * z},
        normal   = linalg.normalize([3]f32{x, y, z}),
        color    = color,
        uv       = {
          f32(seg) / f32(segments),
          1.0 - f32(ring) / f32(2.0 * sphere_rings),
        },
      }
      v += 1
    }
  }
  // --- Bottom Hemisphere ---
  for ring in 0 ..= sphere_rings {
    phi := (math.PI / 2.0) * f32(ring) / f32(sphere_rings)
    y := -math.sin(phi)
    r := math.cos(phi)
    for seg in 0 ..= segments {
      theta := 2.0 * math.PI * f32(seg) / f32(segments)
      x := r * math.cos(theta)
      z := r * math.sin(theta)
      ret.vertices[v] = Vertex {
        position = {radius * x, -cyl_height / 2 + radius * y, radius * z},
        normal   = linalg.normalize([3]f32{x, y, z}),
        color    = color,
        uv       = {
          f32(seg) / f32(segments),
          0.5 + f32(ring) / f32(2.0 * sphere_rings),
        },
      }
      v += 1
    }
  }
  // --- Cylinder Sides ---
  for seg in 0 ..= segments {
    theta := 2.0 * math.PI * f32(seg) / f32(segments)
    x := math.cos(theta)
    z := math.sin(theta)
    // Top ring
    ret.vertices[v] = Vertex {
      position = {radius * x, cyl_height / 2, radius * z},
      normal   = linalg.normalize([3]f32{x, 0, z}),
      color    = color,
      uv       = {f32(seg) / f32(segments), 0.5},
    }
    v += 1
    // Bottom ring
    ret.vertices[v] = Vertex {
      position = {radius * x, -cyl_height / 2, radius * z},
      normal   = linalg.normalize([3]f32{x, 0, z}),
      color    = color,
      uv       = {f32(seg) / f32(segments), 0.5},
    }
    v += 1
  }
  // --- Indices ---
  i := 0
  top_start: u32 = 0
  bottom_start := top_hemi_verts
  cyl_start := top_hemi_verts + bottom_hemi_verts
  // Top hemisphere indices
  for ring in 0 ..< sphere_rings {
    for seg in 0 ..< segments {
      a := top_start + ring * (segments + 1) + seg
      b := top_start + (ring + 1) * (segments + 1) + seg
      a1 := top_start + ring * (segments + 1) + (seg + 1)
      b1 := top_start + (ring + 1) * (segments + 1) + (seg + 1)
      p := ret.indices[i:]
      p[0], p[1], p[2], p[3], p[4], p[5] = a, b, a1, b, b1, a1
      i += 6
    }
  }
  // Bottom hemisphere indices
  for ring in 0 ..< sphere_rings {
    for seg in 0 ..< segments {
      a := bottom_start + ring * (segments + 1) + seg
      b := bottom_start + (ring + 1) * (segments + 1) + seg
      a1 := bottom_start + ring * (segments + 1) + (seg + 1)
      b1 := bottom_start + (ring + 1) * (segments + 1) + (seg + 1)
      p := ret.indices[i:]
      p[0], p[1], p[2], p[3], p[4], p[5] = a, a1, b, b, a1, b1
      i += 6
    }
  }
  // Cylinder indices
  for seg in 0 ..< segments {
    a := cyl_start + seg * 2
    b := a + 1
    c := cyl_start + (seg + 1) * 2
    d := c + 1
    p := ret.indices[i:]
    p[0], p[1], p[2], p[3], p[4], p[5] = a, c, b, b, c, d
    i += 6
  }
  ret.aabb = aabb_from_vertices(ret.vertices)
  return
}

make_torus :: proc(
  segments: u32 = 32,
  sides: u32 = 16,
  major_radius: f32 = 1.0,
  minor_radius: f32 = 0.3,
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
) -> (
  ret: Geometry,
) {
  vert_count := (segments + 1) * (sides + 1)
  idx_count := segments * sides * 6
  ret.vertices = make([]Vertex, vert_count)
  ret.indices = make([]u32, idx_count)
  for seg in 0 ..= segments {
    theta := 2.0 * math.PI * f32(seg) / f32(segments)
    cos_theta := math.cos(theta)
    sin_theta := math.sin(theta)
    for side in 0 ..= sides {
      phi := 2.0 * math.PI * f32(side) / f32(sides)
      cos_phi := math.cos(phi)
      sin_phi := math.sin(phi)
      x := (major_radius + minor_radius * cos_phi) * cos_theta
      y := (major_radius + minor_radius * cos_phi) * sin_theta
      z := minor_radius * sin_phi
      idx := seg * (sides + 1) + side
      nx := cos_theta * cos_phi
      ny := sin_theta * cos_phi
      nz := sin_phi
      ret.vertices[idx] = Vertex {
        position = {x, y, z},
        normal   = {nx, ny, nz},
        color    = color,
        uv       = {f32(seg) / f32(segments), f32(side) / f32(sides)},
      }
    }
  }
  i := 0
  for seg in 0 ..< segments {
    for side in 0 ..< sides {
      a := seg * (sides + 1) + side
      b := ((seg + 1) % (segments + 1)) * (sides + 1) + side
      p := ret.indices[i:]
      p[0], p[1], p[2], p[3], p[4], p[5] = a, b, a + 1, b, b + 1, a + 1
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
) -> (
  ret: Geometry,
) {
  // Vertices: (segments+1)*2 for body, 1 center+segments+1 for each cap
  body_verts := (segments + 1) * 2
  cap_verts := (segments + 2) * 2 // +1 for center, +segments+1 for rim (duplicate first for UV seam)
  vert_count := body_verts + cap_verts
  idx_count := segments * 6 + segments * 3 * 2
  ret.vertices = make([]Vertex, vert_count)
  ret.indices = make([]u32, idx_count)
  half_h := height * 0.5
  v: u32 = 0
  // Body vertices (top and bottom rings)
  for i in 0 ..= segments {
    theta := 2.0 * math.PI * f32(i) / f32(segments)
    x := math.cos(theta)
    z := math.sin(theta)
    // Top ring
    ret.vertices[v] = Vertex {
      position = {radius * x, half_h, radius * z},
      normal   = {x, 0, z},
      color    = color,
      uv       = {f32(i) / f32(segments), 0.0},
    }
    v += 1
    // Bottom ring
    ret.vertices[v] = Vertex {
      position = {radius * x, -half_h, radius * z},
      normal   = {x, 0, z},
      color    = color,
      uv       = {f32(i) / f32(segments), 1.0},
    }
    v += 1
  }
  // Top cap center
  top_center := v
  ret.vertices[v] = Vertex {
    position = {0, half_h, 0},
    normal   = {0, 1, 0},
    color    = color,
    uv       = {0.5, 0.5},
  }
  v += 1
  // Top cap rim
  for i in 0 ..= segments {
    theta := 2.0 * math.PI * f32(i) / f32(segments)
    x := math.cos(theta)
    z := math.sin(theta)
    ret.vertices[v] = Vertex {
      position = {radius * x, half_h, radius * z},
      normal   = {0, 1, 0},
      color    = color,
      uv       = {0.5 + 0.5 * x, 0.5 + 0.5 * z},
    }
    v += 1
  }
  // Bottom cap center
  bottom_center := v
  ret.vertices[v] = Vertex {
    position = {0, -half_h, 0},
    normal   = {0, -1, 0},
    color    = color,
    uv       = {0.5, 0.5},
  }
  v += 1
  // Bottom cap rim
  for i in 0 ..= segments {
    theta := 2.0 * math.PI * f32(i) / f32(segments)
    x := math.cos(theta)
    z := math.sin(theta)
    ret.vertices[v] = Vertex {
      position = {radius * x, -half_h, radius * z},
      normal   = {0, -1, 0},
      color    = color,
      uv       = {0.5 + 0.5 * x, 0.5 + 0.5 * z},
    }
    v += 1
  }
  // Indices
  i := 0
  // Body
  for seg in 0 ..< segments {
    a := seg * 2
    b := a + 1
    c := (seg + 1) * 2
    d := c + 1
    p := ret.indices[i:]
    p[0], p[1], p[2], p[3], p[4], p[5] = a, c, b, b, c, d
    i += 6
  }
  top_rim := top_center + 1
  for seg in 0 ..< segments {
    p := ret.indices[i:]
    p[0], p[1], p[2] = top_center, top_rim + seg + 1, top_rim + seg
    i += 3
  }
  bottom_rim := bottom_center + 1
  for seg in 0 ..< segments {
    p := ret.indices[i:]
    p[0], p[1], p[2] = bottom_center, bottom_rim + seg, bottom_rim + seg + 1
    i += 3
  }
  ret.aabb = aabb_from_vertices(ret.vertices)
  return
}

vector_equal :: proc(a, b: [3]f32, epsilon: f32 = 0.0001) -> bool {
    diff := linalg.abs(a - b)
    return diff.x < epsilon && diff.y < epsilon && diff.z < epsilon
}

// Calculate squared distance from point to line segment in 2D (XZ plane)
point_segment_distance2_2d :: proc(p, a, b: [3]f32) -> (dist_sqr: f32, t: f32) {
    ab := b - a
    ap := p - a
    segment_length_sqr := linalg.length2(ab.xz)
    if segment_length_sqr > math.F32_EPSILON {
        t = linalg.saturate(linalg.dot(ap.xz, ab.xz) / segment_length_sqr)
    }
    pt := linalg.mix(a, b, t)
    return linalg.length2((p - pt).xz), t
}

// Find closest point on line segment in 2D (XZ plane)
closest_point_on_segment_2d :: proc "contextless" (p, a, b: [3]f32) -> [3]f32 {
    ab := b - a
    ap := p - a
    segment_length_sqr := linalg.length2(ab.xz)
    if segment_length_sqr  < math.F32_EPSILON {
        return a
    }
    t := linalg.saturate(linalg.dot(ap.xz, ab.xz) / segment_length_sqr)
    return linalg.mix(a, b, t)
}

// Ray-circle intersection test (2D XZ plane)
ray_circle_intersect_2d :: proc "contextless" (pos, vel: [3]f32, radius: f32) -> (t: f32, intersect: bool) {
    a := linalg.length2(vel.xz)
    if a < 1e-6 do return  // No movement
    b := 2.0 * linalg.dot(pos.xz, vel.xz)
    c := linalg.length2(pos.xz) - radius*radius
    discriminant := b*b - 4*a*c
    if discriminant < 0 do return  // No intersection
    sqrt_disc := math.sqrt(discriminant)
    t1 := (-b - sqrt_disc) / (2*a)
    t2 := (-b + sqrt_disc) / (2*a)
    if t1 >= 0 do return t1, true
    if t2 >= 0 do return t2, true
    return
}

// Ray-segment intersection test (2D XZ plane)
ray_segment_intersect_2d :: proc "contextless" (ray_start, ray_dir, seg_start, seg_end: [3]f32) -> (t: f32, intersect: bool) {
    d := seg_end - seg_start
    denominator := linalg.cross(ray_dir.xz, d.xz)
    if math.abs(denominator) < 1e-6 {
        return
    }
    s := ray_start - seg_start
    t = linalg.cross(d.xz, s.xz) / denominator
    u := linalg.cross(ray_dir.xz, s.xz) / denominator
    intersect = t >= 0 && u >= 0 && u <= 1
    return
}

segment_segment_intersect_2d :: proc(p0, p1, a, b: [3]f32) -> bool {
    segment := p1 - p0
    edge := b - a
    denominator := linalg.cross(segment.xz, edge.xz)
    if abs(denominator) < 1e-6 do return false
    ap := p0 - a
    t1 := linalg.cross(edge.xz, ap.xz) / denominator
    t2 := linalg.cross(segment.xz, ap.xz) / denominator
    return t1 >= 0.0 && t1 <= 1.0 && t2 >= 0.0 && t2 <= 1.0
}

// Calculate perpendicular cross product in 2D (XZ plane)
perpendicular_cross_2d :: proc "contextless" (a, b, c: [3]f32) -> f32 {
    return linalg.cross(b.xz - a.xz, c.xz - a.xz)
}

// Check if point is inside triangle in 2D (XZ plane)
point_in_triangle_2d :: proc "contextless" (p, a, b, c: [3]f32, epsilon: f32 = 0.0) -> bool {
    // Use edge testing method - point is inside if it's on the same side of all edges
    cross1 := linalg.cross(b.xz - a.xz, p.xz - a.xz)
    cross2 := linalg.cross(c.xz - b.xz, p.xz - b.xz)
    cross3 := linalg.cross(a.xz - c.xz, p.xz - c.xz)
    // Check if all cross products have the same sign
    return (cross1 >= -epsilon && cross2 >= -epsilon && cross3 >= -epsilon) ||
           (cross1 <= epsilon && cross2 <= epsilon && cross3 <= epsilon)
}

// Calculate barycentric coordinates for a point in a triangle (2D XZ plane)
barycentric_2d :: proc "contextless" (p, a, b, c: [3]f32) -> [3]f32 {
    v0 := b.xz - a.xz
    v1 := c.xz - a.xz
    v2 := p.xz - a.xz
    d00 := linalg.dot(v0, v0)
    d01 := linalg.dot(v0, v1)
    d11 := linalg.dot(v1, v1)
    d20 := linalg.dot(v2, v0)
    d21 := linalg.dot(v2, v1)
    denom := d00 * d11 - d01 * d01
    if math.abs(denom) < math.F32_EPSILON {
        return {1.0/3.0, 1.0/3.0, 1.0/3.0}
    }
    v := (d11 * d20 - d01 * d21) / denom
    w := (d00 * d21 - d01 * d20) / denom
    u := 1.0 - v - w
    return {u, v, w}
}

// Point in polygon test (2D XZ plane)
point_in_polygon_2d :: proc "contextless" (pt: [3]f32, verts: [][3]f32) -> bool {
    c := false
    j := len(verts) - 1
    for i in 0..<len(verts) {
        vi := verts[i]
        vj := verts[j]
        // Use >= for one endpoint to handle edge case where ray passes through vertex
        if ((vi.z > pt.z) != (vj.z >= pt.z)) &&
           (pt.x < (vj.x - vi.x) * (pt.z - vi.z) / (vj.z - vi.z) + vi.x) {
            c = !c
        }
        j = i
    }
    return c
}

// Check if two bounding boxes overlap in 3D
overlap_bounds :: proc "contextless" (amin, amax, bmin, bmax: [3]f32) -> bool {
    return amin.x <= bmax.x && amax.x >= bmin.x &&
           amin.y <= bmax.y && amax.y >= bmin.y &&
           amin.z <= bmax.z && amax.z >= bmin.z
}

// Quantize floating point vector to integer coordinates
quantize_float :: proc "contextless" (v: [3]f32, factor: f32) -> [3]i32 {
    scaled := v * factor + 0.5
    return {i32(math.floor(scaled.x)), i32(math.floor(scaled.y)), i32(math.floor(scaled.z))}
}

// Check if quantized bounds overlap
overlap_quantized_bounds :: proc "contextless" (amin, amax, bmin, bmax: [3]i32) -> bool {
    return amin.x <= bmax.x && amax.x >= bmin.x &&
           amin.y <= bmax.y && amax.y >= bmin.y &&
           amin.z <= bmax.z && amax.z >= bmin.z
}

// Calculate triangle normal
calc_tri_normal :: proc(v0, v1, v2: [3]f32) -> (norm: [3]f32) {
    e0 := v1 - v0
    e1 := v2 - v0
    norm = linalg.cross(e0, e1)
    norm = linalg.normalize(norm)
    return
}

// Calculate signed area of triangle formed by three 2D points
// Positive area = counter-clockwise, negative = clockwise
// This is the 2D cross product of vectors (b-a) and (c-a)
area2 :: proc "contextless" (a, b, c: [2]i32) -> i32 {
    return linalg.cross(b - a, c - a)
}

// Check if point c is to the left or on the directed line from a to b
left_on :: proc "contextless" (a, b, c: [2]i32) -> bool {
    return area2(a, b, c) <= 0
}

// Check if point p is inside the cone formed by three consecutive vertices a0, a1, a2
// a1 is the apex of the cone
in_cone :: proc "contextless" (a0, a1, a2, p: [2]i32) -> bool {
    // If a1 is a convex vertex (a2 is left or on the line from a0 to a1)
    if left_on(a0, a1, a2) {
        // p must be left of a1->p->a0 AND left of p->a1->a2
        return left(a1, p, a0) && left(p, a1, a2)
    }
    // else a1 is reflex
    // p must NOT be (left-or-on a1->p->a2 AND left-or-on p->a1->a0)
    return !(left_on(a1, p, a2) && left_on(p, a1, a0))
}

// Check if point c is to the left of the directed line from a to b
left :: proc "contextless" (a, b, c: [2]i32) -> bool {
    return area2(a, b, c) < 0
}

// Check if point p lies on the line segment from a to b
between :: proc "contextless" (a, b, p: [2]i32) -> bool {
    if area2(a, b, p) != 0 {
        return false // Not collinear
    }
    // If ab not vertical, check betweenness on x; else on y
    if a.x != b.x {
        return ((a.x <= p.x) && (p.x <= b.x)) || ((a.x >= p.x) && (p.x >= b.x))
    } else {
        return ((a.y <= p.y) && (p.y <= b.y)) || ((a.y >= p.y) && (p.y >= b.y))
    }
}

// Check if line segments ab and cd intersect properly (at a point interior to both segments)
intersect_prop :: proc "contextless" (a, b, c, d: [2]i32) -> bool {
    // Eliminate improper cases (endpoints touching)
    if area2(a, b, c) == 0 ||
       area2(a, b, d) == 0 ||
       area2(c, d, a) == 0 ||
       area2(c, d, b) == 0 {
        return false
    }
    // Check if c and d are on opposite sides of ab, and a and b are on opposite sides of cd
    return (left(a, b, c) != left(a, b, d)) &&
           (left(c, d, a) != left(c, d, b))
}

// Check if line segments ab and cd intersect (properly or improperly)
intersect :: proc "contextless" (a, b, c, d: [2]i32) -> bool {
    if intersect_prop(a, b, c, d) {
        return true
    }
    // Check if any endpoint lies on the other segment
    return between(a, b, c) ||
           between(a, b, d) ||
           between(c, d, a) ||
           between(c, d, b)
}

// Direction utilities

// Get next direction in clockwise order (0=+X, 1=+Z, 2=-X, 3=-Z)
next_dir :: proc "contextless" (dir: int) -> int {
    return (dir + 1) & 0x3
}

// Get previous direction in clockwise order
prev_dir :: proc "contextless" (dir: int) -> int {
    return (dir + 3) & 0x3
}

// Calculate area of triangle in 2D (XZ plane)
signed_triangle_area_2d :: proc "contextless" (a, b, c: [3]f32) -> f32 {
    return linalg.cross(b.xz - a.xz, c.xz - a.xz) * 0.5
}

// Calculate area of triangle in 2D (XZ plane)
triangle_area_2d :: proc "contextless" (a, b, c: [3]f32) -> f32 {
    return math.abs(signed_triangle_area_2d(a, b, c))
}

// Intersection test between ray/segment and triangle
intersect_segment_triangle :: proc "contextless" (sp, sq: [3]f32, a, b, c: [3]f32) -> (hit: bool, t: f32) {
    ab := b - a
    ac := c - a
    qp := sp - sq
    // Compute triangle normal
    norm := linalg.cross(ab, ac)
    // Compute denominator
    d := linalg.dot(qp, norm)
    if math.abs(d) < math.F32_EPSILON {
        return false, 0
    }
    // Compute intersection t value
    ap := sp - a
    t = linalg.dot(ap, norm) / d
    if t < 0 || t > 1 {
        return false, 0
    }
    // Compute barycentric coordinates
    e := linalg.cross(qp, ap)
    v := linalg.dot(ac, e) / d
    if v < 0 || v > 1 {
        return false, 0
    }
    w := -linalg.dot(ab, e) / d
    if w < 0 || v + w > 1 {
        return false, 0
    }
    return true, t
}

// Find closest point on triangle in 3D
closest_point_on_triangle :: proc "contextless" (p, a, b, c: [3]f32) -> [3]f32 {
    // Check if P in vertex region outside A
    ab := b - a
    ac := c - a
    ap := p - a
    d1 := linalg.dot(ab, ap)
    d2 := linalg.dot(ac, ap)
    if d1 <= 0 && d2 <= 0 {
        return a
    }
    // Check if P in vertex region outside B
    bp := p - b
    d3 := linalg.dot(ab, bp)
    d4 := linalg.dot(ac, bp)
    if d3 >= 0 && d4 <= d3 {
        return b
    }
    // Check if P in edge region of AB
    vc := d1*d4 - d3*d2
    if vc <= 0 && d1 >= 0 && d3 <= 0 {
        v := d1 / (d1 - d3)
        return a + v * ab
    }
    // Check if P in vertex region outside C
    cp := p - c
    d5 := linalg.dot(ab, cp)
    d6 := linalg.dot(ac, cp)
    if d6 >= 0 && d5 <= d6 {
        return c
    }
    // Check if P in edge region of AC
    vb := d5*d2 - d1*d6
    if vb <= 0 && d2 >= 0 && d6 <= 0 {
        w := d2 / (d2 - d6)
        return a + w * ac
    }
    // Check if P in edge region of BC
    va := d3*d6 - d5*d4
    if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
        w := (d4 - d3) / ((d4 - d3) + (d5 - d6))
        return b + w * (c - b)
    }
    // P inside face region
    denom := 1 / (va + vb + vc)
    v := vb * denom
    w := vc * denom
    return a + ab * v + ac * w
}

// Calculate polygon normal using Newell's method
calc_poly_normal :: proc "contextless" (verts: [][3]f32) -> [3]f32 {
    normal := [3]f32{0, 0, 0}
    for i in 0..<len(verts) {
        v0 := verts[i]
        v1 := verts[(i + 1) % len(verts)]
        normal.x += (v0.y - v1.y) * (v0.z + v1.z)
        normal.y += (v0.z - v1.z) * (v0.x + v1.x)
        normal.z += (v0.x - v1.x) * (v0.y + v1.y)
    }
    // Normalize the result
    if linalg.length2(normal) > math.F32_EPSILON * math.F32_EPSILON {
        normal = linalg.normalize(normal)
    }
    return normal
}

// Calculate polygon area using cross products (2D XZ plane)
poly_area_2d :: proc "contextless" (verts: [][3]f32) -> f32 {
    area: f32 = 0
    for i in 0..<len(verts) {
        a := verts[i].xz
        b := verts[(i + 1) % len(verts)].xz
        area += linalg.cross(a, b)
    }
    return area * 0.5
}

// Check if two line segments intersect in 2D (XZ plane)
intersect_segments_2d :: proc "contextless" (ap, aq, bp, bq: [3]f32) -> (hit: bool, s: f32, t: f32) {
    a_dir := aq.xz - ap.xz
    b_dir := bq.xz - bp.xz
    diff  := bp.xz - ap.xz
    cross := linalg.cross(a_dir, b_dir)
    if math.abs(cross) < math.F32_EPSILON {
        return false, 0, 0
    }
    s = linalg.cross(diff, b_dir) / cross
    t = linalg.cross(diff, a_dir) / cross
    return s >= 0 && s <= 1 && t >= 0 && t <= 1, s, t
}

// Check if circle overlaps with line segment (2D XZ plane)
overlap_circle_segment :: proc(center: [3]f32, radius: f32, p, q: [3]f32) -> bool {
    dist_sqr, _ := point_segment_distance2_2d(center, p, q)
    return dist_sqr <= radius*radius
}

// Next power of two
next_pow2 :: proc "contextless" (v: u32) -> u32 {
    val := v
    val -= 1
    val |= val >> 1
    val |= val >> 2
    val |= val >> 4
    val |= val >> 8
    val |= val >> 16
    val += 1
    return val
}

// Integer log base 2
ilog2 :: proc "contextless" (v: u32) -> u32 {
    val := v
    r: u32 = 0
    shift: u32
    shift = u32(val > 0xffff) << 4
    val >>= shift
    r |= shift
    shift = u32(val > 0xff) << 3
    val >>= shift
    r |= shift
    shift = u32(val > 0xf) << 2
    val >>= shift
    r |= shift
    shift = u32(val > 0x3) << 1
    val >>= shift
    r |= shift
    r |= val >> 1
    return r
}

// Align value to given alignment
align :: proc "contextless" (value, alignment: int) -> int {
    return (value + alignment - 1) & ~(alignment - 1)
}

// Check if two bounding boxes overlap in 2D (XZ plane)
overlap_bounds_2d :: proc "contextless" (amin, amax, bmin, bmax: [3]f32) -> bool {
    return amin.x <= bmax.x && amax.x >= bmin.x &&
           amin.z <= bmax.z && amax.z >= bmin.z
}

// Calculate circumcircle of a triangle
// Returns center and radius squared
// Based on C++ circumCircle from RecastMeshDetail.cpp
circum_circle :: proc "contextless" (a, b, c: [3]f32) -> (center: [2]f32, r_sq: f32, valid: bool) {
    EPS :: 1e-6
    ab := b - a
    ac := c - a
    cross := linalg.cross(ac.xz, ab.xz)
    if abs(cross) < EPS {
        valid = false
        return
    }
    len_ab_sq := linalg.length2(ab.xz)
    len_ac_sq := linalg.length2(ac.xz)
    inv_cross := 1.0 / (2.0 * cross)
    ux := (ac.z * len_ab_sq - ab.z * len_ac_sq) * inv_cross
    uy := (ab.x * len_ac_sq - ac.x * len_ab_sq) * inv_cross
    center.x = a.x + ux
    center.y = a.z + uy
    r_sq = ux * ux + uy * uy
    valid = true
    return
}

// Check if a point is inside the circumcircle of a triangle
in_circumcircle :: proc "contextless" (p, a, b, c: [3]f32) -> bool {
    center, r_sq := circum_circle(a, b, c) or_return
    return linalg.length2(p.xz - center) <= r_sq
}

// Distance squared from point to line segment in 3D
// Returns the squared distance for performance
point_segment_distance_sq :: proc "contextless" (pt, va, vb: [3]f32) -> f32 {
    segment := vb - va
    to_pt := pt - va
    segment_length_sq := linalg.length2(segment)
    if segment_length_sq < math.F32_EPSILON {
        return linalg.length2(to_pt)
    }
    // Project point onto segment
    t := linalg.saturate(linalg.dot(to_pt, segment) / segment_length_sq)
    closest := va + segment * t
    return linalg.length2(pt - closest)
}

// Distance from point to line segment in 3D
point_segment_distance :: proc "contextless" (pt, va, vb: [3]f32) -> f32 {
    return math.sqrt(point_segment_distance_sq(pt, va, vb))
}

// Distance from point to polygon boundary with inside/outside test
// Returns negative distance if point is inside, positive if outside
// Based on C++ distToPoly from RecastMeshDetail.cpp
point_polygon_distance :: proc(pt: [3]f32, vertices: [][3]f32) -> f32 {
    if len(vertices) < 3 do return math.F32_MAX
    min_dist_sq := f32(math.F32_MAX)
    inside := false
    for i in 0..<len(vertices) {
        j := (i + len(vertices) - 1) % len(vertices)
        vi := vertices[i]
        vj := vertices[j]
        // Point-in-polygon test using ray casting (XZ plane)
        if ((vi.z > pt.z) != (vj.z > pt.z)) &&
           (pt.x < (vj.x - vi.x) * (pt.z - vi.z) / (vj.z - vi.z) + vi.x) {
            inside = !inside
        }
        // Find minimum distance to edge
        dist_sq, _ := point_segment_distance2_2d(pt, vi, vj)
        min_dist_sq = min(min_dist_sq, dist_sq)
    }
    min_dist := math.sqrt(min_dist_sq)
    return inside ? -min_dist : min_dist
}

// Distance from point to triangle mesh
// Based on C++ distToTriMesh from RecastMeshDetail.cpp
point_triangle_mesh_distance :: proc(p: [3]f32, verts: [][3]f32, tris: [][3]u8) -> f32 {
    min_dist := f32(math.F32_MAX)
    for tri in tris {
        va := verts[tri[0]]
        vb := verts[tri[1]]
        vc := verts[tri[2]]
        // Project point onto triangle plane
        n := linalg.cross(vb - va, vc - va)
        if linalg.length2(n) < math.F32_EPSILON do continue
        n = linalg.normalize(n)
        plane_dist := linalg.dot(p - va, n)
        projected := p - n * plane_dist
        // Check if projected point is inside triangle using barycentric coordinates
        v0 := vc - va
        v1 := vb - va
        v2 := projected - va
        dot00 := linalg.dot(v0, v0)
        dot01 := linalg.dot(v0, v1)
        dot02 := linalg.dot(v0, v2)
        dot11 := linalg.dot(v1, v1)
        dot12 := linalg.dot(v1, v2)
        denom := dot00 * dot11 - dot01 * dot01
        if abs(denom) < math.F32_EPSILON do continue
        inv_denom := 1.0 / denom
        u := (dot11 * dot02 - dot01 * dot12) * inv_denom
        v := (dot00 * dot12 - dot01 * dot02) * inv_denom
        if (u >= 0) && (v >= 0) && (u + v <= 1) {
            return abs(plane_dist)
        }
        // Point is outside triangle, find distance to edges
        d0 := point_segment_distance(p, va, vb)
        d1 := point_segment_distance(p, vb, vc)
        d2 := point_segment_distance(p, vc, va)
        min_dist = min(min_dist, d0, d1, d2)
    }
    return min_dist
}

safe_normalize :: proc(v: ^[3]f32) {
    sq_mag := v.x * v.x + v.y * v.y + v.z * v.z
    if sq_mag <= math.F32_EPSILON do return
    inv_mag := 1.0 / math.sqrt(sq_mag)
    v.x *= inv_mag
    v.y *= inv_mag
    v.z *= inv_mag
}

// Offset polygon - creates an inset/outset polygon with proper miter/bevel handling
// Returns the offset vertices and success status
offset_poly_2d :: proc(verts: [][3]f32, offset: f32) -> (out_verts: [dynamic][3]f32, ok: bool) {
    // Defines the limit at which a miter becomes a bevel
    // Similar in behavior to https://developer.mozilla.org/en-US/docs/Web/SVG/Attribute/stroke-miterlimit
    MITER_LIMIT :: 1.20
    num_verts := len(verts)
    if num_verts < 3 do return nil, false
    // First pass: calculate how many vertices we'll need
    estimated_verts := num_verts * 2  // Conservative estimate for beveling
    out_verts = make([dynamic][3]f32, 0, estimated_verts)
    for vert_index in 0..<num_verts {
        // Grab three vertices of the polygon
        vert_index_a := (vert_index + num_verts - 1) % num_verts
        vert_index_b := vert_index
        vert_index_c := (vert_index + 1) % num_verts
        vert_a := verts[vert_index_a]
        vert_b := verts[vert_index_b]
        vert_c := verts[vert_index_c]
        // From A to B on the x/z plane
        prev_segment_dir: [3]f32
        prev_segment_dir.x = vert_b.x - vert_a.x
        prev_segment_dir.y = 0 // Squash onto x/z plane
        prev_segment_dir.z = vert_b.z - vert_a.z
        safe_normalize(&prev_segment_dir)
        // From B to C on the x/z plane
        curr_segment_dir: [3]f32
        curr_segment_dir.x = vert_c.x - vert_b.x
        curr_segment_dir.y = 0 // Squash onto x/z plane
        curr_segment_dir.z = vert_c.z - vert_b.z
        safe_normalize(&curr_segment_dir)
        // The y component of the cross product of the two normalized segment directions
        // The X and Z components of the cross product are both zero because the two
        // segment direction vectors fall within the x/z plane
        cross := linalg.cross(curr_segment_dir.xz, prev_segment_dir.xz)
        // CCW perpendicular vector to AB. The segment normal
        prev_segment_norm_x := -prev_segment_dir.z
        prev_segment_norm_z := prev_segment_dir.x
        // CCW perpendicular vector to BC. The segment normal
        curr_segment_norm_x := -curr_segment_dir.z
        curr_segment_norm_z := curr_segment_dir.x
        // Average the two segment normals to get the proportional miter offset for B
        // This isn't normalized because it's defining the distance and direction the corner will need to be
        // adjusted proportionally to the edge offsets to properly miter the adjoining edges
        corner_miter_x := (prev_segment_norm_x + curr_segment_norm_x) * 0.5
        corner_miter_z := (prev_segment_norm_z + curr_segment_norm_z) * 0.5
        corner_miter_sq_mag := corner_miter_x * corner_miter_x + corner_miter_z * corner_miter_z
        // If the magnitude of the segment normal average is less than about .69444,
        // the corner is an acute enough angle that the result should be beveled
        bevel := corner_miter_sq_mag * MITER_LIMIT * MITER_LIMIT < 1.0
        // Scale the corner miter so it's proportional to how much the corner should be offset compared to the edges
        if corner_miter_sq_mag > math.F32_EPSILON {
            scale := 1.0 / corner_miter_sq_mag
            corner_miter_x *= scale
            corner_miter_z *= scale
        }
        if bevel && cross < 0.0 { // If the corner is convex and an acute enough angle, generate a bevel
            // Generate two bevel vertices at distances from B proportional to the angle between the two segments
            // Move each bevel vertex out proportional to the given offset
            d := (1.0 - (prev_segment_dir.x * curr_segment_dir.x + prev_segment_dir.z * curr_segment_dir.z)) * 0.5
            append(&out_verts, [3]f32{
                vert_b.x + (-prev_segment_norm_x + prev_segment_dir.x * d) * offset,
                vert_b.y,
                vert_b.z + (-prev_segment_norm_z + prev_segment_dir.z * d) * offset,
            })
            append(&out_verts, [3]f32{
                vert_b.x + (-curr_segment_norm_x - curr_segment_dir.x * d) * offset,
                vert_b.y,
                vert_b.z + (-curr_segment_norm_z - curr_segment_dir.z * d) * offset,
            })
        } else {
            // Move B along the miter direction by the specified offset
            append(&out_verts, [3]f32{
                vert_b.x - corner_miter_x * offset,
                vert_b.y,
                vert_b.z - corner_miter_z * offset,
            })
        }
    }
    // Allocate final output with the exact size needed
    if len(out_verts) == 0 {
        delete(out_verts)
        return nil, false
    }
    return out_verts, true
}
