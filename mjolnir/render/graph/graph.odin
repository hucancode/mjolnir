package render_graph

import "../../gpu"
import vk "vendor:vulkan"

// Per-resource barrier state tracked during compilation
ResourceState :: struct {
	layout:     vk.ImageLayout,
	access:     vk.AccessFlags,
	stage:      vk.PipelineStageFlags,
}

INITIAL_RESOURCE_STATE :: ResourceState {
	layout = .UNDEFINED,
	access = {},
	stage  = {.TOP_OF_PIPE},
}

// A barrier to be emitted before a pass executes
ImageBarrierInfo :: struct {
	resource_id: ResourceId,
	old_state:   ResourceState,
	new_state:   ResourceState,
	aspect_mask: vk.ImageAspectFlags,
	layer_count: u32,
}

BufferBarrierInfo :: struct {
	resource_id: ResourceId,
	src_access:  vk.AccessFlags,
	dst_access:  vk.AccessFlags,
	src_stage:   vk.PipelineStageFlags,
	dst_stage:   vk.PipelineStageFlags,
}

// Compiled pass - ready to execute
CompiledPass :: struct {
	pass_id:         PassId,
	queue:           QueueType,
	image_barriers:  [dynamic]ImageBarrierInfo,
	buffer_barriers: [dynamic]BufferBarrierInfo,
}

ResourceEntry :: struct {
	name:     string,
	resource: Resource,
}

Graph :: struct {
	resources:           map[ResourceId]ResourceEntry,
	passes:              map[PassId]PassDecl,
	pass_order:          [dynamic]PassId,
	compiled:            [dynamic]CompiledPass,
	is_compiled:         bool,
	swapchain_resources: [dynamic]ResourceId,
	next_resource_id:    ResourceId,
	next_pass_id:        PassId,
	// Transient resource storage (allocated/freed each frame)
	transient_textures:  map[ResourceId]gpu.Texture2DHandle,
	transient_buffers:   map[ResourceId]TransientBufferAlloc,
}

// Allocated transient buffer (no type parameter needed)
TransientBufferAlloc :: struct {
	buffer: vk.Buffer,
	memory: vk.DeviceMemory,
	size:   vk.DeviceSize,
}

init :: proc(g: ^Graph) {
	g.resources = make(map[ResourceId]ResourceEntry)
	g.passes = make(map[PassId]PassDecl)
	g.pass_order = make([dynamic]PassId)
	g.compiled = make([dynamic]CompiledPass)
	g.swapchain_resources = make([dynamic]ResourceId)
	g.transient_textures = make(map[ResourceId]gpu.Texture2DHandle)
	g.transient_buffers = make(map[ResourceId]TransientBufferAlloc)
	g.is_compiled = false
	g.next_resource_id = 1
	g.next_pass_id = 1
}

destroy :: proc(g: ^Graph) {
	for _, &pass in g.passes {
		delete(pass.reads)
		delete(pass.writes)
	}
	for &cp in g.compiled {
		delete(cp.image_barriers)
		delete(cp.buffer_barriers)
	}
	delete(g.resources)
	delete(g.passes)
	delete(g.pass_order)
	delete(g.compiled)
	delete(g.swapchain_resources)
	delete(g.transient_textures)
	delete(g.transient_buffers)
}

// Reset the graph for re-recording (clears compiled state and all registered passes/resources)
// Note: This implicitly frees transient resources from the previous frame
// They've been alive for at least 1 frame, so GPU should be done with them
reset :: proc(g: ^Graph, gctx: ^gpu.GPUContext, texture_manager: ^gpu.TextureManager) {
	// Free transient resources from previous frame
	for res_id, handle in g.transient_textures {
		gpu.free_texture_2d(texture_manager, gctx, handle)
	}
	for res_id, alloc in g.transient_buffers {
		vk.DestroyBuffer(gctx.device, alloc.buffer, nil)
		vk.FreeMemory(gctx.device, alloc.memory, nil)
	}

	for _, &pass in g.passes {
		delete(pass.reads)
		delete(pass.writes)
	}
	for &cp in g.compiled {
		delete(cp.image_barriers)
		delete(cp.buffer_barriers)
	}
	clear(&g.compiled)
	clear(&g.resources)
	clear(&g.passes)
	clear(&g.pass_order)
	clear(&g.swapchain_resources)
	clear(&g.transient_textures)
	clear(&g.transient_buffers)
	g.is_compiled = false
	g.next_resource_id = 1
	g.next_pass_id = 1
}

// Allocate transient resources - called after compile(), before execute()
allocate_transient_resources :: proc(
	g: ^Graph,
	gctx: ^gpu.GPUContext,
	texture_manager: ^gpu.TextureManager,
	frame_index: u32,
) {
	// Iterate through all resources and allocate transient ones
	for res_id, entry in g.resources {
		#partial switch r in entry.resource {
		case TransientTexture:
			// Create a temporary texture for this frame
			handle := gpu.allocate_texture_2d(
				texture_manager,
				gctx,
				r.extent,
				r.format,
				r.usage,
				false, // generate_mips
			) or_continue
			g.transient_textures[res_id] = handle
		case TransientBuffer:
			// Create a temporary buffer for this frame
			buffer_size := vk.DeviceSize(r.element_size * r.element_count)
			create_info := vk.BufferCreateInfo {
				sType       = .BUFFER_CREATE_INFO,
				size        = buffer_size,
				usage       = r.usage,
				sharingMode = .EXCLUSIVE,
			}
			buffer: vk.Buffer
			if vk.CreateBuffer(gctx.device, &create_info, nil, &buffer) != .SUCCESS do continue

			mem_reqs: vk.MemoryRequirements
			vk.GetBufferMemoryRequirements(gctx.device, buffer, &mem_reqs)
			memory, mem_err := gpu.allocate_memory(gctx, mem_reqs, {.DEVICE_LOCAL})
			if mem_err != .SUCCESS {
				vk.DestroyBuffer(gctx.device, buffer, nil)
				continue
			}
			if vk.BindBufferMemory(gctx.device, buffer, memory, 0) != .SUCCESS {
				vk.FreeMemory(gctx.device, memory, nil)
				vk.DestroyBuffer(gctx.device, buffer, nil)
				continue
			}

			g.transient_buffers[res_id] = TransientBufferAlloc {
				buffer = buffer,
				memory = memory,
				size   = buffer_size,
			}
		}
	}
}
