package render

import "base:intrinsics"
import "core:reflect"
import "rhi"

// The post-process effect stack: fullscreen passes over the main camera's image, each
// effect's fragment shader reading the previous pass's output. The last pass writes the
// backbuffer.

// The fragment shader of each PostprocessEffect tag (0 = nil, a copy).
@(private = "file")
EFFECT_COUNT :: intrinsics.type_union_variant_count(PostprocessEffect) + 1

@(private)
PostState :: struct {
  // [is_last][tag]: every pass writes an HDR ring image but the last, which writes the backbuffer
  pipelines: [2][EFFECT_COUNT]rhi.Pipeline,
}

// Odin stores a union's variant bytes at offset 0, so `effect` puts the active struct at offset 32.
@(private = "file")
PostPush :: struct {
  // camera clip planes, for effects that linearize depth (fog, dof, outline)
  camera_near:          f32,
  camera_far:           f32,
  normal_texture_index: u32,
  depth_texture_index:  u32,
  // the previous pass's output
  input_image_index:    u32,
  // the previous pass's input (bloom V composites over the scene as it entered bloom H)
  original_image_index: u32,
  // this pass of the effect
  pass:                 u32,
  _:                    u32,
  effect:               PostprocessEffect,
}
#assert(offset_of(PostPush, effect) == 32)

@(private)
post_init :: proc(r: ^Renderer) -> bool {
  vertex := wgsl_join(wgsl("shader/wgpu/common.wgsl"), wgsl("shader/wgpu/postprocess.wgsl"))
  frag_spirv := [EFFECT_COUNT][]u8 {
    spirv("shader/vulkan/postprocess/frag.spv"),
    spirv("shader/vulkan/grayscale/frag.spv"),
    spirv("shader/vulkan/tonemap/frag.spv"),
    spirv("shader/vulkan/blur/frag.spv"),
    spirv("shader/vulkan/bloom/frag.spv"),
    spirv("shader/vulkan/outline/frag.spv"),
    spirv("shader/vulkan/fog/frag.spv"),
    spirv("shader/vulkan/crosshatch/frag.spv"),
    spirv("shader/vulkan/dof/frag.spv"),
  }
  frag_wgsl := [EFFECT_COUNT]string {
    wgsl("shader/wgpu/post_copy.wgsl"),
    wgsl("shader/wgpu/post_grayscale.wgsl"),
    wgsl("shader/wgpu/post_tonemap.wgsl"),
    wgsl("shader/wgpu/post_blur.wgsl"),
    wgsl("shader/wgpu/post_bloom.wgsl"),
    wgsl("shader/wgpu/post_outline.wgsl"),
    wgsl("shader/wgpu/post_fog.wgsl"),
    wgsl("shader/wgpu/post_crosshatch.wgsl"),
    wgsl("shader/wgpu/post_dof.wgsl"),
  }
  formats := [2]TextureFormat{HDR_COLOR_FORMAT, .BACKBUFFER}
  for &pipelines, is_last in r.post.pipelines {
    for tag in 0 ..< EFFECT_COUNT {
      desc := rhi.GraphicsPipelineDesc {
        shader = {spirv = {vert = spirv("shader/vulkan/postprocess/vert.spv"), frag = frag_spirv[tag]}, wgsl = wgsl_join(vertex, frag_wgsl[tag])},
        layout = pipeline_layout(r, .NONE, .POST),
        color_formats = formats[is_last:][:1],
      }
      pipelines[tag] = dev.graphics_pipeline_create(&r.gpu, desc) or_return
    }
  }
  return true
}

// Every pass but the last writes a texture; the last writes the backbuffer.
@(private)
post_record :: proc(r: ^Renderer, cmd: rhi.CommandList, f: u32, cam: ^FrameCamera) {
  outputs := make([dynamic]TextureHandle, 0, len(r.post_passes), context.temp_allocator)
  outer: for &p, i in r.post_passes {
    if p.output == 0 do continue
    for q in r.post_passes[:i] do if q.output == p.output do continue outer
    append(&outputs, p.output)
  }
  for &p, i in r.post_passes {
    if i == 0 do barrier_discard(r, cmd, outputs[:])
    else do barrier(r, cmd, .POST_PASS)
    is_last := p.output == 0
    colors := [1]rhi.ColorTarget{{texture = BACKBUFFER if is_last else p.output, load = .DONT_CARE}}
    dev.cmd_begin_pass(&r.gpu, cmd, {colors = colors[:]})
    push := PostPush {
      camera_near          = cam.near,
      camera_far           = cam.far,
      normal_texture_index = u32(cam.attachments[.NORMAL]),
      depth_texture_index  = u32(cam.attachments[.DEPTH]),
      input_image_index    = u32(p.input),
      original_image_index = u32(p.original),
      pass                 = p.pass,
      effect               = p.effect,
    }
    pipeline := r.post.pipelines[int(is_last)][reflect.get_union_variant_raw_tag(p.effect)]
    pipeline_bind(r, cmd, pipeline, .NONE, f, &push, .POST, p.input, p.original, cam.attachments[.NORMAL], cam.attachments[.DEPTH])
    dev.cmd_draw(&r.gpu, cmd, 3, 1, 0, 0)
    dev.cmd_end_pass(&r.gpu, cmd)
  }
}
