package render_graph

import "core:log"
import "../../gpu"
import vk "vendor:vulkan"

// ============================================================================
// Resource Allocation
// ============================================================================

allocate_resources :: proc(
	graph: ^Graph,
	gctx: rawptr,
	tm_ptr: rawptr,
	loc := #caller_location,
) -> CompileError {
	// Determine which resources need frame variants (NEXT/PREV access)
	needs_frame_variants := make(map[string]bool, len(graph.resource_instances))
	defer delete(needs_frame_variants)

	for &pass in graph.pass_instances {
		for read in pass.reads {
			if read.frame_offset != .CURRENT {
				needs_frame_variants[read.resource_name] = true
			}
		}
		for write in pass.writes {
			if write.frame_offset != .CURRENT {
				needs_frame_variants[write.resource_name] = true
			}
		}
	}

	// Allocate resources
	for &res in graph.resource_instances {
		is_external := false
		switch res.type {
		case .BUFFER:
			is_external = res.buffer_desc.is_external
		case .TEXTURE_2D, .TEXTURE_CUBE:
			is_external = res.texture_desc.is_external
		}
		if is_external do continue

		wants_double_buffer := res.type != .BUFFER && res.texture_desc.double_buffer
		variant_count := 1
		if needs_frame_variants[res.name] || wants_double_buffer {
			variant_count = graph.frames_in_flight
		}

		switch res.type {
		case .BUFFER:
			allocate_buffer(&res, gctx, variant_count) or_return
		case .TEXTURE_2D:
			allocate_texture_2d(&res, gctx, tm_ptr, variant_count) or_return
		case .TEXTURE_CUBE:
			allocate_texture_cube(&res, gctx, tm_ptr, variant_count) or_return
		}
	}

	return .NONE
}

// ============================================================================
// Buffer Allocation
// ============================================================================

allocate_buffer :: proc(
	res: ^ResourceInstance,
	gctx_ptr: rawptr,
	variant_count: int,
	loc := #caller_location,
) -> CompileError {
	gctx := cast(^gpu.GPUContext)gctx_ptr

	res.buffers      = make([dynamic]vk.Buffer,       variant_count)
	res.buffer_memory = make([dynamic]vk.DeviceMemory, variant_count)
	res.buffer_size  = res.buffer_desc.size

	for i in 0 ..< variant_count {
		create_info := vk.BufferCreateInfo{
			sType       = .BUFFER_CREATE_INFO,
			size        = res.buffer_desc.size,
			usage       = res.buffer_desc.usage,
			sharingMode = .EXCLUSIVE,
		}
		if vk.CreateBuffer(gctx.device, &create_info, nil, &res.buffers[i]) != .SUCCESS {
			log.errorf("graph allocator: failed to create buffer '%s'[%d]", res.name, i)
			return .ALLOCATION_FAILED
		}

		mem_reqs: vk.MemoryRequirements
		vk.GetBufferMemoryRequirements(gctx.device, res.buffers[i], &mem_reqs)

		res.buffer_memory[i] = gpu.allocate_memory(gctx, mem_reqs, {.DEVICE_LOCAL}) or_else 0
		if res.buffer_memory[i] == 0 {
			log.errorf("graph allocator: failed to allocate memory for buffer '%s'[%d]", res.name, i)
			return .ALLOCATION_FAILED
		}

		if vk.BindBufferMemory(gctx.device, res.buffers[i], res.buffer_memory[i], 0) != .SUCCESS {
			log.errorf("graph allocator: failed to bind memory for buffer '%s'[%d]", res.name, i)
			return .ALLOCATION_FAILED
		}
	}

	return .NONE
}

// ============================================================================
// Texture Allocation
// ============================================================================

allocate_texture_2d :: proc(
	res: ^ResourceInstance,
	gctx_ptr: rawptr,
	tm_ptr: rawptr,
	variant_count: int,
	loc := #caller_location,
) -> CompileError {
	gctx := cast(^gpu.GPUContext)gctx_ptr
	tm   := cast(^gpu.TextureManager)tm_ptr

	res.images              = make([dynamic]vk.Image,     variant_count)
	res.image_views         = make([dynamic]vk.ImageView,  variant_count)
	res.texture_handle_bits = make([dynamic]u64,           variant_count)

	extent := vk.Extent2D{res.texture_desc.width, res.texture_desc.height}

	for i in 0 ..< variant_count {
		handle, ret := gpu.allocate_texture_2d(tm, gctx, extent, res.texture_desc.format, res.texture_desc.usage)
		if ret != .SUCCESS {
			log.errorf("graph allocator: failed to allocate texture_2d '%s'[%d]: %v", res.name, i, ret)
			return .ALLOCATION_FAILED
		}

		img := gpu.get_texture_2d(tm, handle)
		res.images[i]              = img.image
		res.image_views[i]         = img.view
		res.texture_handle_bits[i] = transmute(u64)handle
	}

	return .NONE
}

allocate_texture_cube :: proc(
	res: ^ResourceInstance,
	gctx_ptr: rawptr,
	tm_ptr: rawptr,
	variant_count: int,
	loc := #caller_location,
) -> CompileError {
	gctx := cast(^gpu.GPUContext)gctx_ptr
	tm   := cast(^gpu.TextureManager)tm_ptr

	res.images              = make([dynamic]vk.Image,     variant_count)
	res.image_views         = make([dynamic]vk.ImageView,  variant_count)
	res.texture_handle_bits = make([dynamic]u64,           variant_count)

	for i in 0 ..< variant_count {
		handle, ret := gpu.allocate_texture_cube(tm, gctx, res.texture_desc.width, res.texture_desc.format, res.texture_desc.usage)
		if ret != .SUCCESS {
			log.errorf("graph allocator: failed to allocate texture_cube '%s'[%d]: %v", res.name, i, ret)
			return .ALLOCATION_FAILED
		}

		img := gpu.get_texture_cube(tm, handle)
		res.images[i]              = img.image
		res.image_views[i]         = img.view
		res.texture_handle_bits[i] = transmute(u64)handle
	}

	return .NONE
}

// ============================================================================
// Resource Deallocation
// ============================================================================

// Deallocate a single resource's GPU memory. Called by graph.destroy_resource.
deallocate_resource :: proc(res: ^ResourceInstance, gctx_ptr: rawptr, tm_ptr: rawptr) {
	gctx := cast(^gpu.GPUContext)gctx_ptr
	tm   := cast(^gpu.TextureManager)tm_ptr

	switch res.type {
	case .BUFFER:
		for i in 0 ..< len(res.buffers) {
			vk.DestroyBuffer(gctx.device, res.buffers[i], nil)
			vk.FreeMemory(gctx.device, res.buffer_memory[i], nil)
		}
		delete(res.buffers)
		delete(res.buffer_memory)

	case .TEXTURE_2D:
		for bits in res.texture_handle_bits {
			handle := transmute(gpu.Texture2DHandle)bits
			gpu.free_texture_2d(tm, gctx, handle)
		}
		delete(res.images)
		delete(res.image_views)
		delete(res.texture_handle_bits)

	case .TEXTURE_CUBE:
		for bits in res.texture_handle_bits {
			handle := transmute(gpu.TextureCubeHandle)bits
			gpu.free_texture_cube(tm, gctx, handle)
		}
		delete(res.images)
		delete(res.image_views)
		delete(res.texture_handle_bits)
	}
}

// Deallocate all non-external resources. Called by graph.destroy.
deallocate_resources :: proc(graph: ^Graph, gctx: rawptr, tm_ptr: rawptr) {
	for &res in graph.resource_instances {
		destroy_resource(&res, gctx, tm_ptr)
	}
}
