package mjolnir

import "core:log"
import vk "vendor:vulkan"

RendererPostProcess :: struct {
  pipeline: PipelinePostProcess,
  images:   [2]ImageBuffer,
}

renderer_postprocess_init :: proc(
  self: ^RendererPostProcess,
  color_format: vk.Format,
  width: u32,
  height: u32,
) -> vk.Result {
  pipeline_postprocess_init(
    &self.pipeline,
    color_format,
    width,
    height,
  ) or_return
  for &image in self.images {
    image = malloc_image_buffer(
      width,
      height,
      color_format,
      .OPTIMAL,
      {.COLOR_ATTACHMENT, .SAMPLED, .TRANSFER_SRC, .TRANSFER_DST},
      {.DEVICE_LOCAL},
    ) or_return
    image.view = create_image_view(
      image.image,
      color_format,
      {.COLOR},
    ) or_return
  }
  return .SUCCESS
}

renderer_postprocess_deinit :: proc(self: ^RendererPostProcess) {
  pipeline_postprocess_deinit(&self.pipeline)
  for &image in self.images do image_buffer_deinit(&image)
}

render_postprocess_stack :: proc(
  self: ^RendererPostProcess,
  command_buffer: vk.CommandBuffer,
  input_view: vk.ImageView,
  output_view: vk.ImageView,
  extent: vk.Extent2D,
) {
  pipeline := &self.pipeline
  if len(pipeline.effect_stack) == 0 {
    // if no postprocess effect, just copy the input to output
    append(&pipeline.effect_stack, nil)
  }
  postprocess_update_input(pipeline, 0, input_view)
  postprocess_update_input(pipeline, 1, self.images[0].view)
  postprocess_update_input(pipeline, 2, self.images[1].view)
  for effect, i in pipeline.effect_stack {
    is_first := i == 0
    is_last := i == len(pipeline.effect_stack) - 1
    src_idx := 0 if is_first else (i - 1) % 2 + 1
    dst_image_idx := i % 2
    src_image_idx := (i - 1) % 2
    prepare_image_for_render(
      command_buffer,
      self.images[dst_image_idx].image,
      .SHADER_READ_ONLY_OPTIMAL,
    )
    // first image is main pass output, it is already ready for shader
    if !is_first {
      prepare_image_for_shader_read(
        command_buffer,
        self.images[src_image_idx].image,
      )
    }
    color_attachment := vk.RenderingAttachmentInfoKHR {
      sType = .RENDERING_ATTACHMENT_INFO_KHR,
      imageView = output_view if is_last else self.images[dst_image_idx].view,
      imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
      loadOp = .CLEAR,
      storeOp = .STORE,
      clearValue = {color = {float32 = BG_BLUE_GRAY}},
    }
    render_info := vk.RenderingInfoKHR {
      sType = .RENDERING_INFO_KHR,
      renderArea = {extent = extent},
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
    effect_type := get_effect_type(effect)
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
