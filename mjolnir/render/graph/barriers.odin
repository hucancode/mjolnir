package render_graph

import "core:fmt"
import vk "vendor:vulkan"

// ============================================================================
// Barrier Computation
// ============================================================================

compute_barriers :: proc(graph: ^Graph) {
	// Resource state is keyed by *physical* ResourceInstanceId so that aliased
	// resources (which share the same VkImage/VkBuffer) automatically inherit
	// the correct Vulkan layout/stage from their alias target.
	//
	// When resource B aliases physical resource A:
	//   • B's first barrier uses A's final state as old_layout (correct).
	//   • B's accesses update the state under A's physical ID.
	//   • A third resource C aliasing A after B can then start from B's final state.
	resource_state := make(map[ResourceInstanceId]ResourceState)
	defer delete(resource_state)

	// Process passes in execution order
	for pass_id in graph.sorted_passes {
		pass := get_pass(graph, pass_id)

		// Emit barriers for all reads.
		// For resources declared via read_write_texture (appears in both reads and
		// writes), skip the read barrier — the write barrier handles the layout
		// transition.  The reads entry still creates the dependency edge in the DAG.
		for read in pass.reads {
			// Skip if also written by this pass (read_write_texture / read_write_buffer).
			is_also_written := false
			for write in pass.writes {
				if write.resource_name == read.resource_name {
					is_also_written = true
					break
				}
			}
			if is_also_written { continue }

			if read.frame_offset != .CURRENT {
				emit_memory_barrier(graph, pass_id, read.resource_name, read.frame_offset, .READ, pass.queue, &resource_state)
			} else {
				emit_full_barrier(graph, pass_id, read.resource_name, read.frame_offset, .READ, pass.queue, &resource_state)
			}
		}

		// Emit barriers for all writes
		for write in pass.writes {
			if write.frame_offset != .CURRENT {
				emit_memory_barrier(graph, pass_id, write.resource_name, write.frame_offset, .WRITE, pass.queue, &resource_state)
			} else {
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

// _phys_id returns the physical ResourceInstanceId for res_id, following one
// level of aliasing.  Aliased resources share state with their alias_target.
_phys_id :: proc(graph: ^Graph, res_id: ResourceInstanceId) -> ResourceInstanceId {
	res := get_resource(graph, res_id)
	if res.is_alias { return res.alias_target }
	return res_id
}

update_resource_state :: proc(
	pass:  ^PassInstance,
	state: ^map[ResourceInstanceId]ResourceState,
	graph: ^Graph,
) {
	// Update state for all writes
	for write in pass.writes {
		if write.frame_offset != .CURRENT { continue }

		res: ^ResourceInstance = nil
		phys: ResourceInstanceId
		if res_id, found := find_resource_by_name(graph, write.resource_name); found {
			res  = get_resource(graph, res_id)
			phys = _phys_id(graph, res_id)
		} else {
			continue
		}

		new_state := infer_resource_state_after_access(write.access_mode, pass.queue, res)
		(state^)[phys] = new_state
	}

	// Update state for pure reads (not part of a read_write_texture pair).
	for read in pass.reads {
		if read.frame_offset != .CURRENT { continue }

		is_also_written := false
		for write in pass.writes {
			if write.resource_name == read.resource_name {
				is_also_written = true
				break
			}
		}
		if is_also_written { continue }

		if pass.queue == .GRAPHICS {
			if res_id, found := find_resource_by_name(graph, read.resource_name); found {
				res   := get_resource(graph, res_id)
				phys  := _phys_id(graph, res_id)
				new_state := infer_resource_state_after_access(.READ, pass.queue, res)
				(state^)[phys] = new_state
			}
		}
	}
}

// ============================================================================
// Barrier Emission
// ============================================================================

emit_full_barrier :: proc(
	graph:         ^Graph,
	pass_id:       PassInstanceId,
	resource_name: string,
	frame_offset:  FrameOffset,
	access:        AccessMode,
	queue:         QueueType,
	state:         ^map[ResourceInstanceId]ResourceState,
) {
	res_id, found := find_resource_by_name(graph, resource_name)
	if !found { return }

	res     := get_resource(graph, res_id)
	phys    := _phys_id(graph, res_id)
	phys_res := get_resource(graph, phys)

	current_state, has_state := (state^)[phys]
	if !has_state {
		current_state = get_initial_resource_state(phys_res)
	}

	desired_state := infer_resource_state_before_access(access, queue, res)
	// Store physical ID in the barrier so executor resolves the actual handles
	// without needing to follow the alias chain at emit time.
	barrier := create_barrier(phys, phys_res, frame_offset, current_state, desired_state)
	add_barrier(graph, pass_id, barrier)
}

emit_memory_barrier :: proc(
	graph:         ^Graph,
	pass_id:       PassInstanceId,
	resource_name: string,
	frame_offset:  FrameOffset,
	access:        AccessMode,
	queue:         QueueType,
	state:         ^map[ResourceInstanceId]ResourceState,
) {
	res_id, found := find_resource_by_name(graph, resource_name)
	if !found { return }

	res      := get_resource(graph, res_id)
	phys     := _phys_id(graph, res_id)
	phys_res := get_resource(graph, phys)

	current_state, has_state := (state^)[phys]
	if !has_state {
		current_state = get_initial_resource_state(phys_res)
	}

	desired_state := infer_resource_state_before_access(access, queue, res)
	barrier := create_memory_barrier(phys, phys_res, frame_offset, current_state, desired_state)
	add_barrier(graph, pass_id, barrier)
}

// ============================================================================
// Barrier Creation
// ============================================================================

create_barrier :: proc(
	res_id: ResourceInstanceId,
	res:    ^ResourceInstance,
	frame_offset: FrameOffset,
	from:   ResourceState,
	to:     ResourceState,
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
	res:    ^ResourceInstance,
	frame_offset: FrameOffset,
	from:   ResourceState,
	to:     ResourceState,
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
		last_stage  = {.TOP_OF_PIPE},
		last_access = {},
		last_layout = .UNDEFINED,
		last_queue  = .GRAPHICS,
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
				state.last_stage  = {.EARLY_FRAGMENT_TESTS}
				state.last_access = {.DEPTH_STENCIL_ATTACHMENT_READ}
				state.last_layout = .DEPTH_STENCIL_READ_ONLY_OPTIMAL
			} else {
				state.last_stage  = {.FRAGMENT_SHADER}
				state.last_access = {.SHADER_READ}
				state.last_layout = .SHADER_READ_ONLY_OPTIMAL
			}
		case .WRITE:
			if is_depth {
				state.last_stage  = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS}
				state.last_access = {.DEPTH_STENCIL_ATTACHMENT_WRITE}
				state.last_layout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL
			} else {
				state.last_stage  = {.COLOR_ATTACHMENT_OUTPUT}
				state.last_access = {.COLOR_ATTACHMENT_WRITE}
				state.last_layout = .COLOR_ATTACHMENT_OPTIMAL
			}
		case .READ_WRITE:
			if is_depth {
				state.last_stage  = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS}
				state.last_access = {.DEPTH_STENCIL_ATTACHMENT_READ, .DEPTH_STENCIL_ATTACHMENT_WRITE}
				state.last_layout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL
			} else {
				// Render attachment read-write (loadOp=LOAD / storeOp=STORE).
				state.last_stage  = {.COLOR_ATTACHMENT_OUTPUT}
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
