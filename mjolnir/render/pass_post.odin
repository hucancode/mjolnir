package render

import "base:intrinsics"
import "rhi"

// Post-processing: each camera's effects as fullscreen passes over its image, each pass's
// fragment shader reading the previous pass's output. Every effect runs a post shader: render's
// own, registered at init, or yours (post_shader_create).

// The built-in effects, in the order init registers their shaders: handle 2 onward, after the
// copy (COPY_SHADER).
@(private)
BuiltinEffect :: union {
  GrayscaleEffect,
  ToneMapEffect,
  BlurEffect,
  BloomEffect,
  OutlineEffect,
  FogEffect,
  CrossHatchEffect,
  DoFEffect,
  FXAAEffect,
}

// The shader that copies its input: what an effect of a shader that is gone runs, and what pads
// a chain.
@(private)
COPY_SHADER :: ShaderHandle(1)

// The shaders init registers, from COPY_SHADER on.
@(private)
BUILTIN_SHADERS :: intrinsics.type_union_variant_count(BuiltinEffect) + 1

// Effect is one of a camera's effects (Camera.effects): a post shader and its params, made by
// make_effect.
Effect :: struct {
  shader: ShaderHandle,
  params: [PARAMS_BYTES]u8,
}

@(private)
post_init :: proc(self: ^Renderer) -> bool {
  // blur and bloom pass horizontally, then vertically
  shaders := [BUILTIN_SHADERS]struct {
    source: rhi.ShaderSource,
    passes: u32,
  } {
    {shader_source("post_copy"), 1},
    {shader_source("post_grayscale"), 1},
    {shader_source("post_tonemap"), 1},
    {shader_source("post_blur"), 2},
    {shader_source("post_bloom"), 2},
    {shader_source("post_outline"), 1},
    {shader_source("post_fog"), 1},
    {shader_source("post_crosshatch"), 1},
    {shader_source("post_dof"), 1},
    {shader_source("post_fxaa"), 1},
  }
  for s, i in shaders {
    handle := post_shader_create(self, s.source, s.passes) or_return
    assert(handle == COPY_SHADER + ShaderHandle(i))
  }
  return true
}

// A fullscreen pass of post.slang's interface writing a `format` image.
@(private)
post_pipeline_create :: proc(self: ^Renderer, source: rhi.ShaderSource, format: TextureFormat) -> (rhi.Pipeline, bool) {
  formats := [1]TextureFormat{format}
  return dev.graphics_pipeline_create(&self.gpu, {shader = source, layout = pipeline_layout(self, .USER, .POST), color_formats = formats[:]})
}

// post_shader_create makes a post shader from a compiled shader (the entry points of
// post.slang: its vs_main and a fs_main), for make_effect. Compile it from a .slang that
// declares `struct Effect` (its params) and includes shader/post.slang; load it with
// #load("name." + SHADER_EXT). Each effect runs it `passes` times, each pass reading the
// previous one's output; the shader tells them apart by post_push.pass_index.
post_shader_create :: proc(self: ^Renderer, source: []u8, passes: u32 = 1) -> (shader: ShaderHandle, ok: bool) #optional_ok {
  lock(self)
  s := Shader {
    kind   = .POST,
    passes = max(passes, 1),
  }
  formats := [2]TextureFormat{HDR_COLOR_FORMAT, .BACKBUFFER}
  created := true
  for &p, to_backbuffer in s.pipelines {
    if created do p, created = post_pipeline_create(self, source, formats[to_backbuffer])
  }
  return shader_add(self, s, created)
}

// make_effect makes an Effect for a camera's effects:
//   make_effect(FogEffect{...}): one of render's effects (GrayscaleEffect, ToneMapEffect,
//   BlurEffect, BloomEffect, OutlineEffect, FogEffect, CrossHatchEffect, DoFEffect, FXAAEffect)
//   make_effect(shader, params): a post shader of yours with params, laid out as the shader's
//   `struct Effect` reads them: the same fields in the same order (a [3]f32 must be followed by
//   an f32, so prefer [4]f32 and scalars); at most PARAMS_BYTES
make_effect :: proc {
  make_builtin_effect,
  make_shader_effect,
}

@(private = "file")
make_builtin_effect :: proc(params: $T) -> Effect where intrinsics.type_is_variant_of(BuiltinEffect, T) {
  return make_shader_effect(COPY_SHADER + 1 + ShaderHandle(intrinsics.type_variant_index_of(BuiltinEffect, T)), params)
}

@(private = "file")
make_shader_effect :: proc(shader: ShaderHandle, params: $T) -> Effect {
  return {shader = shader, params = pack_params(params)}
}

// The post shader an effect runs: its own, or the copy when that is gone.
@(private = "file")
effect_shader :: proc(self: ^Renderer, effect: Effect) -> ^Shader {
  return shader_of(self, effect.shader, .POST) or_else &self.shaders[COPY_SHADER]
}

// A camera's effects as fullscreen passes over its image: pass `pass` of an effect reads input,
// the previous pass's output, and original, the previous pass's input. Pass i reads ring slot
// i % 3 and writes the next of FINAL_IMAGE and the camera's two post images. On the presented
// camera the last pass writes the backbuffer (no effects: a copy); on any other, copies pad the
// chain to land back on FINAL_IMAGE.
@(private)
post_record :: proc(self: ^Renderer, cmd: rhi.CommandList, f: u32, cam: u32, present: bool) {
  camera, targets := &self.cameras[cam], &self.camera_targets[cam]
  total: u32
  for effect in camera.effects do if effect.shader != 0 do total += effect_shader(self, effect).passes
  if present do total = max(total, 1)
  else do total += (3 - total % 3) % 3
  if total == 0 do return
  ring := [3]TextureHandle{targets.images[.FINAL_IMAGE][f], targets.post[f][0], targets.post[f][1]}
  barrier_discard(self, cmd, ring[1:])
  i: u32
  for effect in camera.effects {
    if effect.shader == 0 do continue
    s := effect_shader(self, effect)
    for pass in 0 ..< s.passes {
      post_pass(self, cmd, f, cam, ring, i, present && i == total - 1, s, {camera_index = cam, pass = pass, params = effect.params})
      i += 1
    }
  }
  for ; i < total; i += 1 do post_pass(self, cmd, f, cam, ring, i, present && i == total - 1, &self.shaders[COPY_SHADER], {camera_index = cam})
}

// Pass i of a camera's chain, of shader s with push (its images filled in here).
@(private = "file")
post_pass :: proc(self: ^Renderer, cmd: rhi.CommandList, f, cam: u32, ring: [3]TextureHandle, i: u32, to_backbuffer: bool, s: ^Shader, push: ShaderPush) {
  images := &self.camera_targets[cam].images
  if i > 0 do barrier(self, cmd, .POST_PASS)
  input := ring[i % 3]
  original := ring[(i + 2) % 3] if i > 0 else input
  colors := [1]rhi.ColorTarget{{texture = BACKBUFFER if to_backbuffer else ring[(i + 1) % 3], load = .DONT_CARE}}
  dev.cmd_begin_pass(&self.gpu, cmd, {colors = colors[:]})
  push := push
  push.input_image_index, push.original_image_index = u32(input), u32(original)
  pipeline_bind(self, cmd, s.pipelines[int(to_backbuffer)], .USER, f, &push, .POST, input, original, images[.NORMAL][f], images[.DEPTH][f])
  dev.cmd_draw(&self.gpu, cmd, 3, 1, 0, 0)
  dev.cmd_end_pass(&self.gpu, cmd)
}
