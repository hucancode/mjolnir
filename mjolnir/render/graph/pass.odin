package render_graph

import vk "vendor:vulkan"
import "core:fmt"

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
	name:      string,           // Template name (e.g., "geometry_pass")
	scope:     PassScope,
	queue:     QueueType,
	setup:     PassSetupProc,   // Setup phase: declare dependencies
	execute:   PassExecuteProc, // Execute phase: render with resolved resources
	user_data: rawptr,          // Points to subsystem renderer
}

// Builder API - used during setup phase
PassBuilder :: struct {
	graph:       ^Graph,
	pass_id:     PassId,
	scope_index: u32,  // Camera/light index for PER_CAMERA/PER_LIGHT
	inputs:      [dynamic]ResourceId,
	outputs:     [dynamic]ResourceId,
}

// Compiled pass instance (after template instantiation)
PassInstance :: struct {
	template_name: string,
	instance_name: string,   // "geometry_pass_camera_0"
	scope_index:   u32,
	queue:         QueueType,
	inputs:        [dynamic]ResourceId,
	outputs:       [dynamic]ResourceId,
	execute:       PassExecuteProc,
	user_data:     rawptr,
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
	id, ok := b.graph.resource_ids[name]
	if ok {
		append(&b.inputs, id)
	}
	return id, ok
}

// Builder API: Declare write dependency on existing resource
builder_write :: proc(b: ^PassBuilder, name: string) -> (ResourceId, bool) {
	id, ok := b.graph.resource_ids[name]
	if ok {
		append(&b.outputs, id)
	}
	return id, ok
}

// Builder API: Create new transient resource (Frostbite-style)
builder_create :: proc(b: ^PassBuilder, name: string, format: ResourceFormat) -> ResourceId {
	desc := ResourceDescriptor{
		name = name,
		scope = .GLOBAL, // Transient resources are global by default
		type = infer_resource_type(format),
		format = format,
		is_transient = true,
		resolve = transient_resolve_proc, // Resolved from transient pool
	}
	id := register_resource(b.graph, desc)
	append(&b.outputs, id)
	return id
}

// Builder API: Declare read-write dependency (both input and output)
builder_read_write :: proc(b: ^PassBuilder, name: string) -> (ResourceId, bool) {
	id, ok := b.graph.resource_ids[name]
	if ok {
		append(&b.inputs, id)
		append(&b.outputs, id)
	}
	return id, ok
}

// Transient resource resolve proc (placeholder - will be implemented with transient pool)
transient_resolve_proc :: proc(
	ctx: ^GraphExecutionContext,
	name: string,
	frame_index: u32,
) -> (ResourceHandle, bool) {
	// TODO: Implement transient resource pool resolution
	// For now, transient resources are not supported
	return {}, false
}

// Generate instance name from template (e.g., "geometry_pass_camera_0")
make_instance_name :: proc(template_name: string, scope: PassScope, index: u32, allocator := context.allocator) -> string {
	switch scope {
	case .GLOBAL:
		return template_name
	case .PER_CAMERA:
		return fmt.aprintf("%s_camera_%d", template_name, index, allocator = allocator)
	case .PER_LIGHT:
		return fmt.aprintf("%s_light_%d", template_name, index, allocator = allocator)
	}
	return template_name
}

// Type-safe resource resolution (generic procedure)
// Takes execution context as parameter
resolve :: proc($T: typeid, ctx: ^PassContext, exec_ctx: ^GraphExecutionContext, resource_id: ResourceId) -> (result: T, ok: bool) {
	// Get resource name from ID
	name: string
	for res_name, res_id in ctx.graph.resource_ids {
		if res_id == resource_id {
			name = res_name
			break
		}
	}
	if name == "" do return {}, false

	// Get descriptor
	desc, has_desc := ctx.graph.resources[name]
	if !has_desc do return {}, false

	// Resolve to actual handle (pass execution context to callback)
	handle, resolve_ok := desc.resolve(exec_ctx, name, ctx.frame_index)
	if !resolve_ok do return {}, false

	// Type-safe extraction
	typed_handle, type_ok := handle.(T)
	return typed_handle, type_ok
}

// Graph is defined in graph.odin
// register_resource is defined in graph.odin
