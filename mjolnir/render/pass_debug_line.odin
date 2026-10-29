package render

import "rhi"

// Debug lines are drawn over the main camera's image after post-processing. The shader pulls
// each segment's two vertices from the debug line table and skips a segment past its expiry;
// ring 0 is depth-tested against the camera's depth, ring 1 drawn over everything.

@(private)
debug_line_init :: proc(self: ^Renderer) -> bool {
  shader := shader_source("debug_line")
  formats := [?]TextureFormat{.BACKBUFFER}
  for p in BuiltinPipeline.DEBUG_LINE ..= BuiltinPipeline.DEBUG_LINE_OVER {
    desc := rhi.GraphicsPipelineDesc {
      shader        = shader,
      layout        = pipeline_layout(self, .DEBUG_LINE),
      topology      = .LINE_LIST,
      color_formats = formats[:],
      blend         = .ALPHA,
      depth         = rhi.DepthState{compare = .LESS_EQUAL if p == .DEBUG_LINE else .ALWAYS},
    }
    self.pipelines[p] = dev.graphics_pipeline_create(&self.gpu, desc) or_return
  }
  return true
}

@(private)
debug_line_record :: proc(self: ^Renderer, cmd: rhi.CommandList, f: u32, cam: u32) {
  // filled segments of each ring
  counts := [2]u32{u32(min(self.debug_filled[0], DEBUG_RING)), u32(min(self.debug_filled[1], DEBUG_RING))}
  if counts == {} do return
  colors := [1]rhi.ColorTarget{{texture = BACKBUFFER, load = .LOAD}}
  dev.cmd_begin_pass(&self.gpu, cmd, {colors = colors[:], depth = rhi.DepthTarget{texture = self.camera_targets[cam].images[.DEPTH][f], load = .LOAD, read_only = true}})
  // the shader skips segments past their expiry
  camera_index := cam
  pipeline_bind(self, cmd, self.pipelines[.DEBUG_LINE], .DEBUG_LINE, f, &camera_index, .NONE)
  for count, ring in counts {
    if count == 0 do continue
    dev.cmd_bind_pipeline(&self.gpu, cmd, self.pipelines[.DEBUG_LINE if ring == 0 else .DEBUG_LINE_OVER])
    dev.cmd_draw(&self.gpu, cmd, 2 * count, 1, u32(ring) * 2 * DEBUG_RING, 0)
  }
  dev.cmd_end_pass(&self.gpu, cmd)
}
