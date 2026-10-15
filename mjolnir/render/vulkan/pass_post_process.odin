package vulkan_backend

import rhi "../rhi"

import "base:intrinsics"
import "core:reflect"
import vk "vendor:vulkan"











@(private)
SHADER_POSTPROCESS_VERT :: #load("shader/postprocess/vert.spv")

// Fragment shader per PostprocessEffect tag (0 = nil).
EFFECTS := [?][]u8 {
  #load("shader/postprocess/frag.spv"),
  #load("shader/grayscale/frag.spv"),
  #load("shader/tonemap/frag.spv"),
  #load("shader/blur/frag.spv"),
  #load("shader/bloom/frag.spv"),
  #load("shader/outline/frag.spv"),
  #load("shader/fog/frag.spv"),
  #load("shader/crosshatch/frag.spv"),
  #load("shader/dof/frag.spv"),
}
#assert(len(EFFECTS) == intrinsics.type_union_variant_count(rhi.PostprocessEffect) + 1)

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
  // this pass of the effect
  pass:                 u32,
  _:                    u32,
  effect:               rhi.PostprocessEffect,
}
#assert(offset_of(PostProcessPushConstant, effect) == 32)

@(private)
post_process_init :: proc(b: ^Backend) -> vk.Result {
  formats := [2]vk.Format{FORMATS[rhi.HDR_COLOR_FORMAT], b.swapchain.format.format}
  blend := [?]vk.PipelineColorBlendAttachmentState{BLEND_OVERRIDE}
  for &pipelines, is_last in b.post_process_pipelines {
    for frag, tag in EFFECTS {
      pipelines[tag] = create_graphics_pipeline(
        &b.gctx,
        {
          vert = SHADER_POSTPROCESS_VERT,
          frag = frag,
          topology = .TRIANGLE_LIST,
          blend = blend[:],
          color_formats = formats[is_last:][:1],
          layout = b.scene.layout,
        },
      ) or_return
    }
  }
  return .SUCCESS
}

// Every pass but the last writes a texture; the last writes output_view.
@(private)
post_process_record :: proc(
  b: ^Backend,
  desc: ^rhi.FrameDesc,
  frame_index: u32,
  extent: vk.Extent2D,
  output_view: vk.ImageView,
  cam: ^rhi.FrameCamera,
) {
  command_buffer := b.command_buffers[frame_index]
  discards := make([dynamic]ImageDiscard, 0, len(desc.post_passes), context.temp_allocator)
  outer: for &p, i in desc.post_passes {
    if p.output == 0 do continue
    for q in desc.post_passes[:i] do if q.output == p.output do continue outer
    append(&discards, attachment_discard(texture_image(b, p.output)))
  }
  image_discard_barrier(command_buffer, ..discards[:])
  for &p, i in desc.post_passes {
    if i > 0 do barrier(command_buffer, .POST_PASS)
    is_last := p.output == 0
    dst_view := output_view if is_last else texture_image(b, p.output).view
    begin_rendering(
      command_buffer,
      extent,
      nil,
      // the fullscreen triangle overwrites every pixel
      create_color_attachment(dst_view, .DONT_CARE, .STORE),
    )
    vk.CmdBindPipeline(command_buffer, .GRAPHICS, b.post_process_pipelines[int(is_last)][reflect.get_union_variant_raw_tag(p.effect)])
    push := PostProcessPushConstant {
      camera_near          = cam.near,
      camera_far           = cam.far,
      normal_texture_index = u32(cam.attachments[.NORMAL]),
      depth_texture_index  = u32(cam.attachments[.DEPTH]),
      input_image_index    = u32(p.input),
      original_image_index = u32(p.original),
      pass                 = p.pass,
      effect               = p.effect,
    }
    push_constants(b, command_buffer, &push)
    vk.CmdDraw(command_buffer, 3, 1, 0, 0)
    vk.CmdEndRendering(command_buffer)
  }
}
