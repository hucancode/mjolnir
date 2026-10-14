package wgpu_backend

import wgpu "vendor:wgpu"

// Debug line segments live in two rings of DEBUG_RING in the debug line table:
// [0] depth-tested, [1] drawn over the scene.
MAX_SEGMENTS :: 65536
DEBUG_RING :: MAX_SEGMENTS / 2

@(private = "file")
DEBUG_LINE_WGSL :: #load("shader/common.wgsl", string) + #load("shader/debug_line.wgsl", string)

// One pipeline per ring: WebGPU has no dynamic depth test.
@(private)
debug_line_init :: proc(b: ^Backend) {
  formats := [?]wgpu.TextureFormat{b.surface_view_format}
  for &pipeline, ring in b.debug_line_pipelines {
    pipeline = graphics_pipeline(
      b,
      {
        source = DEBUG_LINE_WGSL,
        scene = .DEBUG_LINE,
        topology = .LineList,
        color_formats = formats[:],
        blend = &BLEND_ALPHA,
        depth = true,
        depth_compare = .LessEqual if ring == 0 else .Always,
        fragment = true,
      },
    )
  }
}

// The shader pulls each segment's two vertices from the debug line table and skips a segment
// past its expiry.
@(private)
debug_line_record :: proc(b: ^Backend, desc: ^FrameDesc, encoder: wgpu.CommandEncoder, cam: ^FrameCamera, output: wgpu.TextureView) {
  counts := desc.debug_line_counts
  if counts == {} do return
  color := wgpu.RenderPassColorAttachment{view = output, depthSlice = wgpu.DEPTH_SLICE_UNDEFINED, loadOp = .Load, storeOp = .Store}
  depth := wgpu.RenderPassDepthStencilAttachment{view = b.textures[cam.attachments[.DEPTH]].view, depthReadOnly = true}
  rp := wgpu.CommandEncoderBeginRenderPass(encoder, &{colorAttachmentCount = 1, colorAttachments = &color, depthStencilAttachment = &depth})
  defer {
    wgpu.RenderPassEncoderEnd(rp)
    wgpu.RenderPassEncoderRelease(rp)
  }
  u := struct {
    camera_index: u32,
    time:         f32,
  }{cam.index, desc.debug_line_time}
  offset := uniform(b, &u)
  wgpu.RenderPassEncoderSetBindGroup(rp, 0, b.scene_groups[.DEBUG_LINE])
  wgpu.RenderPassEncoderSetBindGroup(rp, 1, group(b, {layout = .NONE}))
  wgpu.RenderPassEncoderSetBindGroup(rp, 2, b.frame_group, {offset})
  for count, ring in counts {
    if count == 0 do continue
    wgpu.RenderPassEncoderSetPipeline(rp, b.debug_line_pipelines[ring])
    wgpu.RenderPassEncoderDraw(rp, 2 * count, 1, u32(ring) * 2 * DEBUG_RING, 0)
  }
}
