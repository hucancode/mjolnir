package debug_line

import "../gpu"
import "core:log"
import "core:sync"
import vk "vendor:vulkan"

SHADER_VERT :: #load("../shader/debug_line/vert.spv")
SHADER_FRAG :: #load("../shader/debug_line/frag.spv")

MAX_SEGMENTS :: 65536
// Every queued segment fits, so record never drops one.
MAX_VERTICES :: 2 * MAX_SEGMENTS

Vertex :: struct {
  position: [3]f32,
  color:    [4]f32,
}

// A line to draw. `life` is how long it stays, in seconds of the clock
// advanced by `advance`; zero or less draws it for one frame.
Segment :: struct {
  a, b:         [3]f32,
  color:        [4]f32,
  life:         f32,
  bypass_depth: bool,
}

@(private)
Queued :: struct {
  using segment: Segment,
  expiry:        f32,
}

Renderer :: struct {
  pipeline_layout: vk.PipelineLayout,
  pipeline:        vk.Pipeline,
  vertex_buffers:  [gpu.FRAMES_IN_FLIGHT]gpu.MutableBuffer(Vertex),
  segments:        [dynamic]Queued,
  now:             f32,
  mu:              sync.Mutex,
}

init :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  camera_set_layout: vk.DescriptorSetLayout,
) -> (
  ret: vk.Result,
) {
  for i in 0 ..< gpu.FRAMES_IN_FLIGHT {
    self.vertex_buffers[i] = gpu.create_mutable_buffer(
      gctx,
      Vertex,
      MAX_VERTICES,
      {.VERTEX_BUFFER},
    ) or_return
  }

  self.pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange{stageFlags = {.VERTEX}, size = size_of(u32)},
    camera_set_layout,
  ) or_return

  vert_module := gpu.create_shader_module(gctx.device, SHADER_VERT) or_return
  defer vk.DestroyShaderModule(gctx.device, vert_module, nil)
  frag_module := gpu.create_shader_module(gctx.device, SHADER_FRAG) or_return
  defer vk.DestroyShaderModule(gctx.device, frag_module, nil)

  bindings := [?]vk.VertexInputBindingDescription {
    {binding = 0, stride = size_of(Vertex), inputRate = .VERTEX},
  }
  attrs := [?]vk.VertexInputAttributeDescription {
    {location = 0, binding = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(Vertex, position))},
    {location = 1, binding = 0, format = .R32G32B32A32_SFLOAT, offset = u32(offset_of(Vertex, color))},
  }
  // Depth test toggled dynamically per draw to fold overlay variant into the same pipeline.
  dyn_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR, .DEPTH_TEST_ENABLE}
  color_formats := [?]vk.Format{.B8G8R8A8_SRGB}
  blend := [?]vk.PipelineColorBlendAttachmentState{gpu.BLEND_ADDITIVE}
  self.pipeline = gpu.create_graphics_pipeline(
    gctx,
    {
      vert = vert_module,
      frag = frag_module,
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

  self.segments = make([dynamic]Queued, 0, 1024)
  log.debugf("debug_line renderer initialized")
  return .SUCCESS
}

shutdown :: proc(self: ^Renderer, gctx: ^gpu.GPUContext) {
  delete(self.segments)
  for i in 0 ..< gpu.FRAMES_IN_FLIGHT {
    gpu.mutable_buffer_destroy(gctx.device, &self.vertex_buffers[i])
  }
  vk.DestroyPipeline(gctx.device, self.pipeline, nil)
  vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
  self.pipeline = 0
  self.pipeline_layout = 0
}

// Sentinel for one-frame draws; dropped after the first record() packs them.
@(private)
ONE_FRAME_EXPIRY :: f32(-1.0)

// Advance the clock that segment lifetimes count against.
advance :: proc(self: ^Renderer, delta_time: f32) {
  sync.mutex_lock(&self.mu)
  self.now += delta_time
  sync.mutex_unlock(&self.mu)
}

add_segments :: proc(self: ^Renderer, segs: ..Segment) {
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
    append(&self.segments, Queued{segment = seg, expiry = expiry})
  }
}

record :: proc(
  self: ^Renderer,
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
    v: []Vertex
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
