package geometry

import "core:math"
import "core:math/linalg"

// make_cube builds a 2x2x2 cube centered at the origin with per-face normals.
make_cube :: proc(
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
) -> Mesh {
  vertices := make([]Vertex, 24)
  indices := make([]u32, 36)
  vertices[0] = {{-1, -1, 1}, VEC_FORWARD, color, {0, 1}, {}}
  vertices[1] = {{1, -1, 1}, VEC_FORWARD, color, {1, 1}, {}}
  vertices[2] = {{1, 1, 1}, VEC_FORWARD, color, {1, 0}, {}}
  vertices[3] = {{-1, 1, 1}, VEC_FORWARD, color, {0, 0}, {}}
  vertices[4] = {{-1, 1, -1}, VEC_BACKWARD, color, {1, 1}, {}}
  vertices[5] = {{1, 1, -1}, VEC_BACKWARD, color, {0, 1}, {}}
  vertices[6] = {{1, -1, -1}, VEC_BACKWARD, color, {0, 0}, {}}
  vertices[7] = {{-1, -1, -1}, VEC_BACKWARD, color, {1, 0}, {}}
  vertices[8] = {{1, 1, -1}, VEC_UP, color, {0, 1}, {}}
  vertices[9] = {{-1, 1, -1}, VEC_UP, color, {1, 1}, {}}
  vertices[10] = {{-1, 1, 1}, VEC_UP, color, {1, 0}, {}}
  vertices[11] = {{1, 1, 1}, VEC_UP, color, {0, 0}, {}}
  vertices[12] = {{1, -1, 1}, VEC_DOWN, color, {0, 1}, {}}
  vertices[13] = {{-1, -1, 1}, VEC_DOWN, color, {1, 1}, {}}
  vertices[14] = {{-1, -1, -1}, VEC_DOWN, color, {1, 0}, {}}
  vertices[15] = {{1, -1, -1}, VEC_DOWN, color, {0, 0}, {}}
  vertices[16] = {{1, -1, -1}, VEC_RIGHT, color, {0, 1}, {}}
  vertices[17] = {{1, 1, -1}, VEC_RIGHT, color, {1, 1}, {}}
  vertices[18] = {{1, 1, 1}, VEC_RIGHT, color, {1, 0}, {}}
  vertices[19] = {{1, -1, 1}, VEC_RIGHT, color, {0, 0}, {}}
  vertices[20] = {{-1, -1, 1}, VEC_LEFT, color, {0, 1}, {}}
  vertices[21] = {{-1, 1, 1}, VEC_LEFT, color, {1, 1}, {}}
  vertices[22] = {{-1, 1, -1}, VEC_LEFT, color, {1, 0}, {}}
  vertices[23] = {{-1, -1, -1}, VEC_LEFT, color, {0, 0}, {}}
  #unroll for face in 0 ..< 6 {
    i := u32(face * 4)
    p := indices[face * 6:]
    p[0], p[1], p[2], p[3], p[4], p[5] = i, i + 1, i + 2, i + 2, i + 3, i
  }
  return make_mesh(vertices, indices)
}

// make_wedge builds make_cube's 2x2x2 box with its top sloping down toward +Z: the front top
// edge drops `taper` of the height (0 is the cube, 1 a full wedge).
make_wedge :: proc(
  taper: f32 = 1,
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
) -> Mesh {
  front := 1 - 2 * clamp(taper, 0, 1)
  slope := linalg.normalize([3]f32{0, 1, taper})
  faces := [6]struct {
    normal:  [3]f32,
    corners: [4][3]f32,
  } {
    {VEC_FORWARD, {{-1, -1, 1}, {1, -1, 1}, {1, front, 1}, {-1, front, 1}}},
    {VEC_BACKWARD, {{-1, 1, -1}, {1, 1, -1}, {1, -1, -1}, {-1, -1, -1}}},
    {slope, {{1, 1, -1}, {-1, 1, -1}, {-1, front, 1}, {1, front, 1}}},
    {VEC_DOWN, {{1, -1, 1}, {-1, -1, 1}, {-1, -1, -1}, {1, -1, -1}}},
    {VEC_RIGHT, {{1, -1, -1}, {1, 1, -1}, {1, front, 1}, {1, -1, 1}}},
    {VEC_LEFT, {{-1, -1, 1}, {-1, front, 1}, {-1, 1, -1}, {-1, -1, -1}}},
  }
  uvs := [4][2]f32{{0, 1}, {1, 1}, {1, 0}, {0, 0}}
  vertices := make([]Vertex, 24)
  indices := make([]u32, 36)
  for face, f in faces {
    i := u32(f * 4)
    for corner, c in face.corners do vertices[int(i) + c] = {corner, face.normal, color, uvs[c], {}}
    p := indices[f * 6:]
    p[0], p[1], p[2], p[3], p[4], p[5] = i, i + 1, i + 2, i + 2, i + 3, i
  }
  return make_mesh(vertices, indices)
}

// make_quad builds a quad on the XZ plane facing +Y.
make_quad :: proc(
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
) -> Mesh {
  vertices := make([]Vertex, 4)
  indices := make([]u32, 6)
  vertices[0] = {{-1, 0, -1}, VEC_UP, color, {0, 0}, {}}
  vertices[1] = {{-1, 0, 1}, VEC_UP, color, {0, 1}, {}}
  vertices[2] = {{1, 0, 1}, VEC_UP, color, {1, 1}, {}}
  vertices[3] = {{1, 0, -1}, VEC_UP, color, {1, 0}, {}}
  indices[0], indices[1], indices[2] = 0, 1, 2
  indices[3], indices[4], indices[5] = 2, 3, 0
  return make_mesh(vertices, indices)
}

// make_billboard_quad builds a quad on the XY plane facing +Z, for camera-facing sprites.
make_billboard_quad :: proc(
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
) -> Mesh {
  vertices := make([]Vertex, 4)
  indices := make([]u32, 6)
  vertices[0] = {{-1, -1, 0}, VEC_FORWARD, color, {0, 1}, {}}
  vertices[1] = {{1, -1, 0}, VEC_FORWARD, color, {1, 1}, {}}
  vertices[2] = {{1, 1, 0}, VEC_FORWARD, color, {1, 0}, {}}
  vertices[3] = {{-1, 1, 0}, VEC_FORWARD, color, {0, 0}, {}}
  indices[0], indices[1], indices[2] = 0, 1, 2
  indices[3], indices[4], indices[5] = 2, 3, 0
  return make_mesh(vertices, indices)
}

// make_sphere builds a UV sphere of the given radius centered at the origin. A faceted sphere
// gives each quad its own four vertices, all with the normal through the quad's center, so the
// quads shade flat and can move apart.
make_sphere :: proc(
  segments: u32 = 16,
  rings: u32 = 16,
  radius: f32 = 1.0,
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
  faceted := false,
) -> Mesh {
  point :: proc(seg, ring: f32, segments, rings: u32) -> [3]f32 {
    phi := math.PI * ring / f32(rings)
    theta := 2.0 * math.PI * seg / f32(segments)
    return {math.sin(phi) * math.cos(theta), math.cos(phi), math.sin(phi) * math.sin(theta)}
  }
  if faceted {
    vertices := make([]Vertex, rings * segments * 4)
    indices := make([]u32, rings * segments * 6)
    for ring in 0 ..< rings {
      for seg in 0 ..< segments {
        quad := ring * segments + seg
        normal := point(f32(seg) + 0.5, f32(ring) + 0.5, segments, rings)
        for corner in u32(0) ..< 4 {
          s, r := seg + corner % 2, ring + corner / 2
          vertices[quad * 4 + corner] = Vertex {
            position = radius * point(f32(s), f32(r), segments, rings),
            normal   = normal,
            color    = color,
            uv       = {f32(s) / f32(segments), f32(r) / f32(rings)},
          }
        }
        a := quad * 4
        p := indices[quad * 6:]
        p[0], p[1], p[2], p[3], p[4], p[5] = a, a + 1, a + 2, a + 2, a + 1, a + 3
      }
    }
    return make_mesh(vertices, indices)
  }
  vert_count := (rings + 1) * (segments + 1)
  idx_count := rings * segments * 6
  vertices := make([]Vertex, vert_count)
  indices := make([]u32, idx_count)
  for ring in 0 ..= rings {
    for seg in 0 ..= segments {
      n := point(f32(seg), f32(ring), segments, rings)
      idx := ring * (segments + 1) + seg
      vertices[idx] = Vertex {
        position = radius * n,
        normal   = n,
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
  return make_mesh(vertices, indices)
}

// make_cone builds a cone along Y with a capped base and its tip at +height/2. A top_radius
// above 0 cuts the tip off into a capped frustum of that radius.
make_cone :: proc(
  segments: u32 = 32,
  height: f32 = 2.0,
  radius: f32 = 1.0,
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
  top_radius: f32 = 0,
) -> Mesh {
  // side columns (top then bottom vertex), then the bottom cap's center and rim, then the top cap's
  ring := segments + 1
  bottom_center := 2 * ring
  top_center := bottom_center + 1 + ring
  top_cap := top_radius > 0
  vertices := make([]Vertex, top_center + (1 + ring if top_cap else 0))
  indices := make([]u32, segments * (12 if top_cap else 6))
  half_h := height * 0.5
  for i in 0 ..< ring {
    theta := 2.0 * math.PI * f32(i) / f32(segments)
    x, z := math.cos(theta), math.sin(theta)
    u := f32(i) / f32(segments)
    normal := linalg.normalize([3]f32{x * height, radius - top_radius, z * height})
    vertices[i * 2] = {position = {top_radius * x, half_h, top_radius * z}, normal = normal, color = color, uv = {u, 0}}
    vertices[i * 2 + 1] = {position = {radius * x, -half_h, radius * z}, normal = normal, color = color, uv = {u, 1}}
    cap_uv := [2]f32{0.5 + 0.5 * x, 0.5 + 0.5 * z}
    vertices[bottom_center + 1 + i] = {position = {radius * x, -half_h, radius * z}, normal = {0, -1, 0}, color = color, uv = cap_uv}
    if top_cap do vertices[top_center + 1 + i] = {position = {top_radius * x, half_h, top_radius * z}, normal = {0, 1, 0}, color = color, uv = cap_uv}
  }
  vertices[bottom_center] = {position = {0, -half_h, 0}, normal = {0, -1, 0}, color = color, uv = {0.5, 0.5}}
  if top_cap do vertices[top_center] = {position = {0, half_h, 0}, normal = {0, 1, 0}, color = color, uv = {0.5, 0.5}}
  i := 0
  for seg in 0 ..< segments {
    a, c := seg * 2, seg * 2 + 2
    if top_cap {
      top_rim := top_center + 1 + seg
      p := indices[i:]
      p[0], p[1], p[2], p[3], p[4], p[5] = a, c, a + 1, top_center, top_rim + 1, top_rim
      i += 6
    }
    rim := bottom_center + 1 + seg
    p := indices[i:]
    p[0], p[1], p[2], p[3], p[4], p[5] = a + 1, c, c + 1, bottom_center, rim, rim + 1
    i += 6
  }
  return make_mesh(vertices, indices)
}

// make_capsule builds a capsule along Y: two hemispheres joined by a cylinder.
// V runs from 0 at the top pole to 1 at the bottom pole.
make_capsule :: proc(
  segments: u32 = 16,
  rings: u32 = 8,
  height: f32 = 2.0,
  radius: f32 = 0.5,
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
) -> Mesh {
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
  return make_mesh(vertices, indices)
}

// make_torus builds a torus in the XY plane, around the Z axis.
make_torus :: proc(
  segments: u32 = 32,
  sides: u32 = 16,
  major_radius: f32 = 1.0,
  minor_radius: f32 = 0.3,
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
) -> Mesh {
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
  return make_mesh(vertices, indices)
}

// make_cylinder builds a cylinder along Y centered at the origin, its side cut into `rings`
// bands from top to bottom, capped at both ends when `caps`. The side sweeps `arc` radians
// from +X toward +Z (math.PI makes a half cylinder whose round side faces +Z); under a full
// turn `caps` also closes the two flat cut faces.
make_cylinder :: proc(
  segments: u32 = 32,
  rings: u32 = 1,
  height: f32 = 2.0,
  radius: f32 = 1.0,
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
  caps := true,
  arc: f32 = 2.0 * math.PI,
) -> Mesh {
  // side columns top to bottom, then each cap's center and rim, then the two cut faces (axis top,
  // axis bottom, rim top, rim bottom); columns repeat the first for the UV seam
  ring := segments + 1
  column := rings + 1
  side := ring * column
  top_center := side
  bottom_center := top_center + 1 + ring
  cut := caps && arc < 2.0 * math.PI - 1e-4
  cut_start := bottom_center + 1 + ring
  vertices := make([]Vertex, side + (2 * (ring + 1) if caps else 0) + (8 if cut else 0))
  indices := make([]u32, segments * rings * 6 + (segments * 6 if caps else 0) + (12 if cut else 0))
  half_h := height * 0.5
  for i in 0 ..< ring {
    theta := arc * f32(i) / f32(segments)
    x, z := math.cos(theta), math.sin(theta)
    u := f32(i) / f32(segments)
    for r in 0 ..< column {
      v := f32(r) / f32(rings)
      vertices[i * column + r] = {position = {radius * x, half_h - height * v, radius * z}, normal = {x, 0, z}, color = color, uv = {u, v}}
    }
  }
  for seg in 0 ..< segments {
    for r in 0 ..< rings {
      a, c := seg * column + r, (seg + 1) * column + r
      p := indices[(seg * rings + r) * 6:]
      p[0], p[1], p[2], p[3], p[4], p[5] = a, c, a + 1, a + 1, c, c + 1
    }
  }
  if !caps do return make_mesh(vertices, indices)
  vertices[top_center] = {position = {0, half_h, 0}, normal = {0, 1, 0}, color = color, uv = {0.5, 0.5}}
  vertices[bottom_center] = {position = {0, -half_h, 0}, normal = {0, -1, 0}, color = color, uv = {0.5, 0.5}}
  for i in 0 ..< ring {
    theta := arc * f32(i) / f32(segments)
    x, z := math.cos(theta), math.sin(theta)
    cap_uv := [2]f32{0.5 + 0.5 * x, 0.5 + 0.5 * z}
    vertices[top_center + 1 + i] = {position = {radius * x, half_h, radius * z}, normal = {0, 1, 0}, color = color, uv = cap_uv}
    vertices[bottom_center + 1 + i] = {position = {radius * x, -half_h, radius * z}, normal = {0, -1, 0}, color = color, uv = cap_uv}
  }
  for seg in 0 ..< segments {
    top_rim, bottom_rim := top_center + 1 + seg, bottom_center + 1 + seg
    p := indices[segments * rings * 6 + seg * 6:]
    p[0], p[1], p[2] = top_center, top_rim + 1, top_rim
    p[3], p[4], p[5] = bottom_center, bottom_rim, bottom_rim + 1
  }
  if !cut do return make_mesh(vertices, indices)
  for face in 0 ..< u32(2) {
    theta := arc * f32(face)
    x, z := math.cos(theta), math.sin(theta)
    normal := [3]f32{0, 0, -1} if face == 0 else [3]f32{-z, 0, x}
    a := cut_start + face * 4
    corners := [4][3]f32{{0, half_h, 0}, {0, -half_h, 0}, {radius * x, half_h, radius * z}, {radius * x, -half_h, radius * z}}
    uvs := [4][2]f32{{0, 0}, {0, 1}, {1, 0}, {1, 1}}
    for c in 0 ..< 4 do vertices[int(a) + c] = {position = corners[c], normal = normal, color = color, uv = uvs[c]}
    p := indices[segments * rings * 6 + segments * 6 + face * 6:]
    if face == 0 do p[0], p[1], p[2], p[3], p[4], p[5] = a, a + 2, a + 1, a + 1, a + 2, a + 3
    else do p[0], p[1], p[2], p[3], p[4], p[5] = a, a + 1, a + 2, a + 1, a + 3, a + 2
  }
  return make_mesh(vertices, indices)
}

// make_circle builds a disc in XZ facing +Y centered at the origin: a fan of `segments`
// triangles, uv mapping the disc's square to [0, 1].
make_circle :: proc(segments: u32 = 32, radius: f32 = 1.0, color: [4]f32 = {1.0, 1.0, 1.0, 1.0}) -> Mesh {
  vertices := make([]Vertex, segments + 2)
  indices := make([]u32, segments * 3)
  vertices[0] = {normal = {0, 1, 0}, color = color, uv = {0.5, 0.5}}
  for i in 0 ..= segments {
    theta := 2.0 * math.PI * f32(i) / f32(segments)
    x, z := math.cos(theta), math.sin(theta)
    vertices[1 + i] = {position = {radius * x, 0, radius * z}, normal = {0, 1, 0}, color = color, uv = {0.5 + 0.5 * x, 0.5 + 0.5 * z}}
  }
  for seg in 0 ..< segments {
    p := indices[seg * 3:]
    p[0], p[1], p[2] = 0, seg + 2, seg + 1
  }
  return make_mesh(vertices, indices)
}
