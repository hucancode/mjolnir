package render

import "core:math/linalg"
import "rhi"

// The overlay draws render's 2D batches (UIBatch) into the backbuffer after post-processing,
// with one pipeline and one vertex stream.

@(private)
OverlayState :: struct {
  pipeline: rhi.Pipeline,
}

@(private = "file")
OverlayPush :: struct {
  projection: matrix[4, 4]f32,
  texture:    TextureHandle,
}

@(private)
overlay_init_pass :: proc(r: ^Renderer) -> bool {
  attributes := [?]rhi.VertexAttribute {
    {location = 0, format = .F32X2, offset = u32(offset_of(Vertex2D, pos))},
    {location = 1, format = .F32X2, offset = u32(offset_of(Vertex2D, uv))},
    {location = 2, format = .UNORM8X4, offset = u32(offset_of(Vertex2D, color))},
  }
  streams := [?]rhi.VertexBuffer{{stride = size_of(Vertex2D), attributes = attributes[:]}}
  formats := [?]TextureFormat{.BACKBUFFER}
  desc := rhi.GraphicsPipelineDesc {
    shader = {
      spirv = {vert = spirv("shader/vulkan/ui/vert.spv"), frag = spirv("shader/vulkan/ui/frag.spv")},
      wgsl = wgsl_join(wgsl("shader/wgpu/common.wgsl"), wgsl("shader/wgpu/ui.wgsl")),
    },
    layout = pipeline_layout(r, .NONE, .SINGLE),
    vertex = streams[:],
    color_formats = formats[:],
    blend = .ALPHA,
  }
  r.overlay_gpu.pipeline = dev.graphics_pipeline_create(&r.gpu, desc) or_return
  return true
}

// Writes the frame's 2D vertices and indices into its buffers.
@(private)
overlay_upload :: proc(r: ^Renderer, f: u32) {
  if len(r.ui_vertices) > 0 do dev.buffer_write(&r.gpu, r.res.ui_vertices[f], 0, ([^]u8)(raw_data(r.ui_vertices))[:len(r.ui_vertices) * size_of(Vertex2D)])
  if len(r.ui_indices) > 0 do dev.buffer_write(&r.gpu, r.res.ui_indices[f], 0, ([^]u8)(raw_data(r.ui_indices))[:len(r.ui_indices) * size_of(u32)])
}

@(private)
overlay_record :: proc(r: ^Renderer, cmd: rhi.CommandList, f: u32) {
  if len(r.ui_batches) == 0 do return
  colors := [1]rhi.ColorTarget{{texture = BACKBUFFER, load = .LOAD}}
  dev.cmd_begin_pass(&r.gpu, cmd, {colors = colors[:]})
  dev.cmd_bind_pipeline(&r.gpu, cmd, r.overlay_gpu.pipeline)
  scene_bind(r, cmd, .NONE, f)
  extent := dev.extent(&r.gpu)
  // pixel y grows down, as clip-space y does
  push := OverlayPush{projection = linalg.matrix_ortho3d_f32(0, f32(extent.x), 0, f32(extent.y), -1, 1)}
  dev.cmd_bind_vertex(&r.gpu, cmd, 0, r.res.ui_vertices[f], 0)
  dev.cmd_bind_index(&r.gpu, cmd, r.res.ui_indices[f], 0)
  for &batch in r.ui_batches {
    if batch.index_count == 0 do continue
    s := batch.scissor
    if s.z <= 0 || s.w <= 0 do continue
    dev.cmd_set_scissor(&r.gpu, cmd, u32(s.x), u32(s.y), u32(s.z), u32(s.w))
    texture_bind(r, cmd, .SINGLE, batch.texture)
    push.texture = batch.texture
    dev.cmd_push(&r.gpu, cmd, &push, size_of(push))
    dev.cmd_draw_indexed(&r.gpu, cmd, batch.index_count, 1, batch.first_index, 0, 0)
  }
  dev.cmd_end_pass(&r.gpu, cmd)
}
