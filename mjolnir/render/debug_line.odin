package render

import "../geometry"
import "core:math"
import "core:math/linalg"
import "core:sync"

// Also the GPU record the debug line shader pulls its two vertices from.
@(private)
DebugLineSegment :: struct {
  a:            [3]f32,
  // render clock time the shader stops drawing the segment after
  expiry:       f32,
  b:            [3]f32,
  _:            u32,
  color:        [4]f32,
}
#assert(size_of(DebugLineSegment) == 48)

// Segments beyond DEBUG_RING per ring between two frames are dropped. life <= 0 shows the
// segment for one frame.
@(private)
debug_line_add :: proc(self: ^Renderer, life: f32, bypass_depth: bool, segs: ..DebugLineSegment) {
  sync.mutex_lock(&self.debug_mutex)
  defer sync.mutex_unlock(&self.debug_mutex)
  inbox := &self.debug_lines[1 if bypass_depth else 0]
  if len(inbox) + len(segs) > DEBUG_RING do return
  // one-frame segments (life <= 0) are stamped at flush, once the clock for the frame that
  // draws them is known; update may advance it between this call and that frame
  expiry: f32 = -1
  if life > 0 do expiry = f32(self.time) + life
  for seg in segs {
    s := seg
    s.expiry = expiry
    append(inbox, s)
  }
}

// Moves the segments added since the last frame into the write table's rings; the oldest
// make room when a ring is full. Caller holds the render mutex.
@(private)
flush_debug_lines :: proc(self: ^Renderer) {
  sync.mutex_lock(&self.debug_mutex)
  defer sync.mutex_unlock(&self.debug_mutex)
  table := write_table(self, .DEBUG_LINES, DebugLineSegment)
  for &inbox, ring in self.debug_lines {
    if len(inbox) == 0 do continue
    start := int(self.debug_filled[ring] % DEBUG_RING)
    for seg, k in inbox {
      seg := seg
      if seg.expiry < 0 do seg.expiry = f32(self.time)
      table[ring * DEBUG_RING + (start + k) % DEBUG_RING] = seg
    }
    // the ring's written run, which wraps past its end at most once (inboxes hold a ring at most)
    first := min(len(inbox), DEBUG_RING - start)
    mark_dirty(self, .DEBUG_LINES, ring * DEBUG_RING + start, first)
    mark_dirty(self, .DEBUG_LINES, ring * DEBUG_RING, len(inbox) - first)
    self.debug_filled[ring] += u64(len(inbox))
    clear(&inbox)
  }
}

// Every debug_* proc takes a color (COLOR_RGB holds the stock ones), `life`, the seconds the
// shape stays (0 for one frame), and `bypass_depth` to draw it over everything.

@(private = "file")
CIRCLE_SEGMENTS :: 24

@(private = "file")
fill_circle :: proc(
  segs: []DebugLineSegment,
  center, u, v: [3]f32,
  radius: f32,
  color: [4]f32,
) {
  prev := center + u * radius
  for i in 1 ..= CIRCLE_SEGMENTS {
    t := f32(i) / f32(CIRCLE_SEGMENTS) * math.TAU
    p := center + u * (radius * math.cos(t)) + v * (radius * math.sin(t))
    segs[i - 1] = {a = prev, b = p, color = color}
    prev = p
  }
}

// debug_segment queues a line from a to b; life is seconds to live, 0 for one frame.
debug_segment :: proc(
  self: ^Renderer,
  a, b: [3]f32,
  color: [4]f32 = COLOR_RGB[.WHITE],
  life: f32 = 0,
  bypass_depth: bool = false,
) {
  debug_line_add(self, life, bypass_depth, {a = a, b = b, color = color})
}

// debug_aabb queues the wireframe of the box lo..hi.
debug_aabb :: proc(
  self: ^Renderer,
  lo, hi: [3]f32,
  color: [4]f32 = COLOR_RGB[.WHITE],
  life: f32 = 0,
  bypass_depth: bool = false,
) {
  debug_cube(self, (lo + hi) * 0.5, 1, (hi - lo) * 0.5, color, life, bypass_depth)
}

// debug_cube queues a wireframe box at center with the given rotation, half_extents along each
// axis (as a cube primitive scaled by them).
debug_cube :: proc(
  self: ^Renderer,
  center: [3]f32,
  rotation: quaternion128 = 1,
  half_extents: [3]f32 = {0.5, 0.5, 0.5},
  color: [4]f32 = COLOR_RGB[.WHITE],
  life: f32 = 0,
  bypass_depth: bool = false,
) {
  h := half_extents
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
  self: ^Renderer,
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
    segs[i] = {a = c[e[0]], b = c[e[1]], color = color}
  }
  debug_line_add(self, life, bypass_depth, ..segs[:])
}

// debug_circle queues a circle around center in the plane perpendicular to normal.
debug_circle :: proc(
  self: ^Renderer,
  center, normal: [3]f32,
  radius: f32 = 1,
  color: [4]f32 = COLOR_RGB[.WHITE],
  life: f32 = 0,
  bypass_depth: bool = false,
) {
  if normal == 0 do return
  u, v := geometry.tangent_basis(linalg.normalize(normal))
  segs: [CIRCLE_SEGMENTS]DebugLineSegment
  fill_circle(segs[:], center, u, v, radius, color)
  debug_line_add(self, life, bypass_depth, ..segs[:])
}

// debug_sphere queues three orthogonal circles around center.
debug_sphere :: proc(
  self: ^Renderer,
  center: [3]f32,
  radius: f32 = 1,
  color: [4]f32 = COLOR_RGB[.WHITE],
  life: f32 = 0,
  bypass_depth: bool = false,
) {
  segs: [3 * CIRCLE_SEGMENTS]DebugLineSegment
  X :: [3]f32{1, 0, 0}
  Y :: [3]f32{0, 1, 0}
  Z :: [3]f32{0, 0, 1}
  fill_circle(segs[0 * CIRCLE_SEGMENTS:1 * CIRCLE_SEGMENTS], center, Y, Z, radius, color)
  fill_circle(segs[1 * CIRCLE_SEGMENTS:2 * CIRCLE_SEGMENTS], center, X, Z, radius, color)
  fill_circle(segs[2 * CIRCLE_SEGMENTS:3 * CIRCLE_SEGMENTS], center, X, Y, radius, color)
  debug_line_add(self, life, bypass_depth, ..segs[:])
}

// debug_arrow queues an arrow from from to to.
debug_arrow :: proc(
  self: ^Renderer,
  from, to: [3]f32,
  color: [4]f32 = COLOR_RGB[.WHITE],
  life: f32 = 0,
  bypass_depth: bool = false,
) {
  dir := to - from
  length := linalg.length(dir)
  // a zero-length arrow's head collapses onto `to`
  d := linalg.normalize0(dir)
  u, v: [3]f32
  if length > 0 do u, v = geometry.tangent_basis(d)
  head_len := min(length * 0.2, 0.5)
  head_r := head_len * 0.4
  base := to - d * head_len
  segs: [5]DebugLineSegment
  segs[0] = {a = from, b = to, color = color}
  for i in 0 ..< 4 {
    t := f32(i) / 4.0 * math.TAU
    p := base + u * (head_r * math.cos(t)) + v * (head_r * math.sin(t))
    segs[1 + i] = {a = to, b = p, color = color}
  }
  debug_line_add(self, life, bypass_depth, ..segs[:])
}

// debug_axes queues RGB axis lines at origin, rotated and scaled.
debug_axes :: proc(
  self: ^Renderer,
  origin: [3]f32,
  rotation: quaternion128 = 1,
  scale: f32 = 1,
  life: f32 = 0,
  bypass_depth: bool = false,
) {
  x := linalg.quaternion_mul_vector3(rotation, [3]f32{scale, 0, 0})
  y := linalg.quaternion_mul_vector3(rotation, [3]f32{0, scale, 0})
  z := linalg.quaternion_mul_vector3(rotation, [3]f32{0, 0, scale})
  // pure RGB, unlike the tinted COLOR_RGB[.BLUE]
  segs := [3]DebugLineSegment {
    {a = origin, b = origin + x, color = {1, 0, 0, 1}},
    {a = origin, b = origin + y, color = {0, 1, 0, 1}},
    {a = origin, b = origin + z, color = {0, 0, 1, 1}},
  }
  debug_line_add(self, life, bypass_depth, ..segs[:])
}

// debug_point queues a small cross at p.
debug_point :: proc(
  self: ^Renderer,
  p: [3]f32,
  size: f32 = 0.1,
  color: [4]f32 = COLOR_RGB[.WHITE],
  life: f32 = 0,
  bypass_depth: bool = false,
) {
  h := size * 0.5
  segs := [3]DebugLineSegment {
    {a = p - {h, 0, 0}, b = p + {h, 0, 0}, color = color},
    {a = p - {0, h, 0}, b = p + {0, h, 0}, color = color},
    {a = p - {0, 0, h}, b = p + {0, 0, h}, color = color},
  }
  debug_line_add(self, life, bypass_depth, ..segs[:])
}
