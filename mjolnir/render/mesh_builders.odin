package render

import "../geometry"
import "core:math"
import "core:math/linalg"

// make_cube builds a 2x2x2 cube centered at the origin with per-face normals.
make_cube :: proc(
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
) -> Geometry {
  vertices := make([]Vertex, 24)
  indices := make([]u32, 36)
  vertices[0] = {{-1, -1, 1}, geometry.VEC_FORWARD, color, {0, 1}, {}}
  vertices[1] = {{1, -1, 1}, geometry.VEC_FORWARD, color, {1, 1}, {}}
  vertices[2] = {{1, 1, 1}, geometry.VEC_FORWARD, color, {1, 0}, {}}
  vertices[3] = {{-1, 1, 1}, geometry.VEC_FORWARD, color, {0, 0}, {}}
  vertices[4] = {{-1, 1, -1}, geometry.VEC_BACKWARD, color, {1, 1}, {}}
  vertices[5] = {{1, 1, -1}, geometry.VEC_BACKWARD, color, {0, 1}, {}}
  vertices[6] = {{1, -1, -1}, geometry.VEC_BACKWARD, color, {0, 0}, {}}
  vertices[7] = {{-1, -1, -1}, geometry.VEC_BACKWARD, color, {1, 0}, {}}
  vertices[8] = {{1, 1, -1}, geometry.VEC_UP, color, {0, 1}, {}}
  vertices[9] = {{-1, 1, -1}, geometry.VEC_UP, color, {1, 1}, {}}
  vertices[10] = {{-1, 1, 1}, geometry.VEC_UP, color, {1, 0}, {}}
  vertices[11] = {{1, 1, 1}, geometry.VEC_UP, color, {0, 0}, {}}
  vertices[12] = {{1, -1, 1}, geometry.VEC_DOWN, color, {0, 1}, {}}
  vertices[13] = {{-1, -1, 1}, geometry.VEC_DOWN, color, {1, 1}, {}}
  vertices[14] = {{-1, -1, -1}, geometry.VEC_DOWN, color, {1, 0}, {}}
  vertices[15] = {{1, -1, -1}, geometry.VEC_DOWN, color, {0, 0}, {}}
  vertices[16] = {{1, -1, -1}, geometry.VEC_RIGHT, color, {0, 1}, {}}
  vertices[17] = {{1, 1, -1}, geometry.VEC_RIGHT, color, {1, 1}, {}}
  vertices[18] = {{1, 1, 1}, geometry.VEC_RIGHT, color, {1, 0}, {}}
  vertices[19] = {{1, -1, 1}, geometry.VEC_RIGHT, color, {0, 0}, {}}
  vertices[20] = {{-1, -1, 1}, geometry.VEC_LEFT, color, {0, 1}, {}}
  vertices[21] = {{-1, 1, 1}, geometry.VEC_LEFT, color, {1, 1}, {}}
  vertices[22] = {{-1, 1, -1}, geometry.VEC_LEFT, color, {1, 0}, {}}
  vertices[23] = {{-1, -1, -1}, geometry.VEC_LEFT, color, {0, 0}, {}}
  #unroll for face in 0 ..< 6 {
    i := u32(face * 4)
    p := indices[face * 6:]
    p[0], p[1], p[2], p[3], p[4], p[5] = i, i + 1, i + 2, i + 2, i + 3, i
  }
  return geometry_create(vertices, indices)
}

// make_quad builds a quad on the XZ plane facing +Y.
make_quad :: proc(
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
) -> Geometry {
  vertices := make([]Vertex, 4)
  indices := make([]u32, 6)
  vertices[0] = {{-1, 0, -1}, geometry.VEC_UP, color, {0, 0}, {}}
  vertices[1] = {{-1, 0, 1}, geometry.VEC_UP, color, {0, 1}, {}}
  vertices[2] = {{1, 0, 1}, geometry.VEC_UP, color, {1, 1}, {}}
  vertices[3] = {{1, 0, -1}, geometry.VEC_UP, color, {1, 0}, {}}
  indices[0], indices[1], indices[2] = 0, 1, 2
  indices[3], indices[4], indices[5] = 2, 3, 0
  return geometry_create(vertices, indices)
}

// make_billboard_quad builds a quad on the XY plane facing +Z, for camera-facing sprites.
make_billboard_quad :: proc(
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
) -> Geometry {
  vertices := make([]Vertex, 4)
  indices := make([]u32, 6)
  vertices[0] = {{-1, -1, 0}, geometry.VEC_FORWARD, color, {0, 1}, {}}
  vertices[1] = {{1, -1, 0}, geometry.VEC_FORWARD, color, {1, 1}, {}}
  vertices[2] = {{1, 1, 0}, geometry.VEC_FORWARD, color, {1, 0}, {}}
  vertices[3] = {{-1, 1, 0}, geometry.VEC_FORWARD, color, {0, 0}, {}}
  indices[0], indices[1], indices[2] = 0, 1, 2
  indices[3], indices[4], indices[5] = 2, 3, 0
  return geometry_create(vertices, indices)
}

// make_sphere builds a UV sphere of the given radius centered at the origin.
make_sphere :: proc(
  segments: u32 = 16,
  rings: u32 = 16,
  radius: f32 = 1.0,
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
) -> Geometry {
  vert_count := (rings + 1) * (segments + 1)
  idx_count := rings * segments * 6
  vertices := make([]Vertex, vert_count)
  indices := make([]u32, idx_count)
  for ring in 0 ..= rings {
    phi := math.PI * f32(ring) / f32(rings)
    y := math.cos(phi)
    r := math.sin(phi)
    for seg in 0 ..= segments {
      theta := 2.0 * math.PI * f32(seg) / f32(segments)
      x := r * math.cos(theta)
      z := r * math.sin(theta)
      idx := ring * (segments + 1) + seg
      vertices[idx] = Vertex {
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
      p := indices[i:]
      p[0], p[1], p[2], p[3], p[4], p[5] = a, a + 1, b, b, a + 1, b + 1
      i += 6
    }
  }
  return geometry_create(vertices, indices)
}

// make_cone builds a cone along Y with a capped base and its tip at +height/2.
make_cone :: proc(
  segments: u32 = 32,
  height: f32 = 2.0,
  radius: f32 = 1.0,
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
) -> Geometry {
  vert_count := segments + 3
  idx_count := segments * 6
  vertices := make([]Vertex, vert_count)
  indices := make([]u32, idx_count)
  vertices[0] = Vertex {
    position = {0, height / 2, 0},
    normal   = {0, 1, 0},
    color    = color,
    uv       = {0.5, 1.0},
  }
  vertices[1] = Vertex {
    position = {0, -height / 2, 0},
    normal   = {0, -1, 0},
    color    = color,
    uv       = {0.5, 0.0},
  }
  for i in 0 ..= segments {
    theta := 2.0 * math.PI * f32(i) / f32(segments)
    x := radius * math.cos(theta)
    z := radius * math.sin(theta)
      side_normal := linalg.normalize([3]f32{x, radius / height, z})
    vertices[2 + i] = Vertex {
      position = {x, -height / 2, z},
      normal   = side_normal,
      color    = color,
      uv       = {0.5 + 0.5 * math.cos(theta), 0.5 + 0.5 * math.sin(theta)},
    }
  }
  idx := 0
  for i in 0 ..< segments {
    next := 2 + ((i + 1) % (segments + 1))
    p := indices[idx:]
    p[0], p[1], p[2] = 0, next, 2 + i
    idx += 3
  }
  for i in 0 ..< segments {
    next := 2 + ((i + 1) % (segments + 1))
    p := indices[idx:]
    p[0], p[1], p[2] = 1, 2 + i, next
    idx += 3
  }
  return geometry_create(vertices, indices)
}

// make_capsule builds a capsule along Y: two hemispheres joined by a cylinder.
// V runs from 0 at the top pole to 1 at the bottom pole.
make_capsule :: proc(
  segments: u32 = 16,
  rings: u32 = 8,
  height: f32 = 2.0,
  radius: f32 = 0.5,
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
) -> Geometry {
  half_cyl := height * 0.5 - radius
  hemi_verts := (rings + 1) * (segments + 1)
  vertices := make([]Vertex, 2 * hemi_verts + 2 * (segments + 1))
  indices := make([]u32, (2 * rings + 1) * segments * 6)
  v: u32 = 0
  i := 0
  // Hemispheres: ring 0 is the equator, ring `rings` the pole
  for sign in ([2]f32{1, -1}) {
    start := v
    for ring in 0 ..= rings {
      t := f32(ring) / f32(rings)
      phi := (math.PI / 2.0) * t
      y := sign * math.sin(phi)
      r := math.cos(phi)
      for seg in 0 ..= segments {
        theta := 2.0 * math.PI * f32(seg) / f32(segments)
        x := r * math.cos(theta)
        z := r * math.sin(theta)
        vertices[v] = Vertex {
          position = {radius * x, sign * half_cyl + radius * y, radius * z},
          normal   = {x, y, z},
          color    = color,
          uv       = {f32(seg) / f32(segments), 0.5 - sign * (0.25 + 0.25 * t)},
        }
        v += 1
      }
    }
    for ring in 0 ..< rings {
      for seg in 0 ..< segments {
        a := start + ring * (segments + 1) + seg
        b := a + segments + 1
        p := indices[i:]
        if sign > 0 {
          p[0], p[1], p[2], p[3], p[4], p[5] = a, b, a + 1, b, b + 1, a + 1
        } else {
          p[0], p[1], p[2], p[3], p[4], p[5] = a, a + 1, b, b, a + 1, b + 1
        }
        i += 6
      }
    }
  }
  // Cylinder sides: top and bottom ring interleaved
  cyl_start := v
  for seg in 0 ..= segments {
    theta := 2.0 * math.PI * f32(seg) / f32(segments)
    x := math.cos(theta)
    z := math.sin(theta)
    u := f32(seg) / f32(segments)
    vertices[v] = {{radius * x, half_cyl, radius * z}, {x, 0, z}, color, {u, 0.25}, {}}
    vertices[v + 1] = {{radius * x, -half_cyl, radius * z}, {x, 0, z}, color, {u, 0.75}, {}}
    v += 2
  }
  for seg in 0 ..< segments {
    a := cyl_start + seg * 2
    b := a + 1
    c := a + 2
    d := a + 3
    p := indices[i:]
    p[0], p[1], p[2], p[3], p[4], p[5] = a, c, b, b, c, d
    i += 6
  }
  return geometry_create(vertices, indices)
}

// make_torus builds a torus in the XY plane, around the Z axis.
make_torus :: proc(
  segments: u32 = 32,
  sides: u32 = 16,
  major_radius: f32 = 1.0,
  minor_radius: f32 = 0.3,
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
) -> Geometry {
  vert_count := (segments + 1) * (sides + 1)
  idx_count := segments * sides * 6
  vertices := make([]Vertex, vert_count)
  indices := make([]u32, idx_count)
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
      vertices[idx] = Vertex {
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
      p := indices[i:]
      p[0], p[1], p[2], p[3], p[4], p[5] = a, b, a + 1, b, b + 1, a + 1
      i += 6
    }
  }
  return geometry_create(vertices, indices)
}

// make_cylinder builds a capped cylinder along Y centered at the origin.
make_cylinder :: proc(
  segments: u32 = 32,
  height: f32 = 2.0,
  radius: f32 = 1.0,
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
) -> Geometry {
  // body rings interleaved, then each cap's center and rim; rings repeat their first vertex for the UV seam
  ring := segments + 1
  top_center := 2 * ring
  bottom_center := top_center + 1 + ring
  vertices := make([]Vertex, 2 * ring + 2 * (ring + 1))
  indices := make([]u32, segments * 12)
  half_h := height * 0.5
  vertices[top_center] = {position = {0, half_h, 0}, normal = {0, 1, 0}, color = color, uv = {0.5, 0.5}}
  vertices[bottom_center] = {position = {0, -half_h, 0}, normal = {0, -1, 0}, color = color, uv = {0.5, 0.5}}
  for i in 0 ..< ring {
    theta := 2.0 * math.PI * f32(i) / f32(segments)
    x, z := math.cos(theta), math.sin(theta)
    top, bottom := [3]f32{radius * x, half_h, radius * z}, [3]f32{radius * x, -half_h, radius * z}
    u := f32(i) / f32(segments)
    cap_uv := [2]f32{0.5 + 0.5 * x, 0.5 + 0.5 * z}
    vertices[2 * i] = {position = top, normal = {x, 0, z}, color = color, uv = {u, 0}}
    vertices[2 * i + 1] = {position = bottom, normal = {x, 0, z}, color = color, uv = {u, 1}}
    vertices[top_center + 1 + i] = {position = top, normal = {0, 1, 0}, color = color, uv = cap_uv}
    vertices[bottom_center + 1 + i] = {position = bottom, normal = {0, -1, 0}, color = color, uv = cap_uv}
  }
  // per segment: a body quad, then a triangle of each cap
  for seg in 0 ..< segments {
    a, c := seg * 2, (seg + 1) * 2
    top_rim, bottom_rim := top_center + 1 + seg, bottom_center + 1 + seg
    p := indices[seg * 12:]
    p[0], p[1], p[2], p[3], p[4], p[5] = a, c, a + 1, a + 1, c, c + 1
    p[6], p[7], p[8] = top_center, top_rim + 1, top_rim
    p[9], p[10], p[11] = bottom_center, bottom_rim, bottom_rim + 1
  }
  return geometry_create(vertices, indices)
}
