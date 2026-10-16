package render

import "base:intrinsics"
import "core:reflect"
import "rhi"

// The post-process effect stack: fullscreen passes over the main camera's image, each
// effect's fragment shader reading the previous pass's output. The last pass writes the
// backbuffer.

// The fragment shader of each PostprocessEffect tag (0 = nil, a copy).
@(private)
POST_EFFECT_COUNT :: intrinsics.type_union_variant_count(PostprocessEffect) + 1

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
#assert(size_of(PostPush) <= PUSH_SIZE)

@(private)
post_init :: proc(r: ^Renderer) -> bool {
  // every tag but CustomEffect's, whose pipelines post_shader_create makes
  frag_spirv := [POST_EFFECT_COUNT - 1][]u8 {
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
  frag_wgsl := [POST_EFFECT_COUNT - 1]string {
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
  for tag in 0 ..< POST_EFFECT_COUNT - 1 {
    pipelines := post_pipelines_create(r, frag_spirv[tag], frag_wgsl[tag]) or_return
    for p, is_last in pipelines do r.post_pipelines[is_last][tag] = p
  }
  return true
}

// An effect's pipelines, [is_last]: every pass writes an HDR ring image but the last, which
// writes the backbuffer. The fragment shader follows the shared vertex stage: on WebGPU its
// source is appended to common.wgsl and postprocess.wgsl.
@(private = "file")
post_pipelines_create :: proc(r: ^Renderer, frag_spirv: []u8, frag_wgsl: string) -> (pipelines: [2]rhi.Pipeline, ok: bool) {
  vertex := wgsl_join(wgsl("shader/wgpu/common.wgsl"), wgsl("shader/wgpu/postprocess.wgsl"))
  formats := [2]TextureFormat{HDR_COLOR_FORMAT, .BACKBUFFER}
  for &p, is_last in pipelines {
    desc := rhi.GraphicsPipelineDesc {
      shader = {spirv = {vert = spirv("shader/vulkan/postprocess/vert.spv"), frag = frag_spirv}, wgsl = wgsl_join(vertex, frag_wgsl)},
      layout = pipeline_layout(r, .NONE, .POST),
      color_formats = formats[is_last:][:1],
    }
    p = dev.graphics_pipeline_create(&r.gpu, desc) or_return
  }
  return pipelines, true
}

// post_shader_create makes a post-process shader from a user fragment shader, for
// CustomEffect. A backend uses only its own source: `frag_spirv` on Vulkan, `frag_wgsl` on
// WebGPU.
//
// Vulkan: compile against shader/vulkan/include/post.glsl (glslc -I), which declares the
// fullscreen uv input, the color output, the textures and the push block, its params the
// user's (POST_PARAMS).
// WebGPU: the source follows common.wgsl and postprocess.wgsl, so it reads the bindings, the
// uniforms `u` and helpers they declare; it declares `struct Effect` (its params) and
// `fs_main(in: VertexOut) -> @location(0) vec4f`.
post_shader_create :: proc(r: ^Renderer, frag_spirv: []u8, frag_wgsl: string) -> (PostShader, bool) {
  pipelines, ok := post_pipelines_create(r, frag_spirv, frag_wgsl)
  if !ok do return 0, false
  for &slot, i in r.custom_post_pipelines {
    if slot[0] != 0 do continue
    slot = pipelines
    return PostShader(i + 1), true
  }
  append(&r.custom_post_pipelines, pipelines)
  return PostShader(len(r.custom_post_pipelines)), true
}

// post_shader_destroy frees a shader from post_shader_create; take its effects off the stack
// first.
post_shader_destroy :: proc(r: ^Renderer, shader: PostShader) {
  if shader == 0 || int(shader) > len(r.custom_post_pipelines) do return
  slot := &r.custom_post_pipelines[shader - 1]
  for p in slot do if p != 0 do dev.pipeline_retire(&r.gpu, p)
  slot^ = {}
}

// custom_effect packs `params` into a CustomEffect of `shader`, laid out as the shader's push
// block reads them.
custom_effect :: proc(shader: PostShader, params: $T, passes: u32 = 1) -> CustomEffect {
  #assert(size_of(T) <= CUSTOM_EFFECT_PARAM_BYTES)
  params := params
  e := CustomEffect{shader = shader, passes = passes}
  intrinsics.mem_copy_non_overlapping(&e.params, &params, size_of(T))
  return e
}

// One fullscreen pass of the effect stack: pass `pass` of effect (blur and bloom take two)
// reads input, the previous pass's output, and original, the previous pass's input, and
// writes output; NO_TEXTURE (0) is the presented image. A nil effect copies input.
@(private = "file")
PostPass :: struct {
  effect:                  PostprocessEffect,
  pass:                    u32,
  input, original, output: TextureHandle,
}

// The effect stack as passes over the main camera's image: pass i writes ring slot
// i % POST_PROCESS_RING, the last one the presented image. Blur and bloom take two passes
// (horizontal, then vertical); an empty stack copies the image unchanged (nil effect).
@(private = "file")
post_passes :: proc(r: ^Renderer, f: u32, cam: u32) -> []PostPass {
  effects := r.effect_stack[:]
  copy_only := [1]PostprocessEffect{nil}
  if len(effects) == 0 do effects = copy_only[:]
  passes := make([dynamic]PostPass, 0, 2 * len(effects), context.temp_allocator)
  input := r.cameras[cam].attachments[.FINAL_IMAGE][f]
  original := input
  for effect in effects {
    pass_count: u32 = 1
    #partial switch e in effect {
    case BlurEffect, BloomEffect:
      pass_count = 2
    case CustomEffect:
      pass_count = max(e.passes, 1)
    }
    for pass in 0 ..< pass_count {
      output := r.post_process_ring[f][len(passes) % POST_PROCESS_RING]
      append(&passes, PostPass{effect, pass, input, original, output})
      original, input = input, output
    }
  }
  passes[len(passes) - 1].output = NO_TEXTURE
  return passes[:]
}

// Every pass but the last writes a texture; the last writes the backbuffer.
@(private)
post_record :: proc(r: ^Renderer, cmd: rhi.CommandList, f: u32, cam: u32) {
  camera := &r.cameras[cam]
  passes := post_passes(r, f, cam)
  outputs := make([dynamic]TextureHandle, 0, len(passes), context.temp_allocator)
  outer: for &p, i in passes {
    if p.output == 0 do continue
    for q in passes[:i] do if q.output == p.output do continue outer
    append(&outputs, p.output)
  }
  normal, depth := camera.attachments[.NORMAL][f], camera.attachments[.DEPTH][f]
  for &p, i in passes {
    if i == 0 do barrier_discard(r, cmd, outputs[:])
    else do barrier(r, cmd, .POST_PASS)
    is_last := p.output == 0
    colors := [1]rhi.ColorTarget{{texture = BACKBUFFER if is_last else p.output, load = .DONT_CARE}}
    dev.cmd_begin_pass(&r.gpu, cmd, {colors = colors[:]})
    push := PostPush {
      camera_near          = camera.near,
      camera_far           = camera.far,
      normal_texture_index = u32(normal),
      depth_texture_index  = u32(depth),
      input_image_index    = u32(p.input),
      original_image_index = u32(p.original),
      pass                 = p.pass,
      effect               = p.effect,
    }
    pipeline := r.post_pipelines[int(is_last)][reflect.get_union_variant_raw_tag(p.effect)]
    if custom, is_custom := p.effect.(CustomEffect); is_custom {
      pipeline = post_shader_pipeline(r, custom.shader, is_last)
    }
    pipeline_bind(r, cmd, pipeline, .NONE, f, &push, .POST, p.input, p.original, normal, depth)
    dev.cmd_draw(&r.gpu, cmd, 3, 1, 0, 0)
    dev.cmd_end_pass(&r.gpu, cmd)
  }
}

// A CustomEffect's pipeline; the copy pipeline stands in for a shader that is gone.
@(private = "file")
post_shader_pipeline :: proc(r: ^Renderer, shader: PostShader, is_last: bool) -> rhi.Pipeline {
  if shader > 0 && int(shader) <= len(r.custom_post_pipelines) {
    if p := r.custom_post_pipelines[shader - 1][int(is_last)]; p != 0 do return p
  }
  return r.post_pipelines[int(is_last)][0]
}
