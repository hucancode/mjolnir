package mjolnir

import "core:log"
import "core:mem"
import "core:slice"
import vk "vendor:vulkan"

BloomEffect :: struct {
  threshold:   f32,
  intensity:   f32,
  blur_radius: f32,
}

ToneMapEffect :: struct {
  exposure: f32,
  gamma:    f32,
}

FXAAEffect :: struct {
  // FXAA-specific params (placeholder)
}

PostprocessEffect :: struct {
  effect:    union {
    BloomEffect,
    ToneMapEffect,
    FXAAEffect,
  },
  pipeline:       vk.Pipeline,
  layout:         vk.PipelineLayout,
  descriptor_set: vk.DescriptorSet,
}

PostprocessStack :: [dynamic]PostprocessEffect

postprocess_stack_init :: proc(stack: ^PostprocessStack) {
  stack^ = make([dynamic]PostprocessEffect, 0)
}

add_postprocess_effect :: proc(
  stack: ^PostprocessStack,
  effect: PostprocessEffect,
) {
  append(stack, effect)
}

clear_postprocess_effects :: proc(stack: ^PostprocessStack) {
  resize(stack, 0)
}

postprocess_stack_count :: proc(stack: ^PostprocessStack) -> int {
  return len(stack)
}

// Utility: run the postprocess stack, ping-ponging between two images.
// - input_view: the initial image view (scene color output)
// - input_sampler: the initial sampler
// - pingpong_views: two image views for ping-ponging
// - pingpong_samplers: two samplers for ping-ponging
// - swapchain_view: the final swapchain image view
// - command_buffer: Vulkan command buffer
run_postprocess_stack :: proc(
  stack: ^PostprocessStack,
  command_buffer: vk.CommandBuffer,
  input_view: vk.ImageView,
  input_sampler: vk.Sampler,
  pingpong_views: [2]vk.ImageView,
  pingpong_samplers: [2]vk.Sampler,
  swapchain_view: vk.ImageView,
  render_fullscreen_quad: proc(
    command_buffer: vk.CommandBuffer,
    pipeline: vk.Pipeline,
    layout: vk.PipelineLayout,
    descriptor_set: vk.DescriptorSet,
  ),
  render_copy_to_swapchain: proc(
    command_buffer: vk.CommandBuffer,
    input_view: vk.ImageView,
    input_sampler: vk.Sampler,
    swapchain_view: vk.ImageView,
  ),
) {
  src_idx: int = 0
  dst_idx: int = 1

  current_view := input_view
  current_sampler := input_sampler

  for i in 0 ..< len(stack) {
    effect := &stack[i]
    output_view := pingpong_views[dst_idx]
    output_sampler := pingpong_samplers[dst_idx]

    // Begin render pass to output_view (implementation-specific)
    // User must handle render pass begin/end outside or via callback

    // Bind pipeline, layout, descriptor set, and draw fullscreen quad
    render_fullscreen_quad(
      command_buffer,
      effect.pipeline,
      effect.layout,
      effect.descriptor_set,
    )

    // Swap src/dst for next effect
    src_idx, dst_idx = dst_idx, src_idx
    current_view = pingpong_views[src_idx]
    current_sampler = pingpong_samplers[src_idx]
  }

  // Final pass: copy or render to swapchain
  render_copy_to_swapchain(
    command_buffer,
    current_view,
    current_sampler,
    swapchain_view,
  )
}
