# Anatomy of a frame

Optimal frame render flow
```
// Initialization
create_fences_and_semaphores_for_each_frame_in_flight()

// Per-frame rendering
frame() {
    // 1. Wait for previous frame's completion
    wait_for_frame_fence()
    reset_frame_fence()

    // 2. Acquire next swapchain image
    acquire_next_image(acquire_semaphore)

    // 3. Begin unified command buffer
    reset_command_buffer()
    begin_command_buffer()

    // 4. Shadow pass (all lights)
    for each shadow-casting light {
        transition_to_depth_attachment(shadow_map)
        render_shadows(shadow_map)
        transition_to_shader_read(shadow_map)
    }

    // 5. Main pass
    transition_to_color_attachment(swapchain_image)
    render_main_scene()
    transition_to_present_src(swapchain_image)

    // 6. End and submit
    end_command_buffer()

    submit_to_queue(
        wait_semaphores: [acquire_semaphore],
        wait_stages: [COLOR_ATTACHMENT_OUTPUT],
        signal_semaphores: [render_complete_semaphore],
        fence: frame_fence
    )

    // 7. Present
    present(
        wait_semaphores: [render_complete_semaphore]
    )
}
```