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

// Each effect's fragment shader and pass count, indexed by the
// PostprocessEffect union tag (0 = nil). A separable effect runs its shader
// once per pass, reading the pass number from the push constant (blur and
// bloom: 0 horizontal, 1 vertical).
EFFECTS := [?]struct {
  frag:   []u8,
  passes: u32,
} {
  {SHADER_POSTPROCESS_FRAG, 1},
  {SHADER_GRAYSCALE_FRAG, 1},
  {SHADER_TONEMAP_FRAG, 1},
  {SHADER_BLUR_FRAG, 2},
  {SHADER_BLOOM_FRAG, 2},
  {SHADER_OUTLINE_FRAG, 1},
  {SHADER_FOG_FRAG, 1},
  {SHADER_CROSSHATCH_FRAG, 1},
  {SHADER_DOF_FRAG, 1},
}
#assert(len(EFFECTS) == intrinsics.type_union_variant_count(PostprocessEffect) + 1)

// Odin stores a union's variant bytes at offset 0, so `effect` places the
// active effect struct at offset 32, followed by the (unread) tag.
PostProcessPushConstant :: struct {
  // camera clip planes, for effects that linearize depth (fog, dof, outline)
  camera_near:          f32,
  camera_far:           f32,
  normal_texture_index: u32,
  depth_texture_index:  u32,
  // the previous pass's output
  input_image_index:    u32,
  // the output of the pass before that: the previous pass's input (bloom V
  // composites over the scene as it entered bloom H)
  original_image_index: u32,
  // this pass of the effect, below EFFECTS[tag].passes
  pass:                 u32,
  _:                    u32,
  effect:               PostprocessEffect,
}
#assert(offset_of(PostProcessPushConstant, effect) == 32)

POST_PROCESS_RING :: 3

PostProcessRenderer :: struct {
  // [is_last][tag]: every pass writes an HDR ring image but the last, which
  // writes the swapchain format
  pipelines:       [2][len(EFFECTS)]vk.Pipeline,
  effect_stack:    [dynamic]PostprocessEffect,
  // Ring of up to POST_PROCESS_RING images per frame in flight, allocated as
  // the stack needs them: pass i writes slot i % POST_PROCESS_RING while its
  // input and original are the two slots before it.
  images:          [gpu.FRAMES_IN_FLIGHT][POST_PROCESS_RING]TextureHandle,
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
  layout: vk.PipelineLayout,
) -> (
  ret: vk.Result,
) {
  self.effect_stack = make([dynamic]PostprocessEffect)
  defer if ret != .SUCCESS do delete(self.effect_stack)
  formats := [2]vk.Format{gpu.HDR_COLOR_FORMAT, color_format}
  blend := [?]vk.PipelineColorBlendAttachmentState{gpu.BLEND_OVERRIDE}
  for &pipelines, is_last in self.pipelines {
    for effect, tag in EFFECTS {
      pipelines[tag] = gpu.create_graphics_pipeline(
        gctx,
        {
          vert = SHADER_POSTPROCESS_VERT,
          frag = effect.frag,
          topology = .TRIANGLE_LIST,
          raster = gpu.DOUBLE_SIDED_RASTERIZER,
          blend = blend[:],
          color_formats = formats[is_last:][:1],
          layout = layout,
        },
      ) or_return
    }
  }
  log.info("Postprocess pipeline initialized successfully")
  return .SUCCESS
}

// Passes the stack runs: each effect's EFFECTS passes.
post_process_pass_count :: proc(effects: []PostprocessEffect) -> (count: int) {
  for effect in effects do count += int(EFFECTS[reflect.get_union_variant_raw_tag(effect)].passes)
  return
}

// Ring images the stack needs: every pass but the last writes one.
post_process_image_count :: proc(effects: []PostprocessEffect) -> int {
  return min(max(post_process_pass_count(effects) - 1, 0), POST_PROCESS_RING)
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
    handle = allocate_texture(
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
      free_texture(texture_manager, gctx, handle)
      handle = {}
    }
  }
}

post_process_shutdown :: proc(self: ^PostProcessRenderer, gctx: ^gpu.GPUContext) {
  for &pipelines in self.pipelines {
    for &p in pipelines {
      vk.DestroyPipeline(gctx.device, p, nil)
      p = 0
    }
  }
  delete(self.effect_stack)
}

// post_process_record runs the post-process effect stack into output_view.
// Pass i reads the output of passes i-1 (input) and i-2 (original), the
// camera's final image standing in before the first pass, and writes ring
// slot i % POST_PROCESS_RING; the last pass writes output_view. An empty
// stack copies the final image to output.
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
  layout: vk.PipelineLayout,
) {
  effects := self.effect_stack[:]
  // with no effect, a single copy (nil effect) brings the input to output
  copy_only := [1]PostprocessEffect{nil}
  if len(effects) == 0 do effects = copy_only[:]
  ring: [POST_PROCESS_RING]^gpu.Image
  discards: [POST_PROCESS_RING]gpu.ImageDiscard
  ring_count := post_process_image_count(effects)
  for &img, slot in ring[:ring_count] {
    img = get_texture(texture_manager, self.images[frame_index][slot])
    if img == nil {
      log.errorf("Post-process image handle %v not found", self.images[frame_index][slot])
      return
    }
    discards[slot] = gpu.attachment_discard(img)
  }
  gpu.image_discard_barrier(command_buffer, ..discards[:ring_count])
  gpu.set_viewport_scissor(command_buffer, extent)
  input, original := final_image_idx, final_image_idx
  pass_count := post_process_pass_count(effects)
  i := 0
  for effect in effects {
    tag := reflect.get_union_variant_raw_tag(effect)
    for pass in 0 ..< EFFECTS[tag].passes {
      defer i += 1
      is_last := i == pass_count - 1
      if i > 0 {
        // The previous pass's output is read here; the slot written here was
        // read by the two passes before.
        gpu.memory_barrier(
          command_buffer,
          {.COLOR_ATTACHMENT_WRITE},
          {.SHADER_READ, .COLOR_ATTACHMENT_WRITE},
          {.COLOR_ATTACHMENT_OUTPUT, .FRAGMENT_SHADER},
          {.FRAGMENT_SHADER, .COLOR_ATTACHMENT_OUTPUT},
        )
      }
      dst_view := output_view
      if !is_last do dst_view = ring[i % POST_PROCESS_RING].view
      gpu.begin_rendering(
        command_buffer,
        extent,
        nil,
        // the fullscreen triangle overwrites every pixel
        gpu.create_color_attachment(dst_view, .DONT_CARE, .STORE),
      )
      vk.CmdBindPipeline(command_buffer, .GRAPHICS, self.pipelines[int(is_last)][tag])
      push := PostProcessPushConstant {
        camera_near          = near,
        camera_far           = far,
        normal_texture_index = gbuffer.normal,
        depth_texture_index  = gbuffer.depth,
        input_image_index    = input,
        original_image_index = original,
        pass                 = pass,
        effect               = effect,
      }
      push_constants(command_buffer, layout, &push)
      vk.CmdDraw(command_buffer, 3, 1, 0, 0)
      vk.CmdEndRendering(command_buffer)
      if !is_last {
        original = input
        input = self.images[frame_index][i % POST_PROCESS_RING].index
      }
    }
  }
}
