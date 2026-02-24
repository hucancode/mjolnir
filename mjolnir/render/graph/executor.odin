package render_graph

import vk "vendor:vulkan"
import "core:log"

// ============================================================================
// PUBLIC API - EXECUTE PHASE
// ============================================================================

// Execute graph for a frame with automatic barrier insertion
// Takes execution context as parameter (NOT stored in Graph!)
graph_execute :: proc(g: ^Graph, cmd: vk.CommandBuffer, frame_index: u32, exec_ctx: ^GraphExecutionContext) -> Result {
	for pass_id in g.execution_order {
		pass := &g.passes[pass_id]

		// Insert barriers before pass
		if barriers, has_barriers := g.barriers[pass_id]; has_barriers {
			for barrier in barriers {
				_emit_barrier(g, cmd, barrier, frame_index, exec_ctx)
			}
		}

		// Execute pass
		ctx := PassContext{
			graph = g,
			frame_index = frame_index,
			scope_index = pass.scope_index,
			cmd = cmd,
			exec_ctx = exec_ctx,  // Pass execution context for resource resolution
		}
		pass.execute(&ctx, pass.user_data)
	}

	log.infof("Executed %d passes", len(g.execution_order))
	return .SUCCESS
}

// ============================================================================
// PRIVATE HELPERS
// ============================================================================

@(private)
_emit_barrier :: proc(g: ^Graph, cmd: vk.CommandBuffer, barrier: Barrier, frame_index: u32, exec_ctx: ^GraphExecutionContext) {
	// Get resource descriptor
	desc, ok := g.resources[barrier.resource_id]
	if !ok {
		log.warnf("Failed to find resource descriptor for '%s'", string(barrier.resource_id))
		return
	}

	// Resolve resource
	handle, handle_ok := desc.resolve(exec_ctx, string(barrier.resource_id), frame_index)
	if !handle_ok {
		// This is not necessarily an error - resource might not exist yet (e.g., inactive camera)
		return
	}

	// Emit appropriate barrier based on handle type
	switch h in handle {
	case BufferHandle:
		buffer_barrier := vk.BufferMemoryBarrier{
			sType = .BUFFER_MEMORY_BARRIER,
			srcAccessMask = barrier.src_access,
			dstAccessMask = barrier.dst_access,
			srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			buffer = h.buffer,
			offset = 0,
			size = h.size,
		}
		vk.CmdPipelineBarrier(
			cmd,
			barrier.src_stage,
			barrier.dst_stage,
			{},
			0, nil,
			1, &buffer_barrier,
			0, nil,
		)

	case TextureHandle:
		image_barrier := vk.ImageMemoryBarrier{
			sType = .IMAGE_MEMORY_BARRIER,
			srcAccessMask = barrier.src_access,
			dstAccessMask = barrier.dst_access,
			oldLayout = barrier.old_layout,
			newLayout = barrier.new_layout,
			srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			image = h.image,
			subresourceRange = {
				aspectMask = {.COLOR},
				baseMipLevel = 0,
				levelCount = 1,
				baseArrayLayer = 0,
				layerCount = 1,
			},
		}
		vk.CmdPipelineBarrier(
			cmd,
			barrier.src_stage,
			barrier.dst_stage,
			{},
			0, nil,
			0, nil,
			1, &image_barrier,
		)

	case DepthTextureHandle:
		image_barrier := vk.ImageMemoryBarrier{
			sType = .IMAGE_MEMORY_BARRIER,
			srcAccessMask = barrier.src_access,
			dstAccessMask = barrier.dst_access,
			oldLayout = barrier.old_layout,
			newLayout = barrier.new_layout,
			srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			image = h.image,
			subresourceRange = {
				aspectMask = {.DEPTH},
				baseMipLevel = 0,
				levelCount = 1,
				baseArrayLayer = 0,
				layerCount = 1,
			},
		}
		vk.CmdPipelineBarrier(
			cmd,
			barrier.src_stage,
			barrier.dst_stage,
			{},
			0, nil,
			0, nil,
			1, &image_barrier,
		)
	}
}
