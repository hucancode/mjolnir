package render_graph

import vk "vendor:vulkan"
import "core:log"

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

// Execute phase callback (like Frostbite's execute lambda)
PassExecuteProc :: #type proc(ctx: ^PassContext, user_data: rawptr)

// Pass template - declares a pass type that can be instantiated
PassTemplate :: struct {
	name:             string, // Template name (e.g., "geometry_pass")
	scope:            PassScope,
	instance_indices: []u32, // Used for PER_CAMERA/PER_LIGHT instantiation
	queue:            QueueType,
	execute:          PassExecuteProc, // Execute phase: render with resolved resources
	user_data:        rawptr, // Points to subsystem renderer

	// Declarative input/output lists (Phase 2)
	// Use template strings: "{cam}" for PER_CAMERA, "{slot}" for PER_LIGHT
	// Examples: "camera_{cam}_depth", "shadow_draw_commands_{slot}"
	inputs:           []string, // Resources this pass reads
	outputs:          []string, // Resources this pass writes
}

// Compiled pass instance (after template instantiation)
PassInstance :: struct {
	name:        string,
	scope_index: u32,
	queue:       QueueType,
	inputs:      [dynamic]ResourceId,
	outputs:     [dynamic]ResourceId,
	execute:     PassExecuteProc,
	user_data:   rawptr,
	is_valid:    bool,
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

// ============================================================================
// PUBLIC API - RESOURCE RESOLUTION
// ============================================================================

// Type-safe resource resolution (generic procedure)
resolve :: proc($T: typeid, ctx: ^PassContext, resource_id: ResourceId) -> (result: T, ok: bool) {
	// Get descriptor
	desc, has_desc := _get_resource_descriptor(ctx.graph, resource_id)
	if !has_desc do return {}, false

	// Resolve to actual handle
	handle, resolve_ok := desc.resolve(ctx.exec_ctx, string(resource_id), ctx.frame_index)
	if !resolve_ok do return {}, false

	// Type-safe extraction
	typed_handle, type_ok := handle.(T)
	return typed_handle, type_ok
}
