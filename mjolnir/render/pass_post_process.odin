#+private
package render

import "gpu"
import "base:intrinsics"
import "core:log"
import "core:reflect"
import vk "vendor:vulkan"

SHADER_POSTPROCESS_VERT :: #load("shader/postprocess/vert.spv")
SHADER_POSTPROCESS_FRAG :: #load("shader/postprocess/frag.spv")
SHADER_BLOOM_FRAG :: #load("shader/bloom/frag.spv")
SHADER_BLUR_FRAG :: #load("shader/blur/frag.spv")
SHADER_GRAYSCALE_FRAG :: #load("shader/grayscale/frag.spv")
SHADER_TONEMAP_FRAG :: #load("shader/tonemap/frag.spv")
SHADER_OUTLINE_FRAG :: #load("shader/outline/frag.spv")
SHADER_FOG_FRAG :: #load("shader/fog/frag.spv")
SHADER_CROSSHATCH_FRAG :: #load("shader/crosshatch/frag.spv")
SHADER_DOF_FRAG :: #load("shader/dof/frag.spv")

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
PostProcessPushConstant :: struct {
  // camera clip planes, for effects that linearize depth (fog, dof, outline)
  camera_near:          f32,
  camera_far:           f32,
  normal_texture_index: u32,
  depth_texture_index:  u32,
  input_image_index:    u32,
  // bloom: the scene as it entered bloom, composited by the V pass
  original_image_index: u32,
  _:                    [2]u32,
  effect:               PostprocessEffect,
}
#assert(offset_of(PostProcessPushConstant, effect) == 32)
#assert(size_of(PostProcessPushConstant) <= 128)

PostProcessRenderer :: struct {
  pipelines_hdr:   [len(FRAG_SHADERS)]vk.Pipeline,
  pipelines_ldr:   [len(FRAG_SHADERS)]vk.Pipeline,
  pipeline_layout: vk.PipelineLayout,
  effect_stack:    [dynamic]PostprocessEffect,
  // Up to 3 ping-pong buffers per frame in flight, allocated as the stack
  // needs them: a bloom V pass reads the H output and the pre-bloom scene
  // while writing a third.
  images:          [gpu.FRAMES_IN_FLIGHT][3]Texture2DHandle,
}

post_process_teardown :: proc(
  self: ^PostProcessRenderer,
  gctx: ^gpu.GPUContext,
  texture_manager: ^TextureManager,
) {
  post_process_release_images(self, gctx, texture_manager)
}

post_process_init :: proc(
  self: ^PostProcessRenderer,
  gctx: ^gpu.GPUContext,
  color_format: vk.Format,
  textures_set_layout: vk.DescriptorSetLayout,
) -> (
  ret: vk.Result,
) {
  self.effect_stack = make([dynamic]PostprocessEffect)
  defer if ret != .SUCCESS do delete(self.effect_stack)
  self.pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange{stageFlags = {.FRAGMENT}, size = size_of(PostProcessPushConstant)},
    textures_set_layout,
  ) or_return
  hdr_formats := [?]vk.Format{gpu.HDR_COLOR_FORMAT}
  ldr_formats := [?]vk.Format{color_format}
  blend := [?]vk.PipelineColorBlendAttachmentState{gpu.BLEND_OVERRIDE}
  for shader_code, i in FRAG_SHADERS {
    desc := gpu.GraphicsPipelineDesc {
      vert = SHADER_POSTPROCESS_VERT,
      frag = shader_code,
      specialization = &SHADER_SPEC_CONSTANTS,
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

// Ping-pong images the stack needs: none when a single effect writes the
// output directly, two to alternate, a third when a bloom V pass must keep
// its composite source.
post_process_image_count :: proc(effects: []PostprocessEffect) -> int {
  if len(effects) <= 1 do return 0
  for e in effects do if _, ok := e.(BloomEffect); ok do return min(len(effects) - 1, 3)
  return min(len(effects) - 1, 2)
}

// Allocate the ping-pong images the current stack needs and does not have
// yet. Images are kept until the swapchain is resized or the level torn down.
post_process_ensure_images :: proc(
  self: ^PostProcessRenderer,
  gctx: ^gpu.GPUContext,
  texture_manager: ^TextureManager,
  extent: vk.Extent2D,
  frame_index: u32,
) -> vk.Result {
  for &handle in self.images[frame_index][:post_process_image_count(self.effect_stack[:])] {
    if handle != {} do continue
    handle = allocate_texture_2d(
      texture_manager,
      gctx,
      extent,
      gpu.HDR_COLOR_FORMAT,
      {.COLOR_ATTACHMENT, .SAMPLED},
    ) or_return
  }
  return .SUCCESS
}

post_process_release_images :: proc(
  self: ^PostProcessRenderer,
  gctx: ^gpu.GPUContext,
  texture_manager: ^TextureManager,
) {
  for &frame in self.images {
    for &handle in frame {
      if handle == {} do continue
      free_texture_2d(texture_manager, gctx, handle)
      handle = {}
    }
  }
}

post_process_shutdown :: proc(self: ^PostProcessRenderer, gctx: ^gpu.GPUContext) {
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

// post_process_record runs the post-process effect stack into output_view. An empty stack
// copies the input to output.
post_process_record :: proc(
  self: ^PostProcessRenderer,
  command_buffer: vk.CommandBuffer,
  frame_index: u32,
  extent: vk.Extent2D,
  output_view: vk.ImageView,
  final_image_idx: u32,
  gbuffer: GBuffer,
  near, far: f32,
  texture_manager: ^TextureManager,
) {
  images := &self.images[frame_index]
  effects := self.effect_stack[:]
  // with no effect, a single copy (nil effect) brings the input to output
  copy_only := [1]PostprocessEffect{nil}
  if len(effects) == 0 do effects = copy_only[:]
  gpu.set_viewport_scissor(command_buffer, extent, flip_y = false)
  // Slot tracking for 3-buffer ping-pong.
  //   current_input_slot == -1 means current input is `final_image_idx`
  //   (external, not one of the ping-pong images), so no transition required.
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
      dst_texture := get_texture_2d(
        texture_manager,
        images[dst_slot],
      )
      if dst_texture == nil {
        log.errorf(
          "Post-process image handle %v not found",
          images[dst_slot],
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
      src_texture := get_texture_2d(
        texture_manager,
        images[current_input_slot],
      )
      if src_texture == nil {
        log.errorf(
          "Post-process source image handle %v not found",
          images[current_input_slot],
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
      // the fullscreen triangle overwrites every pixel
      gpu.create_color_attachment(dst_view, .DONT_CARE, .STORE),
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
    push := PostProcessPushConstant {
      camera_near          = near,
      camera_far           = far,
      normal_texture_index = gbuffer.normal,
      depth_texture_index  = gbuffer.depth,
      input_image_index    = input_image_index,
      original_image_index = input_image_index if is_bloom_h else bloom_h_input_image_idx,
      effect               = effect,
    }
    vk.CmdPushConstants(
      command_buffer,
      self.pipeline_layout,
      {.FRAGMENT},
      0,
      size_of(PostProcessPushConstant),
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
      current_input_image_idx = images[dst_slot].index
    }
  }
}
