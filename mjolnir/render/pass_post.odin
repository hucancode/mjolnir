package render

import "base:intrinsics"
import "../containers"
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
  // render's clock in seconds
  time:                 f32,
  effect:               PostprocessEffect,
}
#assert(offset_of(PostPush, effect) == 32)
#assert(size_of(PostPush) <= PUSH_SIZE)

@(private)
post_init :: proc(self: ^Renderer) -> bool {
  // every tag but CustomEffect's, whose pipelines post_shader_create makes
  sources := [POST_EFFECT_COUNT - 1]rhi.ShaderSource {
    shader_source("post_copy"),
    shader_source("post_grayscale"),
    shader_source("post_tonemap"),
    shader_source("post_blur"),
    shader_source("post_bloom"),
    shader_source("post_outline"),
    shader_source("post_fog"),
    shader_source("post_crosshatch"),
    shader_source("post_dof"),
  }
  for tag in 0 ..< POST_EFFECT_COUNT - 1 {
    pipelines := post_pipelines_create(self, sources[tag]) or_return
    self.post_pipelines[tag] = pipelines
  }
  return true
}

// An effect's pipelines, [is_last]: every pass writes an HDR ring image but the last, which
// writes the backbuffer.
@(private = "file")
post_pipelines_create :: proc(self: ^Renderer, source: rhi.ShaderSource) -> (pipelines: [2]rhi.Pipeline, ok: bool) {
  formats := [2]TextureFormat{HDR_COLOR_FORMAT, .BACKBUFFER}
  for &p, is_last in pipelines {
    desc := rhi.GraphicsPipelineDesc {
      shader = source,
      layout = pipeline_layout(self, .NONE, .POST),
      color_formats = formats[is_last:][:1],
    }
    p = dev.graphics_pipeline_create(&self.gpu, desc) or_return
  }
  return pipelines, true
}

// post_shader_create makes a post-process shader from a compiled user shader (the entry points
// of post.slang: its vs_main and a fs_main), for CustomEffect in effect_stack, which the main
// camera runs. Compile it from a .slang that declares `struct Effect` (its params) and includes
// shader/post.slang; load it with #load("name." + SHADER_EXT). It reads render's time and the
// image size (post_resolution).
post_shader_create :: proc(self: ^Renderer, source: []u8) -> (shader: PostShader, ok: bool) #optional_ok {
  lock(self)
  shader = PostShader(containers.slots_alloc(&self.slots[.POST_SHADERS]) or_return)
  self.post_pipelines[post_index(shader)], ok = post_pipelines_create(self, source)
  if !ok do post_shader_destroy(self, shader)
  return
}

// post_shader_destroy frees a shader from post_shader_create; take its effects off the stack
// first.
post_shader_destroy :: proc(self: ^Renderer, shader: PostShader) {
  lock(self)
  if !containers.slots_free(&self.slots[.POST_SHADERS], u32(shader)) do return
  for p in self.post_pipelines[post_index(shader)] do dev.pipeline_retire(&self.gpu, p)
  self.post_pipelines[post_index(shader)] = {}
}

// Where a post shader's pipelines are: after the built-in effects'.
@(private = "file")
post_index :: #force_inline proc(shader: PostShader) -> int {
  return POST_EFFECT_COUNT + int(shader)
}

// make_custom_effect packs `params` into a CustomEffect of `shader`, laid out as the shader's push
// block reads them: declare the same fields in the same order there. A [3]f32 must be followed
// by an f32 (the shader pads a lone vec3 to 16 bytes), so prefer [4]f32 and scalars.
make_custom_effect :: proc(shader: PostShader, params: $T, passes: u32 = 1) -> CustomEffect {
  #assert(size_of(T) <= CUSTOM_EFFECT_PARAM_BYTES)
  params := params
  e := CustomEffect{shader = shader, passes = passes}
  intrinsics.mem_copy_non_overlapping(&e.params, &params, size_of(T))
  return e
}

// How many fullscreen passes an effect takes: blur and bloom two (horizontal, then vertical).
@(private = "file")
post_pass_count :: proc(effect: PostprocessEffect) -> u32 {
  #partial switch e in effect {
  case BlurEffect, BloomEffect:
    return 2
  case CustomEffect:
    return max(e.passes, 1)
  }
  return 1
}

// The effect stack as fullscreen passes over the main camera's image: pass `pass` of an effect
// reads input, the previous pass's output, and original, the previous pass's input. Pass i
// writes ring slot i % POST_PROCESS_RING, the last one the backbuffer. An empty stack copies the
// image unchanged (nil effect).
@(private)
post_record :: proc(self: ^Renderer, cmd: rhi.CommandList, f: u32, cam: u32) {
  camera, targets := &self.cameras[cam], &self.camera_targets[cam]
  effects := self.effect_stack[:]
  copy_only := [1]PostprocessEffect{nil}
  if len(effects) == 0 do effects = copy_only[:]
  total: u32
  for effect in effects do total += post_pass_count(effect)
  barrier_discard(self, cmd, self.post_process_ring[f][:min(total - 1, POST_PROCESS_RING)])
  normal, depth := targets.images[.NORMAL][f], targets.images[.DEPTH][f]
  input := targets.images[.FINAL_IMAGE][f]
  original := input
  i: u32
  for effect in effects {
    for pass in 0 ..< post_pass_count(effect) {
      if i > 0 do barrier(self, cmd, .POST_PASS)
      is_last := i == total - 1
      output := self.post_process_ring[f][i % POST_PROCESS_RING]
      colors := [1]rhi.ColorTarget{{texture = BACKBUFFER if is_last else output, load = .DONT_CARE}}
      dev.cmd_begin_pass(&self.gpu, cmd, {colors = colors[:]})
      push := PostPush {
        camera_near          = camera.near,
        camera_far           = camera.far,
        normal_texture_index = u32(normal),
        depth_texture_index  = u32(depth),
        input_image_index    = u32(input),
        original_image_index = u32(original),
        pass                 = pass,
        time                 = f32(self.time),
        effect               = effect,
      }
      index := int(reflect.get_union_variant_raw_tag(effect))
      if custom, is_custom := effect.(CustomEffect); is_custom do index = post_index(custom.shader)
      // the copy stands in for a shader that is gone
      pipeline := self.post_pipelines[index][int(is_last)] if index < len(self.post_pipelines) else 0
      if pipeline == 0 do pipeline = self.post_pipelines[0][int(is_last)]
      pipeline_bind(self, cmd, pipeline, .NONE, f, &push, .POST, input, original, normal, depth)
      dev.cmd_draw(&self.gpu, cmd, 3, 1, 0, 0)
      dev.cmd_end_pass(&self.gpu, cmd)
      original, input = input, output
      i += 1
    }
  }
}
