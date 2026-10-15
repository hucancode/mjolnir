package wgpu_backend

import rhi "../rhi"

import "base:intrinsics"
import "core:reflect"
import wgpu "vendor:wgpu"











@(private = "file")
POST_VS :: #load("shader/common.wgsl", string) + #load("shader/postprocess.wgsl", string)

// Fragment shader per PostprocessEffect tag (0 = nil).
@(private = "file")
EFFECTS := [?]string {
  POST_VS + #load("shader/post_copy.wgsl", string),
  POST_VS + #load("shader/post_grayscale.wgsl", string),
  POST_VS + #load("shader/post_tonemap.wgsl", string),
  POST_VS + #load("shader/post_blur.wgsl", string),
  POST_VS + #load("shader/post_bloom.wgsl", string),
  POST_VS + #load("shader/post_outline.wgsl", string),
  POST_VS + #load("shader/post_fog.wgsl", string),
  POST_VS + #load("shader/post_crosshatch.wgsl", string),
  POST_VS + #load("shader/post_dof.wgsl", string),
}
#assert(len(EFFECTS) == intrinsics.type_union_variant_count(rhi.PostprocessEffect) + 1)
@(private)
EFFECT_COUNT :: len(EFFECTS)

// Odin stores a union's variant bytes at offset 0, so `effect` puts the active struct at
// offset 16 (PostUniforms in postprocess.wgsl).
@(private = "file")
PostUniforms :: struct {
  // camera clip planes, for effects that linearize depth (fog, dof, outline)
  camera_near: f32,
  camera_far:  f32,
  // this pass of the effect
  pass:        u32,
  _:           u32,
  effect:      rhi.PostprocessEffect,
}
#assert(offset_of(PostUniforms, effect) == 16)

@(private)
post_process_init :: proc(b: ^Backend) {
  formats := [2]wgpu.TextureFormat{FORMATS[rhi.HDR_COLOR_FORMAT], b.surface_view_format}
  for &pipelines, is_last in b.post_pipelines {
    for source, tag in EFFECTS {
      pipelines[tag] = graphics_pipeline(
        b,
        {source = source, textures = .POST, topology = .TriangleList, color_formats = formats[is_last:][:1], fragment = true},
      )
    }
  }
}

// Every pass but the last writes a texture; the last writes output.
@(private)
post_process_record :: proc(b: ^Backend, desc: ^rhi.FrameDesc, encoder: wgpu.CommandEncoder, output: wgpu.TextureView, cam: ^rhi.FrameCamera) {
  for &p in desc.post_passes {
    is_last := p.output == 0
    color := wgpu.RenderPassColorAttachment {
      view       = output if is_last else b.textures[p.output].view,
      depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
      // the fullscreen triangle overwrites every pixel
      loadOp     = .Clear,
      storeOp    = .Store,
    }
    rp := wgpu.CommandEncoderBeginRenderPass(encoder, &{colorAttachmentCount = 1, colorAttachments = &color})
    u := PostUniforms{camera_near = cam.near, camera_far = cam.far, pass = p.pass, effect = p.effect}
    offset := uniform(b, &u)
    key := GroupKey{layout = .POST, textures = {0 = p.input, 1 = p.original, 2 = cam.attachments[.NORMAL], 3 = cam.attachments[.DEPTH]}}
    wgpu.RenderPassEncoderSetPipeline(rp, b.post_pipelines[int(is_last)][reflect.get_union_variant_raw_tag(p.effect)])
    wgpu.RenderPassEncoderSetBindGroup(rp, 0, b.scene_groups[.NONE])
    wgpu.RenderPassEncoderSetBindGroup(rp, 1, group(b, key))
    wgpu.RenderPassEncoderSetBindGroup(rp, 2, b.frame_group, {offset})
    wgpu.RenderPassEncoderDraw(rp, 3, 1, 0, 0)
    wgpu.RenderPassEncoderEnd(rp)
    wgpu.RenderPassEncoderRelease(rp)
  }
}
