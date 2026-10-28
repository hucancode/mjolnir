package geometry

import "core:math"
import "core:math/linalg"

// ProfilePoint is a point of a profile make_lathe turns about the Y axis: its distance from the
// axis and its height, its outward normal in that plane, and its v texture coordinate.
ProfilePoint :: struct {
  position: [2]f32, // (radius, y)
  normal:   [2]f32, // (radial, y)
  v:        f32,
}

// make_lathe turns profile strips about the Y axis, `arc` radians from +X toward +Z, each strip
// into a smooth band of `segments` columns: vases, columns, wheels, caps. Walk each strip down
// the outside: top to bottom along a side, center to rim for a top cap, rim to center for a
// bottom one; a corner is two strips meeting. u runs along the turn and v is the point's; a flat
// strip (normals along Y) maps planar instead, as a disc as wide as its widest point. A faceted
// lathe gives each quad its own four vertices and flat normal, so the quads can move apart.
// Under a full turn `close` fills each cut end between the strips and the axis.
make_lathe :: proc(
  strips: [][]ProfilePoint,
  segments: u32 = 32,
  arc: f32 = 2.0 * math.PI,
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
  faceted := false,
  close := false,
) -> Mesh {
  columns := int(segments) + 1
  cut := close && arc < 2.0 * math.PI - 1e-4
  // a band's triangles touching the axis have no area: skipped
  on_axis :: proc(p: [2]f32) -> bool {
    return abs(p.x) < 1e-6
  }
  vertex_count, index_count := 0, 0
  for strip in strips {
    if !faceted do vertex_count += len(strip) * columns
    for k in 0 ..< len(strip) - 1 {
      p0, p1 := strip[k].position, strip[k + 1].position
      index_count += int(segments) * 3 * (int(!on_axis(p0)) + int(!on_axis(p1)))
      if faceted do vertex_count += int(segments) * 4
      if cut && has_cut_face(p0, p1) do vertex_count, index_count = vertex_count + 8, index_count + 12
    }
  }
  vertices := make([]Vertex, vertex_count)
  indices := make([]u32, index_count)
  turn :: proc(p: [2]f32, angle: f32) -> [3]f32 {
    return {p.x * math.cos(angle), p.y, p.x * math.sin(angle)}
  }
  has_cut_face :: proc(p0, p1: [2]f32) -> bool {
    return (p0.x + p1.x) * abs(p0.y - p1.y) > 1e-6
  }
  v, i := 0, 0
  for strip in strips {
    flat := true
    widest: f32
    for p in strip {
      if abs(p.normal.x) > 1e-6 do flat = false
      widest = max(widest, p.position.x)
    }
    uv := proc(p: ProfilePoint, column: int, segments: u32, arc: f32, flat: bool, widest: f32) -> [2]f32 {
      if !flat do return {f32(column) / f32(segments), p.v}
      angle := arc * f32(column) / f32(segments)
      r := p.position.x / widest if widest > 0 else 0
      return 0.5 + 0.5 * r * [2]f32{math.cos(angle), math.sin(angle)}
    }
    base := v
    if !faceted {
      for p in strip {
        for column in 0 ..< columns {
          angle := arc * f32(column) / f32(segments)
          vertices[v] = {
            position = turn(p.position, angle),
            normal   = turn(p.normal, angle),
            color    = color,
            uv       = uv(p, column, segments, arc, flat, widest),
          }
          v += 1
        }
      }
    }
    for k in 0 ..< len(strip) - 1 {
      p0, p1 := strip[k], strip[k + 1]
      for column in 0 ..< int(segments) {
        // the quad's corners: column then column + 1 at p0, then at p1
        a, a1, b, b1: u32
        if faceted {
          a = u32(v)
          a1, b, b1 = a + 1, a + 2, a + 3
          normal := turn(linalg.normalize0(p0.normal + p1.normal), arc * (f32(column) + 0.5) / f32(segments))
          for corner in 0 ..< 4 {
            p, c := strip[k + corner / 2], column + corner % 2
            vertices[v] = {
              position = turn(p.position, arc * f32(c) / f32(segments)),
              normal   = normal,
              color    = color,
              uv       = uv(p, c, segments, arc, flat, widest),
            }
            v += 1
          }
        } else {
          a = u32(base + k * columns + column)
          a1, b, b1 = a + 1, a + u32(columns), a + u32(columns) + 1
        }
        if !on_axis(p0.position) {
          indices[i], indices[i + 1], indices[i + 2] = a, a1, b
          i += 3
        }
        if !on_axis(p1.position) {
          indices[i], indices[i + 1], indices[i + 2] = b, a1, b1
          i += 3
        }
      }
      if !cut || !has_cut_face(p0.position, p1.position) do continue
      // the end at angle 0 faces -Z, the end at arc faces on along the turn
      for end in 0 ..< 2 {
        angle := arc * f32(end)
        normal := [3]f32{0, 0, -1} if end == 0 else {-math.sin(angle), 0, math.cos(angle)}
        q := u32(v)
        corners := [4]ProfilePoint{{position = {0, p0.position.y}, v = p0.v}, {position = {0, p1.position.y}, v = p1.v}, p0, p1}
        for c in corners {
          vertices[v] = {position = turn(c.position, angle), normal = normal, color = color, uv = {c.position.x / widest if widest > 0 else 0, c.v}}
          v += 1
        }
        p := indices[i:]
        if end == 0 do p[0], p[1], p[2], p[3], p[4], p[5] = q, q + 2, q + 1, q + 1, q + 2, q + 3
        else do p[0], p[1], p[2], p[3], p[4], p[5] = q, q + 1, q + 2, q + 1, q + 3, q + 2
        i += 6
      }
    }
  }
  return make_mesh(vertices, indices)
}

// make_extrusion builds a prism: a convex `polygon` in the XY plane, counter-clockwise seen from
// +Z, extruded `depth` along Z and centered on it, with a flat normal per face. Each side maps
// uv 0..1 along its edge and from front to back; the caps map planar over the polygon's bounds.
make_extrusion :: proc(polygon: [][2]f32, depth: f32 = 2, color: [4]f32 = {1.0, 1.0, 1.0, 1.0}) -> Mesh {
  n := len(polygon)
  if n < 3 do return {}
  vertices := make([]Vertex, 6 * n)
  indices := make([]u32, 6 * (n - 2) + 6 * n)
  lo, hi := polygon[0], polygon[0]
  for p in polygon do lo, hi = linalg.min(lo, p), linalg.max(hi, p)
  size := linalg.max(hi - lo, 1e-6)
  half := depth * 0.5
  for p, j in polygon {
    u, v := (p.x - lo.x) / size.x, (hi.y - p.y) / size.y
    vertices[j] = {position = {p.x, p.y, half}, normal = VEC_FORWARD, color = color, uv = {u, v}}
    vertices[n + j] = {position = {p.x, p.y, -half}, normal = VEC_BACKWARD, color = color, uv = {1 - u, v}}
  }
  i := 0
  for j in 1 ..< u32(n - 1) {
    back := u32(n)
    p := indices[i:]
    p[0], p[1], p[2], p[3], p[4], p[5] = 0, j, j + 1, back, back + j + 1, back + j
    i += 6
  }
  for a, j in polygon {
    b := polygon[(j + 1) % n]
    normal := linalg.normalize0([3]f32{b.y - a.y, a.x - b.x, 0})
    q := u32(2 * n + 4 * j)
    vertices[q] = {position = {a.x, a.y, half}, normal = normal, color = color, uv = {0, 0}}
    vertices[q + 1] = {position = {b.x, b.y, half}, normal = normal, color = color, uv = {1, 0}}
    vertices[q + 2] = {position = {b.x, b.y, -half}, normal = normal, color = color, uv = {1, 1}}
    vertices[q + 3] = {position = {a.x, a.y, -half}, normal = normal, color = color, uv = {0, 1}}
    p := indices[i:]
    p[0], p[1], p[2], p[3], p[4], p[5] = q, q + 2, q + 1, q, q + 3, q + 2
    i += 6
  }
  return make_mesh(vertices, indices)
}

// make_cube builds a 2x2x2 cube centered at the origin with per-face normals.
make_cube :: proc(color: [4]f32 = {1.0, 1.0, 1.0, 1.0}) -> Mesh {
  square := [4][2]f32{{-1, -1}, {1, -1}, {1, 1}, {-1, 1}}
  return make_extrusion(square[:], 2, color)
}

// make_wedge builds make_cube's 2x2x2 box with its top sloping down toward +Z: the front top
// edge drops `taper` of the height (0 is the cube, 1 a full wedge).
make_wedge :: proc(taper: f32 = 1, color: [4]f32 = {1.0, 1.0, 1.0, 1.0}) -> Mesh {
  // the side profile (z, y), extruded along X
  front := 1 - 2 * clamp(taper, 0, 1)
  side := [4][2]f32{{-1, -1}, {1, -1}, {1, front}, {-1, 1}}
  mesh := make_extrusion(side[:], 2, color)
  mesh_transform(mesh, {rotation = linalg.quaternion_angle_axis_f32(-math.PI / 2, VEC_UP), scale = {1, 1, 1}})
  return mesh
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

// make_sphere builds a UV sphere of the given radius centered at the origin: ring r of the
// (rings + 1) * (segments + 1) vertices runs around at latitude r from the top. A faceted
// sphere gives each quad its own four vertices, all with the normal through the quad's center,
// so the quads shade flat and can move apart.
make_sphere :: proc(
  segments: u32 = 16,
  rings: u32 = 16,
  radius: f32 = 1.0,
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
  faceted := false,
) -> Mesh {
  profile := make([]ProfilePoint, rings + 1, context.temp_allocator)
  for &p, ring in profile {
    phi := math.PI * f32(ring) / f32(rings)
    n := [2]f32{math.sin(phi), math.cos(phi)}
    p = {radius * n, n, f32(ring) / f32(rings)}
  }
  strips := [1][]ProfilePoint{profile}
  return make_lathe(strips[:], segments, color = color, faceted = faceted)
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
  h := height * 0.5
  slope := linalg.normalize([2]f32{height, radius - top_radius})
  side := [2]ProfilePoint{{{top_radius, h}, slope, 0}, {{radius, -h}, slope, 1}}
  bottom := [2]ProfilePoint{{{radius, -h}, {0, -1}, 0}, {{0, -h}, {0, -1}, 0}}
  top := [2]ProfilePoint{{{0, h}, {0, 1}, 0}, {{top_radius, h}, {0, 1}, 0}}
  strips := [3][]ProfilePoint{side[:], bottom[:], top[:]}
  return make_lathe(strips[:3 if top_radius > 0 else 2], segments, color = color)
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
  // each hemisphere's rings + 1 points, pole to equator then equator to pole: the cylinder is
  // the band between the equators
  half := height * 0.5 - radius
  profile := make([]ProfilePoint, 2 * (rings + 1), context.temp_allocator)
  for ring in 0 ..= rings {
    t := f32(ring) / f32(rings)
    phi := math.PI / 2 * t
    n := [2]f32{math.sin(phi), math.cos(phi)}
    profile[ring] = {{radius * n.x, half + radius * n.y}, n, 0.25 * t}
    profile[2 * rings + 1 - ring] = {{radius * n.x, -half - radius * n.y}, {n.x, -n.y}, 1 - 0.25 * t}
  }
  strips := [1][]ProfilePoint{profile}
  return make_lathe(strips[:], segments, color = color)
}

// make_torus builds a torus in the XY plane, around the Z axis.
make_torus :: proc(
  segments: u32 = 32,
  sides: u32 = 16,
  major_radius: f32 = 1.0,
  minor_radius: f32 = 0.3,
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
) -> Mesh {
  // the tube's circle, walked down its outside
  profile := make([]ProfilePoint, sides + 1, context.temp_allocator)
  for &p, side in profile {
    phi := -2.0 * math.PI * f32(side) / f32(sides)
    n := [2]f32{math.cos(phi), math.sin(phi)}
    p = {{major_radius, 0} + minor_radius * n, n, f32(side) / f32(sides)}
  }
  strips := [1][]ProfilePoint{profile}
  mesh := make_lathe(strips[:], segments, color = color)
  // turned about Y, stood up around Z
  mesh_transform(mesh, {rotation = linalg.quaternion_angle_axis_f32(math.PI / 2, VEC_RIGHT), scale = {1, 1, 1}})
  return mesh
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
  h := height * 0.5
  side := make([]ProfilePoint, rings + 1, context.temp_allocator)
  for &p, ring in side {
    v := f32(ring) / f32(rings)
    p = {{radius, h - height * v}, {1, 0}, v}
  }
  top := [2]ProfilePoint{{{0, h}, {0, 1}, 0}, {{radius, h}, {0, 1}, 0}}
  bottom := [2]ProfilePoint{{{radius, -h}, {0, -1}, 0}, {{0, -h}, {0, -1}, 0}}
  strips := [3][]ProfilePoint{side, top[:], bottom[:]}
  return make_lathe(strips[:3 if caps else 1], segments, arc, color, close = caps)
}

// make_circle builds a disc in XZ facing +Y centered at the origin, of `segments` triangles,
// uv mapping the disc's square to [0, 1].
make_circle :: proc(segments: u32 = 32, radius: f32 = 1.0, color: [4]f32 = {1.0, 1.0, 1.0, 1.0}) -> Mesh {
  disc := [2]ProfilePoint{{{0, 0}, {0, 1}, 0}, {{radius, 0}, {0, 1}, 0}}
  strips := [1][]ProfilePoint{disc[:]}
  return make_lathe(strips[:], segments, color = color)
}
