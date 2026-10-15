package render

import "rhi"

// Debug lines are drawn over the main camera's image after post-processing. The shader pulls
// each segment's two vertices from the debug line table and skips a segment past its expiry;
// ring 0 is depth-tested against the camera's depth, ring 1 drawn over everything.

@(private)
DebugLineState :: struct {
  // by ring
  pipelines: [2]rhi.Pipeline,
}

@(private = "file")
DebugLinePush :: struct {
  camera_index: u32,
  time:         f32,
}

@(private)
debug_line_init :: proc(r: ^Renderer) -> bool {
  shader := rhi.ShaderSource {
    spirv = {vert = spirv("shader/vulkan/debug_line/vert.spv"), frag = spirv("shader/vulkan/debug_line/frag.spv")},
    wgsl = wgsl_join(wgsl("shader/wgpu/common.wgsl"), wgsl("shader/wgpu/debug_line.wgsl")),
  }
  formats := [?]TextureFormat{.BACKBUFFER}
  for &pipeline, ring in r.debug_line.pipelines {
    desc := rhi.GraphicsPipelineDesc {
      shader        = shader,
      layout        = pipeline_layout(r, .DEBUG_LINE),
      topology      = .LINE_LIST,
      color_formats = formats[:],
      blend         = .ALPHA,
      depth         = rhi.DepthState{compare = .LESS_EQUAL if ring == 0 else .ALWAYS},
    }
    pipeline = dev.graphics_pipeline_create(&r.gpu, desc) or_return
  }
  return true
}

@(private)
debug_line_record :: proc(r: ^Renderer, cmd: rhi.CommandList, f: u32, cam: ^FrameCamera) {
  counts := r.debug_line_counts
  if counts == {} do return
  colors := [1]rhi.ColorTarget{{texture = BACKBUFFER, load = .LOAD}}
  dev.cmd_begin_pass(&r.gpu, cmd, {colors = colors[:], depth = rhi.DepthTarget{texture = cam.attachments[.DEPTH], load = .LOAD, read_only = true}})
  push := DebugLinePush{cam.index, r.debug_line_time}
  pipeline_bind(r, cmd, r.debug_line.pipelines[0], .DEBUG_LINE, f, &push, .NONE)
  for count, ring in counts {
    if count == 0 do continue
    dev.cmd_bind_pipeline(&r.gpu, cmd, r.debug_line.pipelines[ring])
    dev.cmd_draw(&r.gpu, cmd, 2 * count, 1, u32(ring) * 2 * DEBUG_RING, 0)
  }
  dev.cmd_end_pass(&r.gpu, cmd)
}
