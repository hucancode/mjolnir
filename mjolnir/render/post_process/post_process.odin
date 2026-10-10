package post_process

import "../bindless"
import "../gpu"
import "base:intrinsics"
import "core:log"
import "core:reflect"
import vk "vendor:vulkan"

SHADER_POSTPROCESS_VERT :: #load("../shader/postprocess/vert.spv")
SHADER_POSTPROCESS_FRAG :: #load("../shader/postprocess/frag.spv")
SHADER_BLOOM_FRAG :: #load("../shader/bloom/frag.spv")
SHADER_BLUR_FRAG :: #load("../shader/blur/frag.spv")
SHADER_GRAYSCALE_FRAG :: #load("../shader/grayscale/frag.spv")
SHADER_TONEMAP_FRAG :: #load("../shader/tonemap/frag.spv")
SHADER_OUTLINE_FRAG :: #load("../shader/outline/frag.spv")
SHADER_FOG_FRAG :: #load("../shader/fog/frag.spv")
SHADER_CROSSHATCH_FRAG :: #load("../shader/crosshatch/frag.spv")
SHADER_DOF_FRAG :: #load("../shader/dof/frag.spv")

BG_BLUE_GRAY :: [4]f32{0.0117, 0.0117, 0.0179, 1.0}

// Effect structs are pushed verbatim right after the base fields of
// PushConstant (offset 32); their layout must match each shader's push block.
GrayscaleEffect :: struct {
  weights:  [3]f32,
  strength: f32,
}

ToneMapEffect :: struct {
  exposure: f32,
  gamma:    f32,
}

BlurEffect :: struct {
  radius:         f32,
  direction:      f32, // 0.0 = horizontal, 1.0 = vertical
  weight_falloff: f32, // 0.0 = box blur, 1.0 = gaussian blur
}

BloomEffect :: struct {
  threshold:   f32,
  intensity:   f32,
  blur_radius: f32,
  direction:   f32, // 0.0 = horizontal, 1.0 = vertical
}

OutlineEffect :: struct {
  color:     [3]f32,
  thickness: f32,
}

FogEffect :: struct {
  color:   [3]f32,
  density: f32,
  start:   f32,
  end:     f32,
}

CrossHatchEffect :: struct {
  hatch_offset_y:   f32,
  lum_threshold_01: f32,
  lum_threshold_02: f32,
  lum_threshold_03: f32,
  lum_threshold_04: f32,
}

DoFEffect :: struct {
  focus_distance:  f32, // Distance to the focus plane
  focus_range:     f32, // Range where objects are in focus
  blur_strength:   f32, // Maximum blur radius
  bokeh_intensity: f32, // Bokeh effect intensity
}

// nil is the copy pass that brings the input to the output unchanged
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

// Fragment shaders indexed by the PostprocessEffect union tag (0 = nil).
FRAG_SHADERS := [?][]u8 {
  SHADER_POSTPROCESS_FRAG,
  SHADER_GRAYSCALE_FRAG,
  SHADER_TONEMAP_FRAG,
  SHADER_BLUR_FRAG,
  SHADER_BLOOM_FRAG,
  SHADER_OUTLINE_FRAG,
  SHADER_FOG_FRAG,
  SHADER_CROSSHATCH_FRAG,
  SHADER_DOF_FRAG,
}
#assert(len(FRAG_SHADERS) == intrinsics.type_union_variant_count(PostprocessEffect) + 1)

// Odin stores a union's variant bytes at offset 0, so `effect` places the
// active effect struct at offset 32, followed by the (unread) tag.
PushConstant :: struct {
  position_texture_index: u32,
  normal_texture_index:   u32,
  albedo_texture_index:   u32,
  metallic_texture_index: u32,
  emissive_texture_index: u32,
  depth_texture_index:    u32,
  input_image_index:      u32,
  // bloom: the scene as it entered bloom, composited by the V pass
  original_image_index:   u32,
  effect:                 PostprocessEffect,
}
#assert(offset_of(PushConstant, effect) == 32)
#assert(size_of(PushConstant) <= 128)

Renderer :: struct {
  pipelines_hdr:   [len(FRAG_SHADERS)]vk.Pipeline,
  pipelines_ldr:   [len(FRAG_SHADERS)]vk.Pipeline,
  pipeline_layout: vk.PipelineLayout,
  effect_stack:    [dynamic]PostprocessEffect,
  // 3 ping-pong buffers: bloom V pass needs to read H output AND pre-bloom
  // scene simultaneously while writing to a third slot. With only 2 buffers
  // V would have to write to one of its inputs when bloom isn't the last pass.
  images:          [3]bindless.Texture2DHandle,
}

add_grayscale :: proc(
  self: ^Renderer,
  strength: f32 = 1.0,
  weights: [3]f32 = {0.299, 0.587, 0.114},
) {
  effect := GrayscaleEffect {
    strength = strength,
    weights  = weights,
  }
  append(&self.effect_stack, effect)
}

add_blur :: proc(self: ^Renderer, radius: f32, gaussian: bool = true) {
  horizontal_effect := BlurEffect {
    radius         = radius,
    direction      = 0.0, // horizontal
    weight_falloff = 1.0 if gaussian else 0.0,
  }
  append(&self.effect_stack, horizontal_effect)
  vertical_effect := BlurEffect {
    radius         = radius,
    direction      = 1.0, // vertical
    weight_falloff = 1.0 if gaussian else 0.0,
  }
  append(&self.effect_stack, vertical_effect)
}

add_bloom :: proc(
  self: ^Renderer,
  threshold: f32 = 0.2,
  intensity: f32 = 1.0,
  blur_radius: f32 = 4.0,
) {
  effect := BloomEffect {
    threshold   = threshold,
    intensity   = intensity,
    blur_radius = blur_radius,
    direction   = 0.0, // horizontal
  }
  append(&self.effect_stack, effect)
  effect = BloomEffect {
    threshold   = threshold,
    intensity   = intensity,
    blur_radius = blur_radius,
    direction   = 1.0, // vertical
  }
  append(&self.effect_stack, effect)
}

add_tonemap :: proc(self: ^Renderer, exposure: f32 = 1.0, gamma: f32 = 1.0) {
  effect := ToneMapEffect {
    exposure = exposure,
    gamma    = gamma,
  }
  append(&self.effect_stack, effect)
}

add_outline :: proc(self: ^Renderer, thickness: f32, color: [3]f32 = {0, 0, 0}) {
  effect := OutlineEffect {
    thickness = thickness,
    color     = color,
  }
  append(&self.effect_stack, effect)
}

add_fog :: proc(
  self: ^Renderer,
  color: [3]f32 = {0.7, 0.7, 0.8},
  density: f32 = 0.02,
  start: f32 = 10.0,
  end: f32 = 100.0,
) {
  effect := FogEffect {
    color   = color,
    density = density,
    start   = start,
    end     = end,
  }
  append(&self.effect_stack, effect)
}

add_crosshatch :: proc(
  self: ^Renderer,
  hatch_offset_y: f32 = 5.0,
  lum_threshold_01: f32 = 0.6,
  lum_threshold_02: f32 = 0.3,
  lum_threshold_03: f32 = 0.15,
  lum_threshold_04: f32 = 0.07,
) {
  effect := CrossHatchEffect {
    hatch_offset_y   = hatch_offset_y,
    lum_threshold_01 = lum_threshold_01,
    lum_threshold_02 = lum_threshold_02,
    lum_threshold_03 = lum_threshold_03,
    lum_threshold_04 = lum_threshold_04,
  }
  append(&self.effect_stack, effect)
}

add_dof :: proc(
  self: ^Renderer,
  focus_distance: f32 = 3.0,
  focus_range: f32 = 2.0,
  blur_strength: f32 = 20.0,
  bokeh_intensity: f32 = 0.5,
) {
  effect := DoFEffect {
    focus_distance  = focus_distance,
    focus_range     = focus_range,
    blur_strength   = blur_strength,
    bokeh_intensity = bokeh_intensity,
  }
  append(&self.effect_stack, effect)
}

clear_effects :: proc(self: ^Renderer) {
  clear(&self.effect_stack)
}

setup :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  texture_manager: ^bindless.TextureManager,
  extent: vk.Extent2D,
) -> vk.Result {
  return create_images(gctx, self, texture_manager, extent)
}

teardown :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  texture_manager: ^bindless.TextureManager,
) {
  destroy_images(self, gctx, texture_manager)
}

init :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  color_format: vk.Format,
  textures_set_layout: vk.DescriptorSetLayout,
) -> (
  ret: vk.Result,
) {
  self.effect_stack = make([dynamic]PostprocessEffect)
  defer if ret != .SUCCESS do delete(self.effect_stack)
  vert_module := gpu.create_shader_module(
    gctx.device,
    SHADER_POSTPROCESS_VERT,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, vert_module, nil)
  self.pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange{stageFlags = {.FRAGMENT}, size = size_of(PushConstant)},
    textures_set_layout,
  ) or_return
  hdr_formats := [?]vk.Format{gpu.HDR_COLOR_FORMAT}
  ldr_formats := [?]vk.Format{color_format}
  blend := [?]vk.PipelineColorBlendAttachmentState{gpu.BLEND_OVERRIDE}
  for shader_code, i in FRAG_SHADERS {
    frag_module := gpu.create_shader_module(gctx.device, shader_code) or_return
    defer vk.DestroyShaderModule(gctx.device, frag_module, nil)
    desc := gpu.GraphicsPipelineDesc {
      vert = vert_module,
      frag = frag_module,
      specialization = &bindless.SHADER_SPEC_CONSTANTS,
      topology = .TRIANGLE_LIST,
      raster = gpu.DOUBLE_SIDED_RASTERIZER,
      blend = blend[:],
      color_formats = hdr_formats[:],
      layout = self.pipeline_layout,
    }
    self.pipelines_hdr[i] = gpu.create_graphics_pipeline(gctx, desc) or_return
    desc.color_formats = ldr_formats[:]
    self.pipelines_ldr[i] = gpu.create_graphics_pipeline(gctx, desc) or_return
  }
  log.info("Postprocess pipeline initialized successfully")
  return .SUCCESS
}

@(private)
create_images :: proc(
  gctx: ^gpu.GPUContext,
  self: ^Renderer,
  texture_manager: ^bindless.TextureManager,
  extent: vk.Extent2D,
) -> vk.Result {
  for &handle in self.images {
    handle = bindless.allocate_texture_2d(
      texture_manager,
      gctx,
      extent,
      gpu.HDR_COLOR_FORMAT,
      {.COLOR_ATTACHMENT, .SAMPLED},
    ) or_return
  }
  log.debugf("created post-process image")
  return .SUCCESS
}

@(private)
destroy_images :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  texture_manager: ^bindless.TextureManager,
) {
  for handle in self.images {
    bindless.free_texture_2d(texture_manager, gctx, handle)
  }
}

recreate_images :: proc(
  gctx: ^gpu.GPUContext,
  self: ^Renderer,
  texture_manager: ^bindless.TextureManager,
  extent: vk.Extent2D,
) -> vk.Result {
  destroy_images(self, gctx, texture_manager)
  return create_images(gctx, self, texture_manager, extent)
}

shutdown :: proc(self: ^Renderer, gctx: ^gpu.GPUContext) {
  for &p in self.pipelines_hdr {
    vk.DestroyPipeline(gctx.device, p, nil)
    p = 0
  }
  for &p in self.pipelines_ldr {
    vk.DestroyPipeline(gctx.device, p, nil)
    p = 0
  }
  vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
  self.pipeline_layout = 0
  delete(self.effect_stack)
}

// record runs the post-process effect stack into output_view. An empty stack
// copies the input to output.
record :: proc(
  self: ^Renderer,
  command_buffer: vk.CommandBuffer,
  extent: vk.Extent2D,
  output_view: vk.ImageView,
  final_image_idx: u32,
  gbuffer: bindless.GBuffer,
  texture_manager: ^bindless.TextureManager,
) {
  effects := self.effect_stack[:]
  // with no effect, a single copy (nil effect) brings the input to output
  copy_only := [1]PostprocessEffect{nil}
  if len(effects) == 0 do effects = copy_only[:]
  gpu.set_viewport_scissor(command_buffer, extent, flip_y = false)
  // Slot tracking for 3-buffer ping-pong.
  //   current_input_slot == -1 means current input is `final_image_idx`
  //   (external, not one of self.images), so no transition required.
  //   bloom_h_input_slot is set when an H pass runs and consumed by the V pass
  //   that follows, so V can composite against the scene as it entered bloom.
  current_input_slot := -1
  current_input_image_idx := final_image_idx
  bloom_h_input_slot := -1
  bloom_h_input_image_idx: u32 = 0
  pick_dst_slot :: proc(forbidden_a, forbidden_b: int) -> int {
    for s in 0 ..< 3 {
      if s == forbidden_a do continue
      if s == forbidden_b do continue
      return s
    }
    return 0
  }
  for effect, i in effects {
    is_last := i == len(effects) - 1
    is_bloom_h := false
    is_bloom_v := false
    if e, ok := effect.(BloomEffect); ok {
      if e.direction < 0.5 do is_bloom_h = true
      else do is_bloom_v = true
    }
    dst_slot: int
    if !is_last {
      // V pass must not overwrite its composite source (bloom_h_input).
      forbidden_b := bloom_h_input_slot if is_bloom_v else -1
      dst_slot = pick_dst_slot(current_input_slot, forbidden_b)
    }
    dst_view := output_view
    if !is_last {
      dst_texture := bindless.get_texture_2d(
        texture_manager,
        self.images[dst_slot],
      )
      if dst_texture == nil {
        log.errorf(
          "Post-process image handle %v not found",
          self.images[dst_slot],
        )
        continue
      }
      gpu.image_discard_barrier(
        command_buffer,
        dst_texture.image,
        {.COLOR_ATTACHMENT_WRITE},
        {.COLOR_ATTACHMENT_OUTPUT},
        {.COLOR},
      )
      dst_view = dst_texture.view
    }
    if current_input_slot >= 0 {
      src_texture := bindless.get_texture_2d(
        texture_manager,
        self.images[current_input_slot],
      )
      if src_texture == nil {
        log.errorf(
          "Post-process source image handle %v not found",
          self.images[current_input_slot],
        )
        continue
      }
      gpu.memory_barrier(
        command_buffer,
        {.COLOR_ATTACHMENT_WRITE},
        {.SHADER_READ},
        {.COLOR_ATTACHMENT_OUTPUT},
        {.FRAGMENT_SHADER},
      )
    }
    input_image_index := current_input_image_idx
    gpu.begin_rendering(
      command_buffer,
      extent,
      nil,
      gpu.create_color_attachment(dst_view, .CLEAR, .STORE, BG_BLUE_GRAY),
    )
    tag := reflect.get_union_variant_raw_tag(effect)
    pipeline := self.pipelines_ldr[tag] if is_last else self.pipelines_hdr[tag]
    gpu.bind_pipeline(
      command_buffer,
      .GRAPHICS,
      pipeline,
      self.pipeline_layout,
      texture_manager.descriptor_set,
    )
    push := PushConstant {
      position_texture_index = gbuffer.position,
      normal_texture_index   = gbuffer.normal,
      albedo_texture_index   = gbuffer.albedo,
      metallic_texture_index = gbuffer.metallic_roughness,
      emissive_texture_index = gbuffer.emissive,
      depth_texture_index    = gbuffer.depth,
      input_image_index      = input_image_index,
      original_image_index   = input_image_index if is_bloom_h else bloom_h_input_image_idx,
      effect                 = effect,
    }
    vk.CmdPushConstants(
      command_buffer,
      self.pipeline_layout,
      {.FRAGMENT},
      0,
      size_of(PushConstant),
      &push,
    )
    vk.CmdDraw(command_buffer, 3, 1, 0, 0)
    vk.CmdEndRendering(command_buffer)
    if is_bloom_h {
      bloom_h_input_slot = current_input_slot
      bloom_h_input_image_idx = current_input_image_idx
    } else if is_bloom_v {
      bloom_h_input_slot = -1
      bloom_h_input_image_idx = 0
    }
    if !is_last {
      current_input_slot = dst_slot
      current_input_image_idx = self.images[dst_slot].index
    }
  }
}
