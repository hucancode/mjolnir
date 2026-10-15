package wgpu_backend

import rhi "../rhi"

import "core:math/linalg"
import wgpu "vendor:wgpu"




@(private = "file")
VERTEX2D_ATTRIBUTES := [?]wgpu.VertexAttribute {
  {format = .Float32x2, offset = u64(offset_of(rhi.Vertex2D, pos)), shaderLocation = 0},
  {format = .Float32x2, offset = u64(offset_of(rhi.Vertex2D, uv)), shaderLocation = 1},
  {format = .Unorm8x4, offset = u64(offset_of(rhi.Vertex2D, color)), shaderLocation = 2},
}

@(private = "file")
OVERLAY_WGSL :: #load("shader/common.wgsl", string) + #load("shader/ui.wgsl", string)

// The overlay draws render's 2D batches (FrameDesc.ui_*) into the presented image after
// post-processing, with one pipeline and one vertex stream.
@(private)
overlay_init :: proc(b: ^Backend) {
  buffers := [?]wgpu.VertexBufferLayout{{stepMode = .Vertex, arrayStride = size_of(rhi.Vertex2D), attributeCount = len(VERTEX2D_ATTRIBUTES), attributes = raw_data(VERTEX2D_ATTRIBUTES[:])}}
  formats := [?]wgpu.TextureFormat{b.surface_view_format}
  b.overlay_pipeline = graphics_pipeline(
    b,
    {
      source = OVERLAY_WGSL,
      textures = .SINGLE,
      vertex_buffers = buffers[:],
      topology = .TriangleList,
      color_formats = formats[:],
      blend = &BLEND_ALPHA,
      fragment = true,
    },
  )
  b.ui_vertex_buffer = buffer_create(b, rhi.UI_MAX_VERTICES * size_of(rhi.Vertex2D), {.Vertex, .CopyDst})
  b.ui_index_buffer = buffer_create(b, rhi.UI_MAX_INDICES * size_of(u32), {.Index, .CopyDst})
}

@(private)
overlay_upload :: proc(b: ^Backend, desc: ^rhi.FrameDesc) {
  if len(desc.ui_vertices) > 0 {
    wgpu.QueueWriteBuffer(b.queue, b.ui_vertex_buffer, 0, raw_data(desc.ui_vertices), uint(len(desc.ui_vertices) * size_of(rhi.Vertex2D)))
  }
  if len(desc.ui_indices) > 0 {
    wgpu.QueueWriteBuffer(b.queue, b.ui_index_buffer, 0, raw_data(desc.ui_indices), uint(len(desc.ui_indices) * size_of(u32)))
  }
}

@(private)
overlay_record :: proc(b: ^Backend, desc: ^rhi.FrameDesc, encoder: wgpu.CommandEncoder, output: wgpu.TextureView) {
  if len(desc.ui_batches) == 0 do return
  color := wgpu.RenderPassColorAttachment{view = output, depthSlice = wgpu.DEPTH_SLICE_UNDEFINED, loadOp = .Load, storeOp = .Store}
  rp := wgpu.CommandEncoderBeginRenderPass(encoder, &{colorAttachmentCount = 1, colorAttachments = &color})
  defer {
    wgpu.RenderPassEncoderEnd(rp)
    wgpu.RenderPassEncoderRelease(rp)
  }
  extent := b.surface_extent
  // pixel y grows down, as Vulkan's clip-space y does (clip_output flips it)
  projection := linalg.matrix_ortho3d_f32(0, f32(extent.x), 0, f32(extent.y), -1, 1)
  offset := uniform(b, &projection)
  wgpu.RenderPassEncoderSetPipeline(rp, b.overlay_pipeline)
  wgpu.RenderPassEncoderSetBindGroup(rp, 0, b.scene_groups[.NONE])
  wgpu.RenderPassEncoderSetBindGroup(rp, 2, b.frame_group, {offset})
  wgpu.RenderPassEncoderSetVertexBuffer(rp, 0, b.ui_vertex_buffer, 0, wgpu.BufferGetSize(b.ui_vertex_buffer))
  wgpu.RenderPassEncoderSetIndexBuffer(rp, b.ui_index_buffer, .Uint32, 0, wgpu.BufferGetSize(b.ui_index_buffer))
  for &batch in desc.ui_batches {
    if batch.index_count == 0 do continue
    s := batch.scissor
    if s.z <= 0 || s.w <= 0 do continue
    wgpu.RenderPassEncoderSetScissorRect(rp, u32(s.x), u32(s.y), u32(s.z), u32(s.w))
    wgpu.RenderPassEncoderSetBindGroup(rp, 1, group(b, {layout = .SINGLE, textures = {0 = batch.texture}}))
    wgpu.RenderPassEncoderDrawIndexed(rp, batch.index_count, 1, batch.first_index, 0, 0)
  }
}
