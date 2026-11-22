package render

import "base:intrinsics"
import "rhi"

// Post-processing: a camera's effects (camera_effect) in a fixed order over its lit image, then
// your post shaders (camera_post_shaders); the last writes the camera's image. Each effect is
// passes of the frame graph over transient images, as suits it: one fullscreen pass for most,
// two for the separable blur, a chain of shrinking images for bloom.

// POST_PARAMS_BYTES is the most a post shader's params take (make_effect).
POST_PARAMS_BYTES :: PUSH_SIZE - 32

// Effect is a post shader of yours with its params, made by make_effect, for camera_post_shaders.
Effect :: struct {
  shader: ShaderHandle,
  params: [POST_PARAMS_BYTES]u8,
}

// What a post pass pushes (shader/post.slang PostPush): the camera, the images it reads, which
// step of an effect it is, then the params.
@(private)
PostPush :: struct {
  camera_index:       u32,
  input_image_index:  u32,
  second_image_index: u32,
  normal_image_index: u32,
  depth_image_index:  u32,
  pass_index:         u32,
  _:                  [2]u32,
  params:             [POST_PARAMS_BYTES]u8,
}
#assert(size_of(PostPush) == PUSH_SIZE)

// The levels of bloom's chain at most, each half the one above.
@(private = "file")
BLOOM_LEVELS :: 6

// The steps of bloom (shader/post_bloom.slang): the first and other levels down, each level
// added up into the one above, the glow added to the image.
@(private = "file")
BloomStep :: enum u32 {
  FIRST_DOWN,
  DOWN,
  UP,
  COMPOSITE,
}

// A pass of camera cam's effect (CameraEffect variant) or post shader, step `step` of it.
@(private = "file")
effect_arg :: proc "contextless" (cam: u32, variant: int, step: u32) -> u32 {
  return cam | u32(variant) << 16 | step << 24
}

@(private = "file")
effect_arg_split :: proc "contextless" (arg: u32) -> (cam, variant, step: u32) {
  return arg & 0xFFFF, (arg >> 16) & 0xFF, arg >> 24
}

// What each CameraEffect variant runs over the image after the lighting: its pipeline, and
// whether it reads the depth. Ambient occlusion feeds the lighting instead: no post step.
@(private = "file")
POST_STEPS := [CAMERA_EFFECTS]struct {
  post:     bool,
  pipeline: BuiltinPipeline,
  depth:    bool,
} {
  0 = {},
  1 = {true, .POST_OUTLINE, true},
  2 = {true, .POST_FOG, true},
  3 = {true, .POST_DOF, true},
  4 = {true, .POST_BLOOM, false},
  5 = {true, .POST_FXAA, false},
  6 = {true, .POST_BLUR, false},
  7 = {true, .POST_CROSS_HATCH, false},
  8 = {true, .POST_GRAYSCALE, false},
  9 = {true, .POST_TONE_MAP, false},
}
#assert(intrinsics.type_variant_index_of(CameraEffect, AmbientOcclusion) == 0)
#assert(intrinsics.type_variant_index_of(CameraEffect, OutlineEffect) == 1)
#assert(intrinsics.type_variant_index_of(CameraEffect, BloomEffect) == 4)
#assert(intrinsics.type_variant_index_of(CameraEffect, BlurEffect) == 6)
#assert(intrinsics.type_variant_index_of(CameraEffect, ToneMapEffect) == 9)
// an effect's params are the payload at the head of the union
#assert(size_of(CameraEffect) <= POST_PARAMS_BYTES)

@(private)
post_init :: proc(self: ^Renderer) -> bool {
  sources := [?]struct {
    pipeline: BuiltinPipeline,
    source:   rhi.ShaderSource,
    format:   TextureFormat,
    blend:    rhi.BlendMode,
  } {
    {.POST_OUTLINE, shader_source("post_outline"), HDR_COLOR_FORMAT, .NONE},
    {.POST_FOG, shader_source("post_fog"), HDR_COLOR_FORMAT, .NONE},
    {.POST_DOF, shader_source("post_dof"), HDR_COLOR_FORMAT, .NONE},
    {.POST_BLOOM, shader_source("post_bloom"), HDR_COLOR_FORMAT, .NONE},
    // bloom's up steps add into their level
    {.POST_BLOOM_ADD, shader_source("post_bloom"), HDR_COLOR_FORMAT, .ADDITIVE},
    {.POST_FXAA, shader_source("post_fxaa"), HDR_COLOR_FORMAT, .NONE},
    {.POST_BLUR, shader_source("post_blur"), HDR_COLOR_FORMAT, .NONE},
    {.POST_CROSS_HATCH, shader_source("post_crosshatch"), HDR_COLOR_FORMAT, .NONE},
    {.POST_GRAYSCALE, shader_source("post_grayscale"), HDR_COLOR_FORMAT, .NONE},
    {.POST_TONE_MAP, shader_source("post_tonemap"), HDR_COLOR_FORMAT, .NONE},
    {.POST_COPY, shader_source("post_copy"), HDR_COLOR_FORMAT, .NONE},
    {.PRESENT, shader_source("post_copy"), .BACKBUFFER, .NONE},
  }
  for s in sources do self.pipelines[s.pipeline] = post_pipeline_create(self, s.source, s.format, s.blend) or_return
  return true
}

// A fullscreen pass of post.slang's interface writing a `format` image.
@(private = "file")
post_pipeline_create :: proc(self: ^Renderer, source: rhi.ShaderSource, format: TextureFormat, blend := rhi.BlendMode.NONE) -> (rhi.Pipeline, bool) {
  formats := [1]TextureFormat{format}
  return dev.graphics_pipeline_create(&self.gpu, {shader = source, layout = pipeline_layout(self, .USER, .POST), color_formats = formats[:], blend = blend})
}

// post_shader_create makes a post shader from a compiled shader (the entry points of
// post.slang: its vs_main and a fs_main), for make_effect. Compile it from a .slang that
// declares `struct Effect` (its params) and includes shader/post.slang; load it with
// #load("name." + SHADER_EXT). It runs as one fullscreen pass over the camera's image so far.
// With `normals` it reads the G-buffer normals (post_normal), so only cameras drawing a deferred
// type take it.
post_shader_create :: proc(self: ^Renderer, source: []u8, normals := false) -> (shader: ShaderHandle, ok: bool) #optional_ok {
  lock(self)
  pipeline, created := post_pipeline_create(self, source, HDR_COLOR_FORMAT)
  return shader_add(self, {pipeline = pipeline, kind = .POST, normals = normals}, created)
}

// make_effect makes an Effect running a post shader of yours with params, laid out as the
// shader's `struct Effect` reads them: the same fields in the same order (a [3]f32 must be
// followed by an f32, so prefer [4]f32 and scalars); at most POST_PARAMS_BYTES.
make_effect :: proc(shader: ShaderHandle, params: $T) -> Effect {
  return {shader = shader, params = pack_params(params, POST_PARAMS_BYTES)}
}

// How many effects and post shaders camera c runs over its image: with any, its lighting writes
// a transient image they carry into its own.
@(private)
post_steps :: proc(self: ^Renderer, c: u32) -> (steps: int) {
  targets := &self.camera_targets[c]
  for e, v in targets.effects do if e != nil && POST_STEPS[v].post do steps += 1
  for s in targets.shaders do if s.shader != 0 do steps += 1
  return
}

// Bloom's levels over an image of `extent`: halving down to 8 texels, at least one.
@(private = "file")
bloom_levels :: proc(extent: [2]u32) -> (n: int) {
  for n < BLOOM_LEVELS && (n == 0 || min(extent.x, extent.y) >> u32(n + 1) >= 8) do n += 1
  return
}

// Camera c's effects and post shaders, from `lit` into `final`, each pass reading the one
// before; `normal` is its G-buffer normals (none without the G-buffer). A post pass's uses are
// its input, the image it writes, a second image, the normals and the depth, each none where the
// pass does not read it.
@(private)
post_declare :: proc(self: ^Renderer, c: u32, lit, final, normal: GraphUse) {
  targets := &self.camera_targets[c]
  steps := post_steps(self, c)
  hdr := camera_image_desc(.FINAL_IMAGE, targets.extent)
  // only the lighting writes the lit image as storage
  hdr.usage = {.COLOR_TARGET, .SAMPLED}
  depth := texture_use(targets.depth, .READ)
  input := as(lit, .READ)
  // the image the next step writes: the camera's after the last
  next :: proc(self: ^Renderer, steps: ^int, desc: TextureDesc, final: GraphUse) -> GraphUse {
    steps^ -= 1
    return as(final, .COLOR) if steps^ == 0 else transient_use(self, desc, .COLOR)
  }
  for e, v in targets.effects {
    if e == nil || !POST_STEPS[v].post do continue
    reads := depth if POST_STEPS[v].depth else NO_USE
    normals := as(normal, .READ) if effect_needs_gbuffer(e) else NO_USE
    #partial switch _ in e {
    case BloomEffect:
      out := next(self, &steps, hdr, final)
      bloom_declare(self, c, v, input, out)
      input = as(out, .READ)
    case BlurEffect:
      across := transient_use(self, hdr, .COLOR)
      declare(self, "blur", .RASTER, .EFFECT, effect_arg(c, v, 0), input, across)
      out := next(self, &steps, hdr, final)
      declare(self, "blur", .RASTER, .EFFECT, effect_arg(c, v, 1), as(across, .READ), out)
      input = as(out, .READ)
    case:
      out := next(self, &steps, hdr, final)
      declare(self, "effect", .RASTER, .EFFECT, effect_arg(c, v, 0), input, out, NO_USE, normals, reads)
      input = as(out, .READ)
    }
  }
  for s, i in targets.shaders {
    if s.shader == 0 do continue
    shader := shader_of(self, s.shader, .POST) or_else nil
    out := next(self, &steps, hdr, final)
    normals := as(normal, .READ) if shader != nil && shader.normals else NO_USE
    declare(self, "post shader", .RASTER, .POST_SHADER, effect_arg(c, i, 0), input, out, NO_USE, normals, depth)
    input = as(out, .READ)
  }
}

// Bloom: the image's bright part down a chain of half-sized images, each level added up into the
// one above, the top level added to the image as glow.
@(private = "file")
bloom_declare :: proc(self: ^Renderer, c: u32, v: int, input, out: GraphUse) {
  extent := self.camera_targets[c].extent
  levels: [BLOOM_LEVELS]GraphUse
  n := bloom_levels(extent)
  for &level, i in levels[:n] {
    size := [2]u32{max(extent.x >> u32(i + 1), 1), max(extent.y >> u32(i + 1), 1)}
    level = transient_use(self, {extent = size, format = HDR_COLOR_FORMAT, usage = {.COLOR_TARGET, .SAMPLED}}, .COLOR)
  }
  src := input
  for level, i in levels[:n] {
    step := BloomStep.FIRST_DOWN if i == 0 else .DOWN
    declare(self, "bloom down", .RASTER, .EFFECT, effect_arg(c, v, u32(step)), src, level)
    src = as(level, .READ)
  }
  for i := n - 1; i > 0; i -= 1 {
    declare(self, "bloom up", .RASTER, .EFFECT, effect_arg(c, v, u32(BloomStep.UP)), as(levels[i], .READ), levels[i - 1])
  }
  declare(self, "bloom", .RASTER, .EFFECT, effect_arg(c, v, u32(BloomStep.COMPOSITE)), input, out, as(levels[0], .READ))
}

// A step of one of camera arg's effects: its pipeline (bloom's up steps add) over the effect's
// settings, which lead the union.
@(private)
effect_record :: proc(self: ^Renderer, cmd: rhi.CommandList, f: u32, pass: GraphPass) {
  cam, variant, step := effect_arg_split(pass.arg)
  effect := self.camera_targets[cam].effects[variant]
  if effect == nil do return
  pipeline, load := POST_STEPS[variant].pipeline, rhi.LoadOp.DONT_CARE
  if _, bloom := effect.(BloomEffect); bloom {
    if BloomStep(step) == .UP do pipeline, load = .POST_BLOOM_ADD, .LOAD
    // the composite divides the glow by the levels the up steps summed
    if BloomStep(step) == .COMPOSITE do step |= u32(bloom_levels(self.camera_targets[cam].extent)) << 4
  }
  params: [POST_PARAMS_BYTES]u8
  copy(params[:], ([^]u8)(&effect)[:size_of(effect)])
  post_draw(self, cmd, f, pass, cam, self.pipelines[pipeline], params, step, load)
}

// Post shader i of camera cam (effect_arg); a shader destroyed since passes its input through.
@(private)
post_shader_record :: proc(self: ^Renderer, cmd: rhi.CommandList, f: u32, pass: GraphPass) {
  cam, i, _ := effect_arg_split(pass.arg)
  effect := self.camera_targets[cam].shaders[i]
  pipeline := self.pipelines[.POST_COPY]
  if s, ok := shader_of(self, effect.shader, .POST); ok do pipeline = s.pipeline
  post_draw(self, cmd, f, pass, cam, pipeline, effect.params, 0, .DONT_CARE)
}

// The presented camera's image, copied to the window.
@(private)
present_record :: proc(self: ^Renderer, cmd: rhi.CommandList, f: u32, pass: GraphPass) {
  post_draw(self, cmd, f, pass, pass.arg, self.pipelines[.PRESENT], {}, 0, .DONT_CARE)
}

// A fullscreen pass over the pass's uses: input, output, second image, normals, depth.
@(private = "file")
post_draw :: proc(self: ^Renderer, cmd: rhi.CommandList, f: u32, pass: GraphPass, cam: u32, pipeline: rhi.Pipeline, params: [POST_PARAMS_BYTES]u8, step: u32, load: rhi.LoadOp) {
  input, output := pass_texture(self, pass, 0), pass_texture(self, pass, 1)
  second, normal, depth := pass_texture(self, pass, 2), pass_texture(self, pass, 3), pass_texture(self, pass, 4)
  if second == 0 do second = input
  colors := [1]rhi.ColorTarget{{texture = output, load = load}}
  dev.cmd_begin_pass(&self.gpu, cmd, {colors = colors[:]})
  push := PostPush {
    camera_index       = cam,
    input_image_index  = u32(input),
    second_image_index = u32(second),
    normal_image_index = u32(normal),
    depth_image_index  = u32(depth),
    pass_index         = step,
    params             = params,
  }
  pipeline_bind(self, cmd, pipeline, .USER, f, &push, .POST, input, second, normal, depth)
  dev.cmd_draw(&self.gpu, cmd, 3, 1, 0, 0)
  dev.cmd_end_pass(&self.gpu, cmd)
}
