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

		// Emit barriers for all reads.
		// For resources declared via read_write_texture (appears in both reads and writes),
		// skip the read barrier — the write barrier below handles the layout transition.
		// The reads entry still creates the dependency edge in the DAG.
		for read in pass.reads {
			// Skip if also written by this pass (read_write_texture / read_write_buffer).
			// The write barrier handles the full transition; emitting a separate read barrier
			// would incorrectly try to transition a COLOR_ATTACHMENT to SHADER_READ_ONLY.
			is_also_written := false
			for write in pass.writes {
				if write.resource_name == read.resource_name {
					is_also_written = true
					break
				}
			}
			if is_also_written {
				continue
			}

			if read.frame_offset != .CURRENT {
				// Temporal dependency - memory barrier only (no execution dependency)
				emit_memory_barrier(graph, pass_id, read.resource_name, read.frame_offset, .READ, pass.queue, &resource_state)
			} else {
				// Same-frame dependency - full barrier (execution + memory)
				emit_full_barrier(graph, pass_id, read.resource_name, read.frame_offset, .READ, pass.queue, &resource_state)
			}
		}

		// Emit barriers for all writes
		for write in pass.writes {
			if write.frame_offset != .CURRENT {
				// Temporal dependency
				emit_memory_barrier(graph, pass_id, write.resource_name, write.frame_offset, .WRITE, pass.queue, &resource_state)
			} else {
				// Same-frame dependency
				emit_full_barrier(graph, pass_id, write.resource_name, write.frame_offset, .WRITE, pass.queue, &resource_state)
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

	// Update state for pure reads (not part of a read_write_texture pair).
	// read_write_texture adds the resource to both reads[] and writes[]; the write
	// state set above already reflects the post-access layout for those.  For a
	// resource that is only read (no corresponding write in this pass), the barrier
	// has transitioned it to SHADER_READ_ONLY_OPTIMAL (or the equivalent depth
	// layout), so the state map must be updated accordingly.
	for read in pass.reads {
		if read.frame_offset != .CURRENT {
			continue
		}

		// Skip resources that are also written by this pass (read_write_texture).
		// Their layout is already captured by the write state update above.
		is_also_written := false
		for write in pass.writes {
			if write.resource_name == read.resource_name {
				is_also_written = true
				break
			}
		}
		if is_also_written {
			continue
		}

		if pass.queue == .GRAPHICS {
			res: ^ResourceInstance = nil
			if res_id, found := find_resource_by_name(graph, read.resource_name); found {
				res = get_resource(graph, res_id)
			}

			new_state := infer_resource_state_after_access(.READ, pass.queue, res)
			state[read.resource_name] = new_state
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
	frame_offset: FrameOffset,
	access: AccessMode,
	queue: QueueType,
	state: ^map[string]ResourceState,
) {
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
	barrier := create_barrier(res_id, res, frame_offset, current_state, desired_state)
	add_barrier(graph, pass_id, barrier)
}

emit_memory_barrier :: proc(
	graph: ^Graph,
	pass_id: PassInstanceId,
	resource_name: string,
	frame_offset: FrameOffset,
	access: AccessMode,
	queue: QueueType,
	state: ^map[string]ResourceState,
) {
	// Similar to full barrier but no execution dependency
	// (temporal offset means execution is already separated by frames)
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
	barrier := create_memory_barrier(res_id, res, frame_offset, current_state, desired_state)
	add_barrier(graph, pass_id, barrier)
}

// ============================================================================
// Barrier Creation
// ============================================================================

create_barrier :: proc(
	res_id: ResourceInstanceId,
	res: ^ResourceInstance,
	frame_offset: FrameOffset,
	from: ResourceState,
	to: ResourceState,
) -> Barrier {
	barrier := Barrier{
		resource_id  = res_id,
		frame_offset = frame_offset,
		src_access   = from.last_access,
		dst_access   = to.last_access,
		src_stage    = from.last_stage,
		dst_stage    = to.last_stage,
	}

	// Store image layout/aspect for image barriers (resolved at emit time)
	switch res.type {
	case .TEXTURE_2D, .TEXTURE_CUBE:
		barrier.old_layout = from.last_layout
		barrier.new_layout = to.last_layout
		barrier.aspect = res.texture_desc.aspect
	case .BUFFER:
		// No extra fields needed
	}

	return barrier
}

create_memory_barrier :: proc(
	res_id: ResourceInstanceId,
	res: ^ResourceInstance,
	frame_offset: FrameOffset,
	from: ResourceState,
	to: ResourceState,
) -> Barrier {
	// Memory barrier only (no execution dependency)
	barrier := create_barrier(res_id, res, frame_offset, from, to)
	// Use ALL_COMMANDS for src/dst stages to avoid adding an execution dependency
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
				// Render attachment read-write (loadOp=LOAD / storeOp=STORE).
				// COLOR_ATTACHMENT_OPTIMAL is correct; it only requires COLOR_ATTACHMENT_BIT
				// (unlike SHADER_READ_ONLY_OPTIMAL which requires SAMPLED_BIT).
				state.last_stage = {.COLOR_ATTACHMENT_OUTPUT}
				state.last_access = {.COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE}
				state.last_layout = .COLOR_ATTACHMENT_OPTIMAL
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
