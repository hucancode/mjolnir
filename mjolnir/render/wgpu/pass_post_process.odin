package wgpu_backend

import "base:intrinsics"
import "core:reflect"
import wgpu "vendor:wgpu"

// GrayscaleEffect desaturates the image. Effect structs are copied verbatim into the uniforms,
// so their layout must match each shader's PostUniforms.
GrayscaleEffect :: struct {
  weights:  [3]f32, // zero = Rec. 601 luma
  strength: f32,
}

// ToneMapEffect maps HDR color to display range with an exposure and gamma.
ToneMapEffect :: struct {
  exposure: f32,
  gamma:    f32,
}

// BlurEffect blurs the image in two separable passes.
BlurEffect :: struct {
  radius:         f32,
  weight_falloff: f32, // 0.0 = box blur, 1.0 = gaussian blur
}

// BloomEffect adds a blurred copy of the pixels above threshold.
BloomEffect :: struct {
  threshold:   f32,
  intensity:   f32,
  blur_radius: f32,
}

// OutlineEffect draws edges found in the normal and depth images.
OutlineEffect :: struct {
  color:     [3]f32,
  thickness: f32,
}

// FogEffect blends toward color between depth start and end.
FogEffect :: struct {
  color: [3]f32,
  start: f32,
  end:   f32,
}

// CrossHatchEffect hatches pixels darker than lum_thresholds[i] (tonemapped luminance) with
// stroke family i: the two diagonals, then both shifted by hatch_offset_y.
CrossHatchEffect :: struct {
  hatch_offset_y: f32,
  lum_thresholds: [4]f32,
}

// DoFEffect blurs pixels away from the focus plane.
DoFEffect :: struct {
  focus_distance:  f32, // Distance to the focus plane
  focus_range:     f32, // Range where objects are in focus
  blur_strength:   f32, // Maximum blur radius
  bokeh_intensity: f32, // Bokeh effect intensity
}

// PostprocessEffect is one entry of the effect stack; nil copies the input to the output unchanged.
PostprocessEffect :: union {
  GrayscaleEffect,
  ToneMapEffect,
  BlurEffect,
  BloomEffect,
  OutlineEffect,
  FogEffect,
  CrossHatchEffect,
  DoFEffect,
}

// PostPass is one fullscreen pass of the effect stack: pass `pass` of effect (blur and bloom
// take two) reads input, the previous pass's output, and original, the previous pass's input,
// and writes output; NO_TEXTURE (0) is the presented image. A nil effect copies input.
PostPass :: struct {
  effect:                  PostprocessEffect,
  pass:                    u32,
  input, original, output: TextureHandle,
}

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
#assert(len(EFFECTS) == intrinsics.type_union_variant_count(PostprocessEffect) + 1)
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
  effect:      PostprocessEffect,
}
#assert(offset_of(PostUniforms, effect) == 16)

@(private)
post_process_init :: proc(b: ^Backend) {
  formats := [2]wgpu.TextureFormat{FORMATS[HDR_COLOR_FORMAT], b.surface_view_format}
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
post_process_record :: proc(b: ^Backend, desc: ^FrameDesc, encoder: wgpu.CommandEncoder, output: wgpu.TextureView, cam: ^FrameCamera) {
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
