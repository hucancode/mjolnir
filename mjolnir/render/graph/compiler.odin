package render_graph

import "core:log"
import vk "vendor:vulkan"

// Compile the graph: topo sort + dead pass elimination + barrier computation.
// Must be called after all resources and passes are registered.
compile :: proc(g: ^Graph) {
	// Clear previous compilation
	for &cp in g.compiled {
		delete(cp.image_barriers)
		delete(cp.buffer_barriers)
	}
	clear(&g.compiled)
	g.is_compiled = false

	// --- Step 1: Build adjacency list using progressive last_writer tracking ---
	// Process passes in declaration order so last_writer is deterministic.
	// last_writer[resource_id] = pass_id of most recent writer (updated as we go)
	last_writer := make(map[ResourceId]PassId, context.temp_allocator)
	// in_degree[pass_id] = number of passes that must complete first
	in_degree := make(map[PassId]int, context.temp_allocator)
	// edges[from_pass] = list of passes that depend on from_pass
	edges := make(map[PassId][dynamic]PassId, context.temp_allocator)
	defer {
		for _, &e in edges {
			delete(e)
		}
	}

	for id in g.pass_order {
		if !g.passes[id].enabled do continue
		in_degree[id] = 0
		edges[id] = make([dynamic]PassId, context.temp_allocator)
	}

	// Process each pass in declaration order:
	//   1. For each read: look up last_writer and add a dependency edge
	//   2. For each write: update last_writer to this pass
	for pass_id in g.pass_order {
		pass := g.passes[pass_id]
		if !pass.enabled do continue

		// Reads create dependency edges from previous writers
		for ra in pass.reads {
			// CameraData never creates a hard dependency edge
			if entry, has := g.resources[ra.resource_id]; has {
				if _, is_camera := entry.resource.(CameraData); is_camera {
					continue
				}
			}
			if writer, has := last_writer[ra.resource_id]; has && writer != pass_id {
				edge_list := edges[writer]
				append(&edge_list, pass_id)
				edges[writer] = edge_list
				in_degree[pass_id] += 1
			}
		}

		// Writes update last_writer (no edges created here)
		for wa in pass.writes {
			last_writer[wa.resource_id] = pass_id
		}
	}

	// --- Step 2: Topological sort (Kahn's algorithm) ---
	bfs_queue := make([dynamic]PassId, context.temp_allocator)
	for id in g.pass_order {
		if !g.passes[id].enabled do continue
		if in_degree[id] == 0 {
			append(&bfs_queue, id)
		}
	}

	sorted := make([dynamic]PassId, context.temp_allocator)
	queue_head := 0
	for queue_head < len(bfs_queue) {
		current := bfs_queue[queue_head]
		queue_head += 1
		append(&sorted, current)

		edge_list := edges[current]
		for dep in edge_list {
			in_degree[dep] -= 1
			if in_degree[dep] == 0 {
				append(&bfs_queue, dep)
			}
		}
	}

	enabled_count := 0
	for id in g.pass_order {
		if g.passes[id].enabled do enabled_count += 1
	}
	if len(sorted) != enabled_count {
		log.error("Render graph has a cycle! Compilation failed.")
		return
	}

	// --- Step 3: Dead pass elimination ---
	// Find all resources of type Swapchain
	swapchain_resources := make(map[ResourceId]bool, context.temp_allocator)
	for id, entry in g.resources {
		if _, ok := entry.resource.(SwapchainResource); ok {
			swapchain_resources[id] = true
		}
	}

	// Mark passes that write to swapchain as live seeds
	live := make(map[PassId]bool, context.temp_allocator)
	for pass_id in sorted {
		pass := g.passes[pass_id]
		for wa in pass.writes {
			if swapchain_resources[wa.resource_id] {
				live[pass_id] = true
			}
		}
	}

	// Walk backwards: if a pass is live, mark all its predecessors as live.
	// Use the forward edges map: find all from_id that have an edge to pass_id.
	for i := len(sorted) - 1; i >= 0; i -= 1 {
		pass_id := sorted[i]
		if !live[pass_id] do continue
		for from_id in g.pass_order {
			if !g.passes[from_id].enabled do continue
			for to_id in edges[from_id] {
				if to_id == pass_id {
					live[from_id] = true
					break
				}
			}
		}
	}

	// --- Step 4: Barrier computation ---
	resource_states := make(map[ResourceId]ResourceState, context.temp_allocator)

	for pass_id in sorted {
		if !live[pass_id] do continue

		pass := g.passes[pass_id]
		cp := CompiledPass {
			pass_id         = pass_id,
			queue           = pass.queue,
			image_barriers  = make([dynamic]ImageBarrierInfo),
			buffer_barriers = make([dynamic]BufferBarrierInfo),
		}

		// Process all resource accesses (reads and writes)
		process_access :: proc(
			g: ^Graph,
			cp: ^CompiledPass,
			resource_states: ^map[ResourceId]ResourceState,
			ra: ResourceAccess,
			queue: QueueType,
		) {
			entry, has := g.resources[ra.resource_id]
			if !has do return

			// CameraData never needs barriers
			if _, is_camera := entry.resource.(CameraData); is_camera do return

			required_state, aspect := infer_required_state(entry.resource, ra.access, queue)

			// Check if we're a buffer or image resource
			switch _ in entry.resource {
			case BufferResource:
				current, has_state := resource_states[ra.resource_id]
				if !has_state {
					current = INITIAL_RESOURCE_STATE
				}
				// Only emit barrier if state changes
				if current.access != required_state.access || current.stage != required_state.stage {
					append(
						&cp.buffer_barriers,
						BufferBarrierInfo {
							resource_id = ra.resource_id,
							src_access  = current.access,
							dst_access  = required_state.access,
							src_stage   = current.stage,
							dst_stage   = required_state.stage,
						},
					)
					resource_states[ra.resource_id] = required_state
				}

			case ColorTexture, DepthTexture, CubeTexture, SwapchainResource:
				current, has_state := resource_states[ra.resource_id]
				if !has_state {
					current = INITIAL_RESOURCE_STATE
				}
				// Only emit barrier if state changes
				if current.layout != required_state.layout ||
				   current.access != required_state.access ||
				   current.stage != required_state.stage {
					append(
						&cp.image_barriers,
						ImageBarrierInfo {
							resource_id = ra.resource_id,
							old_state   = current,
							new_state   = required_state,
							aspect_mask = aspect,
							layer_count = 1,
						},
					)
					resource_states[ra.resource_id] = required_state
				}

			case CameraData:
				// No barrier needed
			}
		}

		// Process reads first (establishes required state before pass runs).
		// For READ_WRITE resources these are also in writes, but the second
		// process_access call is a no-op since the state is already set.
		for ra in pass.reads {
			process_access(g, &cp, &resource_states, ra, pass.queue)
		}
		for wa in pass.writes {
			process_access(g, &cp, &resource_states, wa, pass.queue)
		}

		append(&g.compiled, cp)
	}

	g.is_compiled = true
	log.infof("Render graph compiled: %d live passes", len(g.compiled))
}
