package render_graph

import "core:fmt"
import "core:log"
import vk "vendor:vulkan"

// ============================================================================
// Graph Execution
// ============================================================================

execute :: proc(
	graph: ^Graph,
	frame_index: u32,
	cmd: vk.CommandBuffer,
) {
	// Process passes in sorted order
	for pass_id in graph.sorted_passes {
		pass := get_pass(graph, pass_id)

		log.debugf("Executing pass: %s", pass.name)

		// Emit barriers before pass
		emit_barriers_for_pass(graph, pass_id, cmd)

		// Resolve resources for this pass
		resources := resolve_pass_resources(graph, pass, frame_index)
		defer cleanup_pass_resources(&resources)

		// Execute pass
		if pass.execute != nil {
			pass.execute(&resources, cmd, frame_index, pass.user_data)
		}
	}
}

// ============================================================================
// Barrier Emission
// ============================================================================

emit_barriers_for_pass :: proc(
	graph: ^Graph,
	pass_id: PassInstanceId,
	cmd: vk.CommandBuffer,
) {
	// Get barriers for this pass
	barriers, has_barriers := graph.barriers[pass_id]
	if !has_barriers || len(barriers) == 0 {
		return
	}

	// Group barriers by type
	buffer_barriers := make([dynamic]vk.BufferMemoryBarrier, 0, len(barriers))
	image_barriers := make([dynamic]vk.ImageMemoryBarrier, 0, len(barriers))
	defer delete(buffer_barriers)
	defer delete(image_barriers)

	src_stage_mask: vk.PipelineStageFlags = {}
	dst_stage_mask: vk.PipelineStageFlags = {}

	for barrier in barriers {
		src_stage_mask |= barrier.src_stage
		dst_stage_mask |= barrier.dst_stage

		if barrier.buffer != 0 {
			// Buffer barrier
			vk_barrier := vk.BufferMemoryBarrier{
				sType = .BUFFER_MEMORY_BARRIER,
				srcAccessMask = barrier.src_access,
				dstAccessMask = barrier.dst_access,
				srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
				dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
				buffer = barrier.buffer,
				offset = 0,
				size = vk.DeviceSize(vk.WHOLE_SIZE),
			}
			append(&buffer_barriers, vk_barrier)

		} else if barrier.image != 0 {
			// Image barrier
			vk_barrier := vk.ImageMemoryBarrier{
				sType = .IMAGE_MEMORY_BARRIER,
				srcAccessMask = barrier.src_access,
				dstAccessMask = barrier.dst_access,
				oldLayout = barrier.old_layout,
				newLayout = barrier.new_layout,
				srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
				dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
				image = barrier.image,
				subresourceRange = {
					aspectMask = barrier.aspect,
					baseMipLevel = 0,
					levelCount = vk.REMAINING_MIP_LEVELS,
					baseArrayLayer = 0,
					layerCount = vk.REMAINING_ARRAY_LAYERS,
				},
			}
			append(&image_barriers, vk_barrier)
		}
	}

	// Emit pipeline barrier
	if len(buffer_barriers) > 0 || len(image_barriers) > 0 {
		vk.CmdPipelineBarrier(
			cmd,
			src_stage_mask,
			dst_stage_mask,
			{},
			0, nil,
			u32(len(buffer_barriers)), raw_data(buffer_barriers),
			u32(len(image_barriers)), raw_data(image_barriers),
		)
	}
}

// ============================================================================
// Resource Resolution
// ============================================================================

resolve_pass_resources :: proc(
	graph: ^Graph,
	pass: ^PassInstance,
	frame_index: u32,
) -> PassResources {
	resources := PassResources{
		textures = make(map[string]ResolvedTexture),
		buffers = make(map[string]ResolvedBuffer),
		instance_idx = pass.instance,
	}

	// Resolve instance handle based on scope
	switch pass.scope {
	case .PER_CAMERA:
		if int(pass.instance) < len(graph.camera_handles) {
			resources.camera_handle = graph.camera_handles[pass.instance]
		}
	case .PER_LIGHT:
		if int(pass.instance) < len(graph.light_handles) {
			resources.light_handle = graph.light_handles[pass.instance]
		}
	case .GLOBAL:
		// No handle mapping needed
	}

	// Resolve all read resources
	for read in pass.reads {
		resolve_resource(graph, read.resource_name, read.frame_offset, frame_index, &resources)
	}

	// Resolve all write resources
	for write in pass.writes {
		resolve_resource(graph, write.resource_name, write.frame_offset, frame_index, &resources)
	}

	return resources
}

resolve_resource :: proc(
	graph: ^Graph,
	resource_name: string,
	frame_offset: FrameOffset,
	frame_index: u32,
	resources: ^PassResources,
) {
	// Find resource instance
	res_id, found := find_resource_by_name(graph, resource_name)
	if !found {
		fmt.eprintf("ERROR: Resource '%s' not found\n", resource_name)
		return
	}

	res := get_resource(graph, res_id)

	// Compute variant index based on frame offset
	variant_idx := compute_variant_index(frame_index, frame_offset, graph.frames_in_flight)

	// Resolve based on resource type
	switch res.type {
	case .BUFFER:
		resolved := resolve_buffer(res, variant_idx)
		resources.buffers[resource_name] = resolved

	case .TEXTURE_2D, .TEXTURE_CUBE:
		resolved := resolve_texture(res, variant_idx)
		resources.textures[resource_name] = resolved
	}
}

resolve_buffer :: proc(res: ^ResourceInstance, variant_idx: int) -> ResolvedBuffer {
	buffer: vk.Buffer
	size: vk.DeviceSize

	if res.buffer_desc.is_external {
		buffer = res.external_buffer
		size = res.buffer_desc.size
	} else if variant_idx < len(res.buffers) {
		buffer = res.buffers[variant_idx]
		size = res.buffer_size
	}

	return ResolvedBuffer{
		buffer = buffer,
		size = size,
	}
}

resolve_texture :: proc(res: ^ResourceInstance, variant_idx: int) -> ResolvedTexture {
	image: vk.Image
	view: vk.ImageView
	format := res.texture_desc.format
	width := res.texture_desc.width
	height := res.texture_desc.height

	if res.texture_desc.is_external {
		image = res.external_image
		view = res.external_image_view
	} else if variant_idx < len(res.images) {
		image = res.images[variant_idx]
		view = res.image_views[variant_idx]
	}

	return ResolvedTexture{
		image = image,
		view = view,
		format = format,
		width = width,
		height = height,
	}
}

compute_variant_index :: proc(
	frame_index: u32,
	offset: FrameOffset,
	frames_in_flight: int,
) -> int {
	// Compute frame index with offset
	offset_frame := i32(frame_index) + i32(offset)

	// Wrap around frames in flight
	variant := int(offset_frame) % frames_in_flight

	// Handle negative modulo
	if variant < 0 {
		variant += frames_in_flight
	}

	return variant
}

cleanup_pass_resources :: proc(resources: ^PassResources) {
	delete(resources.textures)
	delete(resources.buffers)
}
