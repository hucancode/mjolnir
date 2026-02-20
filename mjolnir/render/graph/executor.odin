package render_graph

import "../../gpu"
import "core:log"
import vk "vendor:vulkan"

// Execute the compiled graph for a given frame.
// graphics_cmd: command buffer for graphics queue passes
// compute_cmd:  command buffer for compute queue passes (may be 0 if no async compute)
// frame_index:  current frame index (0..FRAMES_IN_FLIGHT-1)
execute :: proc(
	g: ^Graph,
	graphics_cmd: vk.CommandBuffer,
	compute_cmd: vk.CommandBuffer,
	frame_index: u32,
) {
	if !g.is_compiled {
		log.error("Render graph not compiled - call compile() before execute()")
		return
	}

	for &cp in g.compiled {
		pass, has := g.passes[cp.pass_id]
		if !has || !pass.enabled do continue

		cmd := graphics_cmd
		if cp.queue == .COMPUTE && compute_cmd != nil {
			cmd = compute_cmd
		}

		// Emit image barriers
		for &ib in cp.image_barriers {
			entry, has_entry := g.resources[ib.resource_id]
			if !has_entry do continue

			resolved, ok := resolve_image(entry.resource, frame_index)
			if !ok do continue

			gpu.image_barrier(
				cmd,
				resolved.image,
				ib.old_state.layout,
				ib.new_state.layout,
				ib.old_state.access,
				ib.new_state.access,
				ib.old_state.stage,
				ib.new_state.stage,
				ib.aspect_mask,
				layer_count = ib.layer_count,
			)
		}

		// Emit buffer barriers
		for &bb in cp.buffer_barriers {
			entry, has_entry := g.resources[bb.resource_id]
			if !has_entry do continue

			resolved, ok := resolve_buffer(entry.resource, frame_index)
			if !ok do continue

			barrier := vk.BufferMemoryBarrier {
				sType               = .BUFFER_MEMORY_BARRIER,
				srcAccessMask       = bb.src_access,
				dstAccessMask       = bb.dst_access,
				srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
				dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
				buffer              = resolved.buffer,
				offset              = 0,
				size                = vk.DeviceSize(vk.WHOLE_SIZE),
			}
			vk.CmdPipelineBarrier(
				cmd,
				bb.src_stage,
				bb.dst_stage,
				{},
				0,
				nil,
				1,
				&barrier,
				0,
				nil,
			)
		}

		// Execute the pass callback
		if pass.execute != nil {
			pass.execute(cmd, frame_index, pass.user_data)
		}
	}
}
