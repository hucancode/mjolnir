package render_graph

import "core:slice"
import vk "vendor:vulkan"

// ============================================================================
// Graph - Compiled Runtime Representation
// ============================================================================

// Graph contains ONLY compiled runtime data, no declarations
// This is the output of compile() and input to execute()
Graph :: struct {
	// Runtime instances (instantiated from PassDecl templates)
	pass_instances:     [dynamic]PassInstance,
	resource_instances: [dynamic]ResourceInstance,

	// Execution order (topologically sorted pass instance IDs)
	sorted_passes:      []PassInstanceId,

	// Barriers to emit before each pass
	barriers:           map[PassInstanceId][]Barrier,

	// Lookup tables (name -> instance ID)
	resource_by_name:   map[string]ResourceInstanceId,

	// Handle mappings: instance_idx -> actual handle
	camera_handles:     []u32,  // Maps instance index to camera handle
	light_handles:      []u32,  // Maps instance index to light node handle

	// Compilation metadata
	frames_in_flight:   int,
}

// ============================================================================
// Graph Lifecycle
// ============================================================================

init :: proc(graph: ^Graph, frames_in_flight: int) {
	graph.pass_instances = make([dynamic]PassInstance)
	graph.resource_instances = make([dynamic]ResourceInstance)
	graph.barriers = make(map[PassInstanceId][]Barrier)
	graph.resource_by_name = make(map[string]ResourceInstanceId)
	graph.frames_in_flight = frames_in_flight
}

destroy :: proc(graph: ^Graph, gctx: rawptr) {
	// Destroy all allocated GPU resources
	for &res in graph.resource_instances {
		destroy_resource(&res, gctx)
	}

	// Free barriers
	for _, barrier_list in graph.barriers {
		delete(barrier_list)
	}

	// Free containers
	delete(graph.pass_instances)
	delete(graph.resource_instances)
	delete(graph.barriers)
	delete(graph.resource_by_name)

	if graph.sorted_passes != nil {
		delete(graph.sorted_passes)
	}

	// Free handle mappings
	if graph.camera_handles != nil {
		delete(graph.camera_handles)
	}
	if graph.light_handles != nil {
		delete(graph.light_handles)
	}
}

// Reset graph for recompilation (keeps allocated GPU resources)
reset :: proc(graph: ^Graph) {
	// Clear pass instances
	for &pass in graph.pass_instances {
		delete(pass.reads)
		delete(pass.writes)
	}
	clear(&graph.pass_instances)

	// Clear barriers
	for _, barrier_list in graph.barriers {
		delete(barrier_list)
	}
	clear(&graph.barriers)

	// Clear sorted passes
	if graph.sorted_passes != nil {
		delete(graph.sorted_passes)
		graph.sorted_passes = nil
	}

	// Clear lookup tables
	clear(&graph.resource_by_name)
}

// ============================================================================
// Resource Lifecycle
// ============================================================================

destroy_resource :: proc(res: ^ResourceInstance, gctx: rawptr) {
	// External resources are not owned by graph
	if (res.type == .BUFFER && res.buffer_desc.is_external) ||
	   (res.type != .BUFFER && res.texture_desc.is_external) {
		return
	}

	// TODO: Once integrated with gpu package, destroy actual resources
	// For now, just clean up arrays

	// Destroy buffers
	for i := 0; i < len(res.buffers); i += 1 {
		// vk.DestroyBuffer(device, res.buffers[i], nil)
		// vk.FreeMemory(device, res.buffer_memory[i], nil)
	}
	delete(res.buffers)
	delete(res.buffer_memory)

	// Destroy images
	for i := 0; i < len(res.images); i += 1 {
		// vk.DestroyImageView(device, res.image_views[i], nil)
		// vk.DestroyImage(device, res.images[i], nil)
		// vk.FreeMemory(device, res.image_memory[i], nil)
	}
	delete(res.images)
	delete(res.image_views)
	delete(res.image_memory)
}

// ============================================================================
// Helper Functions
// ============================================================================

// Get resource instance by name (for runtime lookups)
find_resource_by_name :: proc(graph: ^Graph, name: string) -> (ResourceInstanceId, bool) {
	id, found := graph.resource_by_name[name]
	return id, found
}

// Get pass instance by ID
get_pass :: proc(graph: ^Graph, id: PassInstanceId) -> ^PassInstance {
	return &graph.pass_instances[id]
}

// Get resource instance by ID
get_resource :: proc(graph: ^Graph, id: ResourceInstanceId) -> ^ResourceInstance {
	return &graph.resource_instances[id]
}

// Add pass instance (called by compiler)
add_pass_instance :: proc(graph: ^Graph, pass: PassInstance) -> PassInstanceId {
	id := PassInstanceId(len(graph.pass_instances))
	append(&graph.pass_instances, pass)
	return id
}

// Add resource instance (called by compiler)
add_resource_instance :: proc(graph: ^Graph, res: ResourceInstance) -> ResourceInstanceId {
	id := ResourceInstanceId(len(graph.resource_instances))
	append(&graph.resource_instances, res)

	// Register in lookup table
	graph.resource_by_name[res.name] = id

	return id
}

// Set execution order (called by compiler after topological sort)
set_execution_order :: proc(graph: ^Graph, order: []PassInstanceId) {
	if graph.sorted_passes != nil {
		delete(graph.sorted_passes)
	}
	graph.sorted_passes = slice.clone(order)
}

// Add barrier before pass (called by barrier computation)
add_barrier :: proc(graph: ^Graph, pass_id: PassInstanceId, barrier: Barrier) {
	// Get existing barriers for this pass
	barriers := graph.barriers[pass_id]

	// Append new barrier
	new_barriers := make([]Barrier, len(barriers) + 1)
	copy(new_barriers, barriers)
	new_barriers[len(barriers)] = barrier

	// Update map
	if len(barriers) > 0 {
		delete(barriers)
	}
	graph.barriers[pass_id] = new_barriers
}
