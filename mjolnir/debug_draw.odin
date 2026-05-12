package mjolnir

import "core:math"
import "core:math/linalg"
import "render/debug_line"

DebugColor :: enum {
  WHITE,
  BLACK,
  GRAY,
  RED,
  GREEN,
  BLUE,
  YELLOW,
  CYAN,
  MAGENTA,
  ORANGE,
}

@(private)
DEBUG_PALETTE := [DebugColor][4]f32 {
  .WHITE   = {1, 1, 1, 1},
  .BLACK   = {0, 0, 0, 1},
  .GRAY    = {0.5, 0.5, 0.5, 1},
  .RED     = {1, 0, 0, 1},
  .GREEN   = {0, 1, 0, 1},
  .BLUE    = {0, 0.4, 1, 1},
  .YELLOW  = {1, 1, 0, 1},
  .CYAN    = {0, 1, 1, 1},
  .MAGENTA = {1, 0, 1, 1},
  .ORANGE  = {1, 0.5, 0, 1},
}

DEBUG_DEFAULT_COLOR :: [4]f32{1, 1, 1, 1}

debug_color :: proc(c: DebugColor) -> [4]f32 {
  return DEBUG_PALETTE[c]
}

CIRCLE_SEGMENTS :: 24

@(private)
debug_pre_frame :: proc(self: ^Engine) {
  debug_line.set_time(&self.render.internal.debug_line_renderer, time_since_start(self))
}

@(private)
dl :: proc(self: ^Engine) -> ^debug_line.Renderer {
  return &self.render.internal.debug_line_renderer
}

@(private)
expiry :: #force_inline proc(engine: ^Engine, life: f32) -> f32 {
  return debug_line.resolve_expiry(time_since_start(engine), life)
}

// n must be normalized.
@(private)
orthonormal_basis :: proc(n: [3]f32) -> (u, v: [3]f32) {
  tmp := [3]f32{0, 1, 0} if abs(n.y) < 0.9 else [3]f32{1, 0, 0}
  u = linalg.normalize0(linalg.cross(tmp, n))
  v = linalg.cross(n, u)
  return
}

@(private)
fill_circle :: proc(
  segs: []debug_line.Segment,
  center, u, v: [3]f32,
  radius: f32,
  color: [4]f32,
  exp: f32,
  bypass_depth: bool,
) {
  prev := center + u * radius
  for i in 1 ..= CIRCLE_SEGMENTS {
    t := f32(i) / f32(CIRCLE_SEGMENTS) * math.TAU
    p := center + u * (radius * math.cos(t)) + v * (radius * math.sin(t))
    segs[i - 1] = {a = prev, b = p, color = color, expiry = exp, bypass_depth = bypass_depth}
    prev = p
  }
}

debug_segment :: proc(
  engine: ^Engine,
  a, b: [3]f32,
  color: [4]f32 = DEBUG_DEFAULT_COLOR,
  life: f32 = 0,
  bypass_depth: bool = false,
) {
  debug_line.add_segments(
    dl(engine),
    debug_line.Segment{a = a, b = b, color = color, expiry = expiry(engine, life), bypass_depth = bypass_depth},
  )
}

debug_aabb :: proc(
  engine: ^Engine,
  lo, hi: [3]f32,
  color: [4]f32 = DEBUG_DEFAULT_COLOR,
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
  push_box_edges(engine, c, color, life, bypass_depth)
}

debug_cube :: proc(
  engine: ^Engine,
  center: [3]f32,
  rotation: quaternion128 = 1,
  size: [3]f32 = {1, 1, 1},
  color: [4]f32 = DEBUG_DEFAULT_COLOR,
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
  push_box_edges(engine, c, color, life, bypass_depth)
}

@(private)
push_box_edges :: proc(
  engine: ^Engine,
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
  exp := expiry(engine, life)
  segs: [12]debug_line.Segment
  for e, i in edges {
    segs[i] = {a = c[e[0]], b = c[e[1]], color = color, expiry = exp, bypass_depth = bypass_depth}
  }
  debug_line.add_segments(dl(engine), ..segs[:])
}

debug_circle :: proc(
  engine: ^Engine,
  center, normal: [3]f32,
  radius: f32 = 1,
  color: [4]f32 = DEBUG_DEFAULT_COLOR,
  life: f32 = 0,
  bypass_depth: bool = false,
) {
  u, v := orthonormal_basis(linalg.normalize0(normal))
  exp := expiry(engine, life)
  segs: [CIRCLE_SEGMENTS]debug_line.Segment
  fill_circle(segs[:], center, u, v, radius, color, exp, bypass_depth)
  debug_line.add_segments(dl(engine), ..segs[:])
}

debug_sphere :: proc(
  engine: ^Engine,
  center: [3]f32,
  radius: f32 = 1,
  color: [4]f32 = DEBUG_DEFAULT_COLOR,
  life: f32 = 0,
  bypass_depth: bool = false,
) {
  exp := expiry(engine, life)
  segs: [3 * CIRCLE_SEGMENTS]debug_line.Segment
  X :: [3]f32{1, 0, 0}
  Y :: [3]f32{0, 1, 0}
  Z :: [3]f32{0, 0, 1}
  fill_circle(segs[0 * CIRCLE_SEGMENTS:1 * CIRCLE_SEGMENTS], center, Y, Z, radius, color, exp, bypass_depth)
  fill_circle(segs[1 * CIRCLE_SEGMENTS:2 * CIRCLE_SEGMENTS], center, X, Z, radius, color, exp, bypass_depth)
  fill_circle(segs[2 * CIRCLE_SEGMENTS:3 * CIRCLE_SEGMENTS], center, X, Y, radius, color, exp, bypass_depth)
  debug_line.add_segments(dl(engine), ..segs[:])
}

debug_arrow :: proc(
  engine: ^Engine,
  from, to: [3]f32,
  color: [4]f32 = DEBUG_DEFAULT_COLOR,
  life: f32 = 0,
  bypass_depth: bool = false,
) {
  dir := to - from
  length := linalg.length(dir)
  exp := expiry(engine, life)
  if length < 1e-5 {
    debug_line.add_segments(
      dl(engine),
      debug_line.Segment{a = from, b = to, color = color, expiry = exp, bypass_depth = bypass_depth},
    )
    return
  }
  d := dir / length
  u, v := orthonormal_basis(d)
  head_len := min(length * 0.2, 0.5)
  head_r := head_len * 0.4
  base := to - d * head_len
  segs: [5]debug_line.Segment
  segs[0] = {a = from, b = to, color = color, expiry = exp, bypass_depth = bypass_depth}
  for i in 0 ..< 4 {
    t := f32(i) / 4.0 * math.TAU
    p := base + u * (head_r * math.cos(t)) + v * (head_r * math.sin(t))
    segs[1 + i] = {a = to, b = p, color = color, expiry = exp, bypass_depth = bypass_depth}
  }
  debug_line.add_segments(dl(engine), ..segs[:])
}

debug_axes :: proc(
  engine: ^Engine,
  origin: [3]f32,
  rotation: quaternion128 = 1,
  scale: f32 = 1,
  life: f32 = 0,
  bypass_depth: bool = false,
) {
  x := linalg.quaternion_mul_vector3(rotation, [3]f32{scale, 0, 0})
  y := linalg.quaternion_mul_vector3(rotation, [3]f32{0, scale, 0})
  z := linalg.quaternion_mul_vector3(rotation, [3]f32{0, 0, scale})
  exp := expiry(engine, life)
  // Canonical axis colors (pure RGB) — independent of DEBUG_PALETTE.BLUE which is tinted.
  segs := [3]debug_line.Segment {
    {a = origin, b = origin + x, color = {1, 0, 0, 1}, expiry = exp, bypass_depth = bypass_depth},
    {a = origin, b = origin + y, color = {0, 1, 0, 1}, expiry = exp, bypass_depth = bypass_depth},
    {a = origin, b = origin + z, color = {0, 0, 1, 1}, expiry = exp, bypass_depth = bypass_depth},
  }
  debug_line.add_segments(dl(engine), ..segs[:])
}

debug_point :: proc(
  engine: ^Engine,
  p: [3]f32,
  size: f32 = 0.1,
  color: [4]f32 = DEBUG_DEFAULT_COLOR,
  life: f32 = 0,
  bypass_depth: bool = false,
) {
  h := size * 0.5
  exp := expiry(engine, life)
  segs := [3]debug_line.Segment {
    {a = p - {h, 0, 0}, b = p + {h, 0, 0}, color = color, expiry = exp, bypass_depth = bypass_depth},
    {a = p - {0, h, 0}, b = p + {0, h, 0}, color = color, expiry = exp, bypass_depth = bypass_depth},
    {a = p - {0, 0, h}, b = p + {0, 0, h}, color = color, expiry = exp, bypass_depth = bypass_depth},
  }
  debug_line.add_segments(dl(engine), ..segs[:])
}
