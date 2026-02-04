package geometry

import "core:math"
import "core:math/linalg"
import "core:math/rand"

Geometry :: struct {
  vertices:  []Vertex,
  skinnings: []SkinningData,
  indices:   []u32,
  aabb:      Aabb,
}

Triangle :: struct {
  v0, v1, v2: [3]f32,
}

Sphere :: struct {
  center: [3]f32,
  radius: f32,
}

Disc :: struct {
  center: [3]f32,
  normal: [3]f32,
  radius: f32,
}

triangle_bounds :: proc "contextless" (tri: Triangle) -> Aabb {
  return Aabb {
    min = linalg.min(tri.v0, tri.v1, tri.v2),
    max = linalg.max(tri.v0, tri.v1, tri.v2),
  }
}

sphere_bounds :: proc "contextless" (sphere: Sphere) -> Aabb {
  return Aabb {
    min = sphere.center - sphere.radius,
    max = sphere.center + sphere.radius,
  }
}

disc_bounds :: proc "contextless" (disc: Disc) -> Aabb {
  tan1, tan2 := [3]f32{}, [3]f32{}
  if math.abs(disc.normal.y) > 0.9 {
    tan1 = linalg.normalize(
      linalg.cross(disc.normal, linalg.VECTOR3F32_X_AXIS),
    )
  } else {
    tan1 = linalg.normalize(
      linalg.cross(disc.normal, linalg.VECTOR3F32_Y_AXIS),
    )
  }
  tan2 = linalg.cross(disc.normal, tan1)
  ext1 := tan1 * disc.radius
  ext2 := tan2 * disc.radius
  p1 := disc.center + ext1
  p2 := disc.center - ext1
  p3 := disc.center + ext2
  p4 := disc.center - ext2
  min := linalg.min(linalg.min(p1, p2), linalg.min(p3, p4))
  max := linalg.max(linalg.max(p1, p2), linalg.max(p3, p4))
  return Aabb{min = min, max = max}
}

ray_triangle_intersection :: proc "contextless" (
  ray: Ray,
  tri: Triangle,
  max_t: f32 = F32_MAX,
) -> (
  hit: bool,
  t: f32,
) {
  epsilon :: 1e-6
  edge1 := tri.v1 - tri.v0
  edge2 := tri.v2 - tri.v0
  h := linalg.cross(ray.direction, edge2)
  a := linalg.dot(edge1, h)
  if a > -epsilon && a < epsilon {
    return false, 0
  }
  f := 1.0 / a
  s := ray.origin - tri.v0
  u := f * linalg.dot(s, h)
  if u < 0.0 || u > 1.0 {
    return false, 0
  }
  q := linalg.cross(s, edge1)
  v := f * linalg.dot(ray.direction, q)
  if v < 0.0 || u + v > 1.0 {
    return false, 0
  }
  t = f * linalg.dot(edge2, q)
  if t > epsilon && t < max_t {
    return true, t
  }
  return false, 0
}

ray_sphere_intersection :: proc "contextless" (
  ray: Ray,
  sphere: Sphere,
  max_t: f32 = F32_MAX,
) -> (
  hit: bool,
  t: f32,
) {
  oc := ray.origin - sphere.center
  a := linalg.dot(ray.direction, ray.direction)
  half_b := linalg.dot(oc, ray.direction)
  c := linalg.dot(oc, oc) - sphere.radius * sphere.radius
  discriminant := half_b * half_b - a * c
  if discriminant < 0 {
    return false, 0
  }
  sqrtd := math.sqrt(discriminant)
  root := (-half_b - sqrtd) / a
  if root < 0.001 || root > max_t {
    root = (-half_b + sqrtd) / a
    if root < 0.001 || root > max_t {
      return false, 0
    }
  }
  return true, root
}

PrimitiveType :: enum {
  Triangle,
  Sphere,
}

Primitive :: struct {
  type: PrimitiveType,
  data: union {
    Triangle,
    Sphere,
  },
}

primitive_bounds :: proc(prim: Primitive) -> Aabb {
  switch p in prim.data {
  case Triangle:
    return triangle_bounds(p)
  case Sphere:
    return sphere_bounds(p)
  }
  return AABB_UNDEFINED
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

make_cube :: proc(color: [4]f32 = {1.0, 1.0, 1.0, 1.0}, random_colors: bool = false) -> (ret: Geometry) {
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
  #unroll for face in 0 ..< 6 {
    i := u32(face * 4)
    p := ret.indices[face * 6:]
    p[0], p[1], p[2], p[3], p[4], p[5] = i, i + 1, i + 2, i + 2, i + 3, i
  }
  ret.aabb = {
    min = {-1, -1, -1},
    max = {1, 1, 1},
  }
  if random_colors {
    for &v in ret.vertices {
      v.color = {rand.float32(), rand.float32(), rand.float32(), color.w}
    }
  }
  return
}

make_triangle :: proc(
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
  random_colors: bool = false,
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
  if random_colors {
    for &v in ret.vertices {
      v.color = {rand.float32(), rand.float32(), rand.float32(), color.w}
    }
  }
  return
}

// Quad (on XZ plane, facing Y up)
make_quad :: proc(color: [4]f32 = {1.0, 1.0, 1.0, 1.0}, random_colors: bool = false) -> (ret: Geometry) {
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
  if random_colors {
    for &v in ret.vertices {
      v.color = {rand.float32(), rand.float32(), rand.float32(), color.w}
    }
  }
  return
}

make_sphere :: proc(
  segments: u32 = 16,
  rings: u32 = 16,
  radius: f32 = 1.0,
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
  random_colors: bool = false,
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
  if random_colors {
    for &v in ret.vertices {
      v.color = {rand.float32(), rand.float32(), rand.float32(), color.w}
    }
  }
  return
}

make_cone :: proc(
  segments: u32 = 32,
  height: f32 = 2.0,
  radius: f32 = 1.0,
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
  random_colors: bool = false,
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
  if random_colors {
    for &v in ret.vertices {
      v.color = {rand.float32(), rand.float32(), rand.float32(), color.w}
    }
  }
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
  // Counter-clockwise winding
  ret.indices[0] = 0
  ret.indices[1] = 1
  ret.indices[2] = 2
  ret.aabb = aabb_from_vertices(ret.vertices)
  return
}

make_capsule :: proc(
  segments: u32 = 16,
  rings: u32 = 8,
  height: f32 = 2.0,
  radius: f32 = 0.5,
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
  random_colors: bool = false,
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
  if random_colors {
    for &v in ret.vertices {
      v.color = {rand.float32(), rand.float32(), rand.float32(), color.w}
    }
  }
  return
}

make_torus :: proc(
  segments: u32 = 32,
  sides: u32 = 16,
  major_radius: f32 = 1.0,
  minor_radius: f32 = 0.3,
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
  random_colors: bool = false,
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
  if random_colors {
    for &v in ret.vertices {
      v.color = {rand.float32(), rand.float32(), rand.float32(), color.w}
    }
  }
  return
}

make_cylinder :: proc(
  segments: u32 = 32,
  height: f32 = 2.0,
  radius: f32 = 1.0,
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
  random_colors: bool = false,
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
  if random_colors {
    for &v in ret.vertices {
      v.color = {rand.float32(), rand.float32(), rand.float32(), color.w}
    }
  }
  return
}
