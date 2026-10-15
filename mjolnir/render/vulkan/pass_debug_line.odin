package vulkan_backend

import rhi "../rhi"

import vk "vendor:vulkan"


@(private)
debug_line_init :: proc(b: ^Backend) -> vk.Result {
  // Depth test toggled dynamically per draw to fold overlay variant into the same pipeline.
  dyn_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR, .DEPTH_TEST_ENABLE}
  color_formats := [?]vk.Format{b.swapchain.format.format}
  blend := [?]vk.PipelineColorBlendAttachmentState{BLEND_ALPHA}
  b.pipelines[.DEBUG_LINE] = create_graphics_pipeline(
    &b.gctx,
    {
      vert = #load("shader/debug_line/vert.spv"),
      frag = #load("shader/debug_line/frag.spv"),
      topology = .LINE_LIST,
      depth = READ_ONLY_DEPTH_STATE,
      blend = blend[:],
      color_formats = color_formats[:],
      depth_format = FORMATS[rhi.ATTACHMENTS[.DEPTH].format],
      dynamic_states = dyn_states[:],
      layout = b.scene.layout,
    },
  ) or_return
  return .SUCCESS
}

// The shader pulls each segment's two vertices from the debug line table and skips a segment
// past its expiry.
@(private)
debug_line_record :: proc(
  b: ^Backend,
  desc: ^rhi.FrameDesc,
  frame_index: u32,
  cam: ^rhi.FrameCamera,
  color_view: vk.ImageView,
  extent: vk.Extent2D,
) {
  cmd := b.command_buffers[frame_index]
  counts := desc.debug_line_counts
  if counts == {} do return
  push := struct {
    camera_index: u32,
    time:         f32,
  }{cam.index, desc.debug_line_time}
  begin_rendering(
    cmd,
    extent,
    create_depth_attachment(texture_image(b, cam.attachments[.DEPTH]).view, .LOAD, .STORE),
    create_color_attachment(color_view, .LOAD, .STORE),
  )
  push_constants(b, cmd, &push)
  vk.CmdBindPipeline(cmd, .GRAPHICS, b.pipelines[.DEBUG_LINE])
  if counts[0] > 0 {
    vk.CmdSetDepthTestEnable(cmd, true)
    vk.CmdDraw(cmd, 2 * counts[0], 1, 0, 0)
  }
  if counts[1] > 0 {
    vk.CmdSetDepthTestEnable(cmd, false)
    vk.CmdDraw(cmd, 2 * counts[1], 1, 2 * rhi.DEBUG_RING, 0)
  }
  vk.CmdEndRendering(cmd)
}
