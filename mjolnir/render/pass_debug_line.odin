#+private
package render

import "gpu"
import "core:sync"
import vk "vendor:vulkan"

MAX_SEGMENTS :: 65536

// A queued line, and the GPU record the debug line shader pulls its two
// vertices from. debug_line_add stamps `expiry` and `bypass_depth`.
DebugLineSegment :: struct {
  a:            [3]f32,
  // render clock time the segment is dropped at; ONE_FRAME_EXPIRY draws it
  // once
  expiry:       f32,
  b:            [3]f32,
  // drawn over the scene instead of depth-tested
  bypass_depth: b32,
  color:        [4]f32,
}
#assert(size_of(DebugLineSegment) == 48)

DebugLineRenderer :: struct {
  segments: [dynamic]DebugLineSegment,
  now:      f32,
  mu:       sync.Mutex,
}

debug_line_init :: proc(r: ^Manager) -> vk.Result {
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
  r.debug_line_renderer.segments = make([dynamic]DebugLineSegment, 0, 1024)
  return .SUCCESS
}

// Sentinel for one-frame draws; dropped after the first debug_line_record() packs them.
ONE_FRAME_EXPIRY :: f32(-1.0)

// Advance the clock that segment lifetimes count against.
debug_line_advance :: proc(self: ^DebugLineRenderer, delta_time: f32) {
  sync.mutex_lock(&self.mu)
  self.now += delta_time
  sync.mutex_unlock(&self.mu)
}

// Queue `segs` (a, b and color set) for `life` seconds of the render clock,
// one frame when zero. The oldest segments make room past MAX_SEGMENTS.
debug_line_add :: proc(self: ^DebugLineRenderer, life: f32, bypass_depth: bool, segs: ..DebugLineSegment) {
  if len(segs) == 0 do return
  sync.mutex_lock(&self.mu)
  defer sync.mutex_unlock(&self.mu)
  total := len(self.segments) + len(segs)
  if total > MAX_SEGMENTS {
    overflow := total - MAX_SEGMENTS
    if overflow >= len(self.segments) {
      clear(&self.segments)
    } else {
      copy(self.segments[:len(self.segments) - overflow], self.segments[overflow:])
      resize(&self.segments, len(self.segments) - overflow)
    }
  }
  expiry := ONE_FRAME_EXPIRY if life <= 0 else self.now + life
  for seg in segs {
    s := seg
    s.expiry = expiry
    s.bypass_depth = b32(bypass_depth)
    append(&self.segments, s)
  }
}

// Draw the queued segments over the main camera's image `color_view`:
// depth-tested ones against `depth_image`, then the bypass_depth ones on top.
debug_line_record :: proc(
  r: ^Manager,
  frame_index: u32,
  camera_index: u32,
  color_view: vk.ImageView,
  extent: vk.Extent2D,
  depth_image: ^gpu.Image,
) {
  self := &r.debug_line_renderer
  cmd := r.command_buffers[frame_index]
  sync.mutex_lock(&self.mu)
  defer sync.mutex_unlock(&self.mu)
  if len(self.segments) == 0 do return
  table := frame_table(r, .DEBUG_LINES, DebugLineSegment, frame_index)
  // Depth-tested lines pack from the front, overlay lines from the back.
  // Expired and one-frame segments are dropped while compacting in place.
  front, back := 0, MAX_SEGMENTS
  write := 0
  for seg in self.segments {
    if seg.expiry > 0 && seg.expiry < self.now do continue
    if seg.bypass_depth {
      back -= 1
      table[back] = seg
    } else {
      table[front] = seg
      front += 1
    }
    if seg.expiry != ONE_FRAME_EXPIRY {
      self.segments[write] = seg
      write += 1
    }
  }
  resize(&self.segments, write)
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
  // two vertices per segment
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
