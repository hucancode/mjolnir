package render

import "base:intrinsics"
import "core:log"
import "core:reflect"
import "gpu"
import vk "vendor:vulkan"

// Effect structs are pushed verbatim right after the base fields of
// PostProcessPushConstant (offset 32); their layout must match each shader's push block.
// Append effects to r.post_process.effect_stack; every camera runs the stack
// in order.
GrayscaleEffect :: struct {
  weights:  [3]f32, // zero = Rec. 601 luma
  strength: f32,
}

ToneMapEffect :: struct {
  exposure: f32,
  gamma:    f32,
}

BlurEffect :: struct {
  radius:         f32,
  weight_falloff: f32, // 0.0 = box blur, 1.0 = gaussian blur
}

BloomEffect :: struct {
  threshold:   f32,
  intensity:   f32,
  blur_radius: f32,
}

OutlineEffect :: struct {
  color:     [3]f32,
  thickness: f32,
}

FogEffect :: struct {
  color: [3]f32,
  start: f32,
  end:   f32,
}

// Below lum_thresholds[i] (tonemapped luminance), stroke family i hatches
// the pixel: the two diagonals, then both shifted by hatch_offset_y.
CrossHatchEffect :: struct {
  hatch_offset_y: f32,
  lum_thresholds: [4]f32,
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

@(private)
SHADER_POSTPROCESS_VERT :: #load("shader/postprocess/vert.spv")

// Each effect's fragment shader and pass count, indexed by the
// PostprocessEffect union tag (0 = nil). A separable effect runs its shader
// once per pass, reading the pass number from the push constant (blur and
// bloom: 0 horizontal, 1 vertical).
@(private)
EFFECTS := [?]struct {
  frag:   []u8,
  passes: u32,
} {
  {#load("shader/postprocess/frag.spv"), 1},
  {#load("shader/grayscale/frag.spv"), 1},
  {#load("shader/tonemap/frag.spv"), 1},
  {#load("shader/blur/frag.spv"), 2},
  {#load("shader/bloom/frag.spv"), 2},
  {#load("shader/outline/frag.spv"), 1},
  {#load("shader/fog/frag.spv"), 1},
  {#load("shader/crosshatch/frag.spv"), 1},
  {#load("shader/dof/frag.spv"), 1},
}
#assert(len(EFFECTS) == intrinsics.type_union_variant_count(PostprocessEffect) + 1)

// Odin stores a union's variant bytes at offset 0, so `effect` places the
// active effect struct at offset 32, followed by the (unread) tag.
@(private)
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

@(private)
POST_PROCESS_RING :: 3

@(private)
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

@(private)
post_process_init :: proc(r: ^Renderer) -> vk.Result {
  self := &r.post_process
  self.effect_stack = make([dynamic]PostprocessEffect)
  formats := [2]vk.Format{gpu.HDR_COLOR_FORMAT, r.swapchain.format.format}
  blend := [?]vk.PipelineColorBlendAttachmentState{gpu.BLEND_OVERRIDE}
  for &pipelines, is_last in self.pipelines {
    for effect, tag in EFFECTS {
      pipelines[tag] = gpu.create_graphics_pipeline(
        &r.gctx,
        {
          vert = SHADER_POSTPROCESS_VERT,
          frag = effect.frag,
          topology = .TRIANGLE_LIST,
          blend = blend[:],
          color_formats = formats[is_last:][:1],
          layout = r.scene.layout,
        },
      ) or_return
    }
  }
  return .SUCCESS
}

// Passes the stack runs: each effect's EFFECTS passes.
@(private)
post_process_pass_count :: proc(effects: []PostprocessEffect) -> (count: int) {
  for effect in effects do count += int(EFFECTS[reflect.get_union_variant_raw_tag(effect)].passes)
  return
}

// Ring images the stack needs: every pass but the last writes one.
@(private)
post_process_image_count :: proc(effects: []PostprocessEffect) -> int {
  return min(max(post_process_pass_count(effects) - 1, 0), POST_PROCESS_RING)
}

// Allocate the ping-pong images the current stack needs and does not have
// yet. Images are kept until the swapchain is resized or the level torn down.
@(private)
post_process_ensure_images :: proc(r: ^Renderer, extent: vk.Extent2D, frame_index: u32) -> vk.Result {
  self := &r.post_process
  for &handle in self.images[frame_index][:post_process_image_count(self.effect_stack[:])] {
    if handle != 0 do continue
    handle = allocate_texture(r, extent, gpu.HDR_COLOR_FORMAT, {.COLOR_ATTACHMENT, .SAMPLED}) or_return
  }
  return .SUCCESS
}

// Free the ring images; the next frame allocates them again at its extent.
@(private)
post_process_release_images :: proc(r: ^Renderer) {
  for &frame in r.post_process.images {
    for &handle in frame {
      destroy_texture(r, handle)
      handle = 0
    }
  }
}

// post_process_record runs the post-process effect stack into output_view.
// Pass i reads the output of passes i-1 (input) and i-2 (original), the
// camera's final image standing in before the first pass, and writes ring
// slot i % POST_PROCESS_RING; the last pass writes output_view. An empty
// stack copies the final image to output.
@(private)
post_process_record :: proc(
  r: ^Renderer,
  frame_index: u32,
  extent: vk.Extent2D,
  output_view: vk.ImageView,
  cam: ^Camera,
) {
  self := &r.post_process
  command_buffer := r.command_buffers[frame_index]
  effects := self.effect_stack[:]
  // with no effect, a single copy (nil effect) brings the input to output
  copy_only := [1]PostprocessEffect{nil}
  if len(effects) == 0 do effects = copy_only[:]
  ring: [POST_PROCESS_RING]^gpu.Image
  discards: [POST_PROCESS_RING]gpu.ImageDiscard
  ring_count := post_process_image_count(effects)
  for &img, slot in ring[:ring_count] {
    img = texture_image(r, self.images[frame_index][slot])
    if img == nil {
      log.errorf("Post-process image handle %v not found", self.images[frame_index][slot])
      return
    }
    discards[slot] = gpu.attachment_discard(img)
  }
  gpu.image_discard_barrier(command_buffer, ..discards[:ring_count])
  input := u32(cam.attachments[.FINAL_IMAGE][frame_index])
  original := input
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
        camera_near          = cam.near,
        camera_far           = cam.far,
        normal_texture_index = u32(cam.attachments[.NORMAL][frame_index]),
        depth_texture_index  = u32(cam.attachments[.DEPTH][frame_index]),
        input_image_index    = input,
        original_image_index = original,
        pass                 = pass,
        effect               = effect,
      }
      push_constants(r, command_buffer, &push)
      vk.CmdDraw(command_buffer, 3, 1, 0, 0)
      vk.CmdEndRendering(command_buffer)
      if !is_last {
        original = input
        input = u32(self.images[frame_index][i % POST_PROCESS_RING])
      }
    }
  }
}
