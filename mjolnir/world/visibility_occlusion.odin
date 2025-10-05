package world

import "core:log"
import gpu "../gpu"
import resources "../resources"
import vk "vendor:vulkan"

// Two-phase visibility culling with occlusion testing
// Pass 1 (EARLY): Render objects visible last frame (frustum cull only)
// Pass 2 (LATE): Render objects NOT visible last frame (frustum + occlusion cull)

visibility_system_dispatch_with_occlusion :: proc(
	system: ^VisibilitySystem,
	gpu_context: ^gpu.GPUContext,
	resources_manager: ^resources.Manager,
	command_buffer: vk.CommandBuffer,
	frame_index: u32,
	task: VisibilityCategory,
	request: VisibilityRequest,
	depth_pyramid: ^DepthPyramid, // nil for early pass, pyramid for late pass
	early_pass: bool, // true = early (no occlusion), false = late (with occlusion)
) -> VisibilityResult {
	result := VisibilityResult {
		draw_buffer    = 0,
		count_buffer   = 0,
		command_stride = draw_command_stride(),
	}

	if system.node_count == 0 {
		return result
	}
	if frame_index >= resources.MAX_FRAMES_IN_FLIGHT {
		log.errorf("visibility_system_dispatch_with_occlusion: invalid frame index %d", frame_index)
		return result
	}

	frame := &system.frames[frame_index]
	buffers := &frame.tasks[int(task)]

        // Clear draw count and commands
        vk.CmdFillBuffer(
                command_buffer,
                buffers.draw_count.buffer,
                0,
                vk.DeviceSize(buffers.draw_count.bytes_count),
                0,
        )
        vk.CmdFillBuffer(
                command_buffer,
                buffers.draw_commands.buffer,
                0,
                vk.DeviceSize(buffers.draw_commands.bytes_count),
                0,
        )

        need_history_bootstrap := false
        if early_pass {
                if !system.has_visibility_history {
                        need_history_bootstrap = true
                        vk.CmdFillBuffer(
                                command_buffer,
                                buffers.visibility_history.buffer,
                                0,
                                vk.DeviceSize(buffers.visibility_history.bytes_count),
                                0xFFFFFFFF,
                        )
                }
        } else {
                vk.CmdFillBuffer(
                        command_buffer,
                        buffers.visibility_buffer.buffer,
                        0,
                        vk.DeviceSize(buffers.visibility_buffer.bytes_count),
                        0,
                )
        }

        barriers := [dynamic]vk.BufferMemoryBarrier{}
        defer delete(barriers)

        append(&barriers, vk.BufferMemoryBarrier {
		sType         = .BUFFER_MEMORY_BARRIER,
		srcAccessMask = {.TRANSFER_WRITE},
		dstAccessMask = {.SHADER_WRITE, .SHADER_READ},
		buffer        = buffers.draw_count.buffer,
		offset        = 0,
		size          = vk.DeviceSize(buffers.draw_count.bytes_count),
	})
	append(&barriers, vk.BufferMemoryBarrier {
		sType         = .BUFFER_MEMORY_BARRIER,
		srcAccessMask = {.TRANSFER_WRITE},
		dstAccessMask = {.SHADER_WRITE, .SHADER_READ},
                buffer        = buffers.draw_commands.buffer,
                offset        = 0,
                size          = vk.DeviceSize(buffers.draw_commands.bytes_count),
        })
        if early_pass {
                if need_history_bootstrap {
                        append(&barriers, vk.BufferMemoryBarrier {
                                sType         = .BUFFER_MEMORY_BARRIER,
                                srcAccessMask = {.TRANSFER_WRITE},
                                dstAccessMask = {.SHADER_READ},
                                buffer        = buffers.visibility_history.buffer,
                                offset        = 0,
                                size          = vk.DeviceSize(buffers.visibility_history.bytes_count),
                        })
                }
        } else {
                append(&barriers, vk.BufferMemoryBarrier {
                        sType         = .BUFFER_MEMORY_BARRIER,
                        srcAccessMask = {.TRANSFER_WRITE},
                        dstAccessMask = {.SHADER_WRITE},
                        buffer        = buffers.visibility_buffer.buffer,
                        offset        = 0,
                        size          = vk.DeviceSize(buffers.visibility_buffer.bytes_count),
                })
        }

	vk.CmdPipelineBarrier(
		command_buffer,
		{.TRANSFER},
		{.COMPUTE_SHADER},
		{},
		0,
		nil,
		u32(len(barriers)),
		raw_data(barriers[:]),
		0,
		nil,
	)

        use_occlusion := depth_pyramid != nil

        if use_occlusion {
                vk.CmdBindPipeline(command_buffer, .COMPUTE, system.pipeline_occlusion)

                descriptor_set: vk.DescriptorSet
                vk.AllocateDescriptorSets(
                        gpu_context.device,
                        &vk.DescriptorSetAllocateInfo {
                                sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
                                descriptorPool     = gpu_context.descriptor_pool,
                                descriptorSetCount = 1,
                                pSetLayouts        = &system.descriptor_set_layout_occlusion,
                        },
                        &descriptor_set,
                )

                node_info := vk.DescriptorBufferInfo {
                        buffer = resources_manager.node_data_buffer.device_buffer,
                        range  = vk.DeviceSize(resources_manager.node_data_buffer.bytes_count),
                }
                mesh_info := vk.DescriptorBufferInfo {
                        buffer = resources_manager.mesh_data_buffer.device_buffer,
                        range  = vk.DeviceSize(resources_manager.mesh_data_buffer.bytes_count),
                }
                world_info := vk.DescriptorBufferInfo {
                        buffer = resources_manager.world_matrix_buffer.device_buffer,
                        range  = vk.DeviceSize(resources_manager.world_matrix_buffer.bytes_count),
                }
                camera_info := vk.DescriptorBufferInfo {
                        buffer = resources_manager.camera_buffer.buffer,
                        range  = vk.DeviceSize(resources_manager.camera_buffer.bytes_count),
                }
                count_info := vk.DescriptorBufferInfo {
                        buffer = buffers.draw_count.buffer,
                        range  = vk.DeviceSize(buffers.draw_count.bytes_count),
                }
                command_info := vk.DescriptorBufferInfo {
                        buffer = buffers.draw_commands.buffer,
                        range  = vk.DeviceSize(buffers.draw_commands.bytes_count),
                }
                history_info := vk.DescriptorBufferInfo {
                        buffer = buffers.visibility_history.buffer,
                        range  = vk.DeviceSize(buffers.visibility_history.bytes_count),
                }
                visibility_info := vk.DescriptorBufferInfo {
                        buffer = buffers.visibility_buffer.buffer,
                        range  = vk.DeviceSize(buffers.visibility_buffer.bytes_count),
                }
                pyramid_image_info := vk.DescriptorImageInfo {}
                if depth_pyramid != nil {
                        pyramid_image_info = vk.DescriptorImageInfo {
                                sampler     = depth_pyramid.sampler,
                                imageView   = depth_pyramid.image_view,
                                imageLayout = .SHADER_READ_ONLY_OPTIMAL,
                        }
                }

                writes := make([dynamic]vk.WriteDescriptorSet, 0)
                defer delete(writes)

                append(&writes, vk.WriteDescriptorSet {sType = .WRITE_DESCRIPTOR_SET, dstSet = descriptor_set, dstBinding = 0, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, pBufferInfo = &node_info})
                append(&writes, vk.WriteDescriptorSet {sType = .WRITE_DESCRIPTOR_SET, dstSet = descriptor_set, dstBinding = 1, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, pBufferInfo = &mesh_info})
                append(&writes, vk.WriteDescriptorSet {sType = .WRITE_DESCRIPTOR_SET, dstSet = descriptor_set, dstBinding = 2, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, pBufferInfo = &world_info})
                append(&writes, vk.WriteDescriptorSet {sType = .WRITE_DESCRIPTOR_SET, dstSet = descriptor_set, dstBinding = 3, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, pBufferInfo = &camera_info})
                append(&writes, vk.WriteDescriptorSet {sType = .WRITE_DESCRIPTOR_SET, dstSet = descriptor_set, dstBinding = 4, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, pBufferInfo = &count_info})
                append(&writes, vk.WriteDescriptorSet {sType = .WRITE_DESCRIPTOR_SET, dstSet = descriptor_set, dstBinding = 5, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, pBufferInfo = &command_info})
                append(&writes, vk.WriteDescriptorSet {sType = .WRITE_DESCRIPTOR_SET, dstSet = descriptor_set, dstBinding = 6, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, pBufferInfo = &history_info})
                append(&writes, vk.WriteDescriptorSet {sType = .WRITE_DESCRIPTOR_SET, dstSet = descriptor_set, dstBinding = 7, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, pBufferInfo = &visibility_info})

                if depth_pyramid != nil {
                        append(&writes, vk.WriteDescriptorSet {
                                sType = .WRITE_DESCRIPTOR_SET,
                                dstSet = descriptor_set,
                                dstBinding = 8,
                                descriptorType = .COMBINED_IMAGE_SAMPLER,
                                descriptorCount = 1,
                                pImageInfo = &pyramid_image_info,
                        })
                }

                vk.UpdateDescriptorSets(gpu_context.device, u32(len(writes)), raw_data(writes[:]), 0, nil)

                vk.CmdBindDescriptorSets(
                        command_buffer,
                        .COMPUTE,
                        system.pipeline_layout_occlusion,
                        0,
                        1,
                        &descriptor_set,
                        0,
                        nil,
                )
        } else {
                vk.CmdBindPipeline(command_buffer, .COMPUTE, system.pipeline)
                vk.CmdBindDescriptorSets(
                        command_buffer,
                        .COMPUTE,
                        system.pipeline_layout,
                        0,
                        1,
                        &buffers.descriptor_set,
                        0,
                        nil,
                )
        }

	// Push constants
	push_constants := VisibilityPushConstants {
		camera_index   = request.camera_index,
		node_count     = system.node_count,
		max_draws      = system.max_draws,
		include_flags  = request.include_flags,
		exclude_flags  = request.exclude_flags,
		culling_mode   = early_pass ? 0 : 1, // 0 = early, 1 = late
                pyramid_width  = use_occlusion && depth_pyramid != nil ? f32(depth_pyramid.width) : 0,
                pyramid_height = use_occlusion && depth_pyramid != nil ? f32(depth_pyramid.height) : 0,
        }

        vk.CmdPushConstants(
                command_buffer,
                use_occlusion ? system.pipeline_layout_occlusion : system.pipeline_layout,
                {.COMPUTE},
                0,
                size_of(push_constants),
                &push_constants,
	)

	// Dispatch
	dispatch_x := (system.node_count + 63) / 64
	vk.CmdDispatch(command_buffer, dispatch_x, 1, 1)

	// Post-dispatch barriers
        post_barriers := [dynamic]vk.BufferMemoryBarrier{}
        defer delete(post_barriers)

        append(&post_barriers, vk.BufferMemoryBarrier {
                sType         = .BUFFER_MEMORY_BARRIER,
                srcAccessMask = {.SHADER_WRITE},
                dstAccessMask = {.INDIRECT_COMMAND_READ},
                buffer        = buffers.draw_commands.buffer,
                offset        = 0,
                size          = vk.DeviceSize(buffers.draw_commands.bytes_count),
        })
        append(&post_barriers, vk.BufferMemoryBarrier {
                sType         = .BUFFER_MEMORY_BARRIER,
                srcAccessMask = {.SHADER_WRITE},
                dstAccessMask = {.INDIRECT_COMMAND_READ},
                buffer        = buffers.draw_count.buffer,
                offset        = 0,
                size          = vk.DeviceSize(buffers.draw_count.bytes_count),
        })
        if !early_pass {
                append(&post_barriers, vk.BufferMemoryBarrier {
                        sType         = .BUFFER_MEMORY_BARRIER,
                        srcAccessMask = {.SHADER_WRITE},
                        dstAccessMask = {.TRANSFER_READ},
                        buffer        = buffers.visibility_buffer.buffer,
                        offset        = 0,
                        size          = vk.DeviceSize(buffers.visibility_buffer.bytes_count),
                })
        }

        vk.CmdPipelineBarrier(
                command_buffer,
                {.COMPUTE_SHADER},
                early_pass ? {.DRAW_INDIRECT} : {.DRAW_INDIRECT, .TRANSFER},
                {},
                0,
                nil,
                u32(len(post_barriers)),
                raw_data(post_barriers[:]),
                0,
                nil,
        )

        if !early_pass {
                copy_region := vk.BufferCopy {
                        srcOffset = 0,
                        dstOffset = 0,
                        size      = vk.DeviceSize(buffers.visibility_buffer.bytes_count),
                }
                vk.CmdCopyBuffer(
                        command_buffer,
                        buffers.visibility_buffer.buffer,
                        buffers.visibility_history.buffer,
                        1,
                        &copy_region,
                )

                history_barrier := vk.BufferMemoryBarrier {
                        sType         = .BUFFER_MEMORY_BARRIER,
                        srcAccessMask = {.TRANSFER_WRITE},
                        dstAccessMask = {.SHADER_READ},
                        buffer        = buffers.visibility_history.buffer,
                        offset        = 0,
                        size          = vk.DeviceSize(buffers.visibility_history.bytes_count),
                }

                vk.CmdPipelineBarrier(
                        command_buffer,
                        {.TRANSFER},
                        {.COMPUTE_SHADER},
                        {},
                        0,
                        nil,
                        1,
                        &history_barrier,
                        0,
                        nil,
                )

                system.has_visibility_history = true
        }

        result.draw_buffer = buffers.draw_commands.buffer
        result.count_buffer = buffers.draw_count.buffer
        return result
}
