package render_graph

import vk "vendor:vulkan"

PassId :: distinct u32

INVALID_PASS :: PassId(0)

AccessMode :: enum {
	READ,
	WRITE,
	READ_WRITE,
}

LoadAction :: enum {
	LOAD,
	CLEAR,
	DONT_CARE,
}

QueueType :: enum {
	GRAPHICS,
	COMPUTE,
}

// Callback executed when the pass runs
PassExecuteProc :: #type proc(
	cmd: vk.CommandBuffer,
	frame_index: u32,
	user_data: rawptr,
)

ResourceAccess :: struct {
	resource_id: ResourceId,
	access:      AccessMode,
	load_action: LoadAction,
}

PassDecl :: struct {
	name:      string,
	queue:     QueueType,
	execute:   PassExecuteProc,
	user_data: rawptr,
	reads:     [dynamic]ResourceAccess,
	writes:    [dynamic]ResourceAccess,
	enabled:   bool,
}

// Add a pass to the graph and return its id
add_pass :: proc(
	g: ^Graph,
	name: string,
	execute: PassExecuteProc,
	user_data: rawptr,
	queue: QueueType = .GRAPHICS,
) -> PassId {
	id := g.next_pass_id
	g.next_pass_id += 1
	g.passes[id] = PassDecl {
		name      = name,
		queue     = queue,
		execute   = execute,
		user_data = user_data,
		reads     = make([dynamic]ResourceAccess),
		writes    = make([dynamic]ResourceAccess),
		enabled   = true,
	}
	append(&g.pass_order, id)
	return id
}

// Declare that a pass reads a resource
pass_read :: proc(
	g: ^Graph,
	pass_id: PassId,
	resource_id: ResourceId,
	load_action: LoadAction = .LOAD,
) {
	pass := &g.passes[pass_id]
	append(&pass.reads, ResourceAccess{resource_id = resource_id, access = .READ, load_action = load_action})
}

// Declare that a pass writes to a resource
pass_write :: proc(
	g: ^Graph,
	pass_id: PassId,
	resource_id: ResourceId,
	load_action: LoadAction = .CLEAR,
) {
	pass := &g.passes[pass_id]
	append(&pass.writes, ResourceAccess{resource_id = resource_id, access = .WRITE, load_action = load_action})
}

// Declare that a pass reads and writes to a resource
pass_read_write :: proc(
	g: ^Graph,
	pass_id: PassId,
	resource_id: ResourceId,
	load_action: LoadAction = .LOAD,
) {
	pass := &g.passes[pass_id]
	ra := ResourceAccess{resource_id = resource_id, access = .READ_WRITE, load_action = load_action}
	// Add to reads for dependency tracking and dead-pass liveness propagation
	append(&pass.reads, ra)
	// Add to writes so this pass becomes the new last_writer for the resource
	append(&pass.writes, ra)
}

// Enable or disable a pass
set_pass_enabled :: proc(g: ^Graph, pass_id: PassId, enabled: bool) {
	if pass, ok := &g.passes[pass_id]; ok {
		pass.enabled = enabled
	}
}
