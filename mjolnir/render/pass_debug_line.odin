package render

import "core:math"
import "core:math/linalg"
import "core:sync"
import "gpu"
import vk "vendor:vulkan"

@(private)
MAX_SEGMENTS :: 65536

// Also the GPU record the debug line shader pulls its two vertices from.
@(private)
DebugLineSegment :: struct {
  a:            [3]f32,
  // render clock time the segment is dropped at
  expiry:       f32,
  b:            [3]f32,
  // drawn over the scene instead of depth-tested
  bypass_depth: b32,
  color:        [4]f32,
}
#assert(size_of(DebugLineSegment) == 48)

@(private)
debug_line_init :: proc(r: ^Renderer) -> vk.Result {
  // Depth test toggled dynamically per draw to fold overlay variant into the same pipeline.
  dyn_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR, .DEPTH_TEST_ENABLE}
  color_formats := [?]vk.Format{r.swapchain.format.format}
  blend := [?]vk.PipelineColorBlendAttachmentState{gpu.BLEND_ALPHA}
  r.pipelines[.DEBUG_LINE] = gpu.create_graphics_pipeline(
    &r.gctx,
    {
      vert = #load("shader/debug_line/vert.spv"),
      frag = #load("shader/debug_line/frag.spv"),
      topology = .LINE_LIST,
      depth = gpu.READ_ONLY_DEPTH_STATE,
      blend = blend[:],
      color_formats = color_formats[:],
      depth_format = ATTACHMENTS[.DEPTH].format,
      dynamic_states = dyn_states[:],
      layout = r.scene.layout,
    },
  ) or_return
  r.debug_lines = make([dynamic]DebugLineSegment, 0, 1024)
  return .SUCCESS
}

// Sentinel for one-frame draws; dropped after the first debug_line_record() packs them.
@(private)
ONE_FRAME_EXPIRY :: f32(-1.0)

// The oldest segments make room past MAX_SEGMENTS.
@(private)
debug_line_add :: proc(self: ^Renderer, life: f32, bypass_depth: bool, segs: ..DebugLineSegment) {
  if len(segs) == 0 do return
  sync.mutex_lock(&self.debug_mutex)
  defer sync.mutex_unlock(&self.debug_mutex)
  total := len(self.debug_lines) + len(segs)
  if total > MAX_SEGMENTS {
    overflow := total - MAX_SEGMENTS
    if overflow >= len(self.debug_lines) {
      clear(&self.debug_lines)
    } else {
      copy(self.debug_lines[:len(self.debug_lines) - overflow], self.debug_lines[overflow:])
      resize(&self.debug_lines, len(self.debug_lines) - overflow)
    }
  }
  expiry := ONE_FRAME_EXPIRY if life <= 0 else self.debug_time + life
  for seg in segs {
    s := seg
    s.expiry = expiry
    s.bypass_depth = b32(bypass_depth)
    append(&self.debug_lines, s)
  }
}

@(private)
debug_line_record :: proc(
  r: ^Renderer,
  frame_index: u32,
  camera_index: u32,
  color_view: vk.ImageView,
  extent: vk.Extent2D,
  depth_image: ^gpu.Image,
) {
  cmd := r.command_buffers[frame_index]
  sync.mutex_lock(&r.debug_mutex)
  defer sync.mutex_unlock(&r.debug_mutex)
  if len(r.debug_lines) == 0 do return
  table := frame_table(r, .DEBUG_LINES, DebugLineSegment, frame_index)
  // depth-tested lines pack from the front, bypass_depth from the back; expired ones are dropped
  front, back := 0, MAX_SEGMENTS
  write := 0
  for seg in r.debug_lines {
    if seg.expiry > 0 && seg.expiry < r.debug_time do continue
    if seg.bypass_depth {
      back -= 1
      table[back] = seg
    } else {
      table[front] = seg
      front += 1
    }
    if seg.expiry != ONE_FRAME_EXPIRY {
      r.debug_lines[write] = seg
      write += 1
    }
  }
  resize(&r.debug_lines, write)
  if front == 0 && back == MAX_SEGMENTS do return
  gpu.begin_rendering(
    cmd,
    extent,
    gpu.create_depth_attachment(depth_image.view, .LOAD, .STORE),
    gpu.create_color_attachment(color_view, .LOAD, .STORE),
  )
  camera_index := camera_index
  push_constants(r, cmd, &camera_index)
  vk.CmdBindPipeline(cmd, .GRAPHICS, r.pipelines[.DEBUG_LINE])
  if front > 0 {
    vk.CmdSetDepthTestEnable(cmd, true)
    vk.CmdDraw(cmd, u32(2 * front), 1, 0, 0)
  }
  if back < MAX_SEGMENTS {
    vk.CmdSetDepthTestEnable(cmd, false)
    vk.CmdDraw(cmd, u32(2 * (MAX_SEGMENTS - back)), 1, u32(2 * back), 0)
  }
  vk.CmdEndRendering(cmd)
}

// DEBUG_* are the stock debug line colors.
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

@(private = "file")
CIRCLE_SEGMENTS :: 24

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
  color: [4]f32 = DEBUG_WHITE,
  life: f32 = 0,
  bypass_depth: bool = false,
) {
  debug_line_add(self, life, bypass_depth, {a = a, b = b, color = color})
}

// debug_aabb queues the wireframe of the box lo..hi.
debug_aabb :: proc(
  self: ^Renderer,
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

// debug_cube queues a wireframe cube at center with the given rotation and size.
debug_cube :: proc(
  self: ^Renderer,
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
  color: [4]f32 = DEBUG_WHITE,
  life: f32 = 0,
  bypass_depth: bool = false,
) {
  u, v := orthonormal_basis(linalg.normalize0(normal))
  segs: [CIRCLE_SEGMENTS]DebugLineSegment
  fill_circle(segs[:], center, u, v, radius, color)
  debug_line_add(self, life, bypass_depth, ..segs[:])
}

// debug_sphere queues three orthogonal circles around center.
debug_sphere :: proc(
  self: ^Renderer,
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
  fill_circle(segs[0 * CIRCLE_SEGMENTS:1 * CIRCLE_SEGMENTS], center, Y, Z, radius, color)
  fill_circle(segs[1 * CIRCLE_SEGMENTS:2 * CIRCLE_SEGMENTS], center, X, Z, radius, color)
  fill_circle(segs[2 * CIRCLE_SEGMENTS:3 * CIRCLE_SEGMENTS], center, X, Y, radius, color)
  debug_line_add(self, life, bypass_depth, ..segs[:])
}

// debug_arrow queues an arrow from from to to.
debug_arrow :: proc(
  self: ^Renderer,
  from, to: [3]f32,
  color: [4]f32 = DEBUG_WHITE,
  life: f32 = 0,
  bypass_depth: bool = false,
) {
  dir := to - from
  length := linalg.length(dir)
  // a zero-length arrow's head collapses onto `to`
  d := linalg.normalize0(dir)
  u, v := orthonormal_basis(d)
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
  // pure RGB, unlike the tinted DEBUG_BLUE
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
  color: [4]f32 = DEBUG_WHITE,
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
