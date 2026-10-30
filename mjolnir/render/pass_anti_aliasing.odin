package render

import "rhi"

// Anti-aliasing: one fullscreen pass per camera, after the forward pass, reads the lit image
// (LIT) and writes FINAL_IMAGE whole: a copy for .NONE, FXAA for .FXAA
// (shader/anti_aliasing.slang). It runs on post.slang's interface.

@(private)
anti_aliasing_init :: proc(self: ^Renderer) -> bool {
  self.pipelines[.ANTI_ALIASING] = post_pipeline_create(self, shader_source("anti_aliasing"), HDR_COLOR_FORMAT) or_return
  return true
}

@(private)
anti_aliasing_record :: proc(self: ^Renderer, cmd: rhi.CommandList, f: u32, cam: u32) {
  camera, images := &self.cameras[cam], &self.camera_targets[cam].images
  lit := images[.LIT][f]
  colors := [1]rhi.ColorTarget{{texture = images[.FINAL_IMAGE][f], load = .DONT_CARE}}
  dev.cmd_begin_pass(&self.gpu, cmd, {colors = colors[:]})
  defer dev.cmd_end_pass(&self.gpu, cmd)
  push := ShaderPush {
    camera_index         = cam,
    input_image_index    = u32(lit),
    original_image_index = u32(lit),
    params               = pack_params(camera.anti_aliasing),
  }
  pipeline_bind(self, cmd, self.pipelines[.ANTI_ALIASING], .USER, f, &push, .POST, lit, lit, images[.NORMAL][f], images[.DEPTH][f])
  dev.cmd_draw(&self.gpu, cmd, 3, 1, 0, 0)
}
