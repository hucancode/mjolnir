package mjolnir

import "core:log"
import vk "vendor:vulkan"

render_postprocess_stack :: proc(
  renderer: ^Renderer,
  command_buffer: vk.CommandBuffer,
  input_view: vk.ImageView,
  output_view: vk.ImageView,
  extent: vk.Extent2D,
) {
  pipeline := &renderer.pipeline_postprocess

  if len(pipeline.effect_stack) == 0 {
    // if no postprocess effect, just copy the input to output
    append(&pipeline.effect_stack, nil)
  }

  // effect i:  0, 1, 2, 3, 4, 5, 6
  // read from: m0, p0, p1, 0, 1, 0, input  = (i+1)%2+1  (i != 0)
  // write to:  p0, p1, p0, p1 ...  m1 output = (i%2)+1    (i !=n-1)
  postprocess_update_input(pipeline, 0, input_view)
  postprocess_update_input(
    pipeline,
    1,
    renderer_get_postprocess_pass_view(renderer, 0),
  )
  postprocess_update_input(
    pipeline,
    2,
    renderer_get_postprocess_pass_view(renderer, 1),
  )

  for effect, i in pipeline.effect_stack {
    is_first := i == 0
    is_last := i == len(pipeline.effect_stack) - 1
    src_idx := 0 if is_first else (i - 1) % 2 + 1
    dst_image_idx := i % 2
    src_image_idx := (i - 1) % 2

    log.infof(
      "render effect %v, using descriptor %d, input image %d, output image %d",
      effect,
      src_idx,
      src_image_idx,
      dst_image_idx,
    )

    prepare_image_for_render(
      command_buffer,
      renderer_get_postprocess_pass_image(renderer, dst_image_idx),
      .SHADER_READ_ONLY_OPTIMAL,
    )

    // first image is main pass output, it is already ready for shader
    if !is_first {
      prepare_image_for_shader_read(
        command_buffer,
        renderer_get_postprocess_pass_image(renderer, src_image_idx),
      )
    }

    color_attachment := vk.RenderingAttachmentInfoKHR {
      sType = .RENDERING_ATTACHMENT_INFO_KHR,
      imageView = output_view if is_last else renderer_get_postprocess_pass_view(renderer, dst_image_idx),
      imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
      loadOp = .CLEAR,
      storeOp = .STORE,
      clearValue = vk.ClearValue{color = {float32 = BG_BLUE_GRAY}},
    }

    render_info := vk.RenderingInfoKHR {
      sType = .RENDERING_INFO_KHR,
      renderArea = vk.Rect2D{extent = extent},
      layerCount = 1,
      colorAttachmentCount = 1,
      pColorAttachments = &color_attachment,
    }

    vk.CmdBeginRenderingKHR(command_buffer, &render_info)

    viewport := vk.Viewport {
      width    = f32(extent.width),
      height   = f32(extent.height),
      minDepth = 0.0,
      maxDepth = 1.0,
    }
    scissor := vk.Rect2D {
      extent = extent,
    }
    vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
    vk.CmdSetScissor(command_buffer, 0, 1, &scissor)

    effect_type := postprocess_get_effect_type(effect)
    vk.CmdBindPipeline(
      command_buffer,
      .GRAPHICS,
      pipeline.pipelines[effect_type],
    )
    vk.CmdBindDescriptorSets(
      command_buffer,
      .GRAPHICS,
      pipeline.pipeline_layouts[effect_type],
      0,
      1,
      &pipeline.descriptor_sets[src_idx],
      0,
      nil,
    )

    // Push constants for effects that need them
    postprocess_push_effect_constants(
      command_buffer,
      pipeline,
      effect_type,
      effect,
    )

    vk.CmdDraw(command_buffer, 3, 1, 0, 0)
    vk.CmdEndRenderingKHR(command_buffer)
  }
}

// Helper function to push effect constants
postprocess_push_effect_constants :: proc(
  command_buffer: vk.CommandBuffer,
  pipeline: ^PipelinePostProcess,
  effect_type: PostProcessEffectType,
  effect: PostprocessEffect,
) {
  switch &e in effect {
  case BlurEffect:
    vk.CmdPushConstants(
      command_buffer,
      pipeline.pipeline_layouts[effect_type],
      {.FRAGMENT},
      0,
      size_of(BlurEffect),
      &e,
    )
  case GrayscaleEffect:
    vk.CmdPushConstants(
      command_buffer,
      pipeline.pipeline_layouts[effect_type],
      {.FRAGMENT},
      0,
      size_of(GrayscaleEffect),
      &e,
    )
  case ToneMapEffect:
    vk.CmdPushConstants(
      command_buffer,
      pipeline.pipeline_layouts[effect_type],
      {.FRAGMENT},
      0,
      size_of(ToneMapEffect),
      &e,
    )
  case BloomEffect:
    vk.CmdPushConstants(
      command_buffer,
      pipeline.pipeline_layouts[effect_type],
      {.FRAGMENT},
      0,
      size_of(BloomEffect),
      &e,
    )
  case OutlineEffect:
    vk.CmdPushConstants(
      command_buffer,
      pipeline.pipeline_layouts[effect_type],
      {.FRAGMENT},
      0,
      size_of(OutlineEffect),
      &e,
    )
  }
}
