package mjolnir

import "core:log"
import "core:mem"
import "core:slice"
import vk "vendor:vulkan"

PostProcessEffectType :: enum {
  GRAYSCALE,
  TONEMAP,
  BLUR,
  BLOOM,
  OUTLINE,
}

GrayscaleEffect :: struct {
  strength: f32,
}

ToneMapEffect :: struct {
  exposure: f32,
  gamma:    f32,
}

BlurEffect :: struct {
  radius: f32,
}

BloomEffect :: struct {
  threshold:   f32,
  intensity:   f32,
  blur_radius: f32,
}

OutlineEffect :: struct {
  line_width: f32,
  color:      f32,
}

PostprocessEffect :: struct {
  effect_type:    PostProcessEffectType,
  effect:         union {
    GrayscaleEffect,
    ToneMapEffect,
    BlurEffect,
    BloomEffect,
    OutlineEffect,
  },
  pipeline:       vk.Pipeline,
  layout:         vk.PipelineLayout,
  descriptor_set: vk.DescriptorSet,
}

PostprocessStack :: [dynamic]PostprocessEffect

// Utility: run the postprocess stack, ping-ponging between two images.
// - input_view: the initial image view (scene color output)
// - input_sampler: the initial sampler
// - pingpong_views: two image views for ping-ponging
// - pingpong_samplers: two samplers for ping-ponging
// - swapchain_view: the final swapchain image view
// - command_buffer: Vulkan command buffer
// - extent: the size of the render area
run_postprocess_stack :: proc(
  stack: ^PostprocessStack,
  command_buffer: vk.CommandBuffer,
  input_view: vk.ImageView,
  input_sampler: vk.Sampler,
  pingpong_views: [2]vk.ImageView,
  pingpong_samplers: [2]vk.Sampler,
  swapchain_view: vk.ImageView,
  extent: vk.Extent2D,
) {
  src_idx: int = 0
  dst_idx: int = 1
  current_view := input_view
  current_sampler := input_sampler

  for effect, i in stack {
    is_last := i == len(stack) - 1
    output_view := swapchain_view if is_last else pingpong_views[dst_idx]

    // Begin dynamic rendering to output_view
    color_attachment := vk.RenderingAttachmentInfoKHR {
      sType = .RENDERING_ATTACHMENT_INFO_KHR,
      imageView = output_view,
      imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
      loadOp = .CLEAR,
      storeOp = .STORE,
      clearValue = vk.ClearValue{color = {float32 = {0, 0, 0, 1}}},
    }
    render_info := vk.RenderingInfoKHR {
      sType = .RENDERING_INFO_KHR,
      renderArea = vk.Rect2D{extent = extent},
      layerCount = 1,
      colorAttachmentCount = 1,
      pColorAttachments = &color_attachment,
    }
    vk.CmdBeginRenderingKHR(command_buffer, &render_info)

    // Set viewport and scissor
    viewport := vk.Viewport {
      x        = 0.0,
      y        = f32(extent.height),
      width    = f32(extent.width),
      height   = -f32(extent.height),
      minDepth = 0.0,
      maxDepth = 1.0,
    }
    scissor := vk.Rect2D {
      extent = extent,
    }
    vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
    vk.CmdSetScissor(command_buffer, 0, 1, &scissor)

    // Bind pipeline and descriptor set
    vk.CmdBindPipeline(command_buffer, .GRAPHICS, effect.pipeline)
    // vk.CmdBindDescriptorSets(
    //     command_buffer,
    //     .GRAPHICS,
    //     effect.layout,
    //     0,
    //     1,
    //     &effect.descriptor_set,
    //     0,
    //     nil,
    // )

    // Draw fullscreen triangle (vertex shader generates the quad)
    vk.CmdDraw(command_buffer, 3, 1, 0, 0)

    vk.CmdEndRenderingKHR(command_buffer)

    // Swap for next effect if not last
    if !is_last {
      src_idx, dst_idx = dst_idx, src_idx
      current_view = pingpong_views[src_idx]
      current_sampler = pingpong_samplers[src_idx]
    }
  }
}
