package render_graph

import "core:fmt"
import vk "vendor:vulkan"

// ============================================================================
// Resource Allocation
// ============================================================================

allocate_resources :: proc(
	graph: ^Graph,
	gctx: rawptr,
	loc := #caller_location,
) -> CompileError {
	// Determine which resources need frame variants (NEXT/PREV access)
	needs_frame_variants := make(map[string]bool, len(graph.resource_instances))
	defer delete(needs_frame_variants)

	for &pass in graph.pass_instances {
		// Check reads
		for read in pass.reads {
			if read.frame_offset != .CURRENT {
				needs_frame_variants[read.resource_name] = true
			}
		}

		// Check writes
		for write in pass.writes {
			if write.frame_offset != .CURRENT {
				needs_frame_variants[write.resource_name] = true
			}
		}
	}

	// Allocate resources
	for &res, idx in graph.resource_instances {
		// Skip external resources
		is_external := false
		switch res.type {
		case .BUFFER:
			is_external = res.buffer_desc.is_external
		case .TEXTURE_2D, .TEXTURE_CUBE:
			is_external = res.texture_desc.is_external
		}

		if is_external {
			continue
		}

		// Determine number of variants
		variant_count := 1
		if needs_frame_variants[res.name] {
			variant_count = graph.frames_in_flight
		}

		// Allocate based on resource type
		switch res.type {
		case .BUFFER:
			allocate_buffer(&res, gctx, variant_count) or_return

		case .TEXTURE_2D:
			allocate_texture_2d(&res, gctx, variant_count) or_return

		case .TEXTURE_CUBE:
			allocate_texture_cube(&res, gctx, variant_count) or_return
		}
	}

	return .NONE
}

// ============================================================================
// Buffer Allocation
// ============================================================================

allocate_buffer :: proc(
	res: ^ResourceInstance,
	gctx: rawptr,
	variant_count: int,
	loc := #caller_location,
) -> CompileError {
	// TODO: Integrate with actual gpu.GPUContext once available
	// For now, just allocate arrays to track that allocation happened

	// Allocate variant arrays
	res.buffers = make([dynamic]vk.Buffer, variant_count)
	res.buffer_memory = make([dynamic]vk.DeviceMemory, variant_count)
	res.buffer_size = res.buffer_desc.size

	// In real implementation, would call:
	// for i in 0..<variant_count {
	//     buffer_info := vk.BufferCreateInfo{
	//         sType = .BUFFER_CREATE_INFO,
	//         size = res.buffer_desc.size,
	//         usage = res.buffer_desc.usage,
	//     }
	//     vk.CreateBuffer(device, &buffer_info, nil, &res.buffers[i])
	//     ... allocate and bind memory ...
	// }

	return .NONE
}

// ============================================================================
// Texture Allocation
// ============================================================================

allocate_texture_2d :: proc(
	res: ^ResourceInstance,
	gctx: rawptr,
	variant_count: int,
	loc := #caller_location,
) -> CompileError {
	// TODO: Integrate with actual gpu.GPUContext once available

	// Allocate variant arrays
	res.images = make([dynamic]vk.Image, variant_count)
	res.image_views = make([dynamic]vk.ImageView, variant_count)
	res.image_memory = make([dynamic]vk.DeviceMemory, variant_count)

	// In real implementation, would call:
	// for i in 0..<variant_count {
	//     image_info := vk.ImageCreateInfo{
	//         sType = .IMAGE_CREATE_INFO,
	//         imageType = .IMAGE_TYPE_2D,
	//         format = res.texture_desc.format,
	//         extent = {res.texture_desc.width, res.texture_desc.height, 1},
	//         usage = res.texture_desc.usage,
	//         ...
	//     }
	//     vk.CreateImage(device, &image_info, nil, &res.images[i])
	//     ... allocate and bind memory ...
	//     ... create image view ...
	// }

	return .NONE
}

allocate_texture_cube :: proc(
	res: ^ResourceInstance,
	gctx: rawptr,
	variant_count: int,
	loc := #caller_location,
) -> CompileError {
	// TODO: Integrate with actual gpu.GPUContext once available

	// Allocate variant arrays
	res.images = make([dynamic]vk.Image, variant_count)
	res.image_views = make([dynamic]vk.ImageView, variant_count)
	res.image_memory = make([dynamic]vk.DeviceMemory, variant_count)

	// In real implementation, would create cube textures:
	// image_info.flags = {.CUBE_COMPATIBLE}
	// image_info.arrayLayers = 6

	return .NONE
}

// ============================================================================
// Resource Deallocation (called by graph.destroy)
// ============================================================================

deallocate_resources :: proc(graph: ^Graph, gctx: rawptr) {
	for &res in graph.resource_instances {
		destroy_resource(&res, gctx)
	}
}
