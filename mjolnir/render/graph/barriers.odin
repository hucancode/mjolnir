package render_graph

import "core:fmt"
import vk "vendor:vulkan"

// ============================================================================
// Barrier Computation
// ============================================================================

compute_barriers :: proc(graph: ^Graph) {
	// Build resource state tracking
	// Maps: resource_name -> (last_access_stage, last_access, last_layout)
	resource_state := make(map[string]ResourceState)
	defer delete(resource_state)

	// Process passes in execution order
	for pass_id in graph.sorted_passes {
		pass := get_pass(graph, pass_id)

		// Emit barriers for all reads
		for read in pass.reads {
			if read.frame_offset != .CURRENT {
				// Temporal dependency - memory barrier only (no execution dependency)
				emit_memory_barrier(graph, pass_id, read.resource_name, .READ, pass.queue, &resource_state)
			} else {
				// Same-frame dependency - full barrier (execution + memory)
				emit_full_barrier(graph, pass_id, read.resource_name, .READ, pass.queue, &resource_state)
			}
		}

		// Emit barriers for all writes
		for write in pass.writes {
			if write.frame_offset != .CURRENT {
				// Temporal dependency
				emit_memory_barrier(graph, pass_id, write.resource_name, .WRITE, pass.queue, &resource_state)
			} else {
				// Same-frame dependency
				emit_full_barrier(graph, pass_id, write.resource_name, .WRITE, pass.queue, &resource_state)
			}
		}

		// Update resource state after pass executes
		update_resource_state(pass, &resource_state, graph)
	}
}

// ============================================================================
// Resource State Tracking
// ============================================================================

ResourceState :: struct {
	last_stage:  vk.PipelineStageFlags,
	last_access: vk.AccessFlags,
	last_layout: vk.ImageLayout,
	last_queue:  QueueType,
}

update_resource_state :: proc(pass: ^PassInstance, state: ^map[string]ResourceState, graph: ^Graph) {
	// Update state for all writes
	for write in pass.writes {
		if write.frame_offset != .CURRENT {
			continue
		}

		// Get resource for depth/stencil detection
		res: ^ResourceInstance = nil
		if res_id, found := find_resource_by_name(graph, write.resource_name); found {
			res = get_resource(graph, res_id)
		}

		new_state := infer_resource_state_after_access(write.access_mode, pass.queue, res)
		state[write.resource_name] = new_state
	}

	// Update state for reads (some reads change layout, e.g. shader reads)
	for read in pass.reads {
		if read.frame_offset != .CURRENT {
			continue
		}

		// Only update if this is a "consuming" read that changes state
		if pass.queue == .GRAPHICS {
			// Get resource for depth/stencil detection
			res: ^ResourceInstance = nil
			if res_id, found := find_resource_by_name(graph, read.resource_name); found {
				res = get_resource(graph, res_id)
			}

			new_state := infer_resource_state_after_access(.READ, pass.queue, res)
			// Don't overwrite write state with read state
			if _, exists := state[read.resource_name]; !exists {
				state[read.resource_name] = new_state
			}
		}
	}
}

// ============================================================================
// Barrier Emission
// ============================================================================

emit_full_barrier :: proc(
	graph: ^Graph,
	pass_id: PassInstanceId,
	resource_name: string,
	access: AccessMode,
	queue: QueueType,
	state: ^map[string]ResourceState,
) {
	// Get resource instance
	res_id, found := find_resource_by_name(graph, resource_name)
	if !found {
		return
	}

	res := get_resource(graph, res_id)

	// Get current state (or default)
	current_state, has_state := state[resource_name]
	if !has_state {
		current_state = get_initial_resource_state(res)
	}

	// Infer desired state (pass resource for depth/stencil detection)
	desired_state := infer_resource_state_before_access(access, queue, res)

	// Create barrier
	barrier := create_barrier(res, current_state, desired_state)

	// Add to graph
	add_barrier(graph, pass_id, barrier)
}

emit_memory_barrier :: proc(
	graph: ^Graph,
	pass_id: PassInstanceId,
	resource_name: string,
	access: AccessMode,
	queue: QueueType,
	state: ^map[string]ResourceState,
) {
	// Similar to full barrier, but no execution dependency
	// (the temporal offset means execution already separated by frames)

	res_id, found := find_resource_by_name(graph, resource_name)
	if !found {
		return
	}

	res := get_resource(graph, res_id)

	current_state, has_state := state[resource_name]
	if !has_state {
		current_state = get_initial_resource_state(res)
	}

	desired_state := infer_resource_state_before_access(access, queue, res)

	// Create barrier with memory-only synchronization
	barrier := create_memory_barrier(res, current_state, desired_state)

	add_barrier(graph, pass_id, barrier)
}

// ============================================================================
// Barrier Creation
// ============================================================================

create_barrier :: proc(
	res: ^ResourceInstance,
	from: ResourceState,
	to: ResourceState,
) -> Barrier {
	barrier := Barrier{
		src_access = from.last_access,
		dst_access = to.last_access,
		src_stage = from.last_stage,
		dst_stage = to.last_stage,
	}

	// Set resource handle
	switch res.type {
	case .BUFFER:
		if len(res.buffers) > 0 {
			barrier.buffer = res.buffers[0]
		} else if res.buffer_desc.is_external {
			barrier.buffer = res.external_buffer
		}

	case .TEXTURE_2D, .TEXTURE_CUBE:
		if len(res.images) > 0 {
			barrier.image = res.images[0]
		} else if res.texture_desc.is_external {
			barrier.image = res.external_image
		}

		barrier.old_layout = from.last_layout
		barrier.new_layout = to.last_layout
		barrier.aspect = res.texture_desc.aspect
	}

	return barrier
}

create_memory_barrier :: proc(
	res: ^ResourceInstance,
	from: ResourceState,
	to: ResourceState,
) -> Barrier {
	// Memory barrier only (no execution dependency)
	barrier := create_barrier(res, from, to)

	// Use ALL_COMMANDS for src/dst stages to avoid execution dependency
	barrier.src_stage = {.ALL_COMMANDS}
	barrier.dst_stage = {.ALL_COMMANDS}

	return barrier
}

// ============================================================================
// State Inference
// ============================================================================

get_initial_resource_state :: proc(res: ^ResourceInstance) -> ResourceState {
	// Default initial state for uninitialized resources
	return ResourceState{
		last_stage = {.TOP_OF_PIPE},
		last_access = {},
		last_layout = .UNDEFINED,
		last_queue = .GRAPHICS,
	}
}

infer_resource_state_before_access :: proc(access: AccessMode, queue: QueueType, res: ^ResourceInstance = nil) -> ResourceState {
	state := ResourceState{}

	// Check if this is a depth/stencil texture
	is_depth := false
	if res != nil && (res.type == .TEXTURE_2D || res.type == .TEXTURE_CUBE) {
		is_depth = .DEPTH in res.texture_desc.aspect || .STENCIL in res.texture_desc.aspect
	}

	switch queue {
	case .GRAPHICS:
		switch access {
		case .READ:
			if is_depth {
				state.last_stage = {.EARLY_FRAGMENT_TESTS}
				state.last_access = {.DEPTH_STENCIL_ATTACHMENT_READ}
				state.last_layout = .DEPTH_STENCIL_READ_ONLY_OPTIMAL
			} else {
				state.last_stage = {.FRAGMENT_SHADER}
				state.last_access = {.SHADER_READ}
				state.last_layout = .SHADER_READ_ONLY_OPTIMAL
			}
		case .WRITE:
			if is_depth {
				state.last_stage = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS}
				state.last_access = {.DEPTH_STENCIL_ATTACHMENT_WRITE}
				state.last_layout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL
			} else {
				state.last_stage = {.COLOR_ATTACHMENT_OUTPUT}
				state.last_access = {.COLOR_ATTACHMENT_WRITE}
				state.last_layout = .COLOR_ATTACHMENT_OPTIMAL
			}
		case .READ_WRITE:
			if is_depth {
				state.last_stage = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS}
				state.last_access = {.DEPTH_STENCIL_ATTACHMENT_READ, .DEPTH_STENCIL_ATTACHMENT_WRITE}
				state.last_layout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL
			} else {
				state.last_stage = {.FRAGMENT_SHADER}
				state.last_access = {.SHADER_READ, .SHADER_WRITE}
				state.last_layout = .GENERAL
			}
		}

	case .COMPUTE:
		state.last_stage = {.COMPUTE_SHADER}
		switch access {
		case .READ:
			state.last_access = {.SHADER_READ}
			state.last_layout = .SHADER_READ_ONLY_OPTIMAL
		case .WRITE:
			state.last_access = {.SHADER_WRITE}
			state.last_layout = .GENERAL
		case .READ_WRITE:
			state.last_access = {.SHADER_READ, .SHADER_WRITE}
			state.last_layout = .GENERAL
		}
	}

	state.last_queue = queue

	return state
}

infer_resource_state_after_access :: proc(access: AccessMode, queue: QueueType, res: ^ResourceInstance = nil) -> ResourceState {
	// After access, resource is in the state that the access left it in
	return infer_resource_state_before_access(access, queue, res)
}
