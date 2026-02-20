package render_graph

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
}

init :: proc(g: ^Graph) {
	g.resources = make(map[ResourceId]ResourceEntry)
	g.passes = make(map[PassId]PassDecl)
	g.pass_order = make([dynamic]PassId)
	g.compiled = make([dynamic]CompiledPass)
	g.swapchain_resources = make([dynamic]ResourceId)
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
}

// Reset the graph for re-recording (clears compiled state and all registered passes/resources)
reset :: proc(g: ^Graph) {
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
	g.is_compiled = false
	g.next_resource_id = 1
	g.next_pass_id = 1
}
