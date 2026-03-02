package render_graph

import "core:fmt"
import "core:slice"
import "core:strings"
import vk "vendor:vulkan"

// ============================================================================
// Main Compilation Entry Point
// ============================================================================

compile :: proc(
	pass_decls: []PassDecl,
	ctx: CompileContext,
	loc := #caller_location,
) -> (graph: Graph, err: CompileError) {
	// Initialize graph
	init(&graph, ctx.frames_in_flight)

	// Store handle mappings
	graph.camera_handles = slice.clone(ctx.camera_handles)
	graph.light_handles = slice.clone(ctx.light_handles)

	// Step 1: Instantiate passes based on scope
	instances := instantiate_passes(pass_decls, ctx) or_return

	// Step 2: Run setup callbacks to collect resource declarations
	// IMPORTANT: All passes share the same resources array so later passes
	// can find resources registered by earlier passes via find_texture/find_buffer
	all_resources: [dynamic]ResourceDecl
	defer delete(all_resources)

	// Tracks the current write-version for each resource, incremented on each write.
	// Version numbers let build_dependency_edges resolve "which pass wrote what I read"
	// as a direct O(1) lookup instead of a nearest-predecessor search.
	resource_versions := make(map[string]u32)
	defer delete(resource_versions)

	for &instance in instances {
		// All passes share the same _resources array so later passes can find
		// resources declared by earlier passes via find_texture/find_buffer.
		// After each callback we recover the (potentially reallocated) array header.
		setup := PassSetup{
			pass_name      = instance.name,
			pass_scope     = instance.scope,
			instance_idx   = instance.instance,
			num_cameras    = ctx.num_cameras,
			num_lights     = ctx.num_lights,
			camera_extents = ctx.camera_extents,
			light_is_point = ctx.light_is_point,
			_resources     = all_resources,
			_reads         = make([dynamic]ResourceAccess),
			_writes        = make([dynamic]ResourceAccess),
		}

		// Find which PassDecl this instance came from by matching the base name
		decl_idx := -1
		for decl, idx in pass_decls {
			if instance.scope == .GLOBAL && instance.name == decl.name {
				decl_idx = idx
				break
			} else if instance.scope == .PER_CAMERA && strings.has_prefix(instance.name, fmt.tprintf("%s_cam_", decl.name)) {
				decl_idx = idx
				break
			} else if instance.scope == .PER_LIGHT && strings.has_prefix(instance.name, fmt.tprintf("%s_light_", decl.name)) {
				decl_idx = idx
				break
			}
		}

		if decl_idx == -1 {
			fmt.eprintf("ERROR: Could not find PassDecl for instance '%s'\n", instance.name)
			delete(setup._reads)
			delete(setup._writes)
			continue
		}

		if pass_decls[decl_idx].setup != nil {
			pass_decls[decl_idx].setup(&setup, instance.user_data)
		}

		// Recover shared resources array (may have reallocated during append)
		all_resources = setup._resources

		// Assign versions: reads capture the version currently produced, writes mint the next.
		// Must process reads before writes so a READ_WRITE pass reads version N then produces N+1.
		for &read in setup._reads {
			if read.frame_offset == .CURRENT {
				read.version = resource_versions[read.resource_name]
			}
		}
		for &write in setup._writes {
			if write.frame_offset == .CURRENT {
				resource_versions[write.resource_name] += 1
				write.version = resource_versions[write.resource_name]
			}
		}

		// Instance takes ownership of the reads/writes arrays
		instance.reads  = setup._reads
		instance.writes = setup._writes
	}

	// Step 3: Create resource instances
	resource_map := make(map[string]ResourceInstanceId, len(all_resources))
	defer delete(resource_map)

	for res_decl in all_resources {
		// Check if resource already exists (multiple passes can create same resource)
		if _, exists := resource_map[res_decl.name]; exists {
			// Free the duplicate heap-allocated name (non-GLOBAL names are fmt.aprintf'd)
			if res_decl.scope != .GLOBAL do delete(res_decl.name)
			continue
		}

		res_instance := ResourceInstance{
			name = res_decl.name,
			type = res_decl.type,
			scope = res_decl.scope,
			instance_idx = res_decl.instance_idx,
			texture_desc = res_decl.texture_desc,
			buffer_desc = res_decl.buffer_desc,
			buffers = make([dynamic]vk.Buffer),
			buffer_memory = make([dynamic]vk.DeviceMemory),
			images = make([dynamic]vk.Image),
			image_views = make([dynamic]vk.ImageView),
		}

		id := add_resource_instance(&graph, res_instance)
		resource_map[res_decl.name] = id
	}

	// Step 4: Add pass instances to graph
	for instance in instances {
		add_pass_instance(&graph, instance)
	}

	// Step 5: Validate graph
	validate_graph(&graph, resource_map) or_return

	// Step 6: Build dependency edges
	edges := build_dependency_edges(&graph, resource_map)
	defer {
		for _, edge_list in edges {
			delete(edge_list)
		}
		delete(edges)
	}

	// Step 7: Eliminate dead passes
	live_passes := eliminate_dead_passes(&graph, edges)
	defer delete(live_passes)

	when ODIN_DEBUG {
		fmt.println("\n=== DEAD PASS ELIMINATION ===")
		for &pass, idx in graph.pass_instances {
			status := live_passes[idx] ? "LIVE" : "DEAD"
			fmt.printf("[%s] %s\n", status, pass.name)
		}
		fmt.println("=============================\n")
	}

	// Step 8: Topological sort
	sorted := topological_sort(&graph, edges, live_passes) or_return
	defer delete(sorted)

	// Step 9: Set execution order
	set_execution_order(&graph, sorted[:])

	return graph, .NONE
}

// ============================================================================
// Pass Instantiation
// ============================================================================

instantiate_passes :: proc(
	pass_decls: []PassDecl,
	ctx: CompileContext,
	loc := #caller_location,
) -> (instances: [dynamic]PassInstance, err: CompileError) {
	instances = make([dynamic]PassInstance)

	for decl in pass_decls {
		switch decl.scope {
		case .GLOBAL:
			append(&instances, PassInstance{
				name      = decl.name,
				scope     = decl.scope,
				instance  = 0,
				queue     = decl.queue,
				execute   = decl.execute,
				user_data = decl.user_data,
			})

		case .PER_CAMERA:
			for cam_idx in 0..<ctx.num_cameras {
				append(&instances, PassInstance{
					name      = fmt.aprintf("%s_cam_%d", decl.name, cam_idx),
					scope     = decl.scope,
					instance  = u32(cam_idx),
					queue     = decl.queue,
					execute   = decl.execute,
					user_data = decl.user_data,
				})
			}

		case .PER_LIGHT:
			for light_idx in 0..<ctx.num_lights {
				append(&instances, PassInstance{
					name      = fmt.aprintf("%s_light_%d", decl.name, light_idx),
					scope     = decl.scope,
					instance  = u32(light_idx),
					queue     = decl.queue,
					execute   = decl.execute,
					user_data = decl.user_data,
				})
			}
		}
	}

	return instances, .NONE
}

// ============================================================================
// Graph Validation
// ============================================================================

validate_graph :: proc(
	graph: ^Graph,
	resource_map: map[string]ResourceInstanceId,
	loc := #caller_location,
) -> CompileError {
	// Build set of all written resources (with frame offsets)
	written_resources := make(map[string]bool)
	defer delete(written_resources)

	for &pass in graph.pass_instances {
		for write in pass.writes {
			written_resources[write.resource_name] = true
		}
	}

	// Check for dangling reads (read without corresponding write)
	for &pass in graph.pass_instances {
		for read in pass.reads {
			// Check if resource exists
			if _, exists := resource_map[read.resource_name]; !exists {
				fmt.eprintf("ERROR: Pass '%s' reads non-existent resource '%s'\n",
					pass.name, read.resource_name)
				return .DANGLING_READ
			}

			// For CURRENT/PREV reads, ensure someone writes it
			if read.frame_offset == .CURRENT || read.frame_offset == .PREV {
				if _, written := written_resources[read.resource_name]; !written {
					fmt.eprintf("ERROR: Pass '%s' reads resource '%s' that no one writes\n",
						pass.name, read.resource_name)
					return .DANGLING_READ
				}
			}
		}
	}

	// TODO: Add more validation
	// - Frame offset consistency (PREV requires NEXT writes)
	// - Type matching (TextureId used with textures only)

	return .NONE
}

// ============================================================================
// Dependency Edge Building
// ============================================================================

build_dependency_edges :: proc(
	graph: ^Graph,
	resource_map: map[string]ResourceInstanceId,
	loc := #caller_location,
) -> map[PassInstanceId][dynamic]PassInstanceId {
	edges := make(map[PassInstanceId][dynamic]PassInstanceId)

	// Initialize edge list for every pass (so sinks appear in the map)
	for i in 0..<len(graph.pass_instances) {
		edges[PassInstanceId(i)] = make([dynamic]PassInstanceId)
	}

	// Pass 1: build version → writer map.
	// writers[name] is a list where writers[name][version-1] is the pass that produced that version.
	// Version numbers are 1-based and assigned sequentially in compile(), so the list grows by one
	// per write and has no gaps.
	writers := make(map[string][dynamic]PassInstanceId)
	defer {
		for _, list in writers {
			delete(list)
		}
		delete(writers)
	}

	for &pass, pass_idx in graph.pass_instances {
		for write in pass.writes {
			if write.frame_offset == .CURRENT && write.version > 0 {
				list := writers[write.resource_name]
				append(&list, PassInstanceId(pass_idx))
				writers[write.resource_name] = list
			}
		}
	}

	// Pass 2: for each CURRENT read, find the pass that produced the version being read.
	// This is an O(1) lookup: read.version is the exact version assigned during setup.
	// READ_WRITE chains (A-writes v1, B-reads v1 and writes v2, C-reads v2 ...) produce
	// the correct linear ordering A→B→C automatically.
	for &pass, pass_idx in graph.pass_instances {
		pass_id := PassInstanceId(pass_idx)
		for read in pass.reads {
			if read.frame_offset != .CURRENT || read.version == 0 do continue
			writer_list, found := writers[read.resource_name]
			if !found || int(read.version) > len(writer_list) do continue

			writer_id := writer_list[read.version - 1]
			if writer_id == pass_id do continue // skip self

			// Deduplicate
			already := false
			for existing in edges[writer_id] {
				if existing == pass_id { already = true; break }
			}
			if !already do append(&edges[writer_id], pass_id)
		}
	}

	when ODIN_DEBUG {
		fmt.println("[GRAPH] Dependency edges:")
		for from_id, to_list in edges {
			from_pass := &graph.pass_instances[from_id]
			if len(to_list) == 0 {
				fmt.printf("  %s → (no downstream consumers)\n", from_pass.name)
			} else {
				for to_id in to_list {
					to_pass := &graph.pass_instances[to_id]
					fmt.printf("  %s → %s\n", from_pass.name, to_pass.name)
				}
			}
		}
	}

	return edges
}

// ============================================================================
// Dead Pass Elimination
// ============================================================================

eliminate_dead_passes :: proc(
	graph: ^Graph,
	edges: map[PassInstanceId][dynamic]PassInstanceId,
	loc := #caller_location,
) -> [dynamic]bool {
	// Mark all passes as dead initially
	live := make([dynamic]bool, len(graph.pass_instances))
	for i in 0..<len(live) {
		live[i] = false
	}

	// Mark passes that write to external outputs as live
	for &pass, idx in graph.pass_instances {
		// Heuristic: passes with no downstream consumers are "sinks" (final outputs)
		pass_id := PassInstanceId(idx)
		if pass_id not_in edges || len(edges[pass_id]) == 0 {
			live[idx] = true
			when ODIN_DEBUG { fmt.printf("[GRAPH] Sink pass (no downstream): %s\n", pass.name) }
		}
	}

	// Propagate liveness backward through dependencies
	changed := true
	for changed {
		changed = false

		for &pass, idx in graph.pass_instances {
			if live[idx] {
				pass_id := PassInstanceId(idx)

				// Mark all dependencies as live
				for read in pass.reads {
					// Find who writes this resource
					for &other_pass, other_idx in graph.pass_instances {
						if live[other_idx] {
							continue
						}

						for write in other_pass.writes {
							if write.resource_name == read.resource_name {
								when ODIN_DEBUG {
									fmt.printf("[GRAPH] Marking %s as live (writes %s for %s)\n",
										other_pass.name, write.resource_name, pass.name)
								}
								live[other_idx] = true
								changed = true
							}
						}
					}
				}
			}
		}
	}

	when ODIN_DEBUG {
		fmt.println("[GRAPH] Dead pass elimination results:")
		for &pass, idx in graph.pass_instances {
			if live[idx] {
				fmt.printf("  ✓ LIVE: %s\n", pass.name)
			} else {
				fmt.printf("  ✗ DEAD: %s (eliminated)\n", pass.name)
			}
		}
	}

	return live
}

// ============================================================================
// Topological Sort (Kahn's Algorithm)
// ============================================================================

topological_sort :: proc(
	graph: ^Graph,
	edges: map[PassInstanceId][dynamic]PassInstanceId,
	live: [dynamic]bool,
	loc := #caller_location,
) -> (sorted: [dynamic]PassInstanceId, err: CompileError) {
	// Compute in-degree for each pass
	in_degree := make([dynamic]int, len(graph.pass_instances))
	defer delete(in_degree)

	for i in 0..<len(in_degree) {
		in_degree[i] = 0
	}

	// Count incoming edges
	for from_id, to_list in edges {
		if !live[from_id] {
			continue
		}

		for to_id in to_list {
			if !live[to_id] {
				continue
			}
			in_degree[to_id] += 1
		}
	}

	// Initialize queue with nodes that have no incoming edges
	queue := make([dynamic]PassInstanceId)
	defer delete(queue)

	for i in 0..<len(in_degree) {
		if live[i] && in_degree[i] == 0 {
			append(&queue, PassInstanceId(i))
		}
	}

	// Process queue
	sorted = make([dynamic]PassInstanceId)

	for len(queue) > 0 {
		// Pop from queue
		current := queue[0]
		ordered_remove(&queue, 0)

		append(&sorted, current)

		// Decrease in-degree of neighbors
		if current in edges {
			for neighbor in edges[current] {
				if !live[neighbor] {
					continue
				}

				in_degree[neighbor] -= 1

				if in_degree[neighbor] == 0 {
					append(&queue, neighbor)
				}
			}
		}
	}

	// Check if all live passes were processed (no cycles)
	live_count := 0
	for is_live in live {
		if is_live do live_count += 1
	}

	if len(sorted) < live_count {
		fmt.eprintf("ERROR: Cyclic graph detected\n")
		delete(sorted)
		return {}, .CYCLE_DETECTED
	}

	return sorted, .NONE
}
