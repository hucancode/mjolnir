package render_graph

import vk "vendor:vulkan"

// Pass identification
PassId :: distinct u32

// Pass scope determines instantiation behavior
PassScope :: enum {
	GLOBAL,      // Runs once per frame
	PER_CAMERA,  // Instantiated for each active camera
	PER_LIGHT,   // Instantiated for each shadow-casting light
}

// Queue type for pass execution
QueueType :: enum {
	GRAPHICS,
	COMPUTE,
}

// Setup phase callback (like Frostbite's builder lambda)
PassSetupProc :: #type proc(builder: ^PassBuilder, user_data: rawptr)

// Execute phase callback (like Frostbite's execute lambda)
PassExecuteProc :: #type proc(ctx: ^PassContext, user_data: rawptr)

// Pass template - declares a pass type that can be instantiated
PassTemplate :: struct {
	name:             string, // Template name (e.g., "geometry_pass")
	scope:            PassScope,
	instance_indices: []u32, // Used for PER_CAMERA/PER_LIGHT instantiation
	queue:            QueueType,
	setup:            PassSetupProc, // Setup phase: declare dependencies
	execute:          PassExecuteProc, // Execute phase: render with resolved resources
	user_data:        rawptr, // Points to subsystem renderer
}

// Builder API - used during setup phase
PassBuilder :: struct {
	graph:       ^Graph,
	scope_index: u32,  // Camera/light index for PER_CAMERA/PER_LIGHT
	inputs:      [dynamic]ResourceId,
	outputs:     [dynamic]ResourceId,
}

// Compiled pass instance (after template instantiation)
PassInstance :: struct {
	scope_index: u32,
	queue:       QueueType,
	inputs:      [dynamic]ResourceId,
	outputs:     [dynamic]ResourceId,
	execute:     PassExecuteProc,
	user_data:   rawptr,
}

// Pass execution context (like Frostbite's FrameGraphResources)
// Contains pointer to execution context (stack-allocated during execute())
PassContext :: struct {
	graph:       ^Graph,
	frame_index: u32,
	scope_index: u32,    // Camera/light index
	cmd:         vk.CommandBuffer,
	exec_ctx:    ^GraphExecutionContext,  // For resource resolution
}

// Builder API: Declare read dependency on existing resource
builder_read :: proc(b: ^PassBuilder, name: string) -> (ResourceId, bool) {
	id := ResourceId(name)
	if id not_in b.graph.resources {
		return "", false
	}
	append(&b.inputs, id)
	return id, true
}

// Builder API: Declare write dependency on existing resource
builder_write :: proc(b: ^PassBuilder, name: string) -> (ResourceId, bool) {
	id := ResourceId(name)
	if id not_in b.graph.resources {
		return "", false
	}
	append(&b.outputs, id)
	return id, true
}

// Builder API: Declare read-write dependency (both input and output)
builder_read_write :: proc(b: ^PassBuilder, name: string) -> (ResourceId, bool) {
	id := ResourceId(name)
	if id not_in b.graph.resources {
		return "", false
	}
	append(&b.inputs, id)
	append(&b.outputs, id)
	return id, true
}

// Type-safe resource resolution (generic procedure)
resolve :: proc($T: typeid, ctx: ^PassContext, resource_id: ResourceId) -> (result: T, ok: bool) {
	// Get descriptor
	desc, has_desc := get_resource_descriptor(ctx.graph, resource_id)
	if !has_desc do return {}, false

	// Resolve to actual handle
	handle, resolve_ok := desc.resolve(ctx.exec_ctx, desc.name, ctx.frame_index)
	if !resolve_ok do return {}, false

	// Type-safe extraction
	typed_handle, type_ok := handle.(T)
	return typed_handle, type_ok
}

// Graph is defined in graph.odin
// register_resource is defined in graph.odin
