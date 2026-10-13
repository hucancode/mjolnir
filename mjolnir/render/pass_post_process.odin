package render

import "base:intrinsics"
import "core:log"
import "core:reflect"
import "gpu"
import vk "vendor:vulkan"

// GrayscaleEffect desaturates the image. Effect structs are pushed verbatim, so their layout
// must match each shader's push block. Append effects to r.post_process.effect_stack;
// every camera runs the stack in order.
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

@(private)
SHADER_POSTPROCESS_VERT :: #load("shader/postprocess/vert.spv")

// Indexed by the PostprocessEffect tag (0 = nil). Blur and bloom run twice: pass 0 horizontal, 1 vertical.
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

// Odin stores a union's variant bytes at offset 0, so `effect` puts the active struct at offset 32.
@(private)
PostProcessPushConstant :: struct {
  // camera clip planes, for effects that linearize depth (fog, dof, outline)
  camera_near:          f32,
  camera_far:           f32,
  normal_texture_index: u32,
  depth_texture_index:  u32,
  // the previous pass's output
  input_image_index:    u32,
  // the previous pass's input (bloom V composites over the scene as it entered bloom H)
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
  // pass i writes slot i % POST_PROCESS_RING; its input and original are the two slots before
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

@(private)
post_process_pass_count :: proc(effects: []PostprocessEffect) -> (count: int) {
  for effect in effects do count += int(EFFECTS[reflect.get_union_variant_raw_tag(effect)].passes)
  return
}

@(private)
post_process_image_count :: proc(effects: []PostprocessEffect) -> int {
  return min(max(post_process_pass_count(effects) - 1, 0), POST_PROCESS_RING)
}

// Kept until the swapchain is resized or the level torn down.
@(private)
post_process_ensure_images :: proc(r: ^Renderer, extent: vk.Extent2D, frame_index: u32) -> vk.Result {
  self := &r.post_process
  for &handle in self.images[frame_index][:post_process_image_count(self.effect_stack[:])] {
    if handle != 0 do continue
    handle = allocate_texture(r, extent, gpu.HDR_COLOR_FORMAT, {.COLOR_ATTACHMENT, .SAMPLED}) or_return
  }
  return .SUCCESS
}

@(private)
post_process_release_images :: proc(r: ^Renderer) {
  for &frame in r.post_process.images {
    for &handle in frame {
      destroy_texture(r, handle)
      handle = 0
    }
  }
}

// The camera's final image stands in before the first pass; the last pass writes output_view.
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
