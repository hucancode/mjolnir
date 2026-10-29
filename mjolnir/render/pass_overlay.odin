package render

import "core:math/linalg"
import "core:slice"
import "rhi"

// The overlay draws render's 2D batches (UIBatch) into the backbuffer after post-processing,
// with one pipeline and one vertex stream.

@(private = "file")
OverlayPush :: struct {
  projection: matrix[4, 4]f32,
  texture:    TextureHandle,
}

@(private)
overlay_init :: proc(self: ^Renderer) -> bool {
  self.ui_batches = make([dynamic]UIBatch, 0, 64)
  self.ui_vertices = make([dynamic]Vertex2D, 0, UI_MAX_VERTICES)
  self.ui_indices = make([dynamic]u32, 0, UI_MAX_INDICES)
  attributes := [?]rhi.VertexAttribute {
    {location = 0, format = .F32X2, offset = u32(offset_of(Vertex2D, pos))},
    {location = 1, format = .F32X2, offset = u32(offset_of(Vertex2D, uv))},
    {location = 2, format = .UNORM8X4, offset = u32(offset_of(Vertex2D, color))},
  }
  streams := [?]rhi.VertexBuffer{{stride = size_of(Vertex2D), attributes = attributes[:]}}
  formats := [?]TextureFormat{.BACKBUFFER}
  desc := rhi.GraphicsPipelineDesc {
    shader = shader_source("ui"),
    layout = pipeline_layout(self, .NONE, .SINGLE),
    vertex = streams[:],
    color_formats = formats[:],
    blend = .ALPHA,
  }
  self.pipelines[.OVERLAY] = dev.graphics_pipeline_create(&self.gpu, desc) or_return
  return true
}

// Writes the frame's 2D vertices and indices into its buffers.
@(private)
overlay_upload :: proc(self: ^Renderer, f: u32) {
  if len(self.ui_indices) == 0 do return
  dev.buffer_write(&self.gpu, self.buffers[.UI_VERTICES][f], 0, slice.to_bytes(self.ui_vertices[:]))
  dev.buffer_write(&self.gpu, self.buffers[.UI_INDICES][f], 0, slice.to_bytes(self.ui_indices[:]))
}

@(private)
overlay_record :: proc(self: ^Renderer, cmd: rhi.CommandList, f: u32) {
  if len(self.ui_indices) == 0 do return
  colors := [1]rhi.ColorTarget{{texture = BACKBUFFER, load = .LOAD}}
  dev.cmd_begin_pass(&self.gpu, cmd, {colors = colors[:]})
  dev.cmd_bind_pipeline(&self.gpu, cmd, self.pipelines[.OVERLAY])
  scene_bind(self, cmd, .NONE, f)
  extent := dev.extent(&self.gpu)
  // pixel y grows down, as clip-space y does
  push := OverlayPush{projection = linalg.matrix_ortho3d_f32(0, f32(extent.x), 0, f32(extent.y), -1, 1)}
  dev.cmd_bind_vertex(&self.gpu, cmd, 0, self.buffers[.UI_VERTICES][f], 0)
  dev.cmd_bind_index(&self.gpu, cmd, self.buffers[.UI_INDICES][f], 0)
  for &batch in self.ui_batches {
    if batch.index_count == 0 do continue
    s := batch.scissor
    if s.z <= 0 || s.w <= 0 do continue
    dev.cmd_set_scissor(&self.gpu, cmd, u32(s.x), u32(s.y), u32(s.z), u32(s.w))
    texture_bind(self, cmd, .SINGLE, batch.texture)
    push.texture = batch.texture
    dev.cmd_push(&self.gpu, cmd, &push, size_of(push))
    dev.cmd_draw_indexed(&self.gpu, cmd, batch.index_count, 1, batch.first_index, 0, 0)
  }
  dev.cmd_end_pass(&self.gpu, cmd)
}
