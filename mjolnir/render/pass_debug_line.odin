#+private
package render

import "gpu"
import "core:log"
import "core:sync"
import vk "vendor:vulkan"

DEBUG_LINE_SHADER_VERT :: #load("shader/debug_line/vert.spv")
DEBUG_LINE_SHADER_FRAG :: #load("shader/debug_line/frag.spv")

MAX_SEGMENTS :: 65536
// Every queued segment fits, so debug_line_record never drops one.
MAX_VERTICES :: 2 * MAX_SEGMENTS

DebugLineVertex :: struct {
  position: [3]f32,
  color:    [4]f32,
}

// A line to draw. `life` is how long it stays, in seconds of the clock
// advanced by `advance`; zero or less draws it for one frame.
DebugLineSegment :: struct {
  a, b:         [3]f32,
  color:        [4]f32,
  life:         f32,
  bypass_depth: bool,
}

DebugLineQueued :: struct {
  using segment: DebugLineSegment,
  expiry:        f32,
}

DebugLineRenderer :: struct {
  pipeline_layout: vk.PipelineLayout,
  pipeline:        vk.Pipeline,
  vertex_buffers:  [gpu.FRAMES_IN_FLIGHT]gpu.MutableBuffer(DebugLineVertex),
  segments:        [dynamic]DebugLineQueued,
  now:             f32,
  mu:              sync.Mutex,
}

debug_line_init :: proc(
  self: ^DebugLineRenderer,
  gctx: ^gpu.GPUContext,
  camera_set_layout: vk.DescriptorSetLayout,
  color_format: vk.Format,
) -> (
  ret: vk.Result,
) {
  for i in 0 ..< gpu.FRAMES_IN_FLIGHT {
    self.vertex_buffers[i] = gpu.create_mutable_buffer(
      gctx,
      DebugLineVertex,
      MAX_VERTICES,
      {.VERTEX_BUFFER},
    ) or_return
  }

  self.pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange{stageFlags = {.VERTEX}, size = size_of(u32)},
    camera_set_layout,
  ) or_return


  bindings := [?]vk.VertexInputBindingDescription {
    {binding = 0, stride = size_of(DebugLineVertex), inputRate = .VERTEX},
  }
  attrs := [?]vk.VertexInputAttributeDescription {
    {location = 0, binding = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(DebugLineVertex, position))},
    {location = 1, binding = 0, format = .R32G32B32A32_SFLOAT, offset = u32(offset_of(DebugLineVertex, color))},
  }
  // Depth test toggled dynamically per draw to fold overlay variant into the same pipeline.
  dyn_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR, .DEPTH_TEST_ENABLE}
  color_formats := [?]vk.Format{color_format}
  blend := [?]vk.PipelineColorBlendAttachmentState{gpu.BLEND_ALPHA}
  self.pipeline = gpu.create_graphics_pipeline(
    gctx,
    {
      vert = DEBUG_LINE_SHADER_VERT,
      frag = DEBUG_LINE_SHADER_FRAG,
      vertex_bindings = bindings[:],
      vertex_attributes = attrs[:],
      topology = .LINE_LIST,
      raster = gpu.LINE_RASTERIZER,
      depth = gpu.READ_ONLY_DEPTH_STATE,
      blend = blend[:],
      color_formats = color_formats[:],
      depth_format = .D32_SFLOAT,
      dynamic_states = dyn_states[:],
      layout = self.pipeline_layout,
    },
  ) or_return

  self.segments = make([dynamic]DebugLineQueued, 0, 1024)
  log.debugf("debug_line renderer initialized")
  return .SUCCESS
}

debug_line_shutdown :: proc(self: ^DebugLineRenderer, gctx: ^gpu.GPUContext) {
  delete(self.segments)
  for i in 0 ..< gpu.FRAMES_IN_FLIGHT {
    gpu.mutable_buffer_destroy(gctx.device, &self.vertex_buffers[i])
  }
  vk.DestroyPipeline(gctx.device, self.pipeline, nil)
  vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
  self.pipeline = 0
  self.pipeline_layout = 0
}

// Sentinel for one-frame draws; dropped after the first debug_line_record() packs them.
ONE_FRAME_EXPIRY :: f32(-1.0)

// Advance the clock that segment lifetimes count against.
debug_line_advance :: proc(self: ^DebugLineRenderer, delta_time: f32) {
  sync.mutex_lock(&self.mu)
  self.now += delta_time
  sync.mutex_unlock(&self.mu)
}

debug_line_add_segments :: proc(self: ^DebugLineRenderer, segs: ..DebugLineSegment) {
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
  for seg in segs {
    expiry := ONE_FRAME_EXPIRY if seg.life <= 0 else self.now + seg.life
    append(&self.segments, DebugLineQueued{segment = seg, expiry = expiry})
  }
}

debug_line_record :: proc(
  self: ^DebugLineRenderer,
  cmd: vk.CommandBuffer,
  frame_index: u32,
  camera_set: vk.DescriptorSet,
  camera_index: u32,
  color_view: vk.ImageView,
  extent: vk.Extent2D,
  depth_image: ^gpu.Image,
) {
  sync.mutex_lock(&self.mu)
  defer sync.mutex_unlock(&self.mu)

  if len(self.segments) == 0 do return

  vbuf := &self.vertex_buffers[frame_index]
  mapped := gpu.get_all(vbuf)
  now := self.now

  // Depth-tested lines pack from the front, overlay lines from the back.
  // Expired and one-frame segments are dropped while compacting in place.
  front, back := 0, MAX_VERTICES
  write := 0
  for seg in self.segments {
    if seg.expiry > 0 && seg.expiry < now do continue
    v: []DebugLineVertex
    if seg.bypass_depth {
      back -= 2
      v = mapped[back:][:2]
    } else {
      v = mapped[front:][:2]
      front += 2
    }
    v[0] = {position = seg.a, color = seg.color}
    v[1] = {position = seg.b, color = seg.color}
    if seg.expiry != ONE_FRAME_EXPIRY {
      self.segments[write] = seg
      write += 1
    }
  }
  resize(&self.segments, write)

  if front == 0 && back == MAX_VERTICES do return

  gpu.begin_rendering(
    cmd,
    extent,
    gpu.create_depth_attachment(
      depth_image.view,
      .LOAD,
      .STORE,
    ),
    gpu.create_color_attachment(color_view, .LOAD, .STORE),
  )
  gpu.set_viewport_scissor(cmd, extent)

  camera_index := camera_index
  offset := vk.DeviceSize(0)
  vbuf_h := vbuf.buffer
  vk.CmdBindVertexBuffers(cmd, 0, 1, &vbuf_h, &offset)
  descs := [?]vk.DescriptorSet{camera_set}
  vk.CmdBindDescriptorSets(cmd, .GRAPHICS, self.pipeline_layout, 0, 1, raw_data(descs[:]), 0, nil)
  vk.CmdPushConstants(cmd, self.pipeline_layout, {.VERTEX}, 0, size_of(u32), &camera_index)

  vk.CmdBindPipeline(cmd, .GRAPHICS, self.pipeline)
  if front > 0 {
    vk.CmdSetDepthTestEnable(cmd, true)
    vk.CmdDraw(cmd, u32(front), 1, 0, 0)
  }
  if back < MAX_VERTICES {
    vk.CmdSetDepthTestEnable(cmd, false)
    vk.CmdDraw(cmd, u32(MAX_VERTICES - back), 1, u32(back), 0)
  }
  vk.CmdEndRendering(cmd)
}
