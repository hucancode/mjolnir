package render

import "core:math"
import "core:math/linalg"

// Debug line colors.
DEBUG_WHITE :: [4]f32{1, 1, 1, 1}
DEBUG_BLACK :: [4]f32{0, 0, 0, 1}
DEBUG_GRAY :: [4]f32{0.5, 0.5, 0.5, 1}
DEBUG_RED :: [4]f32{1, 0, 0, 1}
DEBUG_GREEN :: [4]f32{0, 1, 0, 1}
DEBUG_BLUE :: [4]f32{0, 0.4, 1, 1}
DEBUG_YELLOW :: [4]f32{1, 1, 0, 1}
DEBUG_CYAN :: [4]f32{0, 1, 1, 1}
DEBUG_MAGENTA :: [4]f32{1, 0, 1, 1}
DEBUG_ORANGE :: [4]f32{1, 0.5, 0, 1}

CIRCLE_SEGMENTS :: 24

@(private = "file")
dl :: proc(self: ^Manager) -> ^DebugLineRenderer {
  return &self.internal.debug_line_renderer
}

// n must be normalized.
@(private = "file")
orthonormal_basis :: proc(n: [3]f32) -> (u, v: [3]f32) {
  tmp := [3]f32{0, 1, 0} if abs(n.y) < 0.9 else [3]f32{1, 0, 0}
  u = linalg.normalize0(linalg.cross(tmp, n))
  v = linalg.cross(n, u)
  return
}

@(private = "file")
fill_circle :: proc(
  segs: []DebugLineSegment,
  center, u, v: [3]f32,
  radius: f32,
  color: [4]f32,
  life: f32,
  bypass_depth: bool,
) {
  prev := center + u * radius
  for i in 1 ..= CIRCLE_SEGMENTS {
    t := f32(i) / f32(CIRCLE_SEGMENTS) * math.TAU
    p := center + u * (radius * math.cos(t)) + v * (radius * math.sin(t))
    segs[i - 1] = {a = prev, b = p, color = color, life = life, bypass_depth = bypass_depth}
    prev = p
  }
}

debug_segment :: proc(
  self: ^Manager,
  a, b: [3]f32,
  color: [4]f32 = DEBUG_WHITE,
  life: f32 = 0,
  bypass_depth: bool = false,
) {
  debug_line_add_segments(
    dl(self),
    DebugLineSegment{a = a, b = b, color = color, life = life, bypass_depth = bypass_depth},
  )
}

debug_aabb :: proc(
  self: ^Manager,
  lo, hi: [3]f32,
  color: [4]f32 = DEBUG_WHITE,
  life: f32 = 0,
  bypass_depth: bool = false,
) {
  c := [8][3]f32 {
    {lo.x, lo.y, lo.z},
    {hi.x, lo.y, lo.z},
    {hi.x, hi.y, lo.z},
    {lo.x, hi.y, lo.z},
    {lo.x, lo.y, hi.z},
    {hi.x, lo.y, hi.z},
    {hi.x, hi.y, hi.z},
    {lo.x, hi.y, hi.z},
  }
  push_box_edges(self, c, color, life, bypass_depth)
}

debug_cube :: proc(
  self: ^Manager,
  center: [3]f32,
  rotation: quaternion128 = 1,
  size: [3]f32 = {1, 1, 1},
  color: [4]f32 = DEBUG_WHITE,
  life: f32 = 0,
  bypass_depth: bool = false,
) {
  h := size * 0.5
  base := [8][3]f32 {
    {-h.x, -h.y, -h.z},
    { h.x, -h.y, -h.z},
    { h.x,  h.y, -h.z},
    {-h.x,  h.y, -h.z},
    {-h.x, -h.y,  h.z},
    { h.x, -h.y,  h.z},
    { h.x,  h.y,  h.z},
    {-h.x,  h.y,  h.z},
  }
  c: [8][3]f32
  for i in 0 ..< 8 {
    c[i] = linalg.quaternion_mul_vector3(rotation, base[i]) + center
  }
  push_box_edges(self, c, color, life, bypass_depth)
}

@(private = "file")
push_box_edges :: proc(
  self: ^Manager,
  c: [8][3]f32,
  color: [4]f32,
  life: f32,
  bypass_depth: bool,
) {
  edges := [12][2]int {
    {0, 1}, {1, 2}, {2, 3}, {3, 0},
    {4, 5}, {5, 6}, {6, 7}, {7, 4},
    {0, 4}, {1, 5}, {2, 6}, {3, 7},
  }
  segs: [12]DebugLineSegment
  for e, i in edges {
    segs[i] = {a = c[e[0]], b = c[e[1]], color = color, life = life, bypass_depth = bypass_depth}
  }
  debug_line_add_segments(dl(self), ..segs[:])
}

debug_circle :: proc(
  self: ^Manager,
  center, normal: [3]f32,
  radius: f32 = 1,
  color: [4]f32 = DEBUG_WHITE,
  life: f32 = 0,
  bypass_depth: bool = false,
) {
  u, v := orthonormal_basis(linalg.normalize0(normal))
  segs: [CIRCLE_SEGMENTS]DebugLineSegment
  fill_circle(segs[:], center, u, v, radius, color, life, bypass_depth)
  debug_line_add_segments(dl(self), ..segs[:])
}

debug_sphere :: proc(
  self: ^Manager,
  center: [3]f32,
  radius: f32 = 1,
  color: [4]f32 = DEBUG_WHITE,
  life: f32 = 0,
  bypass_depth: bool = false,
) {
  segs: [3 * CIRCLE_SEGMENTS]DebugLineSegment
  X :: [3]f32{1, 0, 0}
  Y :: [3]f32{0, 1, 0}
  Z :: [3]f32{0, 0, 1}
  fill_circle(segs[0 * CIRCLE_SEGMENTS:1 * CIRCLE_SEGMENTS], center, Y, Z, radius, color, life, bypass_depth)
  fill_circle(segs[1 * CIRCLE_SEGMENTS:2 * CIRCLE_SEGMENTS], center, X, Z, radius, color, life, bypass_depth)
  fill_circle(segs[2 * CIRCLE_SEGMENTS:3 * CIRCLE_SEGMENTS], center, X, Y, radius, color, life, bypass_depth)
  debug_line_add_segments(dl(self), ..segs[:])
}

debug_arrow :: proc(
  self: ^Manager,
  from, to: [3]f32,
  color: [4]f32 = DEBUG_WHITE,
  life: f32 = 0,
  bypass_depth: bool = false,
) {
  dir := to - from
  length := linalg.length(dir)
  if length < 1e-5 {
    debug_line_add_segments(
      dl(self),
      DebugLineSegment{a = from, b = to, color = color, life = life, bypass_depth = bypass_depth},
    )
    return
  }
  d := dir / length
  u, v := orthonormal_basis(d)
  head_len := min(length * 0.2, 0.5)
  head_r := head_len * 0.4
  base := to - d * head_len
  segs: [5]DebugLineSegment
  segs[0] = {a = from, b = to, color = color, life = life, bypass_depth = bypass_depth}
  for i in 0 ..< 4 {
    t := f32(i) / 4.0 * math.TAU
    p := base + u * (head_r * math.cos(t)) + v * (head_r * math.sin(t))
    segs[1 + i] = {a = to, b = p, color = color, life = life, bypass_depth = bypass_depth}
  }
  debug_line_add_segments(dl(self), ..segs[:])
}

debug_axes :: proc(
  self: ^Manager,
  origin: [3]f32,
  rotation: quaternion128 = 1,
  scale: f32 = 1,
  life: f32 = 0,
  bypass_depth: bool = false,
) {
  x := linalg.quaternion_mul_vector3(rotation, [3]f32{scale, 0, 0})
  y := linalg.quaternion_mul_vector3(rotation, [3]f32{0, scale, 0})
  z := linalg.quaternion_mul_vector3(rotation, [3]f32{0, 0, scale})
  // Canonical axis colors (pure RGB) — independent of DEBUG_PALETTE.BLUE which is tinted.
  segs := [3]DebugLineSegment {
    {a = origin, b = origin + x, color = {1, 0, 0, 1}, life = life, bypass_depth = bypass_depth},
    {a = origin, b = origin + y, color = {0, 1, 0, 1}, life = life, bypass_depth = bypass_depth},
    {a = origin, b = origin + z, color = {0, 0, 1, 1}, life = life, bypass_depth = bypass_depth},
  }
  debug_line_add_segments(dl(self), ..segs[:])
}

debug_point :: proc(
  self: ^Manager,
  p: [3]f32,
  size: f32 = 0.1,
  color: [4]f32 = DEBUG_WHITE,
  life: f32 = 0,
  bypass_depth: bool = false,
) {
  h := size * 0.5
  segs := [3]DebugLineSegment {
    {a = p - {h, 0, 0}, b = p + {h, 0, 0}, color = color, life = life, bypass_depth = bypass_depth},
    {a = p - {0, h, 0}, b = p + {0, h, 0}, color = color, life = life, bypass_depth = bypass_depth},
    {a = p - {0, 0, h}, b = p + {0, 0, h}, color = color, life = life, bypass_depth = bypass_depth},
  }
  debug_line_add_segments(dl(self), ..segs[:])
}
